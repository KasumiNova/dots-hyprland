#!/usr/bin/env python3

import argparse
import json
import os
import shlex
import stat
import subprocess
import sys
from urllib.parse import unquote, urlparse


def _which(cmd: str) -> str | None:
    for p in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(p, cmd)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _normalize_path(line: str) -> str | None:
    s = line.strip("\r\n")
    if not s:
        return None
    if s.startswith("file://"):
        try:
            u = urlparse(s)
            if u.scheme != "file":
                return None
            return unquote(u.path)
        except Exception:
            return None
    if s.startswith("/"):
        return s
    return None


def _contains_all(haystack: str, needles: list[str]) -> bool:
    for n in needles:
        if n and n not in haystack:
            return False
    return True


def _strip_filter_prefix(s: str) -> str:
    # Be tolerant to legacy tokens being stored in config.
    for k in ("in:", "notin:"):
        if s.startswith(k):
            return s[len(k):]
    return s


def _prefix_match(path: str, prefix: str) -> bool:
    # Treat prefixes as directory prefixes, not plain string prefixes.
    # Ex: /home/u/.gradle should match /home/u/.gradle/... but not /home/u/.gradleX
    p = (prefix or "").rstrip("/")
    if not p:
        return False
    if path == p:
        return True
    return path.startswith(p + "/")


def _fuzzy_match(path_lower: str, token_lower: str) -> bool:
    if not token_lower:
        return False
    # Match against path segments to avoid excluding files like "build.gradle"
    # when token is a hidden dir like ".gradle".
    segs = [s for s in path_lower.split("/") if s]
    if token_lower.startswith("."):
        return any(s == token_lower for s in segs)
    return any(token_lower in s for s in segs)


