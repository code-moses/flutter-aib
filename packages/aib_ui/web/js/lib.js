// Shared plumbing: html tag, API client, store, router, formatters, statistics.
import { h, render, Fragment } from 'preact';
import { useState, useEffect, useRef, useMemo, useCallback, useLayoutEffect } from 'preact/hooks';
import htm from 'htm';

export const html = htm.bind(h);
export { h, render, Fragment, useState, useEffect, useRef, useMemo, useCallback, useLayoutEffect };

// ---------------------------------------------------------------------------
// Store: one small object; components subscribe through useStore().

const listeners = new Set();
export const store = {
  info: null,                    // /api/info
  library: localStorage_get('aib.library'),
  runs: null,                    // /api/runs for the library
  loading: false,
  error: null,
  jobs: [],
  toast: null,
};
function localStorage_get(k) { try { return localStorage.getItem(k) || null; } catch { return null; } }
function localStorage_set(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch { /* private mode */ } }
export const pref = {
  get(k, d) { try { const v = localStorage.getItem('aib.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('aib.' + k, JSON.stringify(v)); } catch { /* ignore */ } },
};
export function setStore(patch) { Object.assign(store, patch); listeners.forEach((l) => l()); }
export function useStore() {
  const [, bump] = useState(0);
  useEffect(() => { const l = () => bump((n) => n + 1); listeners.add(l); return () => listeners.delete(l); }, []);
  return store;
}

export function toast(message, ms = 3800) {
  setStore({ toast: message });
  clearTimeout(toast.t);
  toast.t = setTimeout(() => setStore({ toast: null }), ms);
}

// ---------------------------------------------------------------------------
// API

export async function api(path, { method = 'GET', body, query } = {}) {
  const qs = query ? '?' + new URLSearchParams(Object.entries(query).filter(([, v]) => v != null && v !== '')).toString() : '';
  const res = await fetch('/api/' + path + qs, {
    method,
    headers: method === 'GET' ? {} : { 'content-type': 'application/json', 'x-aib-ui': '1' },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) {
    const err = new Error((data && data.error) || res.statusText);
    err.status = res.status;
    throw err;
  }
  return data;
}
export const lib = () => store.library || store.info?.defaultLibrary;
export const runApi = (path, query = {}) => api(path, { query: { dir: lib(), ...query } });

export async function loadInfo() {
  const info = await api('info');
  setStore({ info });
  return info;
}
export async function loadRuns({ quiet = false } = {}) {
  if (!quiet) setStore({ loading: true, error: null });
  try {
    const data = await api('runs', { query: { dir: lib() } });
    setStore({ runs: data, loading: false, error: null });
  } catch (e) {
    setStore({ loading: false, error: e.message, runs: null });
  }
}
export async function setLibrary(dir) {
  localStorage_set('aib.library', dir);
  setStore({ library: dir, runs: null });
  api('user/recent', { method: 'POST', body: { path: dir } }).then((u) => setStore({ info: { ...store.info, user: u } })).catch(() => {});
  await loadRuns();
}

export function useAsync(fn, deps) {
  const [state, set] = useState({ loading: true, data: null, error: null });
  const [tick, setTick] = useState(0);
  const silent = useRef(false);
  // A reload keeps what is on screen until the new data arrives.
  const reload = useCallback(() => { silent.current = true; setTick((n) => n + 1); }, []);
  useEffect(() => {
    let live = true;
    const quiet = silent.current; silent.current = false;
    set((s) => (quiet ? s : { ...s, loading: true, error: null }));
    Promise.resolve().then(fn).then((data) => live && set({ loading: false, data, error: null }), (error) => live && set({ loading: false, data: null, error: error.message || String(error) }));
    return () => { live = false; };
  }, [...deps, tick]);
  return { ...state, reload };
}

// ---------------------------------------------------------------------------
// Router: #/path/segments?query

export function parseHash(hash = location.hash) {
  const raw = hash.replace(/^#/, '') || '/';
  const [p, q = ''] = raw.split('?');
  return { path: p.split('/').filter(Boolean).map(decodeURIComponent), query: Object.fromEntries(new URLSearchParams(q)) };
}
export function href(path, query) {
  const p = '/' + path.map((s) => encodeURIComponent(s)).join('/');
  const q = query ? Object.entries(query).filter(([, v]) => v != null && v !== '') : [];
  return '#' + p + (q.length ? '?' + new URLSearchParams(q).toString() : '');
}
export function go(path, query, { replace = false } = {}) {
  const target = href(path, query);
  if (replace) history.replaceState(null, '', target), window.dispatchEvent(new HashChangeEvent('hashchange'));
  else location.hash = target;
}
export function useRoute() {
  const [r, set] = useState(parseHash());
  useEffect(() => { const f = () => set(parseHash()); window.addEventListener('hashchange', f); return () => window.removeEventListener('hashchange', f); }, []);
  return r;
}

// ---------------------------------------------------------------------------
// Formatting

const nf = (d) => new Intl.NumberFormat('en', { maximumFractionDigits: d, minimumFractionDigits: 0 });
export const fmtInt = (x) => x == null || Number.isNaN(x) ? '—' : nf(0).format(Math.round(x));
export function fmtNum(x, d = 2) {
  if (x == null || Number.isNaN(x)) return '—';
  const a = Math.abs(x);
  if (a !== 0 && a < 0.01) return x.toExponential(1);
  return nf(a >= 100 ? 0 : a >= 10 ? 1 : d).format(x);
}
export const fmtPct = (x, d = 0) => x == null || Number.isNaN(x) ? '—' : (x * 100).toFixed(d) + '%';
export function fmtMs(ms) {
  if (ms == null || Number.isNaN(ms)) return '—';
  if (ms < 0) return '−' + fmtMs(-ms);
  if (ms < 1) return '0 ms';
  if (ms < 1000) return Math.round(ms) + ' ms';
  const s = ms / 1000;
  if (s < 60) return (s < 10 ? s.toFixed(1) : s.toFixed(0)) + ' s';
  const m = Math.floor(s / 60);
  if (m < 60) return m + ' m ' + String(Math.round(s % 60)).padStart(2, '0') + ' s';
  return Math.floor(m / 60) + ' h ' + String(m % 60).padStart(2, '0') + ' m';
}
export function fmtTok(x) {
  if (x == null || Number.isNaN(x)) return '—';
  if (x < 0) return '−' + fmtTok(-x);
  if (x >= 1e6) return (x / 1e6).toFixed(2) + 'M';
  if (x >= 1e4) return (x / 1e3).toFixed(0) + 'k';
  if (x >= 1e3) return (x / 1e3).toFixed(1) + 'k';
  return String(Math.round(x));
}
export const fmtUsd = (x) => x == null || Number.isNaN(x) ? '—' : x === 0 ? '$0' : x < 0.01 ? '$' + x.toFixed(4) : '$' + x.toFixed(x < 1 ? 3 : 2);
export function fmtBytes(b) {
  if (b == null) return '—';
  if (b < 1024) return b + ' B';
  if (b < 1048576) return (b / 1024).toFixed(1) + ' kB';
  return (b / 1048576).toFixed(1) + ' MB';
}
export function fmtDate(iso, withTime = true) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (isNaN(d)) return String(iso);
  const date = d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' });
  return withTime ? date + ' ' + d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) : date;
}
export function ago(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return '';
  const s = (Date.now() - d) / 1000;
  if (s < 90) return 'just now';
  if (s < 5400) return Math.round(s / 60) + ' min ago';
  if (s < 129600) return Math.round(s / 3600) + ' h ago';
  if (s < 86400 * 45) return Math.round(s / 86400) + ' d ago';
  return Math.round(s / 86400 / 30) + ' mo ago';
}

// A metric's value in its own unit.
export function fmtMetric(name, v) {
  if (typeof v === 'number' && v < 0) return '−' + fmtMetric(name, -v);
  if (v == null || (typeof v === 'number' && Number.isNaN(v))) return '—';
  if (typeof v === 'string') return v;
  const u = metricInfo(name).unit;
  switch (u) {
    case 'ms': return fmtMs(v);
    case 'tokens': return fmtTok(v);
    case 'usd': return fmtUsd(v);
    case 'bytes': return fmtBytes(v);
    case 'bool': case 'ratio': return fmtPct(v, v > 0 && v < 0.1 ? 1 : 0);
    case 'count': return fmtNum(v, 1);
    default: return fmtNum(v, 2);
  }
}

// ---------------------------------------------------------------------------
// Metric catalog (snapshot shipped in metrics.json; the live one wins when the framework answers)

let catalog = new Map();
export async function loadCatalog() {
  try {
    const snap = await (await fetch('metrics.json')).json();
    catalog = new Map(snap.metrics.map((m) => [m.name, m]));
  } catch { /* the UI works without descriptions */ }
}
const LOWER_BETTER = /^(tokens_|wall_clock|llm_latency|framework_overhead|cost_usd|failure|abort|infrastructure|premature|overdue|budget|no_progress|suppressed|unsupported|kind_integrity|failed_envelope|retry|redundant|self_correction|truncated|elided|invalid_tool|uninformative|dead_end|unwarranted|ungrounded|collateral|policy_violation|unconfirmed|harm|peak_prompt|catalog_bytes|observation_|action_count|turns|discovery|time_to_first|recovery_time|token_report_disc|side_call|guard_denials|decision_|prefetch_waste|prefetch_refetch|missed_|unneeded_|ignored|user_correction|user_reask|user_stopped|user_abandoned|memory_peak|energy|brier|calibration_error|llm_roundtrips|tokens_resent|context_util|ttft|llm_call_latency)/;
const HIGHER_BETTER = /^(success|weighted_score|recovered|completion_under|path_efficiency|milestone|facts_seen|tool_recall|tool_complete|tool_ndcg|prefetch_precision|prefetch_recall|outcome_consistency|trajectory_consistency|cache_hit|tokens_per_second|safe_refusal|simulation_valid|consistent_after|confidence_sep|turns_answered|escalation_recovered)/;
export function metricInfo(name) {
  const m = catalog.get(name) || catalog.get(name.replace(/^agent\..*/, 'agent.<name>')) || {};
  const dir = HIGHER_BETTER.test(name) ? 1 : LOWER_BETTER.test(name) ? -1 : 0;
  return { name, unit: m.unit || guessUnit(name), description: m.description || '', source: m.source || '', dir, label: name.replace(/^agent\./, 'agent · ').replace(/_/g, ' ') };
}
function guessUnit(n) {
  if (/_ms$/.test(n)) return 'ms';
  if (/tokens/.test(n)) return 'tokens';
  if (/_usd$/.test(n)) return 'usd';
  if (/_bytes$/.test(n)) return 'bytes';
  if (/ratio|share|rate|precision|recall/.test(n)) return 'ratio';
  if (/count|turns|steps/.test(n)) return 'count';
  return 'score';
}
export const allMetricNames = () => [...catalog.keys()];

// ---------------------------------------------------------------------------
// Statistics

export const isNum = (x) => typeof x === 'number' && Number.isFinite(x);
export const nums = (xs) => xs.filter(isNum);
export const sum = (xs) => nums(xs).reduce((a, b) => a + b, 0);
export function mean(xs) { const v = nums(xs); return v.length ? v.reduce((a, b) => a + b, 0) / v.length : null; }
export function sd(xs) { const v = nums(xs); if (v.length < 2) return null; const m = mean(v); return Math.sqrt(v.reduce((a, b) => a + (b - m) ** 2, 0) / (v.length - 1)); }
export function quantile(xs, q) {
  const v = nums(xs).sort((a, b) => a - b);
  if (!v.length) return null;
  const i = (v.length - 1) * q, lo = Math.floor(i), hi = Math.ceil(i);
  return v[lo] + (v[hi] - v[lo]) * (i - lo);
}
export const median = (xs) => quantile(xs, 0.5);
export function wilson(k, n, z = 1.96) {
  if (!n) return [null, null];
  const p = k / n, d = 1 + z * z / n;
  const c = (p + z * z / (2 * n)) / d, w = z * Math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d;
  return [Math.max(0, c - w), Math.min(1, c + w)];
}
function rng(seed) { let a = seed >>> 0; return () => { a |= 0; a = a + 0x6D2B79F5 | 0; let t = Math.imul(a ^ a >>> 15, 1 | a); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; }; }
/** Bootstrap CI of the mean over [xs] (resampling the units — tasks — not the episodes). */
export function bootMean(xs, n = 2000, seed = 7) {
  const v = nums(xs);
  if (v.length < 2) return [mean(v), mean(v)];
  const r = rng(seed), ms = [];
  for (let i = 0; i < n; i++) { let s = 0; for (let j = 0; j < v.length; j++) s += v[Math.floor(r() * v.length)]; ms.push(s / v.length); }
  return [quantile(ms, 0.025), quantile(ms, 0.975)];
}

// Episodes → value per metric
export function metricValues(episodes, metric) {
  return episodes.map((e) => e.metrics?.[metric]).filter(isNum);
}
/** task → mean of [metric] over its episodes. */
export function taskMeans(episodes, metric) {
  const by = new Map();
  for (const e of episodes) {
    const v = metric === 'score' ? e.score : e.metrics?.[metric];
    if (!isNum(v)) continue;
    if (!by.has(e.taskId)) by.set(e.taskId, []);
    by.get(e.taskId).push(v);
  }
  return new Map([...by].map(([k, v]) => [k, mean(v)]));
}
/** Paired difference of two task→mean maps over their common tasks, with a bootstrap CI. */
export function pairedDelta(a, b) {
  const tasks = [...a.keys()].filter((t) => b.has(t));
  if (!tasks.length) return null;
  const d = tasks.map((t) => b.get(t) - a.get(t));
  const [lo, hi] = bootMean(d);
  return { delta: mean(d), lo, hi, n: tasks.length, sig: tasks.length > 1 && (lo > 0 || hi < 0) };
}

export const VERDICT = {
  success: { glyph: '●', label: 'success', cls: 'v-success', cell: 's' },
  partial: { glyph: '◐', label: 'partial', cls: 'v-partial', cell: 'p' },
  failure: { glyph: '○', label: 'failure', cls: 'v-failure', cell: 'f' },
  error: { glyph: '✕', label: 'error', cls: 'v-error', cell: 'e' },
  unscored: { glyph: '–', label: 'not scored', cls: 'v-error', cell: 'e' },
};
export const verdictOf = (v) => (v == null ? VERDICT.unscored : VERDICT[v] || VERDICT.error);

// ---------------------------------------------------------------------------
// Misc

export function download(name, text, type = 'text/plain') {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}
export function csv(rows) {
  const esc = (v) => v == null ? '' : /[",\n]/.test(String(v)) ? '"' + String(v).replace(/"/g, '""') + '"' : String(v);
  return rows.map((r) => r.map(esc).join(',')).join('\n');
}
export const cls = (...xs) => xs.filter(Boolean).join(' ');
export function shortModel(m) { return m ? String(m).replace(/^claude-/, 'claude ').replace(/-(\d{8})$/, '') : '—'; }
export function runLabel(run, ann) { return (ann && ann.alias) || run.name; }
export function groupBy(xs, f) { const m = new Map(); for (const x of xs) { const k = f(x); if (!m.has(k)) m.set(k, []); m.get(k).push(x); } return m; }
export function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }
