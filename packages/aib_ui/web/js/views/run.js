// One run: headline numbers, task × repetition matrix, metric distributions, episodes, tasks, config, files.
import { html, useState, useMemo, useEffect, useRef, useStore, runApi, useAsync, go, href, api, loadRuns, setStore, pref, toast,
  fmtPct, fmtTok, fmtMs, fmtUsd, fmtInt, fmtNum, fmtDate, fmtBytes, fmtMetric, metricInfo, allMetricNames,
  mean, median, sum, quantile, wilson, isNum, nums, groupBy, verdictOf, VERDICT, shortModel, cls, csv, download, lib } from '../lib.js';
import { PageHead, Section, Tabs, Seg, Verdict, Chip, Loading, ErrorBox, Empty, JsonView, KV, TagEditor, YamlView, Copy, Modal, Field, hint, tip } from '../ui.js';
import { Elapsed } from './launch.js';
import { Scatter, Strip, HBars, Proportion, Legend, Hist, seriesColor, seqColor, seqText, trunc } from '../charts.js';

export const VERDICT_COLORS = { success: 'var(--good)', partial: 'var(--warn)', failure: 'var(--crit)', error: 'var(--ink-3)' };

/** Headline numbers of a set of episodes. */
export function summarize(eps) {
  const n = eps.length;
  const scored = eps.some((e) => e.verdict != null);
  const succ = eps.filter((e) => e.verdict === 'success').length;
  const m = (k) => mean(eps.map((e) => e.metrics?.[k]));
  const [lo, hi] = wilson(succ, n);
  return {
    n, succ, scored, rate: n && scored ? succ / n : null, lo: scored ? lo : null, hi: scored ? hi : null,
    score: mean(eps.map((e) => (isNum(e.score) ? e.score : e.metrics?.weighted_score))),
    tokens: m('tokens_total') ?? mean(eps.map((e) => e.trace?.tokens)),
    wall: m('wall_clock_ms') ?? mean(eps.map((e) => e.trace?.wallMs)),
    steps: m('action_count') ?? mean(eps.map((e) => e.trace?.steps)),
    cost: sum(eps.map((e) => e.metrics?.cost_usd)),
    llm: m('llm_latency_ms'),
    verdicts: Object.fromEntries(['success', 'partial', 'failure', 'error'].map((v) => [v, eps.filter((e) => e.verdict === v).length])),
  };
}

export function useRun(id) {
  return useAsync(() => runApi('run', { run: id }), [id, lib()]);
}

export function RunView({ id, query }) {
  const s = useStore();
  const r = useRun(id);
  const tab = query.tab || 'overview';
  const setTab = (t) => go(['run', id], { tab: t === 'overview' ? null : t }, { replace: true });
  if (r.loading) return html`<${Loading} what="reading run" />`;
  if (r.error) return html`<div><${PageHead} kicker="Run" title="Not found" /><${ErrorBox} error=${r.error} /></div>`;
  const run = r.data;
  const eps = run.episodes;
  const sm = useMemo(() => summarize(eps), [run]);
  const ann = run.annotation || {};
  const save = async (patch) => { await api('user/annotate', { method: 'POST', body: { dir: run.dir, ...patch } }); loadRuns({ quiet: true }); toast('saved'); r.reload?.(); setStore({}); };
  const allTags = [...new Set(Object.values(s.runs?.annotations || {}).flatMap((a) => a.tags || []))];
  const [local, setLocal] = useState(ann);
  useEffect(() => setLocal(ann), [run.dir]);
  const patch = (p) => { setLocal((l) => ({ ...l, ...p })); save(p); };

  return html`<div>
    <${PageHead} kicker=${html`<a href="#/">Runs</a> · ${run.suite}`} title=${html`${local.alias || run.name}`}
      sub=${html`<span class="mono" style="font-size:12px">${run.runId}</span> · ${fmtDate(run.createdAt)} · ${run.environment}`}>
      <button class="btn ghost" onClick=${() => patch({ starred: !local.starred })}>${local.starred ? '★ starred' : '☆ star'}</button>
      <button class="btn" onClick=${() => go(['compare'], { runs: run.id })}>Compare…</button>
    </${PageHead}>
    <div style="display:flex;gap:18px;flex-wrap:wrap;align-items:center;margin:-6px 0 14px">
      <${TagEditor} tags=${local.tags || []} onChange=${(tags) => patch({ tags })} suggestions=${allTags} />
      <input type="text" placeholder="alias — a name you will recognise" value=${local.alias || ''} onChange=${(e) => patch({ alias: e.target.value })} style="max-width:260px;font-size:12.5px" aria-label="alias" />
    </div>
    <${ConfigStrip} run=${run} />
    <${OtelChip} run=${run} />
    <${ScoreBanner} run=${run} onChanged=${() => { r.reload(); loadRuns({ quiet: true }); }} />
    ${run.launch?.study || local.note !== undefined ? '' : ''}
    <${Tabs} tabs=${[{ id: 'overview', label: 'Overview' }, { id: 'episodes', label: 'Episodes', count: eps.length }, { id: 'tasks', label: 'Tasks', count: new Set(eps.map((e) => e.taskId)).size }, { id: 'config', label: 'Configuration' }, { id: 'files', label: 'Files', count: run.files.length }]} value=${tab} onChange=${setTab} />
    <div style="margin-top:22px">
      ${tab === 'overview' && html`<${Overview} run=${run} sm=${sm} note=${local.note || ''} onNote=${(note) => patch({ note })} />`}
      ${tab === 'episodes' && html`<${Episodes} run=${run} />`}
      ${tab === 'tasks' && html`<${Tasks} run=${run} />`}
      ${tab === 'config' && html`<${Config} run=${run} />`}
      ${tab === 'files' && html`<${Files} run=${run} />`}
    </div>
  </div>`;
}

