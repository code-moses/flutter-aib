// One episode, read like a transcript: what the agent was asked, each step it took,
// what the model said (when captured), what the app answered, and what finally changed.
import { html, useState, useMemo, useEffect, useRef, useStore, runApi, api, useAsync, go, href, lib,
  fmtTok, fmtMs, fmtInt, fmtNum, fmtPct, fmtUsd, fmtBytes, fmtMetric, metricInfo, isNum, verdictOf, cls, csv, download, toast, mean } from '../lib.js';
import { PageHead, Section, Verdict, Chip, Loading, ErrorBox, Empty, JsonView, Seg, Copy, useKeys, tip } from '../ui.js';
import { StepBars, Legend, trunc } from '../charts.js';
import { useRun, VERDICT_COLORS } from './run.js';
import { Waterfall, SpanPanel, EndpointBox } from './telemetry.js';

const C = { prompt: 'var(--s1)', completion: 'var(--s2)', llm: 'var(--s1)', env: 'var(--s4)' };

// ---------------------------------------------------------------------------
// Trace model

export function buildTrace(events) {
  const t = { meta: null, start: null, reset: null, baseline: null, descriptor: null, final: null, end: null, steps: [], errors: [], samples: [], probes: [], tail: [] };
  const bySeq = new Map();
  let lastStep = null, lastFp = null;
  for (const ev of events) {
    const d = ev.data || {};
    switch (ev.type) {
      case 'episode.meta': t.meta = d; break;
      case 'episode.start': t.start = d; break;
      case 'env.reset': t.reset = d; break;
      case 'state.baseline': t.baseline = d; lastFp = d.fingerprint; break;
      case 'env.descriptor': t.descriptor = d; break;
      case 'final.state': t.final = d; break;
      case 'episode.end': t.end = { ...d, tUs: ev.tUs }; break;
      case 'agent.envelope': {
        const step = { seq: d.seq, idx: t.steps.length, key: d.key, kind: d.kind, payload: d.payload, bytes: d.payloadBytes, decision: d.decision || null, tUs: ev.tUs, result: null, after: [], changed: false };
        t.steps.push(step); bySeq.set(d.seq, step); lastStep = step; break;
      }
      case 'env.result': { const s = bySeq.get(d.seq); if (s) { s.result = d; s.resultTUs = ev.tUs; } break; }
      case 'state.fingerprint': {
        const s = bySeq.get(d.seq);
        if (s) { s.fingerprint = d.fingerprint; s.changed = lastFp != null && d.fingerprint !== lastFp; }
        lastFp = d.fingerprint; break;
      }
      case 'state.probe': { const s = bySeq.get(d.seq); (s || t).probe = d; t.probes.push({ ...d, tUs: ev.tUs }); break; }
      case 'resource.sample': t.samples.push({ ...d, tUs: ev.tUs }); break;
      case 'engine.error': t.errors.push({ ...d, tUs: ev.tUs }); (lastStep || t).after?.push?.({ type: ev.type, d }); break;
      case 'user.turn': case 'user.steer': case 'user.simulated': case 'engine.no_progress': {
        const s = bySeq.get(d.seq) || lastStep;
        (s ? s.after : t.tail).push({ type: ev.type, d, tUs: ev.tUs });
        break;
      }
      default: if (ev.type !== 'trace.unreadable') (lastStep ? lastStep.after : t.tail).push({ type: ev.type, d, tUs: ev.tUs, unknown: true });
    }
  }
  return t;
}

