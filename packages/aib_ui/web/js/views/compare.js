// Side-by-side runs: what differs in their configuration, what that did to the numbers
// (task-paired deltas with bootstrap intervals), and where on the task list they disagree.
import { html, useState, useMemo, useEffect, useStore, runApi, api, useAsync, go, href, pref, lib, toast,
  fmtPct, fmtTok, fmtMs, fmtUsd, fmtInt, fmtNum, fmtMetric, metricInfo, isNum, nums, mean, median, sum, wilson, taskMeans, pairedDelta, runLabel, cls, csv, download, groupBy, shortModel } from '../lib.js';
import { PageHead, Section, Chip, Loading, ErrorBox, Empty, Seg, Verdict, Copy, tip } from '../ui.js';
import { Strip, Forest, HBars, Scatter, Legend, seriesColor, seqColor, seqText, trunc } from '../charts.js';
import { summarize } from './run.js';

const DEFAULT_METRICS = ['success', 'weighted_score', 'tokens_total', 'wall_clock_ms', 'action_count', 'path_efficiency', 'llm_latency_ms', 'cost_usd'];

/** An episode's value for a metric, with fallbacks to what the traces hold. */
export function epVal(e, m) {
  if (m === 'success') return e.verdict === 'success' ? 1 : e.verdict ? 0 : null;
  if (m === 'weighted_score' || m === 'score') return isNum(e.score) ? e.score : e.metrics?.weighted_score ?? null;
  const v = e.metrics?.[m];
  if (isNum(v)) return v;
  if (m === 'tokens_total') return e.trace?.tokens ?? null;
  if (m === 'wall_clock_ms') return e.trace?.wallMs ?? null;
  if (m === 'action_count') return e.trace?.steps ?? null;
  return null;
}
const perTask = (eps, m) => {
  const by = new Map();
  for (const e of eps) { const v = epVal(e, m); if (!isNum(v)) continue; if (!by.has(e.taskId)) by.set(e.taskId, []); by.get(e.taskId).push(v); }
  return new Map([...by].map(([k, v]) => [k, mean(v)]));
};