function ConfigStrip({ run }) {
  const a = run.agents;
  return html`<div class="chips" style="margin-bottom:6px">
    ${a.map((x) => html`<span key=${x.id} class="chip"><b style="font-weight:600">${x.id}</b> ${x.version || ''}</span>`)}
    ${[...new Set(a.map((x) => x.model))].filter(Boolean).map((m) => html`<${Chip} key=${m} tag>${m}</${Chip}>`)}
    ${[...new Set(a.map((x) => x.provider))].filter(Boolean).map((m) => html`<${Chip} key=${m}>${m}</${Chip}>`)}
    ${a[0]?.router && html`<${Chip} title="router">${a[0].router}</${Chip}>`}
    ${a[0]?.temperature != null && html`<${Chip}>temp ${a[0].temperature}</${Chip}>`}
    ${a[0]?.toolCalling && html`<${Chip}>tools: ${a[0].toolCalling}</${Chip}>`}
    ${run.launch?.config && html`<${Chip} tag title="arm">${run.launch.config}</${Chip}>`}
    ${run.launch?.study && html`<${Chip} title="study">study · ${run.launch.study}</${Chip}>`}
    ${run.judge && html`<${Chip} title="judge">judge · ${run.judge.model} k=${run.judge.k}</${Chip}>`}
    <${Chip}>seed ${run.seed}</${Chip}><${Chip}>${run.repetitions} reps</${Chip}>
  </div>`;
}

function OtelChip({ run }) {
  const d = useAsync(() => api('otel/traces', { query: { run: run.runId } }), [run.runId]);
  const n = d.data?.traces?.length || 0;
  if (!n && !run.launch?.otel) return null;
  return html`<div style="margin:2px 0 6px"><a class="chip" style="text-decoration:none" href=${href(['telemetry'], { run: run.runId })}>◎ OpenTelemetry · ${n ? `${n} episode trace${n > 1 ? 's' : ''} received` : 'exported to ' + run.launch.otel + ' (not received here)'}</a></div>`;
}

// ---------------------------------------------------------------------------

const OVERVIEW_METRICS = ['tokens_total', 'wall_clock_ms', 'action_count', 'path_efficiency', 'llm_latency_ms', 'peak_prompt_tokens'];