function paramText(p, max = 90) {
  if (p == null || typeof p !== 'object') return p == null ? '' : String(p);
  const s = Object.entries(p).map(([k, v]) => `${k}: ${typeof v === 'string' ? JSON.stringify(v) : Array.isArray(v) || (v && typeof v === 'object') ? JSON.stringify(v) : v}`).join(', ');
  return trunc(s, max);
}
export function actionOf(s) {
  const p = s.payload || {};
  if (s.key === 'intents.invoke') return { name: p.intent || 'intents.invoke', args: paramText(p.params) };
  if (s.key === 'intents.describe') return { name: 'describe', args: (p.names || []).join(', ') };
  if (s.key === 'intents.catalog') return { name: 'catalog', args: '' };
  if (s.key === 'semantics.tree') return { name: 'read screen', args: '' };
  if (/^semantics\./.test(s.key)) return { name: s.key.replace('semantics.', ''), args: p.label || (p.nodeId != null ? '#' + p.nodeId : '') + (p.text ? ' ← ' + JSON.stringify(trunc(p.text, 40)) : p.direction ? ' ' + p.direction : '') };
  if (/^meta\./.test(s.key) || /^user\./.test(s.key)) return { name: s.key, args: trunc(p.message || p.question || p.text || paramText(p), 100) };
  return { name: s.key, args: paramText(p) };
}
export function resultPreview(r) {
  if (!r) return '(no result recorded)';
  const p = r.payload;
  if (r.error) return typeof r.error === 'string' ? r.error : r.error.message || JSON.stringify(r.error);
  if (p == null) return '';
  if (typeof p === 'string') return p;
  if (p.message && typeof p.message === 'string') return p.message;
  if (p.error) return typeof p.error === 'string' ? p.error : p.error.message || JSON.stringify(p.error);
  const arr = Object.entries(p).find(([, v]) => Array.isArray(v));
  if (arr && Object.keys(p).length <= 3) return `${arr[0]}: ${arr[1].length} item${arr[1].length === 1 ? '' : 's'}${arr[1][0] && typeof arr[1][0] === 'object' ? ' — ' + trunc(arr[1].slice(0, 3).map((x) => x.name || x.title || x.id || x.label || '').filter(Boolean).join(', '), 90) : ''}`;
  return trunc(JSON.stringify(p), 160);
}
function llmOf(s) {
  const l = s.decision?.extra?.llm;
  return Array.isArray(l) ? l : [];
}
function stepText(s) {
  return [s.key, JSON.stringify(s.payload || {}), JSON.stringify(s.result?.payload ?? ''), s.result?.error ? JSON.stringify(s.result.error) : '', llmOf(s).map((l) => `${l.thinking || ''} ${l.content || ''} ${(l.calls || []).join(' ')}`).join(' '), s.decision?.note || ''].join(' ').toLowerCase();
}

// ---------------------------------------------------------------------------

