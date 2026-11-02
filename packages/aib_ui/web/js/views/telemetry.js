// OpenTelemetry: spans the runs export (aib.episode → invoke_agent → execute_tool),
// received on /v1/traces. A waterfall per episode, a live list, and the link back to the trace.
import { html, useState, useMemo, useEffect, useStore, api, useAsync, go, href, toast, pref, fmtMs, fmtTok, fmtInt, fmtNum, fmtDate, ago, cls, runLabel, isNum } from '../lib.js';
import { PageHead, Section, Chip, Loading, ErrorBox, Empty, Seg, JsonView, Copy, tip } from '../ui.js';
import { ticks, trunc } from '../charts.js';

const KIND = {
  'aib.episode': { color: 'var(--ink)', label: 'episode' },
  invoke_agent: { color: 'var(--s1)', label: 'decision' },
  execute_tool: { color: 'var(--s4)', label: 'tool' },
};
const kindOf = (s) => KIND[s.name] || { color: 'var(--s7)', label: 'span' };
const ok = (s) => s.status?.code !== 2;
const usToMs = (us) => us / 1000;

/** Spans as a depth-first list with their depth, children ordered by start. */
export function spanTree(spans) {
  const by = new Map(spans.map((s) => [s.spanId, s]));
  const kids = new Map();
  const roots = [];
  for (const s of spans) {
    if (s.parentId && by.has(s.parentId)) { if (!kids.has(s.parentId)) kids.set(s.parentId, []); kids.get(s.parentId).push(s); }
    else roots.push(s);
  }
  const out = [];
  const walk = (s, d) => { out.push({ s, d }); (kids.get(s.spanId) || []).sort((a, b) => a.startUs - b.startUs).forEach((c) => walk(c, d + 1)); };
  roots.sort((a, b) => a.startUs - b.startUs).forEach((r) => walk(r, 0));
  return out;
}

function detail(s) {
  const a = s.attrs || {};
  if (s.name === 'invoke_agent') return [a['aib.envelope.key'], a['gen_ai.usage.input_tokens'] != null ? `${fmtTok(a['gen_ai.usage.input_tokens'])}→${fmtTok(a['gen_ai.usage.output_tokens'] || 0)} tok` : null].filter(Boolean).join(' · ');
  if (s.name === 'execute_tool') return `${a['gen_ai.tool.name'] ?? ''}${a['aib.status'] && a['aib.status'] !== 'ok' ? ' · ' + a['aib.status'] : ''}`;
  if (s.name === 'aib.episode') return `${a['aib.task_id'] ?? ''} · ${a['aib.termination_reason'] ?? ''}`;
  return '';
}