function Overview({ run, sm, note, onNote }) {
  const eps = run.episodes;
  const [metric, setMetric] = useState(pref.get('run.metric', 'tokens_total'));
  const names = useMemo(() => { const set = new Set(); eps.forEach((e) => Object.entries(e.metrics || {}).forEach(([k, v]) => isNum(v) && set.add(k))); return [...set].sort(); }, [run]);
  const tasks = useMemo(() => taskTable(run), [run]);
  const reps = Math.max(1, ...eps.map((e) => e.rep || 1));
  const agents = [...new Set(eps.map((e) => e.agentId))];
  const colors = Object.fromEntries(agents.map((a, i) => [a, seriesColor(i)]));
  const strips = ['tokens_total', 'wall_clock_ms', 'action_count', 'path_efficiency'].filter((m) => names.includes(m));
  const withTrace = eps.some((e) => e.trace);
  const ends = Object.entries(Object.fromEntries([...groupBy(eps, (e) => e.trace?.endReason || '—')].map(([k, v]) => [k, v.length]))).sort((a, b) => b[1] - a[1]);

  return html`<div>
    <div class="kpis">
      <div class="kpi"><div class="l">Success rate</div><div class="v">${sm.scored ? fmtPct(sm.rate) : '—'}</div><div class="d">${sm.scored ? `${sm.succ}/${sm.n} · 95% ${fmtPct(sm.lo)}–${fmtPct(sm.hi)}` : 'not scored yet'}</div></div>
      <div class="kpi"><div class="l">Weighted score</div><div class="v">${sm.scored ? fmtNum(sm.score, 2) : '—'}</div><div class="d">${sm.scored ? 'partial credit counted' : 'not scored yet'}</div></div>
      <div class="kpi"><div class="l">Tokens / episode</div><div class="v">${fmtTok(sm.tokens)}</div><div class="d">${fmtTok(sm.tokens * sm.n)} total</div></div>
      <div class="kpi"><div class="l">Wall clock / episode</div><div class="v">${fmtMs(sm.wall)}</div><div class="d">${sm.llm != null ? `${fmtPct(sm.llm / sm.wall)} in the model` : ''}</div></div>
      <div class="kpi"><div class="l">Actions / episode</div><div class="v">${fmtNum(sm.steps, 1)}</div><div class="d">act envelopes</div></div>
      <div class="kpi"><div class="l">Cost</div><div class="v">${sm.cost ? fmtUsd(sm.cost) : '$0'}</div><div class="d">${sm.cost ? fmtUsd(sm.cost / sm.n) + ' / episode' : 'local or unpriced'}</div></div>
    </div>
    ${sm.scored && html`<div style="margin:16px 0 4px">
      <${Proportion} parts=${['success', 'partial', 'failure', 'error'].map((v) => ({ label: v, value: sm.verdicts[v], color: VERDICT_COLORS[v] }))} height=${14} />
      <div class="legend" style="margin-top:6px">${['success', 'partial', 'failure', 'error'].map((v) => html`<span key=${v}><i style=${{ background: VERDICT_COLORS[v] }}></i>${v} <b class="mono" style="font-weight:500">${sm.verdicts[v]}</b></span>`)}</div>
    </div>`}

    <${Section} no="1" title="Task × repetition" hint="one cell per episode — click to read its trace">
      <div class="tw"><table class="mx">
        <thead><tr><th></th>${Array.from({ length: reps }, (_, i) => html`<th class="col" key=${i}>rep ${i + 1}</th>`)}<th class="col" style="padding-left:12px">mean score</th><th class="col">tokens</th></tr></thead>
        <tbody>${tasks.map((t) => html`<tr key=${t.id}>
          <th title=${t.id + (t.title ? ' — ' + t.title : '')}><a href=${href(['run', run.id], { tab: 'tasks', task: t.id })} style="text-decoration:none">${trunc(t.title || t.id, 46)}</a><div class="faint mono" style="font-size:10.5px">${t.id}</div></th>
          ${Array.from({ length: reps }, (_, i) => {
            const eps2 = t.episodes.filter((e) => (e.rep || 1) === i + 1);
            return html`<td key=${i} style="min-width:${Math.max(34, Math.min(70, 520 / reps))}px">${eps2.length ? eps2.map((e) => html`<button key=${e.id} class=${'cell ' + verdictOf(e.verdict).cell} onClick=${() => go(['run', run.id, 'ep', e.id])}
              onMouseMove=${(ev) => tip.show(ev, html`<b>${e.id}</b><div class="row"><span>verdict</span><span>${e.verdict}</span></div><div class="row"><span>score</span><span class="m">${fmtNum(e.score, 2)}</span></div><div class="row"><span>tokens</span><span class="m">${fmtTok(e.metrics?.tokens_total ?? e.trace?.tokens)}</span></div><div class="row"><span>steps</span><span class="m">${e.trace?.steps ?? '—'}</span></div>${e.trace?.endReason ? html`<div class="row"><span>ended</span><span>${e.trace.endReason}</span></div>` : ''}`)} onMouseLeave=${tip.hide}>${isNum(e.score) && e.verdict === 'partial' ? fmtNum(e.score, 2).replace(/^0/, '') : ''}</button>`) : html`<span class="faint">·</span>`}</td>`;
          })}
          <td style="padding-left:12px;min-width:92px"><span class="mono">${fmtNum(t.score, 2)}</span> <span class="mini-track" style="width:40px"><i class="mini-bar" style=${{ width: (t.score || 0) * 100 + '%', background: 'var(--s1)', display: 'block', height: '4px', marginTop: '1px' }}></i></span></td>
          <td class="mono" style="padding-left:8px;font-size:12px;color:var(--ink-2)">${fmtTok(t.tokens)}</td>
        </tr>`)}</tbody>
      </table></div>
      <div class="legend" style="margin-top:10px"><span><i style="background:color-mix(in srgb,var(--good) 62%,var(--paper))"></i>success</span><span><i style="background:color-mix(in srgb,var(--warn) 70%,var(--paper))"></i>partial (credit shown)</span><span><i style="background:color-mix(in srgb,var(--crit) 62%,var(--paper))"></i>failure</span><span><i style="background:var(--sunk)"></i>${sm.scored ? 'error / framework fault' : 'not scored'}</span></div>
    </${Section}>

    <${Section} no="2" title="Where the cost goes" hint="per episode · hover for the numbers">
      <div class="grid2">
        <div>
          <div class="chart-title"><h3>Tokens against score</h3><span class="u">one dot per episode</span></div>
          <${Scatter} height=${280} xLabel="tokens" yLabel="score" xFmt=${fmtTok} yFmt=${(v) => fmtNum(v, 1)} yDomain=${[-0.05, 1.05]}
            points=${eps.filter((e) => isNum(e.metrics?.tokens_total ?? e.trace?.tokens) && isNum(e.score)).map((e) => ({ id: e.id, x: e.metrics?.tokens_total ?? e.trace.tokens, y: e.score + (((e.rep || 1) * 17 + e.id.length * 7) % 9) / 200, color: VERDICT_COLORS[e.verdict], r: 4.5, label: e.taskId + ' #' + e.rep }))}
            onClick=${(p) => go(['run', run.id, 'ep', p.id])} />
          <${Legend} items=${['success', 'partial', 'failure', 'error'].map((v) => ({ label: v, color: VERDICT_COLORS[v] }))} />
        </div>
        <div>
          <div class="chart-title"><h3>How episodes ended</h3><span class="u">${withTrace ? 'from the traces' : ''}</span></div>
          ${withTrace ? html`<${HBars} rows=${ends.map(([k, n]) => ({ label: k, value: n, color: k === 'done' ? 'var(--good)' : k === 'abort' ? 'var(--warn)' : 'var(--s2)' }))} max=${eps.length} fmt=${fmtInt} label="episodes" />` : html`<${Empty}>No traces in this run.</${Empty}>`}
          <div style="margin-top:18px"><div class="chart-title"><h3>Time per episode</h3><span class="u">model · environment · framework</span></div>
            <${TimeBars} eps=${eps} run=${run} /></div>
        </div>
      </div>
    </${Section}>

    <${Section} no="3" title="Metric distributions" hint="dot = episode, bar = interquartile range, tick = median"
      actions=${html`<select value=${metric} onChange=${(e) => { setMetric(e.target.value); pref.set('run.metric', e.target.value); }} style="width:auto" aria-label="metric">${names.map((n) => html`<option key=${n} value=${n}>${n}</option>`)}</select>`}>
      <div class="grid2">
        <div>
          <div class="chart-title"><h3>${metricInfo(metric).label}</h3><span class="u">${metricInfo(metric).unit}${metricInfo(metric).dir ? ' · ' + (metricInfo(metric).dir > 0 ? 'higher is better' : 'lower is better') : ''}</span></div>
          <p class="muted" style="margin:0 0 8px;font-size:12.5px">${metricInfo(metric).description}</p>
          <${Strip} label=${metric} fmt=${(v) => fmtMetric(metric, v)} groups=${taskGroups(eps, metric, colors)} onClick=${(o) => o.id && go(['run', run.id, 'ep', o.id])} />
        </div>
        <div>
          <div class="chart-title"><h3>Spread over all episodes</h3><span class="u">${fmtMetric(metric, median(eps.map((e) => e.metrics?.[metric])))} median</span></div>
          <${Hist} values=${eps.map((e) => e.metrics?.[metric])} fmt=${(v) => fmtMetric(metric, v)} />
          <${KPIRow} eps=${eps} metric=${metric} />
        </div>
      </div>
    </${Section}>

    <${Section} no="4" title="Notes" hint="kept beside the app, not in the run">
      <textarea rows="3" placeholder="What was this run for? What did you learn?" defaultValue=${note} onBlur=${(e) => e.target.value !== note && onNote(e.target.value)} aria-label="note"></textarea>
    </${Section}>
  </div>`;
}