export function TraceView({ run: runId, episode, query }) {
  const run = useRun(runId);
  const ev = useAsync(() => runApi('trace', { run: runId, episode }), [runId, episode, lib()]);
  const [sel, setSel] = useState(0);
  const [openAll, setOpenAll] = useState(query?.open ? true : null);
  const [q, setQ] = useState('');
  const [only, setOnly] = useState('all');
  const refs = useRef({});
  const trace = useMemo(() => (ev.data ? buildTrace(ev.data.events) : null), [ev.data]);
  const ep = run.data?.episodes.find((e) => e.id === episode);
  const list = run.data?.episodes || [];
  const at = list.findIndex((e) => e.id === episode);
  const nav = (d) => { const n = list[at + d]; if (n) go(['run', runId, 'ep', n.id]); };
  const jump = (i) => { setSel(i); refs.current[i]?.scrollIntoView({ block: 'center', behavior: 'smooth' }); };
  useEffect(() => { setSel(0); setOpenAll(query?.open ? true : null); setQ(''); }, [episode]);
  const visible = useMemo(() => (trace ? trace.steps.filter((s) => (only === 'all' || (only === 'act' && s.kind === 'act') || (only === 'changes' && s.changed) || (only === 'problems' && (s.result?.status !== 'ok' || s.result?.suppressed))) && (!q || stepText(s).includes(q.toLowerCase()))) : []), [trace, q, only]);
  useKeys({
    j: () => trace && jump(Math.min(trace.steps.length - 1, sel + 1)), k: () => jump(Math.max(0, sel - 1)),
    ']': () => nav(1), '[': () => nav(-1), e: () => setOpenAll((v) => (v === true ? false : true)), Escape: () => go(['run', runId]),
  }, [sel, trace, at, list.length]);

  if (run.loading || ev.loading) return html`<${Loading} what="reading trace" />`;
  if (run.error || ev.error) return html`<div><${PageHead} kicker="Episode" title="Not found" /><${ErrorBox} error=${run.error || ev.error} /></div>`;
  const r = run.data;
  const task = r.tasks?.find((x) => x.id === ep?.taskId);
  const title = ep?.trace?.title || trace.start?.task?.title || ep?.taskId || episode;
  const budget = trace.start?.task?.budget || {};
  const tokens = trace.steps.map((s) => ({ p: s.decision?.tokensPrompt || 0, c: s.decision?.tokensCompletion || 0 }));
  const totalTok = tokens.reduce((a, b) => a + b.p + b.c, 0);

  return html`<div>
    <${PageHead} kicker=${html`<a href="#/">Runs</a> · <a href=${href(['run', runId])}>${r.name}</a> · ${ep?.agentId} · rep ${ep?.rep ?? '—'}`} title=${title}
      sub=${html`<span class="mono" style="font-size:12px">${episode}</span> · ${trace.meta?.startedAt ? new Date(trace.meta.startedAt).toLocaleString('en-GB') : ''}`}>
      <button class="btn ghost" disabled=${at <= 0} onClick=${() => nav(-1)} title="previous episode ([)">← prev</button>
      <span class="mono faint" style="font-size:12px">${at + 1} / ${list.length}</span>
      <button class="btn ghost" disabled=${at < 0 || at >= list.length - 1} onClick=${() => nav(1)} title="next episode (])">next →</button>
    </${PageHead}>

    <div class="trace-grid">
      <div>
        ${task?.instruction && html`<blockquote style="margin:0 0 16px;padding:2px 0 2px 16px;border-left:3px solid var(--ink);font:italic 400 18px/1.45 var(--serif);max-width:75ch">${task.instruction}<footer class="faint" style="font:11px var(--sans);margin-top:4px;font-style:normal">the task, as given to the agent</footer></blockquote>`}
        ${trace.end && html`<div style="border:1px solid var(--ink);padding:10px 14px;margin-bottom:18px;background:var(--panel);display:grid;grid-template-columns:auto 1fr;gap:4px 16px;align-items:baseline">
          <span class="faint" style="font:600 9.5px var(--sans);letter-spacing:.14em;text-transform:uppercase">ended</span><span><b>${trace.end.reason}</b> · ${fmtMs(trace.end.wallClockMs)} · ${trace.steps.length} envelopes · ${fmtTok(totalTok)} tokens${trace.errors.length ? html` · <span style="color:var(--crit-ink)">${trace.errors.length} engine error</span>` : ''}</span>
          ${trace.end.message && html`<span class="faint" style="font:600 9.5px var(--sans);letter-spacing:.14em;text-transform:uppercase">final words</span><span style="font:italic 400 16px/1.45 var(--serif);white-space:pre-wrap">${trace.end.message}</span>`}
        </div>`}

        <div class="scrub">
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px">
            <div><div class="chart-title"><h3>Tokens per step</h3><span class="u">${fmtTok(totalTok)} total${budget.maxTokens ? ' of ' + fmtTok(budget.maxTokens) : ''}</span></div>
              <${StepBars} steps=${trace.steps.map((s, i) => ({ id: i, label: `step ${i + 1} · ${actionOf(s).name}`, stack: [{ label: 'prompt', value: s.decision?.tokensPrompt || 0, color: C.prompt }, { label: 'completion', value: s.decision?.tokensCompletion || 0, color: C.completion }] }))} selected=${sel} onSelect=${jump} fmt=${fmtTok} height=${88} /></div>
            <div><div class="chart-title"><h3>Time per step</h3><span class="u">${fmtMs(trace.end?.wallClockMs)} wall</span></div>
              <${StepBars} steps=${trace.steps.map((s, i) => ({ id: i, label: `step ${i + 1} · ${actionOf(s).name}`, stack: [{ label: 'model', value: s.decision?.llmLatencyMs || 0, color: C.llm }, { label: 'environment', value: s.result?.handleMs || 0, color: C.env }] }))} selected=${sel} onSelect=${jump} fmt=${fmtMs} height=${88} /></div>
          </div>
          <div style="display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin:4px 0 6px">
            <${Legend} items=${[{ label: 'prompt', color: C.prompt }, { label: 'completion', color: C.completion }, { label: 'model time', color: C.llm }, { label: 'environment time', color: C.env }]} />
            <span style="margin-left:auto;display:flex;gap:8px;align-items:center">
              <input type="search" placeholder="search steps…" value=${q} onInput=${(e) => setQ(e.target.value)} style="width:170px;padding:2px 8px" />
              <${Seg} options=${[{ id: 'all', label: 'all' }, { id: 'act', label: 'acts' }, { id: 'changes', label: 'state changes' }, { id: 'problems', label: 'problems' }]} value=${only} onChange=${setOnly} />
              <button class="btn ghost sm" onClick=${() => setOpenAll(openAll === true ? false : true)} title="e">${openAll === true ? 'collapse all' : 'expand all'}</button>
            </span>
          </div>
        </div>

        <div class="steps">
          ${!visible.length && html`<${Empty}>${trace.steps.length ? 'No step matches.' : 'This episode recorded no agent steps.'}</${Empty}>`}
          ${visible.map((s) => html`<div key=${s.seq} ref=${(el) => (refs.current[s.idx] = el)}><${Step} s=${s} sel=${sel === s.idx} openAll=${openAll} q=${q} onSelect=${() => setSel(s.idx)} prev=${trace.steps[s.idx - 1]} /></div>`)}
          ${trace.tail.map((e, i) => html`<${Event} key=${'t' + i} e=${e} />`)}
        </div>
        <${StateDiff} trace=${trace} />
        <${OtelSection} runId=${r.runId} episode=${episode} onStep=${(i) => i >= 0 && jump(i)} />
        <${Surface} trace=${trace} />
      </div>
      <aside>
        <${VerdictPanel} ep=${ep} />
        <${BudgetPanel} trace=${trace} budget=${budget} ep=${ep} task=${task} />
        <${MetricsPanel} ep=${ep} />
        <div class="sideblock"><h3>Keys</h3><div style="display:grid;grid-template-columns:auto 1fr;gap:3px 10px;font-size:12px"><span class="kbd">j</span><span>next step</span><span class="kbd">k</span><span>previous step</span><span class="kbd">e</span><span>expand / collapse all</span><span class="kbd">[</span><span>previous episode</span><span class="kbd">]</span><span>next episode</span><span class="kbd">esc</span><span>back to the run</span></div></div>
        <div class="sideblock"><h3>Trace file</h3><div class="mono faint" style="font-size:11px;word-break:break-all">${r.dir}/traces/${episode}.jsonl</div><div style="margin-top:6px">${fmtBytes(ep?.trace?.bytes)} · ${ev.data.events.length} events</div></div>
      </aside>
    </div>
  </div>`;
}