/** The span tree against a shared time axis. [onSelect] gets the span and, for decisions, its step index. */
export function Waterfall({ spans, selected, onSelect, compact }) {
  const rows = useMemo(() => spanTree(spans), [spans]);
  const decisions = useMemo(() => spans.filter((s) => s.name === 'invoke_agent').sort((a, b) => a.startUs - b.startUs).map((s) => s.spanId), [spans]);
  if (!rows.length) return html`<${Empty}>No spans.</${Empty}>`;
  const t0 = Math.min(...spans.map((s) => s.startUs)), t1 = Math.max(...spans.map((s) => s.endUs));
  const total = Math.max(1, t1 - t0);
  const tk = ticks(0, total / 1000, 5);
  const rowH = compact ? 22 : 26;
  return html`<div style="border:1px solid var(--rule-2);background:var(--panel)">
    <div style=${{ display: 'grid', gridTemplateColumns: `${compact ? 250 : 320}px 1fr`, borderBottom: '1px solid var(--rule-2)' }}>
      <div class="faint" style="padding:3px 10px;font:600 9.5px var(--sans);letter-spacing:.13em;text-transform:uppercase">span</div>
      <div style="position:relative;height:20px">${tk.map((t) => html`<span key=${t} class="mono faint" style=${{ position: 'absolute', left: (t * 1000 / total) * 100 + '%', fontSize: '10.5px', transform: 'translateX(-50%)', top: '3px' }}>${fmtMs(t)}</span>`)}</div>
    </div>
    ${rows.map(({ s, d }) => {
      const k = kindOf(s), left = ((s.startUs - t0) / total) * 100, width = Math.max(0.35, ((s.endUs - s.startUs) / total) * 100);
      const llm = s.name === 'invoke_agent' ? Number(s.attrs?.['aib.llm_latency_ms']) : NaN;
      const llmW = isNum(llm) ? Math.min(100, (llm * 1000 / Math.max(1, s.endUs - s.startUs)) * 100) : 0;
      const step = s.name === 'invoke_agent' ? decisions.indexOf(s.spanId) : s.name === 'execute_tool' ? decisions.indexOf(s.parentId) : -1;
      const bad = !ok(s);
      return html`<div key=${s.spanId} onClick=${() => onSelect && onSelect(s, step)} style=${{ display: 'grid', gridTemplateColumns: `${compact ? 250 : 320}px 1fr`, height: rowH + 'px', alignItems: 'center', cursor: onSelect ? 'pointer' : 'default', background: selected === s.spanId ? 'var(--mark)' : '', borderBottom: '1px solid var(--rule)' }}
        onMouseMove=${(e) => tip.show(e, html`<b>${s.name}</b> <span style="opacity:.7">${detail(s)}</span><div class="row"><span>duration</span><span class="m">${fmtMs((s.endUs - s.startUs) / 1000)}</span></div><div class="row"><span>starts at</span><span class="m">+${fmtMs((s.startUs - t0) / 1000)}</span></div>${isNum(llm) ? html`<div class="row"><span>model</span><span class="m">${fmtMs(llm)}</span></div>` : ''}${bad ? html`<div style="color:#ffb4b4">error: ${s.status.message || 'status error'}</div>` : ''}`)} onMouseLeave=${tip.hide}>
        <div style=${{ paddingLeft: 10 + d * 16 + 'px', overflow: 'hidden', whiteSpace: 'nowrap', textOverflow: 'ellipsis', fontSize: '12.5px' }}>
          <span style=${{ display: 'inline-block', width: '8px', height: '8px', background: k.color, marginRight: '7px', borderRadius: '2px' }}></span><span class="mono" style="font-size:12px">${s.name}</span>${bad ? html` <span style="color:var(--crit-ink)">✕</span>` : ''} <span class="faint" style="font-size:11.5px">${trunc(detail(s), 44)}</span></div>
        <div style="position:relative;height:100%">
          <div style=${{ position: 'absolute', left: left + '%', width: width + '%', top: '6px', bottom: '6px', background: k.color, opacity: s.name === 'aib.episode' ? 0.18 : 0.38, outline: bad ? '2px solid var(--crit)' : 'none', borderRadius: '1px' }}></div>
          ${llmW > 0 && html`<div style=${{ position: 'absolute', left: left + '%', width: (width * llmW) / 100 + '%', top: '6px', bottom: '6px', background: k.color, borderRadius: '1px' }}></div>`}
          <span class="mono" style=${{ position: 'absolute', ...(left + width > 82 ? { right: `calc(${100 - left}% + 6px)` } : { left: `calc(${left + width}% + 6px)` }), top: '4px', fontSize: '11px', color: 'var(--ink-2)', pointerEvents: 'none' }}>${fmtMs((s.endUs - s.startUs) / 1000)}</span>
        </div>
      </div>`;
    })}
    <div class="legend" style="padding:6px 10px;margin:0"><span><i style="background:var(--ink);opacity:.4"></i>episode</span><span><i style="background:var(--s1)"></i>decision (solid = model time)</span><span><i style="background:var(--s4)"></i>tool call</span></div>
  </div>`;
}

export function SpanPanel({ span }) {
  if (!span) return html`<div class="faint">Click a span to see its attributes.</div>`;
  const { attrs = {}, events = [] } = span;
  let payload = attrs['aib.payload'];
  try { if (typeof payload === 'string') payload = JSON.parse(payload); } catch { /* leave as text */ }
  const rest = Object.fromEntries(Object.entries(attrs).filter(([k]) => k !== 'aib.payload'));
  return html`<div>
    <h3>${span.name}</h3>
    <dl class="kv" style="margin-bottom:10px"><dt>duration</dt><dd>${fmtMs((span.endUs - span.startUs) / 1000)}</dd><dt>span id</dt><dd>${span.spanId}</dd><dt>status</dt><dd>${span.status?.code === 2 ? 'error — ' + span.status.message : span.status?.code === 1 ? 'ok' : 'unset'}</dd></dl>
    <${JsonView} value=${rest} open=${1} />
    ${payload !== undefined && html`<h3 style="margin-top:12px">Captured payload</h3><${JsonView} value=${payload} open=${1} />`}
    ${events.length > 0 && html`<h3 style="margin-top:12px">Events</h3>${events.map((e, i) => html`<div key=${i} class="mono" style="font-size:12px"><b>${e.name}</b> <span class="faint">${JSON.stringify(e.attrs)}</span></div>`)}`}
  </div>`;
}