function KPIRow({ eps, metric }) {
  const v = nums(eps.map((e) => e.metrics?.[metric]));
  if (!v.length) return html`<div class="faint">no values for this metric</div>`;
  return html`<div class="kpis" style="margin-top:10px">
    ${[['min', Math.min(...v)], ['p25', quantile(v, 0.25)], ['median', quantile(v, 0.5)], ['mean', mean(v)], ['p75', quantile(v, 0.75)], ['p95', quantile(v, 0.95)], ['max', Math.max(...v)]].map(([l, x]) => html`<div class="kpi" key=${l} style="padding:6px 8px 6px 0;margin-right:8px"><div class="l">${l}</div><div class="v" style="font-size:17px">${fmtMetric(metric, x)}</div></div>`)}
  </div>`;
}

function taskGroups(eps, metric, colors) {
  const by = groupBy(eps, (e) => e.taskId);
  const ids = [...by.keys()];
  let pre = ids.length > 1 ? ids.reduce((a, b) => { let i = 0; while (i < a.length && a[i] === b[i]) i++; return a.slice(0, i); }) : '';
  pre = pre.includes('.') ? pre.slice(0, pre.lastIndexOf('.') + 1) : '';
  return [...by].map(([task, es], i) => ({ label: task.slice(pre.length), color: seriesColor(0), values: es.map((e) => ({ v: e.metrics?.[metric], id: e.id, label: e.id })).filter((o) => isNum(o.v)) })).filter((g) => g.values.length).slice(0, 60);
}

/** Model time against everything else, per episode, as one stacked bar each. */
function TimeBars({ eps, run }) {
  const rows = eps.map((e) => {
    const wall = e.metrics?.wall_clock_ms ?? e.trace?.wallMs, llm = e.metrics?.llm_latency_ms ?? e.trace?.llmMs, over = e.metrics?.framework_overhead_ms;
    return { e, wall, llm, over };
  }).filter((r) => isNum(r.wall) && isNum(r.llm));
  if (!rows.length) return html`<${Empty}>No timing recorded.</${Empty}>`;
  const L = sum(rows.map((r) => r.llm)), W = sum(rows.map((r) => r.wall)), O = sum(rows.map((r) => r.over || 0));
  const other = Math.max(0, W - L - O);
  return html`<div>
    <${Proportion} height=${18} parts=${[{ label: 'model calls', value: L, color: 'var(--s1)' }, { label: 'environment & tools', value: other, color: 'var(--s4)' }, { label: 'framework overhead', value: O, color: 'var(--s7)' }]} />
    <${Legend} items=${[{ label: `model calls ${fmtPct(L / W)}`, color: 'var(--s1)' }, { label: `environment & tools ${fmtPct(other / W)}`, color: 'var(--s4)' }, { label: `framework ${fmtPct(O / W, 1)}`, color: 'var(--s7)' }]} />
  </div>`;
}

function taskTable(run) {
  const byTask = groupBy(run.episodes, (e) => e.taskId);
  const info = Object.fromEntries((run.tasks || []).map((t) => [t.id, t]));
  const order = (run.taskOrder || [...byTask.keys()]).filter((t) => byTask.has(t));
  for (const t of byTask.keys()) if (!order.includes(t)) order.push(t);
  return order.map((id) => {
    const es = byTask.get(id);
    return { id, title: info[id]?.title || es[0]?.trace?.title, episodes: es, score: mean(es.map((e) => e.score)), tokens: mean(es.map((e) => e.metrics?.tokens_total ?? e.trace?.tokens)), rate: es.filter((e) => e.verdict === 'success').length / es.length };
  });
}

// ---------------------------------------------------------------------------

function Episodes({ run }) {
  const eps = run.episodes;
  const [f, setF] = useState({ q: '', verdict: '', agent: '' });
  const [sort, setSort] = useState({ key: 'id', dir: 1 });
  const cols = useMemo(() => pref.get('run.cols', ['tokens_total', 'wall_clock_ms', 'action_count', 'path_efficiency']), []);
  const [chosen, setChosen] = useState(cols);
  const all = useMemo(() => { const set = new Set(); eps.forEach((e) => Object.entries(e.metrics || {}).forEach(([k, v]) => isNum(v) && set.add(k))); return [...set].sort(); }, [run]);
  const rows = eps.filter((e) => (!f.q || e.id.toLowerCase().includes(f.q.toLowerCase()) || (e.trace?.title || '').toLowerCase().includes(f.q.toLowerCase())) && (!f.verdict || e.verdict === f.verdict) && (!f.agent || e.agentId === f.agent));
  const val = (e, k) => k === 'id' ? e.id : k === 'verdict' ? e.verdict : k === 'score' ? e.score : k === 'steps' ? e.trace?.steps : k === 'end' ? e.trace?.endReason : e.metrics?.[k];
  const sorted = [...rows].sort((a, b) => { const x = val(a, sort.key), y = val(b, sort.key); if (x == null) return 1; if (y == null) return -1; return (x < y ? -1 : x > y ? 1 : 0) * sort.dir; });
  const th = (k, l) => html`<th class="sortable" onClick=${() => setSort((s) => ({ key: k, dir: s.key === k ? -s.dir : 1 }))}>${l}${sort.key === k && html`<span class="ar">${sort.dir > 0 ? '▲' : '▼'}</span>`}</th>`;
  const exportCsv = () => download(run.name + '-episodes.csv', csv([['episode', 'task', 'agent', 'rep', 'verdict', 'score', ...chosen], ...sorted.map((e) => [e.id, e.taskId, e.agentId, e.rep, e.verdict, e.score, ...chosen.map((k) => e.metrics?.[k])])]), 'text/csv');
  const agents = [...new Set(eps.map((e) => e.agentId))];
  return html`<div>
    <div style="display:flex;gap:10px;align-items:center;margin-bottom:10px;flex-wrap:wrap">
      <input type="search" placeholder="Filter episodes…" value=${f.q} onInput=${(e) => setF({ ...f, q: e.target.value })} style="max-width:260px" />
      <${Seg} options=${[{ id: '', label: 'all' }, ...['success', 'partial', 'failure', 'error'].map((v) => ({ id: v, label: v }))]} value=${f.verdict} onChange=${(v) => setF({ ...f, verdict: v })} />
      ${agents.length > 1 && html`<select value=${f.agent} onChange=${(e) => setF({ ...f, agent: e.target.value })} style="width:auto"><option value="">all agents</option>${agents.map((a) => html`<option key=${a}>${a}</option>`)}</select>`}
      <select onChange=${(e) => { if (e.target.value) { const n = [...chosen, e.target.value]; setChosen(n); pref.set('run.cols', n); } e.target.value = ''; }} style="width:auto" aria-label="add column"><option value="">+ metric column</option>${all.filter((m) => !chosen.includes(m)).map((m) => html`<option key=${m}>${m}</option>`)}</select>
      <span class="faint" style="margin-left:auto">${rows.length} of ${eps.length}</span>
      <button class="btn ghost sm" onClick=${exportCsv}>Export CSV</button>
    </div>
    <div class="tw"><table class="t compact">
      <thead><tr>${th('id', 'Episode')}${th('verdict', 'Verdict')}${th('score', 'Score')}${th('steps', 'Steps')}${th('end', 'Ended')}${chosen.map((k) => html`<th key=${k} class="sortable r" onClick=${() => setSort((s) => ({ key: k, dir: s.key === k ? -s.dir : 1 }))} title=${metricInfo(k).description}>${k}${sort.key === k ? html`<span class="ar">${sort.dir > 0 ? '▲' : '▼'}</span>` : ''}<span class="ar" style="cursor:pointer" onClick=${(ev) => { ev.stopPropagation(); const n = chosen.filter((x) => x !== k); setChosen(n); pref.set('run.cols', n); }}> ×</span></th>`)}</tr></thead>
      <tbody>${sorted.map((e) => html`<tr key=${e.id} class="row-link" onClick=${() => go(['run', run.id, 'ep', e.id])}>
        <td><span class="mono" style="font-size:12px">${e.id}</span>${e.trace?.title && html`<div class="sub">${e.trace.title}</div>`}</td>
        <td><${Verdict} v=${e.verdict} /></td><td class="n">${fmtNum(e.score, 2)}</td><td class="n">${e.trace?.steps ?? '—'}</td><td class="muted">${e.trace?.endReason || '—'}</td>
        ${chosen.map((k) => html`<td key=${k} class="n">${fmtMetric(k, e.metrics?.[k])}</td>`)}
      </tr>`)}</tbody>
    </table></div>
    ${!rows.length && html`<${Empty}>No episode matches.</${Empty}>`}
  </div>`;
}