// ---------------------------------------------------------------------------

export function Step({ s, sel, openAll, q, onSelect, prev }) {
  const [open, setOpen] = useState(false);
  useEffect(() => { if (openAll != null) setOpen(openAll); }, [openAll]);
  const a = actionOf(s), d = s.decision, llm = llmOf(s), r = s.result;
  const bad = r && r.status !== 'ok';
  const thought = llm.map((l) => l.thinking).filter(Boolean).join('\n\n'), said = llm.map((l) => l.content).filter(Boolean).join('\n\n');
  const calls = llm.flatMap((l) => l.calls || []);
  const prefetch = d?.extra?.prefetch || d?.llmCalls === 0;
  const chars = llm.reduce((n, l) => n + (l.thinkingChars || 0) + (l.contentChars || 0), 0);
  const extraKeys = d?.extra ? Object.keys(d.extra).filter((k) => !['llm', 'tools', 'requestChars', 'prefetch'].includes(k)) : [];
  const gap = prev ? (s.tUs - (prev.resultTUs || prev.tUs)) / 1000 : null;
  return html`<div>
    <article class=${cls('step', sel && 'sel')} id=${'step-' + s.idx}>
      <div class="hd" onClick=${() => { onSelect(); setOpen(!open); }} role="button" tabindex="0" onKeyDown=${(e) => e.key === 'Enter' && setOpen(!open)} aria-expanded=${open}>
        <span class="ix">${s.idx + 1}</span>
        <span class="act"><span class=${'kind ' + (s.kind || 'meta')}>${s.kind}</span>${a.name}${a.args && html` <span class="p">${a.args}</span>`}</span>
        <span class="meta">
          ${s.changed && html`<span title="the app's state changed" style="color:var(--s3)">✱ state</span>`}
          ${bad && html`<span style="color:var(--crit-ink)">${r.status}</span>`}${r?.suppressed && html`<span style="color:var(--warn-ink)">repeat suppressed</span>`}
          ${d && d.tokensPrompt > 0 ? html`<span>${fmtTok(d.tokensPrompt)}→${fmtTok(d.tokensCompletion)} tok</span><span>${fmtMs(d.llmLatencyMs)}</span>` : prefetch ? html`<span class="faint">prefetch</span>` : ''}
          <span class="faint">+${fmtMs((s.tUs || 0) / 1000)}</span>
        </span>
      </div>
      ${!open && html`<div class="sec2" onClick=${() => setOpen(true)} style="cursor:pointer">
        ${(thought || said) ? html`<div class="thought" style="font-size:14px">${trunc(thought || said, 260)}</div>` : ''}
        <div class=${cls('res', bad && 'bad')} style="margin-top:${thought || said ? 6 : 0}px"><span class="faint">→</span> ${trunc(resultPreview(r), 200)}</div>
      </div>`}
      ${open && html`<div>
        ${(thought || said || calls.length || chars) ? html`<div class="sec2"><div class="lbl">${thought ? 'The model thought' : 'The model said'}<span class="faint" style="text-transform:none;letter-spacing:0">${d?.model} ${d?.llmCalls > 1 ? '· ' + d.llmCalls + ' calls' : ''} ${llm[0]?.stopReason ? '· stop: ' + llm[0].stopReason : ''}</span></div>
          ${thought && html`<div class="thought">${thought}</div>`}
          ${said && html`<div class="thought" style=${{ marginTop: thought ? '8px' : 0, fontStyle: 'normal', fontFamily: 'var(--sans)', fontSize: '13.5px' }}>${said}</div>`}
          ${!thought && !said && html`<div class="thought dim" style="font-size:13.5px">${chars ? `${fmtInt(chars)} characters of model output were produced but not stored (captureModelOutput was off for this run).` : 'No free text — the model went straight to a tool call.'}</div>`}
          ${calls.length > 0 && html`<div class="chips" style="margin-top:6px"><span class="faint" style="font-size:11.5px">tool calls</span>${calls.map((c, i) => html`<${Chip} key=${i} tag>${c}</${Chip}>`)}</div>`}
        </div>` : prefetch ? html`<div class="sec2"><div class="lbl">Framework</div><div class="muted">${d?.note || 'prefetched without a model call'}</div></div>` : ''}
        <div class="sec2"><div class="lbl">Envelope sent <span class="mono" style="text-transform:none;letter-spacing:0">${s.key}</span><span class="faint" style="text-transform:none;letter-spacing:0">${fmtBytes(s.bytes)}</span><${Copy} text=${JSON.stringify(s.payload, null, 2)} /></div><${JsonView} value=${s.payload ?? {}} open=${2} /></div>
        <div class="sec2"><div class="lbl">App answered <span class="mono" style=${{ textTransform: 'none', letterSpacing: 0, color: bad ? 'var(--crit-ink)' : '' }}>${r?.status || '—'}</span><span class="faint" style="text-transform:none;letter-spacing:0">${fmtBytes(r?.payloadBytes)} · handled in ${fmtMs(r?.handleMs)}</span></div>
          ${r?.error && html`<div class="err" style="margin-bottom:6px">${typeof r.error === 'string' ? r.error : JSON.stringify(r.error, null, 2)}</div>`}
          ${r?.suppressed && html`<div class="note" style="margin-bottom:6px">This is the ${r.repeatIndex}${['st', 'nd', 'rd'][r.repeatIndex - 1] || 'th'} identical request; the engine replaced the answer with a no-progress notice.</div>`}
          <${JsonView} value=${r?.payload ?? null} open=${1} />
        </div>
        ${d && html`<div class="sec2"><div class="lbl">Decision <span class="faint" style="text-transform:none;letter-spacing:0">${d.note || ''}</span></div>
          <div class="chips">${[['prompt', fmtTok(d.tokensPrompt)], ['completion', fmtTok(d.tokensCompletion)], ['cached', d.tokensCachedPrompt != null ? fmtTok(d.tokensCachedPrompt) : null], ['latency', fmtMs(d.llmLatencyMs)], ['first token', d.llmFirstTokenMs != null ? fmtMs(d.llmFirstTokenMs) : null], ['tools offered', d.extra?.tools], ['request', d.extra?.requestChars != null ? fmtInt(d.extra.requestChars) + ' chars' : null]].filter(([, v]) => v != null && v !== '0').map(([k, v]) => html`<${Chip} key=${k}>${k} <b class="mono" style="font-weight:500">${v}</b></${Chip}>`)}</div>
          ${extraKeys.length > 0 && html`<details style="margin-top:6px"><summary class="faint" style="cursor:pointer;font-size:12px">${extraKeys.join(', ')}</summary><${JsonView} value=${Object.fromEntries(extraKeys.map((k) => [k, d.extra[k]]))} open=${2} /></details>`}</div>`}
      </div>`}
    </article>
    ${s.after.map((e, i) => html`<${Event} key=${i} e=${e} />`)}
  </div>`;
}