def _score(path: str, name: str, needles: list[str]) -> int:
    # Cheap heuristic score for stable ordering.
    s = 0
    lp = path.lower()
    ln = name.lower()
    for n in needles:
        if not n:
            continue
        if ln == n:
            s += 200
        elif ln.startswith(n):
            s += 120
        elif n in ln:
            s += 80
        elif n in lp:
            s += 30
    # Prefer shorter paths slightly
    s -= min(30, len(path) // 20)
    return s


def _run(cmd: list[str]) -> tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace")
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", f"command not found: {cmd[0]}\n"
    except Exception as e:
        return 1, "", f"failed to run {cmd[0]}: {e}\n"


def _plocate_candidates(seed: str, scope: str, limit: int, has_path_filters: bool) -> tuple[int, list[str], str]:
    plocate = _which("plocate")
    if not plocate:
        return 127, [], "plocate not found"

    # Pull a larger candidate set; we'll filter down.
    # IMPORTANT: when include/exclude filters are present, the first N hits can be entirely
    # filtered out (e.g. searching build.gradle returns mostly ~/.gradle first). Over-fetch
    # to ensure we still have enough survivors.
    raw_limit = max(limit * (400 if has_path_filters else 10), 8000 if has_path_filters else 200)
    cmd = [plocate, "-i", "-l", str(raw_limit)]
    cmd.append("-b" if scope == "name" else "-w")
    cmd.append(seed)

    code, out, err = _run(cmd)
    if code != 0:
        return code, [], (err.strip() or out.strip() or "plocate failed")
    return 0, out.splitlines(), ""


def _baloo_candidates(query_terms: list[str], limit: int, include_dir: str | None, has_path_filters: bool) -> tuple[int, list[str], str]:
    baloo = _which("baloosearch6") or _which("baloosearch")
    if not baloo:
        return 127, [], "baloosearch not found"

    # Pull a larger candidate set; Baloo may return content matches first.
    raw_limit = max(limit * (120 if has_path_filters else 50), 1500 if has_path_filters else 500)
    cmd = [baloo, "-l", str(raw_limit)]
    if include_dir:
        cmd += ["-d", include_dir]

    # baloosearch takes a list of query terms.
    cmd += query_terms

    code, out, err = _run(cmd)
    if code != 0:
        return code, [], (err.strip() or out.strip() or "baloosearch failed")
    return 0, out.splitlines(), ""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=["plocate", "baloo"], required=True)
    ap.add_argument("--term", default="")
    ap.add_argument("--scope", choices=["path", "name"], default="path")
    ap.add_argument("--type", choices=["any", "file", "dir"], default="any")
    ap.add_argument("--limit", type=int, default=80)
    ap.add_argument("--include", action="append", default=[])
    ap.add_argument("--exclude", action="append", default=[])
    args = ap.parse_args()

    term = (args.term or "").strip()
    if not term:
        return 0

    words = [w.strip() for w in term.split() if w.strip()]
    if not words:
        return 0

    include_raw = [p for p in (args.include or []) if isinstance(p, str) and p]
    exclude_raw = [p for p in (args.exclude or []) if isinstance(p, str) and p]

    include_abs: list[str] = []
    include_fuzzy: list[str] = []
    exclude_abs: list[str] = []
    exclude_fuzzy: list[str] = []

    def ingest(raw_list: list[str], abs_out: list[str], fuzzy_out: list[str]):
        for raw in raw_list:
            s = _strip_filter_prefix(str(raw).strip())
            s = s.strip()
            if not s:
                continue
            s = os.path.expanduser(s)
            if os.path.isabs(s):
                abs_out.append(os.path.normpath(s))
            else:
                fuzzy_out.append(s.lower())

    ingest(include_raw, include_abs, include_fuzzy)
    ingest(exclude_raw, exclude_abs, exclude_fuzzy)

    # Dedup
    include_abs = list(dict.fromkeys([p for p in include_abs if p]))
    exclude_abs = list(dict.fromkeys([p for p in exclude_abs if p]))
    include_fuzzy = list(dict.fromkeys([t for t in include_fuzzy if t]))
    exclude_fuzzy = list(dict.fromkeys([t for t in exclude_fuzzy if t]))

    has_path_filters = bool(include_abs or include_fuzzy or exclude_abs or exclude_fuzzy)

    # Choose a seed for plocate; pass all words to baloo.
    seed = max(words, key=len)

    lines: list[str] = []
    err_msg = ""
    if args.backend == "plocate":
        code, lines, err_msg = _plocate_candidates(seed, args.scope, args.limit, has_path_filters)
        if code != 0:
            print(err_msg, file=sys.stderr)
            return code
    else:
        # If user supplied exactly one include path, we can let baloo prefilter by directory.
        include_dir = include_abs[0] if len(include_abs) == 1 and not include_fuzzy else None

        # Try to align Baloo's query semantics with the requested scope.
        # - scope=name: constrain to filename matches
        # - scope=path: plain query (Baloo might still match by content)
        if args.scope == "name":
            query_terms = [f"filename:{w}" for w in words]
        else:
            query_terms = words

        code, lines, err_msg = _baloo_candidates(query_terms, args.limit, include_dir, has_path_filters)
        if code != 0:
            print(err_msg, file=sys.stderr)
            return code

    results = []
    seen = set()
    needles = [w.lower() for w in words]

    # How many "survivor" candidates to collect before sorting.
    # With path filters enabled, early candidates can be dominated by unwanted locations
    # (e.g. ~/.gradle). Collect more so scoring can surface the best matches.
    target_survivors = args.limit * (25 if has_path_filters else 6)
    target_survivors = max(target_survivors, args.limit * 3)
    target_survivors = min(target_survivors, 1500)

    def collect(apply_client_match_filter: bool) -> list[dict]:
        out_results: list[dict] = []
        for raw in lines:
            path = _normalize_path(raw)
            if not path:
                continue

            # Include/exclude filters
            lp = path.lower()
            if include_abs or include_fuzzy:
                ok = False
                if include_abs and any(_prefix_match(path, p) for p in include_abs):
                    ok = True
                if not ok and include_fuzzy and any(_fuzzy_match(lp, t) for t in include_fuzzy):
                    ok = True
                if not ok:
                    continue

            if exclude_abs and any(_prefix_match(path, p) for p in exclude_abs):
                continue
            if exclude_fuzzy and any(_fuzzy_match(lp, t) for t in exclude_fuzzy):
                continue

            # Client-side match filter (plocate always needs this; baloo may not)
            if apply_client_match_filter:
                target = path if args.scope == "path" else os.path.basename(path.rstrip("/"))
                lt = target.lower()
                if not _contains_all(lt, needles):
                    continue

            # Stat + type filter
            try:
                st = os.stat(path)
            except OSError:
                continue

            is_dir = stat.S_ISDIR(st.st_mode)
            is_file = stat.S_ISREG(st.st_mode)
            if args.type == "dir" and not is_dir:
                continue
            if args.type == "file" and not is_file:
                continue

            # Dedup
            if path in seen:
                continue
            seen.add(path)

            nice = path.rstrip("/") if path != "/" else "/"
            name = os.path.basename(nice) if nice != "/" else "/"
            parent = os.path.dirname(nice) if nice != "/" else "/"

            out_results.append({
                "path": path,
                "name": name,
                "parent": parent,
                "isDir": bool(is_dir),
                "isFile": bool(is_file),
                "score": _score(path, name, needles),
            })

            if len(out_results) >= target_survivors:
                # Enough candidates for sorting; avoid walking too far.
                break
        return out_results

    # For Baloo, we prefer consistent matching semantics, but Baloo's query terms
    # may hit file content/metadata. If strict substring matching yields nothing,
    # fall back to Baloo's own matching to avoid a blank result list.
    strict = True
    results = collect(apply_client_match_filter=strict)
    if not results and args.backend == "baloo" and args.scope == "path":
        seen.clear()
        results = collect(apply_client_match_filter=False)

    results.sort(key=lambda r: r.get("score", 0), reverse=True)

    for r in results[: args.limit]:
        sys.stdout.write(json.dumps(r, ensure_ascii=False) + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