export function CompareView({ query }) {
  const s = useStore();
  const ids = (query.runs || '').split('|').filter(Boolean);
  const [picker, setPicker] = useState('');
  const [metric, setMetric] = useState(pref.get('cmp.metric', 'weighted_score'));
  const [extra, setExtra] = useState(pref.get('cmp.extra', []));
  const [showAllCfg, setShowAllCfg] = useState(false);
  const [sortGap, setSortGap] = useState(true);
  const runs = useAsync(() => Promise.all(ids.map((id) => runApi('run', { run: id }))), [ids.join('|'), lib()]);
  const setIds = (n) => go(['compare'], { runs: n.join('|') }, { replace: true });
  const library = s.runs?.runs || [];

  const data = runs.data || [];
  const metrics = useMemo(() => {
    const set = new Set();
    data.forEach((r) => r.episodes.forEach((e) => Object.entries(e.metrics || {}).forEach(([k, v]) => isNum(v) && set.add(k))));
    return [...set].sort();
  }, [runs.data]);
  const rows = [...DEFAULT_METRICS, ...extra.filter((m) => !DEFAULT_METRICS.includes(m))];
  const col = (i) => seriesColor(i);

  const head = html`<${PageHead} kicker="II · Compare" title=${ids.length ? `${ids.length} run${ids.length > 1 ? 's' : ''} side by side` : 'Compare runs'} sub="The first run is the baseline: every difference is read against it, over the tasks the runs share.">
    ${data.length > 0 && html`<button class="btn ghost" onClick=${() => exportTable(data, rows)}>Export CSV</button>`}
  </${PageHead}>`;

  const chips = html`<div class="chips" style="margin-bottom:20px;align-items:center">
    ${ids.map((id, i) => {
      const run = library.find((r) => r.id === id);
      return html`<span key=${id} class="chip" style="line-height:24px;padding:0 8px 0 9px;font-size:12.5px"><span class="sw" style=${{ background: col(i), width: '10px', height: '10px', borderRadius: '2px' }}></span>
        ${i === 0 ? html`<b style="font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3)">base</b>` : ''}${runLabel(run || { name: id }, s.runs?.annotations?.[id])}
        <span class="x" onClick=${() => setIds(ids.filter((x) => x !== id))}>×</span>
        ${i > 0 && html`<span class="x" title="make baseline" onClick=${() => setIds([id, ...ids.filter((x) => x !== id)])}>⇤</span>`}</span>`;
    })}
    <select value=${picker} onChange=${(e) => { if (e.target.value) setIds([...ids, e.target.value]); setPicker(''); }} style="width:260px" aria-label="add a run">
      <option value="">+ add a run…</option>
      ${(function opts() { const g = groupBy(library.filter((r) => !ids.includes(r.id)), (r) => r.suite); return [...g].map(([suite, rs]) => html`<optgroup key=${suite} label=${suite}>${rs.map((r) => html`<option key=${r.id} value=${r.id}>${runLabel(r, s.runs?.annotations?.[r.id])}${r.stats ? ' · ' + fmtPct(r.stats.success) : ''}</option>`)}</optgroup>`); })()}
    </select>
  </div>`;

  if (!ids.length) return html`<div>${head}${chips}<${Empty}>Pick runs from the library with the checkboxes, or add them here.</${Empty}></div>`;
  if (runs.loading) return html`<div>${head}${chips}<${Loading} what="reading runs" /></div>`;
  if (runs.error) return html`<div>${head}${chips}<${ErrorBox} error=${runs.error} /></div>`;

  const suites = [...new Set(data.map((r) => r.suite))];
  const base = data[0];
  const tasksAll = [...new Set(data.flatMap((r) => r.episodes.map((e) => e.taskId)))];
  const shared = tasksAll.filter((t) => data.every((r) => r.episodes.some((e) => e.taskId === t)));
  const sm = data.map((r) => summarize(r.episodes));
  const cell = (r, m) => {
    const eps = r.episodes;
    const vs = nums(eps.map((e) => epVal(e, m)));
    return { value: m === 'cost_usd' ? sum(vs) : mean(vs), n: vs.length };
  };
  const delta = (i, m) => (i === 0 ? null : pairedDelta(perTask(base.episodes, m), perTask(data[i].episodes, m)));
  const info = (m) => metricInfo(m);
  const fmt = (m, v) => (m === 'success' ? fmtPct(v) : m === 'weighted_score' ? fmtNum(v, 2) : fmtMetric(m, v));
  const isRate = (m) => m === 'success' || ['bool', 'ratio'].includes(info(m).unit);
  const dfmt = (m, v) => (v >= 0 ? '+' : '') + (isRate(m) ? (v * 100).toFixed(Math.abs(v) < 0.1 ? 1 : 0) + ' pp' : m === 'weighted_score' ? fmtNum(v, 2) : fmtMetric(m, v));
  const afmt = (m, v) => (isRate(m) ? (v * 100).toFixed(0) + ' pp' : fmt(m, v));
  const verdictOfDelta = (m, d) => {
    if (!d || !d.sig) return 'flat';
    const dir = info(m).dir;
    if (!dir) return 'moved';
    return d.delta * dir > 0 ? 'better' : 'worse';
  };

  return html`<div>
    ${head}${chips}
    ${suites.length > 1 && html`<div class="err" style="margin-bottom:16px;border-left-color:var(--warn);color:var(--warn-ink)">These runs are on different suites (${suites.join(', ')}). Only the ${shared.length} tasks they share are paired; read absolute numbers with care.</div>`}
    ${suites.length === 1 && shared.length < tasksAll.length && html`<div class="note" style="margin-bottom:16px">${shared.length} of ${tasksAll.length} tasks appear in every run; paired differences use the tasks both runs of a pair have.</div>`}

    <${Section} no="1" title="What differs" hint="recorded configuration, only the rows that are not identical">
      <${ConfigDiff} data=${data} ids=${ids} showAll=${showAllCfg} onToggle=${() => setShowAllCfg(!showAllCfg)} />
    </${Section}>

    <${Section} no="2" title="The numbers" hint="mean over episodes · Δ against the baseline, paired by task, 95% bootstrap interval"
      actions=${html`<select onChange=${(e) => { if (e.target.value) { const n = [...extra, e.target.value]; setExtra(n); pref.set('cmp.extra', n); } e.target.value = ''; }} style="width:auto"><option value="">+ metric row</option>${metrics.filter((m) => !rows.includes(m)).map((m) => html`<option key=${m}>${m}</option>`)}</select>`}>
      <div class="tw"><table class="t">
        <thead><tr><th>Metric</th>${data.map((r, i) => html`<th key=${r.id} class="r"><span class="chip" style="border:0;background:none;padding:0"><span class="sw" style=${{ background: col(i), width: '9px', height: '9px', borderRadius: '2px' }}></span>${trunc(runLabel(r, r.annotation), 22)}</span></th>`)}</tr></thead>
        <tbody>
          <tr><td class="nm">Episodes</td>${data.map((r) => html`<td class="n" key=${r.id}>${r.episodes.length}</td>`)}</tr>
          ${rows.map((m) => {
            const cells = data.map((r, i) => ({ c: cell(r, m), d: delta(i, m) }));
            if (cells.every((x) => x.c.value == null)) return null;
            const mx = Math.max(...cells.map((x) => x.c.value ?? 0), 1e-9);
            return html`<tr key=${m} class=${m === metric ? 'sel' : ''} onClick=${() => { setMetric(m); pref.set('cmp.metric', m); }} style="cursor:pointer" title="click to chart this metric below">
              <td><span class="nm">${m}</span><div class="sub">${info(m).unit}${info(m).dir ? ' · ' + (info(m).dir > 0 ? 'higher better' : 'lower better') : ''}</div></td>
              ${cells.map(({ c, d }, i) => {
                const v = verdictOfDelta(m, d);
                return html`<td class="n" key=${i}>
                  <div style="font-size:13.5px">${fmt(m, c.value)}</div>
                  ${d ? html`<div style=${{ fontSize: '11.5px', color: v === 'better' ? 'var(--good-ink)' : v === 'worse' ? 'var(--crit-ink)' : v === 'moved' ? 'var(--ink)' : 'var(--ink-3)' }}
                    onMouseMove=${(e) => tip.show(e, html`<b>Δ vs ${trunc(runLabel(base), 28)}</b><div class="row"><span>difference</span><span class="m">${dfmt(m, d.delta)}</span></div><div class="row"><span>95% CI</span><span class="m">${dfmt(m, d.lo)} … ${dfmt(m, d.hi)}</span></div><div class="row"><span>tasks paired</span><span class="m">${d.n}</span></div>${d.sig ? '' : html`<div style="opacity:.75">the interval contains 0</div>`}`)} onMouseLeave=${tip.hide}>
                    ${d.sig ? (d.delta > 0 ? '▲ ' : '▼ ') : '≈ '}${dfmt(m, d.delta)}${v === 'better' ? ' ✓' : v === 'worse' ? ' ✗' : ''}</div>` : i > 0 ? html`<div class="faint" style="font-size:11px">no shared tasks</div>` : html`<div class="faint" style="font-size:11px">baseline</div>`}
                </td>`;
              })}</tr>`;
          })}
        </tbody>
      </table></div>
      <div class="faint" style="font-size:12px;margin-top:8px">▲▼ the interval excludes zero · ≈ it does not (at few tasks, a difference is a direction, not a result) · ✓ ✗ whether that move is the better or worse one for the metric.</div>
    </${Section}>

    <${Section} no="3" title=${metric} hint=${info(metric).description}
      actions=${html`<select value=${metric} onChange=${(e) => { setMetric(e.target.value); pref.set('cmp.metric', e.target.value); }} style="width:auto"><option value="success">success</option><option value="weighted_score">weighted_score</option>${metrics.filter((m) => m !== 'weighted_score').map((m) => html`<option key=${m}>${m}</option>`)}</select>`}>
      <div class="grid2">
        <div><div class="chart-title"><h3>Difference to baseline</h3><span class="u">${info(metric).unit}</span></div>
          <${Forest} label=${metric} fmt=${(v) => afmt(metric, v)} rows=${data.slice(1).map((r, i) => { const d = delta(i + 1, metric); return { label: runLabel(r, r.annotation), delta: d?.delta, lo: d?.lo, hi: d?.hi, sig: d?.sig, color: col(i + 1), sub: d ? `${d.n} tasks paired` : 'no shared tasks' }; })} />
          ${data.length < 2 && html`<div class="faint">add a second run to see differences</div>`}</div>
        <div><div class="chart-title"><h3>Distribution per run</h3><span class="u">dot = episode</span></div>
          <${Strip} label=${metric} fmt=${(v) => fmt(metric, v)} groups=${data.map((r, i) => ({ label: runLabel(r, r.annotation), color: col(i), values: r.episodes.map((e) => ({ v: epVal(e, metric), id: e.id, label: e.id })).filter((o) => isNum(o.v)) }))} onClick=${(o, g) => { const i = data.findIndex((r) => runLabel(r, r.annotation) === g.label); go(['run', data[i].id, 'ep', o.id]); }} />
        </div>
      </div>
    </${Section}>

    <${Section} no="4" title="Cost and accuracy" hint="up and to the left is better; whiskers are 95% intervals">
      <div class="grid2">
        <div><div class="chart-title"><h3>Success against tokens per episode</h3></div>
          <${Scatter} height=${300} xLabel="tokens / episode" yLabel="success rate" xFmt=${fmtTok} yFmt=${(v) => fmtPct(v)} yDomain=${[0, 1.02]}
            points=${data.map((r, i) => { const x = mean(r.episodes.map((e) => epVal(e, 'tokens_total'))); const k = r.episodes.filter((e) => e.verdict === 'success').length, n = r.episodes.length; const [lo, hi] = wilson(k, n); return { id: r.id, x, y: k / n, ylo: lo, yhi: hi, color: col(i), label: runLabel(r, r.annotation), direct: trunc(runLabel(r, r.annotation), 20), r: 6.5 }; })} onClick=${(p) => go(['run', p.id])} />
        </div>
        <div><div class="chart-title"><h3>Success rate</h3><span class="u">95% Wilson</span></div>
          <${HBars} label="success rate" fmt=${fmtPct} max=${1} rows=${data.map((r, i) => { const k = r.episodes.filter((e) => e.verdict === 'success').length, n = r.episodes.length; const [lo, hi] = wilson(k, n); return { id: r.id, label: runLabel(r, r.annotation), value: k / n, lo, hi, color: col(i), sub: `${k}/${n} episodes` }; })} onClick=${(r) => go(['run', r.id])} />
          <div class="chart-title" style="margin-top:14px"><h3>Weighted score</h3></div>
          <${HBars} label="weighted score" fmt=${(v) => fmtNum(v, 2)} max=${1} rows=${data.map((r, i) => ({ id: r.id, label: runLabel(r, r.annotation), value: sm[i].score, color: col(i) }))} onClick=${(r) => go(['run', r.id])} />
        </div>
      </div>
    </${Section}>

    <${Section} no="5" title="Task by task" hint="mean score per task · scale in the legend · click a cell to open the task"
      actions=${html`<label style="display:flex;gap:6px;align-items:center;font-size:12.5px"><input type="checkbox" checked=${sortGap} onChange=${(e) => setSortGap(e.target.checked)} /> biggest disagreement first</label>`}>
      <${TaskMatrix} data=${data} sortGap=${sortGap} ids=${ids} />
    </${Section}>

    <${Framework} ids=${ids} data=${data} />
  </div>`;
}