// ---------------------------------------------------------------------------

function Tasks({ run }) {
  const tasks = useMemo(() => taskTable(run), [run]);
  const info = Object.fromEntries((run.tasks || []).map((t) => [t.id, t]));
  const [tag, setTag] = useState(null);
  const tagStats = useMemo(() => {
    const m = new Map();
    for (const t of tasks) for (const g of info[t.id]?.tags || []) { if (!m.has(g)) m.set(g, []); m.get(g).push(...t.episodes); }
    return [...m].map(([tag, es]) => ({ tag, n: es.length, tasks: new Set(es.map((e) => e.taskId)).size, ...summarize(es) })).sort((a, b) => a.tag.localeCompare(b.tag));
  }, [run]);
  const shown = tag ? tasks.filter((t) => info[t.id]?.tags?.includes(tag)) : tasks;
  const q = new URLSearchParams(location.hash.split('?')[1] || '').get('task');
  return html`<div>
    ${tagStats.length > 0 ? html`<${Section} no="a" title="Slice by task tag" hint="how the agent does on a kind of task">
      <${HBars} label="success rate" fmt=${fmtPct} max=${1} rows=${tagStats.map((t) => ({ id: t.tag, label: t.tag, value: t.rate, lo: t.lo, hi: t.hi, color: tag === t.tag ? 'var(--ink)' : 'var(--s1)', sub: `${t.tasks} tasks · ${t.n} episodes · score ${fmtNum(t.score, 2)}` }))} onClick=${(r) => setTag(tag === r.id ? null : r.id)} />
      <div class="faint" style="font-size:12px;margin-top:6px">${tag ? html`Showing tasks tagged <b>${tag}</b> · <a href="javascript:void 0" onClick=${() => setTag(null)}>show all</a>` : 'Click a bar to list only those tasks. Whiskers are 95% Wilson intervals over episodes.'}</div>
    </${Section}>` : (run.tasks?.length ? '' : html`<div class="note">The suite file for <code>${run.suite}</code> was not found next to this run, so task tags and instructions are unavailable. Titles come from the traces.</div>`)}
    <${Section} no=${tagStats.length ? 'b' : ''} title="Tasks" hint=${shown.length + ' shown'}>
      ${shown.map((t) => html`<article key=${t.id} id=${t.id} style=${{ borderTop: '1px solid var(--rule-2)', padding: '14px 0', background: q === t.id ? 'var(--mark-soft)' : '' }}>
        <div style="display:grid;grid-template-columns:minmax(0,1fr) auto;gap:20px">
          <div>
            <div style="display:flex;gap:10px;align-items:baseline;flex-wrap:wrap"><h2 style="margin:0;font-size:18px">${t.title || t.id}</h2><span class="mono faint" style="font-size:11.5px">${t.id}</span>${info[t.id]?.holdout && html`<${Chip}>holdout</${Chip}>`}</div>
            ${info[t.id]?.instruction && html`<p style="margin:6px 0 8px;font:italic 400 15.5px/1.5 var(--serif);max-width:80ch">“${info[t.id].instruction}”</p>`}
            <div class="chips">${(info[t.id]?.tags || []).map((g) => html`<${Chip} key=${g} tag on=${tag === g} onClick=${() => setTag(tag === g ? null : g)}>${g}</${Chip}>`)}
              ${info[t.id]?.optimalSteps != null && html`<${Chip}>optimal ${info[t.id].optimalSteps} steps</${Chip}>`}
              ${(info[t.id]?.requiredTools || []).length > 0 && html`<${Chip} title=${info[t.id].requiredTools.join(', ')}>${info[t.id].requiredTools.length} required tools</${Chip}>`}
              ${(info[t.id]?.criteria || []).map((c) => html`<${Chip} key=${c.type}>${c.type}${c.weight != null ? ' ×' + c.weight : ''}</${Chip}>`)}</div>
          </div>
          <div style="display:flex;gap:6px;align-items:flex-start">${t.episodes.map((e) => html`<button key=${e.id} class=${'cell ' + verdictOf(e.verdict).cell} style="width:34px" onClick=${() => go(['run', run.id, 'ep', e.id])} title=${e.id + ' · ' + e.verdict}></button>`)}</div>
        </div>
        ${t.episodes[0]?.criteria && html`<div style="margin-top:8px;font-size:12.5px;color:var(--ink-2)">${Object.entries(t.episodes[0].criteria).map(([k, c]) => html`<div key=${k}><b style="color:var(--ink);font-weight:500">${k}</b> <span class="mono">${fmtNum(c.score, 2)}</span> — ${trunc(c.detail, 200)}</div>`)}<span class="faint">first repetition</span></div>`}
      </article>`)}
    </${Section}>
  </div>`;
}