export function Event({ e }) {
  const d = e.d;
  if (e.type === 'user.turn') return html`<div class="event user"><span>👤</span><span><b>User follow-up</b> (${d.id}${d.simulated ? ', simulated' : ''}): <span style="font:italic 15px var(--serif)">“${d.instruction.trim()}”</span></span></div>`;
  if (e.type === 'user.steer') return html`<div class="event user"><span>👤</span><span><b>User spoke mid-task</b> (${d.id}${d.delivered === false ? ', not delivered: the agent cannot hear mid-task' : ''}): <span style="font:italic 15px var(--serif)">“${(d.message || '').trim()}”</span></span></div>`;
  if (e.type === 'user.simulated') return html`<div class="event user"><span>👤</span><span><b>Simulated user</b> (${d.role}) asked: “${trunc(d.question, 120)}” → <span style="font:italic 15px var(--serif);color:var(--ink)">“${d.text}”</span>${d.satisfied ? ' · satisfied' : ''}${d.valid === false ? html` · <span style="color:var(--crit-ink)">invalid: ${(d.issues || []).join('; ')}</span>` : ''}</span></div>`;
  if (e.type === 'engine.no_progress') return html`<div class="event warn"><span>⟳</span><span><b>No progress</b> — <span class="mono">${d.key}</span> repeated ${d.repeats}×; ${d.suppressedRepeats} answers suppressed</span></div>`;
  if (e.type === 'engine.error') return html`<div class="event bad"><span>✕</span><span><b>Engine error</b> in ${d.phase || 'run'}: ${d.error}<details><summary class="faint" style="cursor:pointer">stack</summary><pre class="code wrap" style="font-size:11px">${d.stackTrace}</pre></details></span></div>`;
  return html`<div class="event"><span>·</span><span class="mono">${e.type}</span></div>`;
}