function exportTable(data, rows) {
  const out = [['metric', ...data.map((r) => r.name)]];
  for (const m of rows) out.push([m, ...data.map((r) => { const v = nums(r.episodes.map((e) => epVal(e, m))); return m === 'cost_usd' ? sum(v) : mean(v); })]);
  download('aib-compare.csv', csv(out), 'text/csv');
}

function ConfigDiff({ data, ids, showAll, onToggle }) {
  const keys = useMemo(() => {
    const all = new Set(data.flatMap((r) => Object.keys(r.cfg || {})));
    return [...all].filter((k) => showAll || new Set(data.map((r) => String(r.cfg?.[k] ?? '∅'))).size > 1).sort();
  }, [data, showAll]);
  const top = [['suite', (r) => r.suite], ['model', (r) => (r.facets.model || []).join(', ')], ['arm', (r) => r.facets.config?.[0]], ['study', (r) => r.facets.study?.[0]], ['judge', (r) => r.facets.judge?.[0]], ['created', (r) => (r.createdAt || '').slice(0, 16).replace('T', ' ')]];
  return html`<div class="tw"><table class="t compact">
    <thead><tr><th style="width:260px">Setting</th>${data.map((r, i) => html`<th key=${r.id}><span class="sw" style=${{ background: seriesColor(i), width: '9px', height: '9px', borderRadius: '2px', display: 'inline-block', marginRight: '6px' }}></span>${trunc(runLabel(r, r.annotation), 24)}</th>`)}</tr></thead>
    <tbody>
      ${top.map(([l, f]) => { const vs = data.map(f); const diff = l !== 'created' && new Set(vs).size > 1; return html`<tr key=${l} class=${diff ? 'diffrow' : ''}><td class="nm">${l}</td>${vs.map((v, i) => html`<td key=${i} class="mono" style="font-size:12px">${v ?? '—'}</td>`)}</tr>`; })}
      ${keys.map((k) => { const vs = data.map((r) => r.cfg?.[k]); const diff = new Set(vs.map(String)).size > 1; return html`<tr key=${k} class=${diff ? 'diffrow' : ''}><td class="mono" style="font-size:11.5px;color:var(--ink-2)">${k}</td>${vs.map((v, i) => html`<td key=${i} class="mono" style="font-size:12px;max-width:260px;overflow:hidden;text-overflow:ellipsis">${v === undefined ? html`<span class="faint">∅</span>` : String(v)}</td>`)}</tr>`; })}
    </tbody></table>
    <div style="margin-top:8px"><button class="btn ghost sm" onClick=${onToggle}>${showAll ? 'only differences' : 'show all recorded settings'}</button> <span class="faint" style="font-size:12px">${keys.length} setting${keys.length === 1 ? '' : 's'} listed${!showAll && !keys.length ? ' — the recorded agent settings are identical' : ''}</span></div>
  </div>`;
}

