pragma Singleton
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
    // Pause/playing inference.
    property bool paused: false
    property int _sameTimeStreak: 0
    property real _lastProgressAtMs: 0
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

    function _setPaused(isPaused, nowMs) {
        const v = !!isPaused;
        if (v === root.paused) return;
        root.paused = v;
        if (root.paused) {
            // Freeze playhead.
            root._playbackRate = 0;
            // Re-anchor to the last reported time if available.
            if (root._reportedAtMs > 0) {
                root._snapToReported(root._reportedTime, nowMs);
            } else {
                root._anchorAtMs = nowMs;
            }
        } else {
            // Resume: ensure we can advance immediately.
            if (!(root._playbackRate > 0)) root._playbackRate = 1.0;
        }
    }

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
            const item = lines[mid];
            const sRaw = Number((item && item.start != null) ? item.start : NaN);
            const s = isFinite(sRaw) ? sRaw : 1e18;
            if (s <= timeMs) {
                best = mid;
                lo = mid + 1;
            } else {
                hi = mid - 1;
            }
        }
        // IMPORTANT:
        // Select the last-started line purely by `start`.
        // `end` is only used for progress calculation (fill), not for switching lines.
        // This makes the lyric stay visible during gaps (line ended but next hasn't started).
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

        const line = (Array.isArray(root.timeline) && root.timeline[idx] != null) ? root.timeline[idx] : ({});
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

            const stalled = (root._lastProgressAtMs > 0)
                ? ((now - root._lastProgressAtMs) > root._silenceSnapAfterMs)
                : false;

            // If the progress stream stalls, keep animating unless we believe playback is paused.
            // This prevents mid-line freezes on WS hiccups, while still stopping on pause.
            const shouldFreeze = stalled && root.paused;
            const predicted = (!shouldFreeze && age >= 0)
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

                    // If the new song has no lyrics (instrumental / missing), clear UI state.
                    if (newLines.length === 0) {
                        root._currentIndex = -1;
                        root.main = "";
                        root.translation = "";
                        root.lineStart = 0;
                        root.lineEnd = 0;
                        root.lineDuration = 0;
                        root.lineProgress = -1;
                        root.segments = [];
                    }
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

                    root._lastProgressAtMs = now;

                    // Update playback rate estimate.
                    const prevT = root._reportedTime;
                    const prevAt = root._reportedAtMs;
                    const dms = now - (prevAt || 0);
                    const dt = newRaw - (prevT || 0);
                    if (dms > 30 && dms < 2000 && Number.isFinite(dt)) {
                        // Track update interval for adaptive animation.
                        root.updateIntervalMs = Math.round(dms);

                        // Pause inference: consecutive identical timestamps.
                        if (dt === 0) {
                            root._sameTimeStreak = (root._sameTimeStreak || 0) + 1;
                            if (root._sameTimeStreak >= 3) {
                                root._setPaused(true, now);
                            }
                        } else {
                            root._sameTimeStreak = 0;
                            // Any forward movement implies playing.
                            if (dt > 0) root._setPaused(false, now);
                        }

                        // Rate estimate; only update when playing.
                        if (!root.paused && dt >= 0) {
                            const r = dt / dms;
                            const clamped = root._clamp(r, 0, 1.25);
                            // If we were near-zero (e.g. just resumed), jump closer to real speed.
                            if (root._playbackRate < 0.4) {
                                root._playbackRate = clamped;
                            } else {
                                // Light smoothing to avoid jitter.
                                root._playbackRate = root._clamp(root._playbackRate * 0.8 + clamped * 0.2, 0, 1.25);
                            }
                        }
                    }

                    const seeked = !!msg.seeked;
                    const noAnchorYet = !(root._anchorAtMs > 0);
                    const anchorAge = now - (root._anchorAtMs || 0);
                    const isSilence = anchorAge > root._silenceSnapAfterMs;
                    const isSeekJump = Math.abs(dt) > root._seekThresholdMs;

                    if (seeked || isSeekJump) {
                        root._sameTimeStreak = 0;
                        root._setPaused(false, now);
                    }

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
                } else if (msg.type === "player") {
                    // Best-effort pause detection from status-change payload.
                    const d = msg.data;
                    let paused = null;
                    if (d && typeof d === "object") {
                        if (typeof d.paused === "boolean") {
                            paused = d.paused;
                        } else if (typeof d.playing === "boolean") {
                            paused = !d.playing;
                        } else if (typeof d.isPlaying === "boolean") {
                            paused = !d.isPlaying;
                        } else if (typeof d.status === "boolean") {
                            // Observed from SPlayer: {status: true/false}
                            paused = !d.status;
                        } else if (typeof d.state === "string") {
                            const s = d.state.toLowerCase();
                            if (s.indexOf("pause") >= 0 || s.indexOf("stop") >= 0) paused = true;
                            if (s.indexOf("play") >= 0) paused = false;
                        } else if (typeof d.status === "string") {
                            const s2 = d.status.toLowerCase();
                            if (s2.indexOf("pause") >= 0 || s2.indexOf("stop") >= 0) paused = true;
                            if (s2.indexOf("play") >= 0) paused = false;
                        }
                    }
                    if (paused !== null) {
                        root._sameTimeStreak = 0;
                        root._setPaused(paused, Date.now());
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