// ---------------------------------------------------------------------------

function diffItems(base, fin) {
  if (!base) return (fin?.items || []).map((item, i) => ({ k: i, kind: 'final', item }));
  const key = (x) => x.id ?? JSON.stringify(x);
  const bm = new Map((base?.items || []).map((x) => [key(x), x])), fm = new Map((fin?.items || []).map((x) => [key(x), x]));
  const out = [];
  for (const [k, f] of fm) {
    const b = bm.get(k);
    if (!b) out.push({ k, kind: 'added', item: f });
    else {
      const ch = Object.keys({ ...b, ...f }).filter((f2) => JSON.stringify(b[f2]) !== JSON.stringify(f[f2])).map((f2) => ({ field: f2, from: b[f2], to: f[f2] }));
      out.push({ k, kind: ch.length ? 'changed' : 'same', item: f, changes: ch });
    }
  }
  for (const [k, b] of bm) if (!fm.has(k)) out.push({ k, kind: 'removed', item: b });
  return out;
}
const show = (v) => (v === undefined ? '∅' : typeof v === 'string' ? JSON.stringify(v) : JSON.stringify(v));

function StateDiff({ trace }) {
  if (!trace.final) return null;
  const base = new Map((trace.baseline?.results || []).map((r) => [r.query, r]));
  const rows = trace.final.results.map((fin) => ({ query: fin.query, diff: diffItems(base.get(fin.query), fin), cb: base.get(fin.query)?.count, cf: fin.count }));
  const changed = rows.reduce((n, r) => n + r.diff.filter((d) => d.kind !== 'same').length, 0);
  return html`<${Section} no="Δ" title="What changed in the app" hint=${changed ? `${changed} difference${changed > 1 ? 's' : ''} against the state after reset` : 'nothing the task watches moved'}>
    ${rows.map((r) => html`<div key=${r.query} style="margin-bottom:14px">
      <div class="mono" style="font-size:12px;color:var(--ink-2)">${r.query} <span class="faint">· ${r.cb == null ? 'not part of the baseline — final state only' : `${r.cb} → ${r.cf} items`}</span></div>
      ${r.diff.map((d) => html`<div key=${d.k} style="display:grid;grid-template-columns:70px 1fr;gap:10px;padding:5px 0;border-bottom:1px solid var(--rule);font-size:12.5px">
        <span style=${{ font: '600 10px var(--sans)', letterSpacing: '.1em', textTransform: 'uppercase', color: d.kind === 'same' || d.kind === 'final' ? 'var(--ink-3)' : d.kind === 'removed' ? 'var(--crit-ink)' : 'var(--good-ink)' }}>${d.kind}</span>
        <span>${d.kind === 'changed' ? html`<span class="mono" style="font-size:11.5px">${d.item.id ?? ''}</span> ${d.item.title ? `“${d.item.title}”` : ''}<div>${d.changes.map((c) => html`<div key=${c.field} class="mono" style="font-size:12px"><span class="faint">${c.field}:</span> <span style="text-decoration:line-through;color:var(--ink-3)">${show(c.from)}</span> → <b style="background:var(--mark);font-weight:500">${show(c.to)}</b></div>`)}</div>` : html`<${JsonView} value=${d.item} open=${0} />`}</span>
      </div>`)}
    </div>`)}
  </${Section}>`;
}