function TaskMatrix({ data, sortGap, ids }) {
  const tasks = [...new Set(data.flatMap((r) => r.episodes.map((e) => e.taskId)))];
  const titles = Object.fromEntries(data.flatMap((r) => (r.tasks || []).map((t) => [t.id, t.title])));
  const per = data.map((r) => perTask(r.episodes, 'weighted_score'));
  const rows = tasks.map((t) => { const v = per.map((m) => m.get(t)); const n = nums(v); return { t, v, gap: n.length > 1 ? Math.max(...n) - Math.min(...n) : 0 }; });
  if (sortGap) rows.sort((a, b) => b.gap - a.gap);
  return html`<div class="tw"><table class="mx">
    <thead><tr><th></th>${data.map((r, i) => html`<th class="col" key=${r.id} style="max-width:110px"><span class="sw" style=${{ background: seriesColor(i), width: '8px', height: '8px', display: 'inline-block', borderRadius: '2px', marginRight: '4px' }}></span>${trunc(runLabel(r, r.annotation), 14)}</th>`)}<th class="col">gap</th></tr></thead>
    <tbody>${rows.map(({ t, v, gap }) => html`<tr key=${t}>
      <th title=${t}>${trunc(titles[t] || t, 46)}<div class="faint mono" style="font-size:10.5px">${t}</div></th>
      ${v.map((x, i) => html`<td key=${i} style="min-width:92px"><button class="cell" style=${{ background: seqColor(x), color: seqText(x), width: '100%' }} disabled=${x == null} onClick=${() => go(['run', ids[i]], { tab: 'tasks', task: t })}
        onMouseMove=${(e) => tip.show(e, html`<b>${t}</b><div class="row"><span>${trunc(runLabel(data[i], data[i].annotation), 26)}</span><span class="m">${fmtNum(x, 2)}</span></div>`)} onMouseLeave=${tip.hide}>${x == null ? '·' : fmtNum(x, 2)}</button></td>`)}
      <td class="mono" style="padding-left:10px;font-size:12px;color:${gap > 0.4 ? 'var(--ink)' : 'var(--ink-3)'}">${gap ? fmtNum(gap, 2) : ''}</td>
    </tr>`)}</tbody></table>
    <${Legend} items=${[0, 0.25, 0.5, 0.75, 1].map((x) => ({ label: fmtNum(x, 2), color: seqColor(x) }))} /></div>`;
}

