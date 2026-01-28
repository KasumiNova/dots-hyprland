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
    // Predicted playhead time in ms (smooth between WS ticks)
    property int time: 0
    property int _reportedTime: 0
    property real _reportedAtMs: 0
    property int _prevReportedTime: 0
    property real _prevReportedAtMs: 0
    // Estimated playback rate (ms/ms). 1.0 ~= normal playback.
    property real _playbackRate: 1.0
    // Estimated interval between API updates (ms). Used to adapt animation duration.
    property int updateIntervalMs: 150
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

    function clearLyrics() {
        root.main = "";
        root.translation = "";
        root.time = 0;
        root._reportedTime = 0;
        root._reportedAtMs = 0;
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
            const age = now - (root._reportedAtMs || 0);

            // If we haven't received progress recently (pause/stop), don't keep advancing.
            const predicted = (age >= 0 && age < 3000)
                ? (root._reportedTime + age * (root._playbackRate || 1.0) + root.offsetMs)
                : root._reportedTime;

            root.time = predicted;

            if (root.lineStart > 0 && root.lineEnd > root.lineStart) {
                const dur = root.lineEnd - root.lineStart;
                const p = (predicted - root.lineStart) / dur;
                root.lineProgress = Math.max(0, Math.min(1, p));
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
                } else if (msg.type === "lyrics") {
                    root.main = (msg.main ?? "");
                    root.translation = (msg.translation ?? "");
                    {
                        const newT = msg.time ?? 0;
                        const now = Date.now();
                        const prevT = root._reportedTime;
                        const prevAt = root._reportedAtMs;
                        root._prevReportedTime = prevT;
                        root._prevReportedAtMs = prevAt;
                        root._reportedTime = newT;
                        root._reportedAtMs = now;
                        const dms = now - (prevAt || 0);
                        const dt = newT - (prevT || 0);
                        if (dms > 0 && dt >= 0) {
                            const r = dt / dms;
                            // Clamp to avoid crazy spikes.
                            root._playbackRate = Math.max(0, Math.min(1.25, r));
                        }
                        // Track update interval for adaptive animation.
                        if (dms > 30 && dms < 2000) {
                            root.updateIntervalMs = Math.round(dms);
                        }
                    }
                    root.time = root._reportedTime;

                    root.lineStart = msg.lineStart ?? 0;
                    root.lineEnd = msg.lineEnd ?? 0;
                    root.lineDuration = msg.lineDuration ?? 0;
                    // lineProgress will be continuously predicted by playheadTimer.
                    root.lineProgress = (typeof msg.lineProgress === "number") ? msg.lineProgress : root.lineProgress;

                    root.segments = (Array.isArray(msg.segments) ? msg.segments : []);
                    root.isTransition = !!msg.isTransition;
                    if (root.isTransition) {
                        transitionClearTimer.restart();
                    }
                } else if (msg.type === "progress") {
                    {
                        const newT = msg.time ?? root._reportedTime;
                        const now = Date.now();
                        const prevT = root._reportedTime;
                        const prevAt = root._reportedAtMs;
                        root._prevReportedTime = prevT;
                        root._prevReportedAtMs = prevAt;
                        root._reportedTime = newT;
                        root._reportedAtMs = now;
                        const dms = now - (prevAt || 0);
                        const dt = newT - (prevT || 0);
                        if (dms > 0 && dt >= 0) {
                            const r = dt / dms;
                            root._playbackRate = Math.max(0, Math.min(1.25, r));
                        }
                        // Track update interval for adaptive animation.
                        if (dms > 30 && dms < 2000) {
                            root.updateIntervalMs = Math.round(dms);
                        }
                    }
                    root.time = root._reportedTime;
                    root.lineStart = msg.lineStart ?? root.lineStart;
                    root.lineEnd = msg.lineEnd ?? root.lineEnd;
                    root.lineDuration = msg.lineDuration ?? root.lineDuration;
                    // lineProgress will be continuously predicted by playheadTimer.
                    if (typeof msg.lineProgress === "number") root.lineProgress = msg.lineProgress;
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