export function EndpointBox({ info }) {
  const url = info?.conventionalEndpoint || info?.endpoint;
  const cmd = `aib run … --otel ${url}`;
  return html`<div style="border:1px solid var(--rule-2);background:var(--panel);padding:10px 14px;display:grid;gap:6px">
    <div class="faint" style="font:600 9.5px var(--sans);letter-spacing:.14em;text-transform:uppercase">OTLP/HTTP endpoint of this UI</div>
    <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap"><code class="mono" style="font-size:13px">${url}</code><${Copy} text=${url} />${info?.conventionalEndpoint && info.endpoint !== url ? html`<span class="faint" style="font-size:12px">also ${info.endpoint}</span>` : ''}</div>
    <div class="muted" style="font-size:12.5px">Point a run at it: <code class="mono">${cmd}</code> (add <code>--otel-capture-content</code> for payloads) — or tick <i>Export OpenTelemetry</i> on the Launch page. Any OTLP/HTTP exporter works (protobuf, JSON, gzip).</div>
  </div>`;
}

// ---------------------------------------------------------------------------

export function TelemetryView({ id, query }) {
  return id ? html`<${TraceDetail} key=${id} id=${id} />` : html`<${TraceList} query=${query} />`;
}

function useLive(path, query, deps, ms = 2000) {
  const [state, set] = useState({ loading: true, data: null, error: null });
  useEffect(() => {
    let live = true, t;
    const tick = async () => {
      try { const data = await api(path, { query }); if (live) set({ loading: false, data, error: null }); }
      catch (e) { if (live) set((s) => ({ ...s, loading: false, error: e.message })); }
      if (live) t = setTimeout(tick, ms);
    };
    tick(); return () => { live = false; clearTimeout(t); };
  }, deps);
  return state;
}

function TraceList({ query }) {
  const s = useStore();
  const [run, setRun] = useState(query.run || '');
  const [q, setQ] = useState('');
  const info = useLive('otel/info', {}, []);
  const list = useLive('otel/traces', { run, q }, [run, q]);
  const traces = list.data?.traces || [];
  const runs = useMemo(() => [...new Set(traces.map((t) => t.runId).filter(Boolean))], [traces]);
  const [allRuns, setAllRuns] = useState([]);
  useEffect(() => { if (runs.length) setAllRuns((old) => [...new Set([...old, ...runs])]); }, [runs.join()]);
  const libRun = (runId) => s.runs?.runs.find((r) => r.runId === runId);
  const live = traces.filter((t) => t.live).length;
  const clear = async () => { if (confirm('Forget all received spans?')) { await api('otel/clear', { method: 'POST', body: {} }); toast('cleared'); } };
  const i = info.data;
  return html`<div>
    <${PageHead} kicker="VI · Telemetry" title=${html`Spans <em>(${i ? fmtInt(i.spans) : '…'})</em>`} sub="What runs export while they execute: one OpenTelemetry trace per episode, following the GenAI conventions. The JSONL trace stays canonical; this is the same events as a second reader sees them.">
      <button class="btn ghost" onClick=${clear}>Clear</button>
    </${PageHead}>
    <${EndpointBox} info=${i} />
    <div style="display:flex;gap:12px;align-items:center;margin:18px 0 10px;flex-wrap:wrap">
      <select value=${run} onChange=${(e) => setRun(e.target.value)} style="width:auto;max-width:360px" aria-label="run"><option value="">all runs</option>${[...new Set([...allRuns, run].filter(Boolean))].map((r) => html`<option key=${r} value=${r}>${libRun(r) ? libRun(r).name + ' · ' : ''}${r}</option>`)}</select>
      <input type="search" placeholder="Filter episode, task, agent…" value=${q} onInput=${(e) => setQ(e.target.value)} style="max-width:260px" />
      <span class="faint" style="margin-left:auto;font-size:12px">${live ? html`<span class="spinner"></span> ${live} running · ` : ''}${i?.lastAt ? 'last batch ' + ago(i.lastAt) : 'nothing received yet'} · refreshes every 2 s</span>
    </div>
    <${ErrorBox} error=${list.error} />
    ${list.loading ? html`<${Loading} />` : !traces.length ? html`<${Empty}>${i?.spans ? 'No trace matches.' : 'No spans yet. Start a run with the endpoint above.'}</${Empty}>` : html`<div class="tw"><table class="t compact">
      <thead><tr><th>Started</th><th>Episode</th><th>Run</th><th class="r">Duration</th><th class="r">Decisions</th><th class="r">Tools</th><th class="r">Tokens in → out</th><th>Ended</th></tr></thead>
      <tbody>${traces.map((t) => html`<tr key=${t.traceId} class="row-link" onClick=${() => go(['telemetry', t.traceId])}>
        <td class="muted" style="white-space:nowrap">${new Date(t.startUs / 1000).toLocaleTimeString('en-GB')}<div class="sub">${ago(new Date(t.startUs / 1000).toISOString())}</div></td>
        <td><div class="nm mono" style="font-size:12px">${t.episodeId || t.traceId.slice(0, 12)}</div><div class="sub">${t.taskId || ''}${t.agent ? ' · ' + t.agent : ''}</div></td>
        <td class="muted" style="font-size:12px">${libRun(t.runId)?.name || t.runId || '—'}</td>
        <td class="n">${fmtMs(t.durationUs / 1000)}</td><td class="n">${t.decisions}</td><td class="n">${t.tools}</td>
        <td class="n">${fmtTok(t.tokensIn)} → ${fmtTok(t.tokensOut)}</td>
        <td>${t.live ? html`<span class="state running">running</span>` : html`<span>${t.reason || '—'}</span>`}${t.errors ? html` <span style="color:var(--crit-ink)" title="spans with error status">✕ ${t.errors}</span>` : ''}</td></tr>`)}</tbody>
    </table></div>`}
  </div>`;
}