function Framework({ ids, data }) {
  const s = useStore();
  const [vary, setVary] = useState('');
  const [state, setState] = useState(null);
  if (!s.info?.framework || data.length < 2) return null;
  const run = async () => {
    setState({ loading: true });
    try {
      const out = await api('fw/compare', { method: 'POST', body: { runs: data.map((r) => r.dir), vary: vary.split(',').map((x) => x.trim()).filter(Boolean) } });
      setState({ out });
    } catch (e) { setState({ error: e.message }); }
  };
  return html`<${Section} no="6" title="The framework's own comparison" hint="aib compare — refuses runs that differ in more than you name">
    <div style="display:flex;gap:10px;align-items:end;max-width:760px"><label class="field" style="flex:1"><span>allowed to differ (dotted-path globs, comma separated)</span><input type="text" placeholder="agents.*.metadata.model, agents.*.version" value=${vary} onInput=${(e) => setVary(e.target.value)} /></label><button class="btn" onClick=${run} disabled=${state?.loading}>${state?.loading ? 'comparing…' : 'Run aib compare'}</button></div>
    ${state?.error && html`<${ErrorBox} error=${state.error} />`}
    ${state?.out?.markdown && html`<pre class="code wrap" style="margin-top:12px;max-height:520px">${state.out.markdown}</pre>`}
  </${Section}>`;
}
