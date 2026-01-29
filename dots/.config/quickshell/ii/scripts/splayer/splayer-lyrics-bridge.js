#!/usr/bin/env node
/*
  SPlayer lyrics WS bridge

  - Connects to SPlayer WebSocket (default ws://localhost:25885)
  - Listens to broadcasts (lyric-change, progress-change, song-change, status-change)
  - Emits NDJSON lines on stdout for Quickshell to consume.

  Output examples:
    {"type":"status","connected":true}
    {"type":"lyrics","main":"...","translation":"...","time":12345}
*/

'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

function parseArgs(argv) {
  const args = { url: 'ws://localhost:25885', cache: '' };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--url' && i + 1 < argv.length) {
      args.url = argv[++i];
    } else if (a.startsWith('--url=')) {
      args.url = a.slice('--url='.length);
    } else if (a === '--cache' && i + 1 < argv.length) {
      args.cache = argv[++i];
    } else if (a.startsWith('--cache=')) {
      args.cache = a.slice('--cache='.length);
    }
  }
  return args;
}

function normalizeUrl(u) {
  return String(u || '').trim().replace(/\/+$/, '');
}

function normalizePath(p) {
  const s = String(p || '').trim();
  if (!s) return '';
  return s.startsWith('file://') ? s.slice('file://'.length) : s;
}

function safeJsonParse(str) {
  try {
    return JSON.parse(str);
  } catch {
    return null;
  }
}

function toNumber(v, fallback = 0) {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function normalizeLine(line) {
  // Observed fields:
  // - startTime, endTime
  // - words: [{word, startTime, endTime, romanWord}]
  // - translatedLyric, romanLyric, isBG, isDuet
  if (!line || typeof line !== 'object') return null;

  const start = toNumber(line.startTime, 0);
  let end = toNumber(line.endTime, -1);

  let main = '';
  let segments = [];
  if (Array.isArray(line.words) && line.words.length > 0) {
    segments = line.words
      .map(w => {
        if (!w || typeof w !== 'object') return null;
        const text = (typeof w.word === 'string') ? w.word : '';
        let s = toNumber(w.startTime, -1);
        let e = toNumber(w.endTime, -1);

        // Some payloads use word times relative to the line start.
        // Heuristic: if word time is small (e.g. <30s) while line start is large,
        // treat it as relative and convert to absolute track time.
        if (s >= 0 && s < 30_000 && start >= 30_000) s = start + s;
        if (e >= 0 && e < 30_000 && start >= 30_000) e = start + e;
        const roman = (typeof w.romanWord === 'string') ? w.romanWord : '';
        return { text, start: s, end: e, roman };
      })
      .filter(Boolean);
    main = segments.map(w => w.text).join('');
  } else if (typeof line.lyric === 'string') {
    main = line.lyric;
  } else if (typeof line.text === 'string') {
    main = line.text;
  }

  const translation = (typeof line.translatedLyric === 'string') ? line.translatedLyric : '';

  return {
    start,
    end,
    main,
    translation,
    isBG: !!line.isBG,
    segments,
  };
}

function normalizeLines(payload) {
  // Prefer yrcData when it contains per-word timing (karaoke).
  // Otherwise fall back to lrcData (coarser, per-line).
  const yrc = payload?.yrcData;
  const lrc = payload?.lrcData;
  const hasYrcWords = Array.isArray(yrc) && yrc.some(line => {
    const words = line?.words;
    return Array.isArray(words) && words.length > 0 && words.some(w => w && (w.startTime != null || w.endTime != null));
  });

  const raw = hasYrcWords ? yrc : (lrc ?? yrc);
  if (!Array.isArray(raw)) return [];

  const normalized = raw
    .map(normalizeLine)
    .filter(Boolean);

  // By default, skip background (isBG) lines and empty lines.
  // Background lines can start between two main lines and cause the UI to
  // "jump to next" even though the next *main* line hasn't started.
  const nonBg = normalized.filter(l => !l.isBG && String(l.main || '').trim().length > 0);
  const nonEmpty = normalized.filter(l => String(l.main || '').trim().length > 0);

  const lines = (nonBg.length > 0 ? nonBg : nonEmpty)
    .sort((a, b) => a.start - b.start);

  // If endTime is missing/invalid, infer it from next line.
  for (let i = 0; i < lines.length; i++) {
    if (!(lines[i].end > lines[i].start)) {
      lines[i].end = (i + 1 < lines.length) ? lines[i + 1].start : lines[i].start + 10_000;
    }
  }

  return lines;
}

function findLineIndex(lines, timeMs) {
  if (!lines || lines.length === 0) return -1;

  // Binary search for last line with start <= timeMs
  let lo = 0;
  let hi = lines.length - 1;
  let best = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid].start <= timeMs) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  if (best < 0) return -1;

  // Select purely by start time; end is for progress only.
  // This keeps the last line visible during gaps until the next line starts.
  return best;
}

