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
    // Pause/playing inference.
    property bool paused: false
    property int _sameTimeStreak: 0
    property real _lastProgressAtMs: 0
    property real _lastMovingAtMs: 0
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

    // If predicted time diverges from a new report by more than this, treat it as a seek.
    readonly property int _seekThreshold: 2000
    // If no progress arrives for this long, stop advancing the predicted time.
    readonly property int _stallTimeoutMs: 3000

    function _setPaused(isPaused, nowMs) {
        const v = !!isPaused;
        if (v === root.paused) return;
        root.paused = v;
        if (root.paused && root._reportedAtMs > 0) {
            // Freeze: snap to last known position.
            root.time = Math.round(root._reportedTime + root.offsetMs);
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

    function clearLyrics() {
        root.main = "";
        root.translation = "";
        root.timeline = [];
        root.time = 0;
        root._reportedTime = 0;
        root._reportedAtMs = 0;
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

            if (root.paused || !(root._reportedAtMs > 0)) {
                // Frozen or no data yet: hold at last reported position.
                root.time = Math.round(root._reportedTime + root.offsetMs);
            } else {
                const elapsed = now - root._reportedAtMs;
                // Stall guard: if no progress tick for too long, stop advancing.
                const stalled = (root._lastProgressAtMs > 0)
                    && ((now - root._lastProgressAtMs) > root._stallTimeoutMs);
                if (stalled) {
                    root.time = Math.round(root._reportedTime + root.offsetMs);
                } else {
                    // Simple linear extrapolation at 1× speed.
                    root.time = Math.round(root._reportedTime + root.offsetMs + elapsed);
                }
            }

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
                        // Keep timeline cached in memory, but stop advancing.
                        root._reportedAtMs = 0;
                        root.time = Math.round(root._reportedTime + root.offsetMs);
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
                    const newRaw = Number(msg.time ?? 0);
                    const now = Date.now();

                    root._lastProgressAtMs = now;

                    // --- Pause inference ---
                    const prevT = root._reportedTime;
                    const dt = newRaw - prevT;

                    if (dt > 0) {
                        root._lastMovingAtMs = now;
                        root._sameTimeStreak = 0;
                        root._setPaused(false, now);
                    } else if (dt === 0) {
                        root._sameTimeStreak = (root._sameTimeStreak || 0) + 1;
                        const lastMove = (root._lastMovingAtMs > 0) ? root._lastMovingAtMs : now;
                        if (root._sameTimeStreak >= 3 && (now - lastMove) > 1200) {
                            root._setPaused(true, now);
                        }
                    }

                    // --- Seek detection ---
                    const seeked = !!msg.seeked;
                    if (seeked || dt < -2000 || dt > 5000) {
                        root._sameTimeStreak = 0;
                        root._setPaused(false, now);
                    }

                    // Always re-anchor to the freshest reported time.
                    // Between ticks the playhead timer linearly extrapolates at 1× speed.
                    root._reportedTime = newRaw;
                    // Use bridge-side timestamp if available — this cancels variable
                    // IPC latency (Node stdout → QML SplitParser) that caused random
                    // early/late karaoke fill jitter.
                    const bridgeTs = Number(msg.ts ?? 0);
                    root._reportedAtMs = (bridgeTs > 0) ? bridgeTs : now;
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