// ---------------------------------------------------------------------------

function Config({ run }) {
  const m = run.manifest;
  const [raw, setRaw] = useState(false);
  const agent0 = m.agents && Object.values(m.agents)[0];
  return html`<div>
    <div class="grid2">
      <${Section} no="a" title="Agents">
        ${Object.entries(m.agents || {}).map(([id, a]) => html`<div key=${id} style="margin-bottom:16px">
          <h3>${id} · ${a.version}</h3>
          <${FlatTable} data=${a.metadata} />
        </div>`)}
      </${Section}>
      <div>
        <${Section} no="b" title="What it ran on">
          <${KV} data=${{ suite: `${m.suite?.name}`, 'suite hash': m.suite?.hash?.slice(0, 16), environment: `${m.environment?.id} ${m.environment?.version || ''}`, repetitions: m.repetitions, seed: m.seed, 'created': m.createdAt, framework: m.frameworkVersion, dart: m.platform?.dartVersion, os: `${m.platform?.operatingSystem} ${m.platform?.operatingSystemVersion || ''}` }} />
          ${m.extra?.models && Object.entries(m.extra.models).map(([id, mm]) => html`<h3 style="margin-top:16px">Model · ${id}</h3><${KV} data=${{ provider: mm.provider, model: mm.model, digest: mm.digest?.slice(0, 24), ...Object.fromEntries(Object.entries(mm.details || {}).map(([k, v]) => ['details.' + k, v])) }} />`)}
        </${Section}>
        ${run.judgeFull?.judge && html`<${Section} no="c" title="Judge"><${KV} data=${{ judge: run.judgeFull.judge.judgeId, 'k votes': run.judgeFull.judge.k, model: run.judgeFull.judge.pinnedModel, evaluated: run.judgeFull.judge.evaluatedAt, calls: run.judgeFull.judge.spend?.calls, 'tokens in': run.judgeFull.judge.spend?.tokensPrompt, 'tokens out': run.judgeFull.judge.spend?.tokensCompletion, 'scored with': run.judgeFull.scoredWith && `${run.judgeFull.scoredWith.revision?.slice(0, 10)}${run.judgeFull.scoredWith.dirty ? ' (dirty)' : ''}`, 'metric providers': (run.judgeFull.metricProviders || []).join(', ') }} /></${Section}>`}
        ${(run.launchesFull || []).length > 0 && html`<${Section} no="d" title="Launches" hint="${run.launchesFull.length} — a resumed run has several">${run.launchesFull.map((l, i) => html`<div key=${i} style="margin-bottom:10px"><${KV} data=${l} /></div>`)}</${Section}>`}
      </div>
    </div>
    <${Section} title="Raw manifest" actions=${html`<${Copy} text=${JSON.stringify(m, null, 2)} />`}><${JsonView} value=${m} open=${1} /></${Section}>
  </div>`;
}

export function FlatTable({ data }) {
  const flat = {};
  (function walk(p, v) { if (v && typeof v === 'object' && !Array.isArray(v)) Object.entries(v).forEach(([k, x]) => walk(p ? p + '.' + k : k, x)); else flat[p] = Array.isArray(v) ? v.join(', ') : v; })('', data || {});
  return html`<${KV} data=${flat} />`;
}

function Maintain({ run }) {
  const s = useStore();
  const [busy, setBusy] = useState('');
  const [out, setOut] = useState(null);
  const [dlg, setDlg] = useState(false);
  if (!s.info?.framework) return null;
  const inRoot = run.dir.startsWith(s.info.root + '/');
  const call = async (label, path, body) => {
    setBusy(label); setOut(null);
    try { const r = await api(path, { method: 'POST', body: { run: run.dir, ...body } }); setOut({ label, r }); loadRuns({ quiet: true }); }
    catch (e) { setOut({ label, error: e.message }); }
    setBusy('');
  };
  if (!inRoot) return html`<div class="note" style="margin-top:14px">This run is outside the checkout, so the framework's scoring and report commands are not offered for it.</div>`;
  return html`<div style="margin-top:18px"><h3>Framework actions</h3>
    <div style="display:flex;gap:8px;flex-wrap:wrap">
      <button class="btn" disabled=${!!busy} onClick=${() => call('evaluate', 'fw/evaluate', {})} title="Aggregate the stored verdicts. Writes nothing.">Re-score from stored verdicts</button>
      <button class="btn" disabled=${!!busy} onClick=${() => setDlg(true)} title="Score this run, or grade its rubric criteria with the judge pinned for the suite">Score / judge…</button>
      <button class="btn" disabled=${!!busy} onClick=${() => call('report', 'fw/report', { formats: ['md', 'html', 'csv', 'json'] })} title="Writes report.md / .html / .csv / .json into the run directory">Write reports</button>
    </div>
    ${dlg && html`<${ScoreDialog} run=${run} onClose=${() => setDlg(false)} onDone=${() => { setDlg(false); loadRuns({ quiet: true }); }} />`}
    ${busy && html`<div class="faint" style="margin-top:8px"><span class="spinner"></span> ${busy}…</div>`}
    ${out?.error && html`<${ErrorBox} error=${out.error} />`}
    ${out?.r && html`<div style="margin-top:10px">${out.r.job ? html`<div class="note">Started job <b>${out.r.job}</b>. <a href="#/launch?tab=jobs">Follow it under Launch → Jobs</a>.</div>` : out.r.markdown ? html`<div class="note">Wrote ${(out.r.written || []).join(', ')}</div><pre class="code wrap" style="max-height:360px;margin-top:8px">${out.r.markdown}</pre>` : html`<pre class="code wrap" style="max-height:300px">${JSON.stringify(out.r, null, 2).slice(0, 6000)}</pre>`}</div>`}
  </div>`;
}