// If stdout is piped (e.g. `... | head`) and the consumer exits early,
// Node will surface this as an EPIPE error on process.stdout.
// Handle it to avoid noisy crashes during debugging.
if (process.stdout && typeof process.stdout.on === 'function') {
  process.stdout.on('error', (err) => {
    if (err && err.code === 'EPIPE') {
      process.exit(0);
    }
  });
}

function emit(obj) {
  try {
    process.stdout.write(JSON.stringify(obj) + '\n');
  } catch (e) {
    // If stdout is gone, just exit.
    process.exit(0);
  }
}

const args = parseArgs(process.argv);
const url = normalizeUrl(args.url) || 'ws://localhost:25885';

function getCacheFilePath() {
  const base = process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache');
  return path.join(base, 'quickshell', 'splayer-lyrics-cache.json');
}

const CACHE_FILE = (() => {
  const explicit = normalizePath(args.cache);
  if (explicit) return path.resolve(explicit);
  return getCacheFilePath();
})();

function loadCache() {
  try {
    const raw = fs.readFileSync(CACHE_FILE, 'utf8');
    const obj = JSON.parse(raw);
    if (!obj || obj.version !== 1) return null;
    if (!Array.isArray(obj.lines)) return null;
    return obj;
  } catch {
    return null;
  }
}

function saveCache(payload) {
  try {
    fs.mkdirSync(path.dirname(CACHE_FILE), { recursive: true });
    fs.writeFileSync(
      CACHE_FILE,
      JSON.stringify({ version: 1, url, savedAt: Date.now(), ...payload })
    );
  } catch {
    // Best-effort only.
  }
}

let ws = null;
let reconnectTimer = null;
let backoffMs = 500;

let lines = [];
let lastIdx = -2;
let lastMain = '';
let lastTranslation = '';
let lastTime = -1;

let lastProgressEmitAt = 0;

let lastSongKey = '';

function emitTimeline(source) {
  if (!Array.isArray(lines) || lines.length === 0) return;
  emit({
    type: 'timeline',
    source: source || 'unknown',
    songKey: lastSongKey,
    lines,
  });
}

function resetLyricsState(keepLines = false) {
  // keepLines=true: preserve cached lyrics (for single-loop / seeking)
  if (!keepLines) {
    lines = [];
  }
  lastIdx = -2;
  lastMain = '';
  lastTranslation = '';
  lastTime = -1;
}

