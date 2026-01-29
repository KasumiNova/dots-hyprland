pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions

Singleton {
    id: root

    property string term: ""
    property var spec: ({ backend: "plocate", limit: 80, scope: "path", type: "any", includePaths: [], excludePaths: [] })

    // Raw parsed results (plain JS objects)
    property list<var> results: []

    property bool running: false
    property string errorMessage: ""
    property string errorDetails: ""

    property int _generation: 0
    property string _lastRequestKey: ""

    function reset() {
        root.term = "";
        root.running = false;
        root.errorMessage = "";
        root.errorDetails = "";
        root.results = [];
        root._lastRequestKey = "";
        debounceTimer.stop();
        // Bump generation so any pending process completion is ignored.
        root._generation++;
        proc.running = false;
    }

    function _stableSpec(spec) {
        const s = spec ?? {};
        const includePaths = (s.includePaths ?? []).slice?.() ?? [];
        const excludePaths = (s.excludePaths ?? []).slice?.() ?? [];
        includePaths.sort();
        excludePaths.sort();
        return {
            backend: String(s.backend ?? Config.options.search.files.backend),
            limit: Number(s.limit ?? Config.options.search.files.limit),
            scope: String(s.scope ?? Config.options.search.files.defaultScope),
            type: String(s.type ?? Config.options.search.files.defaultType),
            includePaths: Array.from(new Set(includePaths.filter(p => typeof p === "string" && p.length > 0))),
            excludePaths: Array.from(new Set(excludePaths.filter(p => typeof p === "string" && p.length > 0))),
        };
    }

    function request(term, spec) {
        const t = String(term ?? "").trim();
        if (!t.length) {
            root.reset();
            return;
        }

        const stable = root._stableSpec(spec ?? root.spec);
        const key = `${t}\n${JSON.stringify(stable)}`;
        if (key === root._lastRequestKey) {
            return;
        }

        root._lastRequestKey = key;
        root.term = t;
        root.spec = stable;
        debounceTimer.restart();
    }

    function _scriptPath() {
        return `${Directories.scriptPath}/search/file_search.py`;
    }

    function _buildCommand(gen) {
        const backend = root.spec?.backend ?? Config.options.search.files.backend;
        const scope = root.spec?.scope ?? Config.options.search.files.defaultScope;
        const type = root.spec?.type ?? Config.options.search.files.defaultType;
        const limit = root.spec?.limit ?? Config.options.search.files.limit;
        const includePaths = root.spec?.includePaths ?? [];
        const excludePaths = root.spec?.excludePaths ?? [];

        /** @type {string[]} */
        let cmd = [
            "python3",
            root._scriptPath(),
            "--backend", String(backend),
            "--term", String(root.term ?? ""),
            "--scope", String(scope),
            "--type", String(type),
            "--limit", String(limit),
        ];

        for (const p of includePaths) {
            if (!p || typeof p !== "string") continue;
            cmd.push("--include", p);
        }
        for (const p of excludePaths) {
            if (!p || typeof p !== "string") continue;
            cmd.push("--exclude", p);
        }

        return cmd;
    }

    Timer {
        id: debounceTimer
        interval: Config.options.search.files.debounceMs
        repeat: false
        onTriggered: {
            root.errorMessage = "";
            root.errorDetails = "";
            const gen = ++root._generation;
            proc.runGeneration = gen;

            proc.running = false;
            proc.command = root._buildCommand(gen);
            proc.running = true;
            root.running = true;
        }
    }

    Process {
        id: proc
        property int runGeneration: 0

        stdout: StdioCollector {
            id: stdoutCollector
        }
        stderr: StdioCollector {
            id: stderrCollector
        }

        onExited: (exitCode, exitStatus) => {
            // Ignore stale runs.
            if (proc.runGeneration !== root._generation)
                return;
            root.running = false;

            const outText = stdoutCollector.text ?? "";
            const errText = stderrCollector.text ?? "";

            if (exitCode !== 0) {
                root.results = [];
                root.errorMessage = Translation.tr("File search backend failed");
                root.errorDetails = (errText.trim().length ? errText.trim() : outText.trim());
                return;
            }

            /** @type {any[]} */
            const items = [];
            const lines = outText.split(/\n/).map(l => l.trim()).filter(l => l.length > 0);
            for (const line of lines) {
                try {
                    const obj = JSON.parse(line);
                    if (obj && typeof obj.path === "string" && obj.path.length > 0) {
                        items.push(obj);
                    }
                } catch (e) {
                    // Ignore malformed lines
                }
            }
            root.results = items;
        }
    }
}