function Files({ run }) {
  const [open, setOpen] = useState(run.files.find((f) => /RUN\.md|report\.md$/.test(f.name))?.name || null);
  const f = useAsync(() => !open ? null : fetch('/api/file?' + new URLSearchParams({ dir: lib(), run: run.id, name: open })).then((r) => (r.ok ? r.text() : r.json().then((j) => Promise.reject(new Error(j.error))))), [open, run.dir]);
  return html`<div class="split" style="grid-template-columns:300px minmax(0,1fr)">
    <div><table class="t compact"><tbody>${run.files.map((x) => html`<tr key=${x.name} class=${cls('row-link', open === x.name && 'sel')} onClick=${() => setOpen(x.name)}><td class="mono" style="font-size:12px">${x.name}</td><td class="n faint">${fmtBytes(x.bytes)}</td></tr>`)}</tbody></table>
      <p class="faint" style="font-size:12px">${run.traces} trace files in <code>traces/</code> — open them from the Episodes tab. Files are shown read-only.</p>
      <div class="mono faint" style="font-size:11px;word-break:break-all">${run.dir}</div><${Maintain} run=${run} /></div>
    <div>${!open ? html`<${Empty}>Pick a file.</${Empty}>` : f.loading ? html`<${Loading} />` : f.error ? html`<${ErrorBox} error=${f.error} />` : /\.html$/.test(open) ? html`<iframe sandbox="" srcdoc=${f.data} style="width:100%;height:80vh;border:1px solid var(--rule-2);background:#fff"></iframe>` : html`<pre class="code wrap" style="max-height:80vh">${f.data.length > 400000 ? f.data.slice(0, 400000) + '\n… truncated' : f.data}</pre>`}</div>
  </div>`;
}

// ---------------------------------------------------------------------------
// Scoring and judging

/** Where this run stands: not scored, scored but never judged, judged — and what to do about it. */
function ScoreBanner({ run, onChanged }) {
  const s = useStore();
  const [dlg, setDlg] = useState(false);
  const scored = run.evaluated;
  const rubric = run.tasks?.length ? run.tasks.some((t) => (t.criteria || []).some((c) => c.type === 'artifactRubric')) : null;
  const root = s.info?.root;
  const mine = (j) => j.kind === 'evaluate' && j.runDir && (j.runDir.startsWith('/') ? j.runDir : root + '/' + j.runDir) === run.dir;
  const job = s.jobs.find((j) => mine(j) && (j.state === 'running' || j.state === 'queued'));
  const lastJob = s.jobs.find(mine);
  // A judging job that finishes changes the run on disk: read it again.
  const prev = useRef(null);
  useEffect(() => {
    const st = lastJob?.state;
    if (prev.current && (prev.current === 'running' || prev.current === 'queued') && st && st !== 'running' && st !== 'queued') onChanged();
    prev.current = st;
  }, [lastJob?.state]);
  const canAct = s.info?.framework && run.dir.startsWith(root + '/');
  const box = (tone, children) => html`<div style=${{ border: '1px solid var(--rule-2)', borderLeft: `4px solid ${tone}`, background: 'var(--panel)', padding: '10px 14px', margin: '8px 0 6px', display: 'flex', gap: '16px', alignItems: 'center', flexWrap: 'wrap' }}>${children}</div>`;
  if (job) {
    return box('var(--s1)', html`<div style="flex:1;min-width:260px"><b>${job.state === 'queued' ? 'Judging is waiting for the model host' : 'Judging in progress'}</b>
      <div class="muted" style="font-size:12.5px">The judge model is grading ${job.episodes.total} episodes. The framework reports no progress until it is done${job.state === 'running' ? html` — <${Elapsed} since=${job.startedAt} />` : ''}. This page updates by itself when it finishes.</div></div>
      <a class="btn" href=${href(['launch'], { tab: 'jobs', job: job.job })}>Follow the job →</a>`);
  }
  if (!scored) {
    return box('var(--warn)', html`<div style="flex:1;min-width:280px"><b>Not scored yet</b>
      <div class="muted" style="font-size:12.5px">${run.traces} traces recorded what the agent did, but nothing has checked whether it was right. Scoring compares each episode's end state with the task's oracle${rubric === false ? '' : ', and a judge model grades the rubric criteria (the answer\'s faithfulness)'}. Until then success rate and score are blank.${job === undefined && lastJob?.state === 'failed' ? ' The last attempt failed — see Launch → Jobs.' : ''}</div></div>
      ${canAct ? html`<button class="btn solid" onClick=${() => setDlg(true)}>Score this run…</button>` : html`<span class="faint" style="font-size:12px">${s.info?.framework ? 'outside the checkout — score it with aib evaluate' : 'start the UI inside a checkout to score runs'}</span>`}
      ${dlg && html`<${ScoreDialog} run=${run} onClose=${() => setDlg(false)} onDone=${() => { setDlg(false); onChanged(); }} />`}`);
  }
  if (rubric && !run.judge) {
    return box('var(--warn)', html`<div style="flex:1;min-width:280px"><b>Scored, but not judged</b>
      <div class="muted" style="font-size:12.5px">The suite has rubric criteria that need a judge model, and none took part in this run's verdicts. Those criteria are not reflected in the scores below.</div></div>
      ${canAct && html`<button class="btn solid" onClick=${() => setDlg(true)}>Judge this run…</button>`}
      ${dlg && html`<${ScoreDialog} run=${run} onClose=${() => setDlg(false)} onDone=${() => { setDlg(false); onChanged(); }} />`}`);
  }
  if (run.judge) {
    return html`<div class="faint" style="font-size:12.5px;margin:6px 0 2px">✓ Judged by <b class="mono" style="font-weight:500">${run.judge.id}</b>, ${run.judge.k} votes per criterion${run.judge.at ? ' · ' + fmtDate(run.judge.at) : ''}${canAct ? html` · <a href="javascript:void 0" onClick=${() => setDlg(true)}>judge again…</a>` : ''}
      ${dlg && html`<${ScoreDialog} run=${run} onClose=${() => setDlg(false)} onDone=${() => { setDlg(false); onChanged(); }} />`}</div>`;
  }
  return null;
}