function restoreCachedLyricsState() {
  const cached = loadCache();
  if (!cached) return;
  lines = cached.lines;
  lastSongKey = (typeof cached.songKey === 'string') ? cached.songKey : '';
  // Force re-emit on next progress tick.
  lastIdx = -2;
  // Also emit timeline immediately so QS can animate locally even before
  // the next lyric-change arrives.
  emitTimeline('cache');
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = backoffMs;
  backoffMs = Math.min(Math.floor(backoffMs * 1.6), 15_000);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function connect() {
  if (ws) {
    try { ws.close(); } catch {}
    ws = null;
  }

  if (typeof WebSocket === 'undefined') {
    // Node 18+ provides global WebSocket. If absent, fail fast.
    console.error('[splayer-lyrics-bridge] Global WebSocket is not available in this Node runtime.');
    emit({ type: 'status', connected: false, error: 'WebSocketUnavailable' });
    process.exit(2);
  }

  resetLyricsState();
  // If SPlayer doesn't resend lyric-change after reconnect, we can still recover
  // by combining cached lyric timing data with the next progress-change ticks.
  restoreCachedLyricsState();

  try {
    ws = new WebSocket(url);
  } catch (e) {
    console.error('[splayer-lyrics-bridge] Failed to create WebSocket:', e);
    emit({ type: 'status', connected: false, error: String(e) });
    scheduleReconnect();
    return;
  }

  ws.onopen = () => {
    backoffMs = 500;
    emit({ type: 'status', connected: true });
  };

  ws.onclose = () => {
    emit({ type: 'status', connected: false });
    scheduleReconnect();
  };

  ws.onerror = (err) => {
    // onclose will handle reconnect; still emit for diagnostics.
    emit({ type: 'status', connected: false, error: 'WebSocketError' });
  };

  ws.onmessage = (ev) => {
    const data = ev?.data;

    if (data === 'PING') {
      try { ws.send('PONG'); } catch {}
      return;
    }

    if (typeof data !== 'string') {
      return;
    }

    const msg = safeJsonParse(data);
    if (!msg || typeof msg.type !== 'string') return;

    switch (msg.type) {
      case 'song-change': {
        // Don't wipe lines here - they may still be valid for single-loop mode.
        // Just reset index tracking so we re-emit on next progress tick.
        // If it's truly a different song, lyric-change will follow and replace lines.
        resetLyricsState(true);  // keepLines=true
        // Don't clear lastSongKey; let lyric-change update it if song actually changed.
        // Emit empty to clear UI momentarily; next progress-change will restore if lines exist.
        emit({ type: 'lyrics', main: '', translation: '', time: 0, lineStart: 0, lineEnd: 0, lineDuration: 0, lineProgress: -1, segments: [], isTransition: true });
        break;
      }

      case 'lyric-change': {
        const newLines = normalizeLines(msg.data);
        lines = newLines;
        // Try to capture a stable identifier if the payload provides one.
        const songKey =
          (msg?.data && (msg.data.songId ?? msg.data.musicId ?? msg.data.id ?? msg.data.hash)) ?? '';
        lastSongKey = (songKey != null) ? String(songKey) : '';
        saveCache({ lines: newLines, songKey: lastSongKey });
        // Emit full timeline for QS-side animation.
        emitTimeline('api');
        // Force re-emit on next progress tick
        lastIdx = -2;
        break;
      }

      case 'progress-change': {
        const t = toNumber(msg?.data?.currentTime, -1);
        if (t < 0) return;

        // Detect seeking: if time jumped by more than 2s backward or 5s forward, treat as seek.
        const timeDelta = t - lastTime;
        const didSeek = lastTime >= 0 && (timeDelta < -2000 || timeDelta > 5000);
        if (didSeek) {
          // Reset index tracking so we re-emit the correct line after seek.
          lastIdx = -2;
          lastMain = '';
          lastTranslation = '';
        }
        lastTime = t;

        const idx = findLineIndex(lines, t);
        const isLineTransition = (idx !== lastIdx && idx >= 0 && lastIdx >= 0);

        let lineStart = 0;
        let lineEnd = 0;
        let lineDuration = 0;
        let lineProgress = -1;
        if (idx !== -1) {
          const line = lines[idx];
          lineStart = toNumber(line.start, 0);
          lineEnd = toNumber(line.end, 0);
          lineDuration = Math.max(0, lineEnd - lineStart);
          lineProgress = (lineDuration > 0)
            ? Math.max(0, Math.min(1, (t - lineStart) / lineDuration))
            : -1;
        }

        const now = Date.now();
        if (now - lastProgressEmitAt >= 150) {
          lastProgressEmitAt = now;
          emit({
            type: 'progress',
            time: t,
            seeked: didSeek,
            idx,
            lineStart,
            lineEnd,
            lineDuration,
            lineProgress,
          });
        }

        if (idx === -1) {
          if (lastIdx !== -1) {
            lastIdx = -1;
            lastMain = '';
            lastTranslation = '';
            emit({ type: 'lyrics', main: '', translation: '', time: t, lineStart: 0, lineEnd: 0, lineDuration: 0, lineProgress: -1, segments: [] });
          }
          break;
        }

        const line = lines[idx];
        const main = (line.main || '').trim();
        const translation = (line.translation || '').trim();

        if (idx !== lastIdx || main !== lastMain || translation !== lastTranslation) {
          const wasTransition = (lastIdx >= 0 && idx !== lastIdx);
          lastIdx = idx;
          lastMain = main;
          lastTranslation = translation;
          emit({
            type: 'lyrics',
            main,
            translation,
            time: t,
            lineStart,
            lineEnd,
            lineDuration,
            lineProgress,
            segments: Array.isArray(line.segments) ? line.segments : [],
            isTransition: wasTransition,  // Signal to UI for faster initial animation
          });
        }
        break;
      }

      case 'status-change':
        // Currently unused, but we keep the hook for future.
        break;

      default:
        break;
    }
  };
}

process.on('SIGINT', () => {
  try { ws?.close(); } catch {}
  process.exit(0);
});
process.on('SIGTERM', () => {
  try { ws?.close(); } catch {}
  process.exit(0);
});

connect();
