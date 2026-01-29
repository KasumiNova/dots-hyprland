pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import qs.modules.common
import qs.modules.common.functions

/**
 * SPlayer lyrics service.
 *
 * Runs a small Node WS bridge process and exposes current main+translated lyric.
 */
Singleton {
    id: root

    readonly property bool enabled: (Config.options?.bar?.lyrics?.enable ?? false)
    readonly property string wsUrl: (Config.options?.bar?.lyrics?.wsUrl ?? "ws://localhost:25885")
    readonly property int offsetMs: (Config.options?.bar?.lyrics?.offsetMs ?? 0)

    property bool connected: false
    property string main: ""
    property string translation: ""
    // Full lyric timeline (per-line timestamps). Populated from the bridge.
    // Each item: {start,end,main,translation,segments,isBG}
    property var timeline: []
    // Predicted playhead time in ms (smooth between WS ticks)
    property int time: 0
    // Last raw time reported by API (without offsetMs).
    property int _reportedTime: 0
    property real _reportedAtMs: 0
    // Anchor used for QS-side free-running clock.
    // Predicted time = _anchorTime + (now - _anchorAtMs) * _playbackRate
    property int _anchorTime: 0
    property real _anchorAtMs: 0
    // Estimated playback rate (ms/ms). 1.0 ~= normal playback.
    property real _playbackRate: 1.0
    // Estimated interval between API updates (ms). Used to adapt animation duration.
    property int updateIntervalMs: 150
    // Current timeline index inferred from QS time.
    property int _currentIndex: -1
    property int lineStart: 0
    property int lineEnd: 0
    property int lineDuration: 0
    // 0..1 when available; -1 means "not provided"
    property real lineProgress: -1
    // Per-word timing segments for karaoke lyrics when available.
    // [{text,start,end,roman}]
    property var segments: []
    // True when we just transitioned to a new lyric line (for faster initial animation).
    property bool isTransition: false
    property string lastError: ""

    // Drift control: only hard-snap when the API time diverges a lot.
    readonly property int _snapThresholdMs: 900
    readonly property int _seekThresholdMs: 2500
    readonly property int _silenceSnapAfterMs: 3500

    function _clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
    }

    function _findTimelineIndex(lines, timeMs) {
        if (!Array.isArray(lines) || lines.length === 0) return -1;

        // Binary search: last line with start <= timeMs
        let lo = 0;
        let hi = lines.length - 1;
        let best = -1;
        while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            const s = Number(lines[mid]?.start ?? -1);
            if (s <= timeMs) {
                best = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        if (best < 0) return -1;
        const end = Number(lines[best]?.end ?? -1);
        if (!(end > timeMs)) return -1;
        return best;
    }

    function _applyIndex(idx) {
        if (idx === root._currentIndex) return;

        root._currentIndex = idx;
        root.isTransition = (idx >= 0);
        transitionClearTimer.restart();

        if (idx < 0) {
            root.main = "";
            root.translation = "";
            root.lineStart = 0;
            root.lineEnd = 0;
            root.lineDuration = 0;
            root.lineProgress = -1;
            root.segments = [];
            return;
        }

        const line = root.timeline[idx] ?? ({});
        root.main = (line.main ?? "");
        root.translation = (line.translation ?? "");
        root.lineStart = Number(line.start ?? 0);
        root.lineEnd = Number(line.end ?? 0);
        root.lineDuration = Math.max(0, root.lineEnd - root.lineStart);
        root.segments = (Array.isArray(line.segments) ? line.segments : []);
    }

    function _snapToReported(rawTimeMs, nowMs) {
        // Store raw for debug/telemetry.
        root._reportedTime = rawTimeMs;
        root._reportedAtMs = nowMs;

        // Anchor includes offsetMs so the entire UI shifts consistently.
        root._anchorTime = rawTimeMs + root.offsetMs;
        root._anchorAtMs = nowMs;
    }

    function _softCorrectToReported(rawTimeMs, nowMs) {
        // Always keep last raw sample.
        root._reportedTime = rawTimeMs;
        root._reportedAtMs = nowMs;

        const reported = rawTimeMs + root.offsetMs;
        const age = nowMs - (root._anchorAtMs || 0);
        const predicted = (age >= 0)
            ? (root._anchorTime + age * (root._playbackRate || 1.0))
            : root._anchorTime;
        const drift = reported - predicted;

        // Nudge the clock a bit toward the reported time to prevent slow drift,
        // without visible snapping. Re-anchor at now to keep the timer stable.
        const correctedNow = predicted + drift * 0.25;
        root._anchorTime = Math.round(correctedNow);
        root._anchorAtMs = nowMs;
    }

    function clearLyrics() {
        root.main = "";
        root.translation = "";
        root.timeline = [];
        root.time = 0;
        root._reportedTime = 0;
        root._reportedAtMs = 0;
        root._anchorTime = 0;
        root._anchorAtMs = 0;
        root._currentIndex = -1;
        root.lineStart = 0;
        root.lineEnd = 0;
        root.lineDuration = 0;
        root.lineProgress = -1;
        root.segments = [];
    }

    function restart() {
        // Toggle running to restart with new arguments.
        bridge.running = false;
        root.connected = false;
        root.lastError = "";
        root.clearLyrics();

        if (!root.enabled || !(Config?.ready ?? false)) {
            return;
        }

        // Small delay avoids rapid restart loops when options change.
        restartTimer.restart();
    }

    onEnabledChanged: restart()
    onWsUrlChanged: restart()

    Timer {
        id: playheadTimer
        // Drive fill progress smoothly; 16ms ~= 60fps.
        interval: 16
        repeat: true
        running: root.enabled && root.connected
        onTriggered: {
            const now = Date.now();

            const age = now - (root._anchorAtMs || 0);

            // If we haven't received progress recently (pause/stop), don't keep advancing.
            const predicted = (age >= 0 && age < root._silenceSnapAfterMs)
                ? (root._anchorTime + age * (root._playbackRate || 1.0))
                : root._anchorTime;

            root.time = Math.round(predicted);

            // Drive current line from the full timeline.
            const idx = root._findTimelineIndex(root.timeline, root.time);
            root._applyIndex(idx);

            if (idx >= 0 && root.lineStart >= 0 && root.lineEnd > root.lineStart) {
                const dur = root.lineEnd - root.lineStart;
                const p = (root.time - root.lineStart) / dur;
                root.lineProgress = root._clamp(p, 0, 1);
            } else {
                root.lineProgress = -1;
            }
        }
    }

    Timer {
        id: restartTimer
        interval: 200
        repeat: false
        onTriggered: {
            if (!root.enabled || !(Config?.ready ?? false)) return;
            bridge.running = true;
        }
    }

    Timer {
        id: crashBackoff
        interval: 1500
        repeat: false
        onTriggered: {
            if (!root.enabled || !(Config?.ready ?? false)) return;
            bridge.running = true;
        }
    }

    Timer {
        id: transitionClearTimer
        interval: 200
        repeat: false
        onTriggered: {
            root.isTransition = false;
        }
    }

    Process {
        id: bridge

        running: root.enabled && (Config?.ready ?? false)
        command: [
            "node",
            `${Directories.scriptPath}/splayer/splayer-lyrics-bridge.js`,
            "--url",
            root.wsUrl,
            "--cache",
            `${FileUtils.trimFileProtocol(Directories.cache)}/quickshell/splayer-lyrics-cache.json`,
        ]

        stdout: SplitParser {
            onRead: line => {
                const trimmed = (line ?? "").trim();
                if (trimmed.length === 0) return;

                let msg;
                try {
                    msg = JSON.parse(trimmed);
                } catch (e) {
                    root.lastError = `Parse error: ${e}`;
                    return;
                }

                if (!msg || typeof msg.type !== "string") return;

                if (msg.type === "status") {
                    root.connected = !!msg.connected;
                    if (msg.error) root.lastError = `${msg.error}`;
                    if (!root.connected) {
                        // Keep timeline cached in memory, but stop animation.
                        root._anchorAtMs = 0;
                        root.time = root._anchorTime;
                    }
                } else if (msg.type === "timeline") {
                    // Full timeline update from SPlayer API (or cache).
                    const newLines = Array.isArray(msg.lines) ? msg.lines : [];
                    root.timeline = newLines;
                    // Force re-apply current index on next tick.
                    root._currentIndex = -2;
                } else if (msg.type === "lyrics") {
                    // Backward-compatible: if timeline is unavailable, fall back.
                    if (!Array.isArray(root.timeline) || root.timeline.length === 0) {
                        root.main = (msg.main ?? "");
                        root.translation = (msg.translation ?? "");
                        root.lineStart = msg.lineStart ?? 0;
                        root.lineEnd = msg.lineEnd ?? 0;
                        root.lineDuration = msg.lineDuration ?? 0;
                        root.segments = (Array.isArray(msg.segments) ? msg.segments : []);
                    }
                } else if (msg.type === "progress") {
                    const newRaw = Number(msg.time ?? root._reportedTime);
                    const now = Date.now();

                    // Update playback rate estimate.
                    const prevT = root._reportedTime;
                    const prevAt = root._reportedAtMs;
                    const dms = now - (prevAt || 0);
                    const dt = newRaw - (prevT || 0);
                    if (dms > 30 && dms < 2000 && Number.isFinite(dt)) {
                        // Track update interval for adaptive animation.
                        root.updateIntervalMs = Math.round(dms);
                        // Rate estimate; dt can be 0 during pause.
                        if (dt >= 0) {
                            const r = dt / dms;
                            const clamped = root._clamp(r, 0, 1.25);
                            // Light smoothing to avoid jitter.
                            root._playbackRate = root._clamp(root._playbackRate * 0.8 + clamped * 0.2, 0, 1.25);
                        }
                    }

                    const seeked = !!msg.seeked;
                    const noAnchorYet = !(root._anchorAtMs > 0);
                    const anchorAge = now - (root._anchorAtMs || 0);
                    const isSilence = anchorAge > root._silenceSnapAfterMs;
                    const isSeekJump = Math.abs(dt) > root._seekThresholdMs;

                    if (noAnchorYet || isSilence || seeked || isSeekJump) {
                        root._snapToReported(newRaw, now);
                    } else {
                        // Decide whether to snap or gently correct.
                        const predictedNow = root._anchorTime + (now - root._anchorAtMs) * (root._playbackRate || 1.0);
                        const reportedNow = newRaw + root.offsetMs;
                        const drift = reportedNow - predictedNow;
                        if (Math.abs(drift) > root._snapThresholdMs) {
                            root._snapToReported(newRaw, now);
                        } else {
                            root._softCorrectToReported(newRaw, now);
                        }
                    }
                }
            }
        }

        stderr: SplitParser {
            onRead: line => {
                const trimmed = (line ?? "").trim();
                if (trimmed.length === 0) return;
                // Keep the last stderr line for quick diagnostics.
                root.lastError = trimmed;
            }
        }

        onExited: (exitCode, exitStatus) => {
            root.connected = false;
            if (!root.enabled) return;

            // If the bridge crashes, attempt to restart.
            bridge.running = false;
            crashBackoff.restart();
        }
    }
}
