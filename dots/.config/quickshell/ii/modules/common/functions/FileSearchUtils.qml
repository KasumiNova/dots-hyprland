pragma Singleton

import Quickshell

Singleton {
    id: root

    /**
     * Parse a file-search query with a dedicated prefix and optional leading tokens.
     *
     * Supported tokens (space-separated, placed immediately after the prefix):
     *  - type:any|file|dir
     *  - scope:path|name
     *  - backend:plocate|baloo
     *  - limit:<int>
     *  - in:<path> (repeatable)
     *  - notin:<path> (repeatable)
     *
     * Everything after the first non-token word is treated as the search term.
     *
     * @param {string} query Full LauncherSearch.query
     * @param {string} prefix Single-character prefix used to enter file-search mode
     * @param {object} defaults { backend, limit, defaultScope, defaultType, includePaths, excludePaths }
     * @returns {{active: boolean, term: string, spec: {backend: string, limit: number, scope: string, type: string, includePaths: string[], excludePaths: string[]}, tokens: string[]}}
     */
    function parse(query, prefix, defaults) {
        const d = defaults ?? {};
        const baseSpec = {
            backend: d.backend ?? "plocate",
            limit: d.limit ?? 80,
            scope: d.defaultScope ?? "path",
            type: d.defaultType ?? "any",
            includePaths: (d.includePaths ?? []).slice?.() ?? [],
            excludePaths: (d.excludePaths ?? []).slice?.() ?? [],
        };

        if (typeof query !== "string" || typeof prefix !== "string" || prefix.length === 0)
            return { active: false, term: "", spec: baseSpec, tokens: [] };

        if (!query.startsWith(prefix))
            return { active: false, term: query, spec: baseSpec, tokens: [] };

        let rest = query.slice(prefix.length);
        // Keep leading spaces optional
        rest = rest.replace(/^\s+/, "");

        // Split on whitespace; first non-token begins the term.
        const parts = rest.length ? rest.split(/\s+/) : [];
        /** @type {string[]} */
        const tokenParts = [];
        let i = 0;

        function isKnownToken(p) {
            return /^(type|scope|backend|limit|in|notin):/.test(p);
        }

        for (; i < parts.length; i++) {
            const p = parts[i];
            if (!p || !isKnownToken(p)) break;
            tokenParts.push(p);
        }

        const term = parts.slice(i).join(" ");

        // Apply tokens
        const spec = {
            backend: baseSpec.backend,
            limit: baseSpec.limit,
            scope: baseSpec.scope,
            type: baseSpec.type,
            includePaths: baseSpec.includePaths.slice(),
            excludePaths: baseSpec.excludePaths.slice(),
        };

        for (const t of tokenParts) {
            const idx = t.indexOf(":");
            const key = t.slice(0, idx);
            const value = t.slice(idx + 1);
            if (!value) continue;

            if (key === "type") {
                if (["any", "file", "dir"].includes(value)) spec.type = value;
            } else if (key === "scope") {
                if (["path", "name"].includes(value)) spec.scope = value;
            } else if (key === "backend") {
                if (["plocate", "baloo"].includes(value)) spec.backend = value;
            } else if (key === "limit") {
                const n = parseInt(value);
                if (!isNaN(n) && n > 0) spec.limit = n;
            } else if (key === "in") {
                spec.includePaths.push(value);
            } else if (key === "notin") {
                spec.excludePaths.push(value);
            }
        }

        // Dedup include/exclude
        spec.includePaths = Array.from(new Set(spec.includePaths.filter(p => typeof p === "string" && p.length > 0)));
        spec.excludePaths = Array.from(new Set(spec.excludePaths.filter(p => typeof p === "string" && p.length > 0)));

        return { active: true, term, spec, tokens: tokenParts };
    }

    function _rebuild(prefix, tokens, term) {
        const t = (tokens ?? []).filter(Boolean).join(" ");
        const suffix = (term ?? "").trim().length ? ((t.length ? " " : "") + term) : "";
        return prefix + (t.length ? (t + suffix) : ((term ?? "").trim().length ? term : ""));
    }

    /**
     * Replace or insert a singleton token (type/scope/backend/limit).
     */
    function setSingletonToken(query, prefix, defaults, key, value) {
        const parsed = parse(query, prefix, defaults);
        if (!parsed.active) return query;
        const tokens = parsed.tokens.slice();
        const newToken = `${key}:${value}`;
        let replaced = false;
        for (let i = 0; i < tokens.length; i++) {
            if (tokens[i].startsWith(key + ":")) {
                tokens[i] = newToken;
                replaced = true;
                break;
            }
        }
        if (!replaced) tokens.push(newToken);
        return _rebuild(prefix, tokens, parsed.term);
    }

    /**
     * Add a repeatable path token (in/notin).
     */
    function addPathToken(query, prefix, defaults, key, path) {
        const parsed = parse(query, prefix, defaults);
        if (!parsed.active) return query;
        const p = String(path ?? "").trim();
        if (!p.length) return query;
        const token = `${key}:${p}`;
        const tokens = parsed.tokens.slice();
        if (!tokens.includes(token)) tokens.push(token);
        return _rebuild(prefix, tokens, parsed.term);
    }

    function removePathToken(query, prefix, defaults, key, path) {
        const parsed = parse(query, prefix, defaults);
        if (!parsed.active) return query;
        const p = String(path ?? "").trim();
        if (!p.length) return query;
        const token = `${key}:${p}`;
        const tokens = parsed.tokens.filter(t => t !== token);
        return _rebuild(prefix, tokens, parsed.term);
    }
}