function TraceDetail({ id }) {
  const s = useStore();
  const d = useLive('otel/trace', { id }, [id], 2500);
  const [sel, setSel] = useState(null);
  if (d.loading) return html`<${Loading} />`;
  if (d.error && !d.data) return html`<div><${PageHead} kicker="Telemetry" title="Not found" /><${ErrorBox} error=${d.error} /></div>`;
  const { summary: sm, spans } = d.data;
  const span = spans.find((x) => x.spanId === sel);
  const lib = s.runs?.runs.find((r) => r.runId === sm.runId);
  return html`<div>
    <${PageHead} kicker=${html`<a href="#/telemetry">Telemetry</a> · ${sm.agent || ''}`} title=${sm.episodeId || sm.traceId} sub=${html`<span class="mono" style="font-size:12px">trace ${sm.traceId}</span> · ${fmtDate(new Date(sm.startUs / 1000).toISOString())}${sm.live ? ' · still running' : ''}`}>
      ${lib && sm.episodeId && html`<a class="btn" href=${href(['run', lib.id, 'ep', sm.episodeId])}>Open the episode trace →</a>`}
    </${PageHead}>
    <div class="kpis">
      <div class="kpi"><div class="l">Duration</div><div class="v">${fmtMs(sm.durationUs / 1000)}</div><div class="d">${sm.wallClockMs != null ? 'engine wall clock ' + fmtMs(sm.wallClockMs) : ''}</div></div>
      <div class="kpi"><div class="l">Decisions</div><div class="v">${sm.decisions}</div><div class="d">${sm.tools} tool calls</div></div>
      <div class="kpi"><div class="l">Tokens</div><div class="v">${fmtTok(sm.tokensIn + sm.tokensOut)}</div><div class="d">${fmtTok(sm.tokensIn)} in · ${fmtTok(sm.tokensOut)} out</div></div>
      <div class="kpi"><div class="l">Ended</div><div class="v" style="font-size:22px">${sm.live ? 'running' : sm.reason || '—'}</div><div class="d">${sm.errors ? sm.errors + ' span' + (sm.errors > 1 ? 's' : '') + ' with error status' : 'no error spans'}</div></div>
    </div>
    <div class="trace-grid" style="margin-top:20px">
      <div><${Waterfall} spans=${spans} selected=${sel} onSelect=${(x) => setSel(x.spanId)} />
        <p class="faint" style="font-size:12px">A decision span opens when the agent gets its turn and closes when its envelope has been handled: its length is thinking plus acting. Payloads appear only when the run was started with content capture.</p></div>
      <aside class="sideblock" style="margin-top:0"><${SpanPanel} span=${span} /></aside>
    </div>
  </div>`;
}