function Surface({ trace }) {
  const env = trace.descriptor;
  if (!env) return null;
  return html`<${Section} no="∑" title="What the agent could use" hint=${`${env.envelopes.length} envelopes · ${env.environmentId} ${env.version}`}>
    <details><summary style="cursor:pointer" class="muted">Show the envelope surface of the environment</summary>
      <table class="t compact" style="margin-top:8px"><tbody>${env.envelopes.map((e) => html`<tr key=${e.key}><td class="mono" style="white-space:nowrap">${e.key}</td><td><span class=${'kind ' + e.kind}>${e.kind}</span></td><td class="muted">${e.description}</td></tr>`)}</tbody></table>
      ${env.instructions && html`<h3 style="margin-top:14px">Instructions published by the app</h3><pre class="code wrap">${typeof env.instructions === 'string' ? env.instructions : JSON.stringify(env.instructions, null, 2)}</pre>`}
    </details>
  </${Section}>`;
}

function VerdictPanel({ ep }) {
  if (!ep) return null;
  const crit = Object.entries(ep.criteria || {});
  return html`<div class="sideblock"><h3>Verdict</h3>
    <div style="display:flex;align-items:baseline;gap:12px"><span style="font:500 34px/1 var(--serif)">${ep.score == null ? '—' : fmtNum(ep.score, 2)}</span><${Verdict} v=${ep.verdict} /></div>
    <div class="faint" style="font-size:12px;margin:2px 0 8px">${ep.label || ''}</div>
    ${crit.map(([name, c]) => html`<div class="crit" key=${name}>
      <div class="top"><span>${name}</span><span class="pill-score" style=${{ color: c.score >= 1 ? 'var(--good-ink)' : c.score <= 0 ? 'var(--crit-ink)' : 'var(--warn-ink)' }}>${fmtNum(c.score, 2)} <span class="faint">×${c.weight}</span></span></div>
      <div class="dt">${c.detail}</div>
      ${c.votes && html`<div class="chips" style="margin-top:4px">${Object.entries(c.votes).map(([k, v]) => html`<${Chip} key=${k}>${k} ${v}/${c.k ?? ''}</${Chip}>`)}</div>`}
      ${c.judgeCalls != null && html`<div class="faint" style="font-size:11px;margin-top:3px">judge: ${c.judgeCalls} calls · ${fmtTok(c.judgeTokensPrompt)} tok · ${fmtMs(c.judgeLatencyMs)}</div>`}
    </div>`)}
    ${!crit.length && html`<div class="faint">no criterion details (run not evaluated)</div>`}
  </div>`;
}

