pragma Singleton
pragma ComponentBehavior: Bound

import qs
import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Double-copy (Ctrl+C then Ctrl+C) helper:
 * - Implemented by watching Wayland clipboard change events via `wl-paste --watch`.
 *   (Pressing Ctrl+C twice often does NOT change clipboard text, so
 *   Quickshell.clipboardTextChanged may not fire for the 2nd copy.)
 * - When two identical clipboard updates happen within `intervalMs`, it opens the left sidebar,
 *   switches to the Translator tab, and injects the clipboard text.
 * - Disabled automatically while "game mode" is active (Hyprland animations:enabled == 0).
 */
Singleton {
    id: root

    property bool enabled: (Config.ready && (Config.options?.sidebar?.translator?.doubleCopyTranslateClipboard ?? false))
    property int intervalMs: (Config.options?.sidebar?.translator?.doubleCopyIntervalMs ?? 450)

    // Avoid false positives when a clipboard manager rewrites the same content immediately
    // after a single copy. Human double-taps are usually >100ms.
    readonly property int _minDoubleCopyGapMs: 120

    property string _lastText: ""
    property double _lastTs: 0

    property string _pendingText: ""
    property bool _probeInFlight: false
    property bool gameModeActive: false

    function load() { } // Dummy to force init

    function _onCopyEvent() {
        if (!root.enabled) return;
        readClipboardProc.running = false;
        readClipboardProc.running = true;
    }

    function _handleCopyEvent(text) {
        if (!root.enabled) return;

        const t = (text ?? "").trim();
        if (t.length === 0) return;

        const now = Date.now();
        const within = (now - root._lastTs) <= root.intervalMs;
        const gapOk = (now - root._lastTs) >= root._minDoubleCopyGapMs;
        const same = t === root._lastText;

        root._lastTs = now;
        root._lastText = t;

        if (!within || !gapOk || !same) return;

        root._pendingText = t;
        root._runGameModeProbe();

        // Cooldown: require a fresh pair of copy-events for the next trigger.
        root._lastTs = 0;
        root._lastText = "";
    }

    function _runGameModeProbe() {
        if (root._probeInFlight) return;
        root._probeInFlight = true;
        gameModeProbe.running = false;
        gameModeProbe.running = true;
    }

    // Long-running watcher that triggers once per Wayland clipboard change.
    Process {
        id: clipboardWatchProc
        // Drain clipboard (stdin) then print a marker.
        command: ["bash", "-c", "wl-paste --watch bash -c 'cat >/dev/null; echo __QS_COPY_EVENT__'"]
        running: root.enabled
        stdout: SplitParser {
            onRead: (line) => {
                if ((line ?? "").trim() === "__QS_COPY_EVENT__") root._onCopyEvent();
            }
        }
        onExited: (exitCode, exitStatus) => {
            // If wl-paste isn't available or the watcher dies, retry slowly.
            if (root.enabled) {
                console.error("[ClipboardTranslateTrigger] wl-paste watcher exited:", exitCode, exitStatus);
                watchRestartTimer.restart();
            }
        }
    }

    Timer {
        id: watchRestartTimer
        interval: 2000
        repeat: false
        onTriggered: {
            if (root.enabled && !clipboardWatchProc.running) clipboardWatchProc.running = true;
        }
    }

    // Fetch clipboard text on each copy event (works even if content is unchanged).
    Process {
        id: readClipboardProc
        command: ["bash", "-c", "wl-paste --type text/plain;charset=utf-8 2>/dev/null || wl-paste --type text/plain 2>/dev/null || true"]
        stdout: StdioCollector {
            onStreamFinished: {
                root._handleCopyEvent(text)
            }
        }
    }

    Process {
        id: gameModeProbe
        // Same detection as GameModeToggle.qml:
        // - exitCode == 0 => animations:enabled != 0 => NOT game mode
        // - exitCode != 0 => animations:enabled == 0 => game mode
        command: ["bash", "-c", `test "$(hyprctl getoption animations:enabled -j | jq ".int")" -ne 0`]

        onExited: (exitCode, exitStatus) => {
            root._probeInFlight = false;
            root.gameModeActive = exitCode !== 0;

            const text = (root._pendingText ?? "").trim();
            root._pendingText = "";

            if (text.length === 0) return;
            if (!root.enabled) return;
            if (root.gameModeActive) return;
            if (!(Config.options?.sidebar?.translator?.enable ?? false)) return;
            if ((Config.options?.panelFamily ?? "ii") !== "ii") return;

            // Set text first, then open sidebar with tab request
            GlobalStates.sidebarLeftTranslatorRequestedText = text;
            GlobalStates.sidebarLeftRequestedTab = "translator";
            GlobalStates.sidebarLeftOpen = true;
        }
    }
}