/** Asks before scoring or judging: which judge, where it runs, what it can cost. */
export function ScoreDialog({ run, onClose, onDone }) {
  const plan = useAsync(() => api('fw/judge/plan', { method: 'POST', body: { run: run.dir } }), [run.dir]);
  const [cap, setCap] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const d = plan.data;
  useEffect(() => { if (d?.judge?.paid && !cap) setCap(String(Math.min(d.maxUsdPerJob ?? 5, 1))); }, [d]);
  const paid = !!d?.judge?.paid;
  const capNum = +cap;
  const capOk = !paid || (capNum > 0 && capNum <= (d?.maxUsdPerJob ?? Infinity));
  const scoreOnly = async () => {
    setBusy(true); setErr(null);
    try { await api('fw/evaluate', { method: 'POST', body: { run: run.dir } }); toast('scored'); onDone(); }
    catch (e) { setErr(e.message); setBusy(false); }
  };
  const judge = async () => {
    setBusy(true); setErr(null);
    try {
      const job = await api('fw/evaluate', { method: 'POST', body: { run: run.dir, judge: true, approved: true, maxUsd: paid ? capNum : undefined } });
      toast('judging started'); onDone(); go(['launch'], { tab: 'jobs', job: job.job });
    } catch (e) { setErr(e.message); setBusy(false); }
  };
  const needs = d?.needsJudge;
  return html`<${Modal} title=${run.evaluated ? 'Judge this run' : 'Score this run'} onClose=${onClose} wide
    footer=${html`<button class="btn ghost" onClick=${onClose}>Cancel</button>
      ${d && (!needs || !d.known) && html`<button class="btn ${needs ? '' : 'solid'}" disabled=${busy} onClick=${scoreOnly}>${run.evaluated ? 'Re-score now' : 'Score now'}</button>`}
      ${d && needs && html`<button class="btn solid" disabled=${busy || !d.judge || !capOk} onClick=${judge}>${busy ? 'starting…' : run.evaluated ? 'Judge again' : 'Judge and score'}</button>`}`}>
    ${plan.loading && html`<${Loading} what="reading the suite" />`}${plan.error && html`<${ErrorBox} error=${plan.error} />`}
    ${d && html`<div style="display:grid;gap:14px">
      <div>
        <h3>What scoring does</h3>
        <p style="margin:0;max-width:70ch">Scoring reads the traces and compares each episode's end state with the task's oracle (<code>finalStateMatch</code>), then writes <code>verdicts.json</code> and <code>metrics.csv</code> into the run folder.
          ${needs ? ` The suite also has rubric criteria — questions about what the agent said, which only a judge model can grade (${d.rubricTasks} tasks, ${d.episodesToJudge} of ${d.episodes} episodes).` : d.known ? ' This suite needs no judge: every criterion is checked mechanically, so scoring is quick and free.' : ' The suite file was not found, so it is unknown whether a judge is needed; scoring is refused by the framework if it is.'}</p>
      </div>
      ${needs && (d.judge ? html`<div>
        <h3>The judge</h3>
        <dl class="kv"><dt>pinned for ${d.suite}</dt><dd>${d.judge.config} — <b>${d.judge.model}</b> (${d.judge.provider})</dd>
          <dt>runs on</dt><dd>${paid ? html`<b style="color:var(--warn-ink)">a paid API — this costs money</b>` : `this machine (${d.judge.hosts.join(', ') || 'local'}) — no spend`}</dd>
          <dt>work</dt><dd>${d.episodesToJudge} episodes, each criterion voted on several times${d.storedJudge ? ` (earlier: k=${d.storedJudge.k})` : ''}; the framework reports no progress, you will see elapsed time</dd>
          ${d.judge.hosts.length > 0 && html`<dt>queue</dt><dd>shares the ${d.judge.hosts[0]} host with runs: it waits if one is going</dd>`}</dl>
        <p class="faint" style="margin:6px 0 0;font-size:12px">The judge is pinned per suite in <code>aib_mcp.yaml</code> so a tuning agent cannot pick a lenient one.</p>
      </div>` : html`<div class="err">No judge is pinned for ${d.suite}. Add it under <code>judges:</code> in aib_mcp.yaml.</div>`)}
      ${needs && d.storedJudge && html`<div class="note" style="border-left-color:var(--warn)">This run was judged by ${d.storedJudge.id} before. Judging again replaces its rubric verdicts.</div>`}
      ${needs && paid && html`<${Field} label="Spend cap (USD) — required" hint=${`The job stops at this amount. At most ${fmtUsd(d.maxUsdPerJob)} per job, ${fmtUsd(d.maxUsdPerDay)} per day (${fmtUsd(d.spentTodayUsd)} spent today).`}>
        <input type="number" min="0.01" step="0.1" value=${cap} onInput=${(e) => setCap(e.target.value)} style=${{ maxWidth: '180px', borderColor: capOk ? '' : 'var(--crit)' }} /></${Field}>`}
      ${needs && !run.evaluated && html`<div class="faint" style="font-size:12.5px">“Judge and score” does both in one job: mechanical criteria and rubric criteria.</div>`}
      ${err && html`<${ErrorBox} error=${err} />`}
    </div>`}
  </${Modal}>`;
}