function BudgetPanel({ trace, budget, ep, task }) {
  const used = { steps: ep?.metrics?.action_count ?? trace.steps.filter((s) => s.kind === 'act').length, tokens: ep?.metrics?.tokens_total ?? ep?.trace?.tokens, wall: trace.end?.wallClockMs, turns: trace.steps.length };
  const rows = [['steps', used.steps, budget.maxSteps, (x) => fmtNum(x, 0)], ['tokens', used.tokens, budget.maxTokens, fmtTok], ['wall clock', used.wall, budget.maxWallClockSeconds && budget.maxWallClockSeconds * 1000, fmtMs], ['turns', used.turns, budget.maxTurns, (x) => fmtNum(x, 0)]];
  return html`<div class="sideblock"><h3>Budget</h3>
    ${rows.filter(([, u, m]) => m).map(([l, u, m, f]) => html`<div key=${l} style="margin-bottom:8px"><div style="display:flex;justify-content:space-between;font-size:12.5px"><span>${l}</span><span class="mono">${f(u)} / ${f(m)}</span></div><div class="prog"><i style=${{ width: Math.min(100, ((u || 0) / m) * 100) + '%', background: u / m > 0.9 ? 'var(--crit)' : 'var(--ink)' }}></i></div></div>`)}
    ${task?.optimalSteps != null && html`<div class="faint" style="font-size:12px">optimal path: ${task.optimalSteps} actions · taken ${used.steps}</div>`}
    ${task?.tags?.length > 0 && html`<div class="chips" style="margin-top:8px">${task.tags.map((t) => html`<${Chip} key=${t} tag>${t}</${Chip}>`)}</div>`}
  </div>`;
}

function MetricsPanel({ ep }) {
  const [f, setF] = useState('');
  const [all, setAll] = useState(false);
  if (!ep) return null;
  const entries = Object.entries(ep.metrics || {}).filter(([k, v]) => isNum(v) && (all || v !== 0) && k.includes(f.toLowerCase())).sort((a, b) => a[0].localeCompare(b[0]));
  return html`<div class="sideblock"><h3>Metrics <span class="faint" style="letter-spacing:0">${Object.keys(ep.metrics || {}).length}</span></h3>
    <div style="display:flex;gap:8px;margin-bottom:6px"><input type="search" placeholder="filter" value=${f} onInput=${(e) => setF(e.target.value)} style="padding:2px 8px" /><label style="display:flex;gap:4px;align-items:center;font-size:12px;white-space:nowrap"><input type="checkbox" checked=${all} onChange=${(e) => setAll(e.target.checked)} />zeros</label></div>
    <div style="max-height:380px;overflow:auto"><table class="t compact"><tbody>${entries.map(([k, v]) => html`<tr key=${k}><td style="padding-left:0" onMouseMove=${(e) => metricInfo(k).description && tip.show(e, html`<b>${k}</b><div style="margin-top:3px">${metricInfo(k).description}</div>`)} onMouseLeave=${tip.hide}>${k}</td><td class="n" style="padding-right:0">${fmtMetric(k, v)}</td></tr>`)}</tbody></table></div>
  </div>`;
}

/** The spans the run exported for this episode, if this server received them. */
function OtelSection({ runId, episode, onStep }) {
  const d = useAsync(() => api('otel/for', { query: { runId, episodeId: episode } }), [runId, episode]);
  const [sel, setSel] = useState(null);
  const info = useAsync(() => api('otel/info'), []);
  if (d.loading) return null;
  const spans = d.data?.spans || [];
  return html`<${Section} no="◎" title="OpenTelemetry" hint=${spans.length ? `${spans.length} spans received · click a decision or tool to jump to its step` : 'no spans received for this episode'}
    actions=${d.data?.summary && html`<a class="btn ghost sm" href=${href(['telemetry', d.data.summary.traceId])}>open full view</a>`}>
    ${spans.length ? html`<div><${Waterfall} spans=${spans} compact selected=${sel} onSelect=${(s, step) => { setSel(s.spanId); onStep(step); }} />
      ${sel && html`<div style="margin-top:12px"><${SpanPanel} span=${spans.find((x) => x.spanId === sel)} /></div>`}</div>`
    : html`<div><div class="note" style="margin-bottom:10px">This run did not export spans to this server, or the UI was not running while it did. Spans are kept in <code>~/.aib_ui/otel</code> once received.</div><${EndpointBox} info=${info.data} /></div>`}
  </${Section}>`;
}
