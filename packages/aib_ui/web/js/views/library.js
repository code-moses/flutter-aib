// The run library: every run in the opened folder, filterable by facets, tags and config values.
import { html, useState, useMemo, useStore, go, href, pref, fmtPct, fmtTok, fmtMs, fmtUsd, fmtInt, fmtNum, fmtDate, ago, runLabel, groupBy, mean, loadRuns, api, setStore, cls, shortModel, isNum } from '../lib.js';
import { PageHead, Seg, Chip, Empty, Loading, ErrorBox, FolderPicker, hint } from '../ui.js';
import { Scatter, Legend, seriesColor, Meter, Proportion } from '../charts.js';

const FACETS = [
  ['suite', 'Suite'], ['model', 'Model'], ['provider', 'Provider'], ['study', 'Study'], ['config', 'Arm (config)'], ['prompt', 'Prompt'],
  ['router', 'Router'], ['agent', 'Agent id'], ['kind', 'Agent version'], ['toolCalling', 'Tool calling'], ['environment', 'Environment'], ['judge', 'Judge'], ['evaluated', 'Evaluated'], ['runner', 'Runner'], ['os', 'OS'],
];
const SORTS = {
  name: (r, a) => runLabel(r, a).toLowerCase(), created: (r) => r.createdAt, suite: (r) => r.suite, model: (r) => (r.facets.model || []).join(),
  episodes: (r) => r.stats?.episodes, success: (r) => r.stats?.success, score: (r) => r.stats?.weighted, tokens: (r) => r.stats?.tokens, wall: (r) => r.stats?.wallMs, cost: (r) => r.stats?.costUsd,
};
const AXES = {
  tokens: ['Tokens / episode', (r) => r.stats?.tokens, fmtTok], wall: ['Wall clock / episode', (r) => r.stats?.wallMs, fmtMs], cost: ['Cost (run total)', (r) => r.stats?.costUsd, fmtUsd],
  steps: ['Actions / episode', (r) => r.stats?.steps, (x) => fmtNum(x, 1)], success: ['Success rate', (r) => r.stats?.success, fmtPct], score: ['Weighted score', (r) => r.stats?.weighted, (x) => fmtNum(x, 2)],
  episodes: ['Episodes', (r) => r.stats?.episodes, fmtInt],
};

function matches(run, ann, f, except) {
  if (f.q) {
    const hay = [run.name, ann?.alias, ann?.note, run.runId, run.suite, ...(ann?.tags || []), ...Object.values(run.facets).flat(), run.launch?.config].join(' ').toLowerCase();
    if (!f.q.toLowerCase().split(/\s+/).every((t) => hay.includes(t))) return false;
  }
  for (const [k] of FACETS) {
    if (k === except) continue;
    const sel = f.facets[k];
    if (sel?.length && !sel.some((v) => (run.facets[k] || []).includes(v))) return false;
  }
  if (except !== 'tags' && f.tags.length && !f.tags.every((t) => (ann?.tags || []).includes(t))) return false;
  for (const c of f.cfg) if (c.values.length && !c.values.includes(String(run.cfg?.[c.path]))) return false;
  if (f.starred && !ann?.starred) return false;
  if (f.days) { if (!run.createdAt || Date.now() - new Date(run.createdAt) > f.days * 86400000) return false; }
  if (f.minSuccess != null && !((run.stats?.success ?? -1) >= f.minSuccess)) return false;
  return true;
}

export function LibraryView() {
  const s = useStore();
  const [picker, setPicker] = useState(false);
  const [f, setF] = useState(() => pref.get('lib.filters', { q: '', facets: {}, tags: [], cfg: [], starred: false, days: 0, minSuccess: null }));
  const [sort, setSort] = useState(() => pref.get('lib.sort', { key: 'created', dir: -1 }));
  const [groupKey, setGroupKey] = useState(() => pref.get('lib.group', 'none'));
  const [view, setView] = useState(() => pref.get('lib.view', 'table'));
  const [sel, setSel] = useState([]);
  const [axes, setAxes] = useState(() => pref.get('lib.axes', { x: 'tokens', y: 'success', color: 'model' }));
  const [open, setOpen] = useState({});
  const upd = (patch) => setF((old) => { const n = { ...old, ...patch }; pref.set('lib.filters', n); return n; });

  const data = s.runs;
  const runs = data?.runs || [];
  const ann = (r) => data?.annotations?.[r.id] || {};

  const filtered = useMemo(() => runs.filter((r) => matches(r, ann(r), f)), [runs, f, data]);
  const sorted = useMemo(() => {
    const get = SORTS[sort.key];
    return [...filtered].sort((a, b) => {
      const x = get(a, ann(a)), y = get(b, ann(b));
      if (x == null && y == null) return 0; if (x == null) return 1; if (y == null) return -1;
      return (x < y ? -1 : x > y ? 1 : 0) * sort.dir;
    });
  }, [filtered, sort, data]);

  // Facet counts: how many runs a value would leave if chosen, given the other filters.
  const counts = useMemo(() => {
    const out = {};
    for (const [k] of FACETS) {
      const m = new Map();
      for (const r of runs) if (matches(r, ann(r), f, k)) for (const v of new Set(r.facets[k] || [])) m.set(v, (m.get(v) || 0) + 1);
      out[k] = [...m].sort((a, b) => b[1] - a[1] || String(a[0]).localeCompare(b[0]));
    }
    const t = new Map();
    for (const r of runs) if (matches(r, ann(r), f, 'tags')) for (const x of ann(r).tags || []) t.set(x, (t.get(x) || 0) + 1);
    out.tags = [...t].sort((a, b) => b[1] - a[1]);
    return out;
  }, [runs, f, data]);

  const varying = useMemo(() => {
    const m = new Map();
    for (const r of runs) for (const [k, v] of Object.entries(r.cfg || {})) { if (!m.has(k)) m.set(k, new Map()); const c = m.get(k); c.set(String(v), (c.get(String(v)) || 0) + 1); }
    return new Map([...m].filter(([, c]) => c.size > 1 && c.size < 40).sort((a, b) => a[0].localeCompare(b[0])));
  }, [runs]);

  const setSortKey = (key) => { const n = sort.key === key ? { key, dir: -sort.dir } : { key, dir: key === 'name' || key === 'suite' || key === 'model' ? 1 : -1 }; setSort(n); pref.set('lib.sort', n); };
  const toggleFacet = (k, v) => { const cur = f.facets[k] || []; upd({ facets: { ...f.facets, [k]: cur.includes(v) ? cur.filter((x) => x !== v) : [...cur, v] } }); };
  const anyFilter = f.q || f.tags.length || f.cfg.length || f.starred || f.days || f.minSuccess != null || Object.values(f.facets).some((x) => x?.length);
  const clear = () => upd({ q: '', facets: {}, tags: [], cfg: [], starred: false, days: 0, minSuccess: null });

  const groups = useMemo(() => {
    if (groupKey === 'none') return [['', sorted]];
    const g = groupBy(sorted, (r) => (r.facets[groupKey] || ['—']).join(' + '));
    return [...g].sort((a, b) => a[0].localeCompare(b[0]));
  }, [sorted, groupKey]);

  const toggleSel = (id) => setSel((old) => (old.includes(id) ? old.filter((x) => x !== id) : [...old, id]));
  const star = async (r) => { await api('user/annotate', { method: 'POST', body: { dir: r.dir, starred: !ann(r).starred } }); loadRuns({ quiet: true }); };

  if (s.loading && !data) return html`<${Loading} what="reading runs" />`;
  return html`<div>
    <${PageHead} kicker="I · The run library" title=${html`Runs <em>${data ? `(${fmtInt(filtered.length)}${filtered.length !== runs.length ? ' of ' + fmtInt(runs.length) : ''})` : ''}</em>`}
      sub=${html`<span class="mono" style="font-size:12px">${s.library || s.info?.defaultLibrary}</span>${data ? ` · scanned in ${data.scanMs} ms` : ''}`}>
      <${Seg} options=${[{ id: 'table', label: 'Ledger' }, { id: 'landscape', label: 'Landscape' }]} value=${view} onChange=${(v) => { setView(v); pref.set('lib.view', v); }} />
      <button class="btn" onClick=${() => setPicker(true)}>Open folder…</button>
      <button class="btn ghost" onClick=${() => loadRuns()} title="Rescan the folder">Rescan</button>
    </${PageHead}>
    ${picker && html`<${FolderPicker} onClose=${() => setPicker(false)} />`}
    <${ErrorBox} error=${s.error} />
    ${data && !runs.length && html`<${Empty}>No runs in this folder. Open one that contains run directories (each has a run_manifest.json).${data.otherFolders?.length ? ` Other folders here: ${data.otherFolders.slice(0, 6).join(', ')}.` : ''}</${Empty}>`}
    ${runs.length > 0 && html`<div class="split">
      <aside class="facets" aria-label="Filters">
        <input type="search" placeholder="Search name, tag, model, note…" value=${f.q} onInput=${(e) => upd({ q: e.target.value })} aria-label="search runs" />
        <div style="display:flex;gap:6px;margin:8px 0;align-items:center;flex-wrap:wrap">
          <${Seg} options=${[{ id: 0, label: 'any time' }, { id: 7, label: '7d' }, { id: 30, label: '30d' }]} value=${f.days} onChange=${(v) => upd({ days: v })} />
          <label style="display:flex;gap:5px;align-items:center;font-size:12px"><input type="checkbox" checked=${f.starred} onChange=${(e) => upd({ starred: e.target.checked })} /> ★ only</label>
        </div>
        <div class="facet" style="border-top:0"><h3>Success ≥ <span class="mono">${f.minSuccess == null ? 'any' : fmtPct(f.minSuccess)}</span></h3>
          <input type="range" min="0" max="1" step="0.05" value=${f.minSuccess ?? 0} onInput=${(e) => upd({ minSuccess: +e.target.value === 0 ? null : +e.target.value })} style="width:100%;accent-color:var(--ink)" aria-label="minimum success rate" /></div>
        ${anyFilter && html`<button class="btn sm ghost" onClick=${clear} style="margin:4px 0 6px">Clear all filters</button>`}
        ${counts.tags.length > 0 && html`<${FacetBox} title="Your tags" items=${counts.tags} selected=${f.tags} onToggle=${(v) => upd({ tags: f.tags.includes(v) ? f.tags.filter((x) => x !== v) : [...f.tags, v] })} />`}
        ${FACETS.map(([k, label]) => counts[k].length > 1 || (f.facets[k] || []).length ? html`<${FacetBox} key=${k} title=${label} items=${counts[k]} selected=${f.facets[k] || []} onToggle=${(v) => toggleFacet(k, v)} />` : null)}
        <div class="facet"><h3>Config value</h3>
          <div class="muted" style="font-size:11.5px;margin-bottom:6px">Filter on any recorded setting — only paths that differ between runs are offered.</div>
          ${f.cfg.map((c, i) => html`<div key=${c.path} style="margin-bottom:8px">
            <div style="display:flex;justify-content:space-between;font:11px var(--mono)"><span>${c.path}</span><a href="javascript:void 0" onClick=${() => upd({ cfg: f.cfg.filter((_, j) => j !== i) })}>×</a></div>
            ${[...varying.get(c.path) || []].map(([v, n]) => html`<label key=${v} style="display:grid;grid-template-columns:16px 1fr auto;gap:6px;font-size:12px;cursor:pointer"><input type="checkbox" checked=${c.values.includes(v)} onChange=${() => upd({ cfg: f.cfg.map((x, j) => j === i ? { ...x, values: x.values.includes(v) ? x.values.filter((y) => y !== v) : [...x.values, v] } : x) })} /><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${v}</span><span class="faint mono">${n}</span></label>`)}
          </div>`)}
          <select onChange=${(e) => { if (e.target.value) upd({ cfg: [...f.cfg, { path: e.target.value, values: [] }] }); e.target.value = ''; }} aria-label="add config filter">
            <option value="">+ add a config path…</option>
            ${[...varying.keys()].filter((k) => !f.cfg.some((c) => c.path === k)).map((k) => html`<option key=${k} value=${k}>${k}</option>`)}
          </select>
        </div>
      </aside>
      <div>
        ${view === 'table' ? html`
          <div style="display:flex;gap:10px;align-items:center;margin-bottom:8px">
            <span class="muted">Group by</span>
            <select value=${groupKey} onChange=${(e) => { setGroupKey(e.target.value); pref.set('lib.group', e.target.value); }} style="width:auto">
              <option value="none">— nothing —</option>${FACETS.slice(0, 8).map(([k, l]) => html`<option key=${k} value=${k}>${l}</option>`)}
            </select>
            <span class="faint" style="margin-left:auto;font-size:12px">Select runs to compare them · click a row to open</span>
          </div>
          <div class="tw"><table class="t">
            <thead><tr>
              <th style="width:34px"></th>
              ${[['name', 'Run'], ['suite', 'Suite'], ['model', 'Model · setup'], ['episodes', 'Eps'], ['success', 'Success'], ['score', 'Score'], ['tokens', 'Tok/ep'], ['wall', 'Wall/ep'], ['cost', 'Cost'], ['created', 'Date']].map(([k, l]) =>
                html`<th key=${l} class=${cls(k && 'sortable', ['episodes', 'success', 'score', 'tokens', 'wall', 'cost'].includes(k) && 'r')} onClick=${() => k && setSortKey(k)}>${l}${sort.key === k && html`<span class="ar">${sort.dir > 0 ? '▲' : '▼'}</span>`}</th>`)}
            </tr></thead>
            <tbody>${groups.map(([g, rows]) => html`
              ${g && html`<tr class="grp" key=${'g' + g}><td colspan="12">${g} <span class="faint mono" style="font:12px var(--mono)">${rows.length}</span></td></tr>`}
              ${rows.map((r) => html`<${RunRow} key=${r.id} r=${r} a=${ann(r)} checked=${sel.includes(r.id)} order=${sel.indexOf(r.id)} onCheck=${() => toggleSel(r.id)} onStar=${() => star(r)} />`)}
            `)}</tbody>
          </table></div>
          ${!sorted.length && html`<${Empty}>No run matches these filters.</${Empty}>`}
        ` : html`<${Landscape} rows=${sorted} ann=${ann} axes=${axes} onAxes=${(a) => { setAxes(a); pref.set('lib.axes', a); }} />`}
        ${sel.length > 0 && html`<div class="dock">
          <b>${sel.length} selected</b><span class="faint">${sel.length < 2 ? 'pick at least one more to compare' : ''}</span>
          <span style="margin-left:auto;display:flex;gap:8px">
            <button class="btn" onClick=${() => setSel([])}>Clear</button>
            <button class="btn solid" disabled=${sel.length < 1} onClick=${() => go(['compare'], { runs: sel.join('|') })}>Compare ${sel.length} →</button>
          </span></div>`}
      </div>
    </div>`}
  </div>`;
}

function FacetBox({ title, items, selected, onToggle }) {
  const [more, setMore] = useState(false);
  const [shut, setShut] = useState(false);
  const shown = more ? items : items.slice(0, 7);
  const sel = selected.filter((s) => !items.some(([v]) => v === s));
  return html`<div class="facet"><h3 onClick=${() => setShut(!shut)}>${title}<span class="faint">${shut ? '+' : '−'}</span></h3>
    ${!shut && html`<div>
      ${[...sel.map((v) => [v, 0]), ...shown].map(([v, n]) => html`<label key=${v}><input type="checkbox" checked=${selected.includes(v)} onChange=${() => onToggle(v)} /><span class="l" title=${v}>${v}</span><span class="c">${n}</span></label>`)}
      ${items.length > 7 && html`<button class="more" onClick=${() => setMore(!more)}>${more ? 'fewer' : `${items.length - 7} more…`}</button>`}
    </div>`}</div>`;
}

function RunRow({ r, a, checked, order, onCheck, onStar }) {
  const st = r.stats;
  const open = () => go(['run', r.id]);
  const models = [...new Set(r.agents.map((x) => shortModel(x.model)))];
  const setup = [...new Set(r.agents.map((x) => x.promptVersion || x.version))].join(' · ');
  const vs = st?.verdicts;
  return html`<tr class=${cls('row-link', checked && 'sel')} onClick=${open}>
    <td onClick=${(e) => e.stopPropagation()} style="line-height:1.2"><input type="checkbox" checked=${checked} onChange=${onCheck} aria-label=${'select ' + r.name} />
      <div onClick=${(e) => { e.stopPropagation(); onStar(); }} style="cursor:pointer;margin-top:2px;color:${a.starred ? 'var(--ink)' : 'var(--ink-3)'}" aria-label="star">${a.starred ? '★' : '☆'}</div></td>
    <td style="max-width:225px"><div class="nm" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title=${r.name}>${a.alias || r.name} ${a.alias && html`<span class="faint mono" style="font-size:11px">${r.name}</span>`}</div>
      <div class="sub" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${r.facets.study?.[0] ? html`<span>${r.facets.study[0]}</span> · ` : ''}${r.facets.config?.[0] ? html`<span class="mono">${r.facets.config[0]}</span>` : r.agents.map((x) => x.id).join(', ')}
      ${(a.tags || []).map((t) => html` <span class="chip tag" key=${t} style="line-height:15px;font-size:10px">${t}</span>`)}</div></td>
    <td class="nowrap">${r.suite}<div class="sub">${r.taskCount}×${r.repetitions}${r.traces && st?.episodes !== r.traces ? ` · ${r.traces} traces` : ''}</div></td>
    <td>${models.join(', ')}<div class="sub" style="max-width:150px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis" title=${r.agents[0]?.router || ''}>${setup}${r.agents[0]?.router ? ' · ' + r.agents[0].router.split(' · ')[0] : ''}</div></td>
    <td class="n">${st ? fmtInt(st.episodes) : html`<span class="faint">${r.traces}</span>`}</td>
    <td class="n" style="min-width:118px">${st?.success != null ? html`<${Meter} value=${st.success} width=${34} color="var(--s1)" />${fmtPct(st.success)}` : r.evaluated ? html`<span class="faint">—</span>` : html`<span class="chip" title="no verdicts yet — open the run to score it" style="line-height:16px;font-size:10.5px">– not scored</span>`}</td>
    <td class="n">${st?.weighted != null ? fmtNum(st.weighted, 2) : '—'}</td>
    <td class="n">${fmtTok(st?.tokens)}</td>
    <td class="n">${fmtMs(st?.wallMs).replace(/ (\d)/, '$1').replace(' s', 's').replace(' m', 'm')}</td>
    <td class="n">${st?.costUsd ? fmtUsd(st.costUsd) : html`<span class="faint">${st ? '—' : ''}</span>`}</td>
    <td class="n muted" title=${fmtDate(r.createdAt)} style="font-family:var(--sans);font-size:12px">${(r.createdAt || '').slice(5, 10).split('-').reverse().join('.')}<div class="sub">${ago(r.createdAt)}</div></td>
  </tr>`;
}

function Landscape({ rows, ann, axes, onAxes }) {
  const colorKeys = FACETS.slice(0, 9);
  const cats = useMemo(() => {
    const m = new Map();
    for (const r of rows) { const k = (r.facets[axes.color] || ['—']).join(' + '); m.set(k, (m.get(k) || 0) + 1); }
    return [...m].sort((a, b) => b[1] - a[1]).map(([k]) => k);
  }, [rows, axes.color]);
  const colorOf = (r) => { const i = cats.indexOf((r.facets[axes.color] || ['—']).join(' + ')); return seriesColor(i); };
  const [, xf, xfmt] = [0, AXES[axes.x][1], AXES[axes.x][2]];
  const yf = AXES[axes.y][1], yfmt = AXES[axes.y][2];
  const points = rows.map((r) => ({ id: r.id, x: xf(r), y: yf(r), color: colorOf(r), label: runLabel(r, ann(r)), tipRows: html`<div class="row"><span>suite</span><span>${r.suite}</span></div><div class="row"><span>model</span><span>${(r.facets.model || []).join(', ')}</span></div>` })).filter((p) => isNum(p.x) && isNum(p.y));
  return html`<div>
    <div style="display:flex;gap:14px;flex-wrap:wrap;margin-bottom:10px;align-items:end">
      ${[['y', 'Up'], ['x', 'Across']].map(([k, l]) => html`<label class="field" key=${k} style="min-width:170px"><span>${l}</span><select value=${axes[k]} onChange=${(e) => onAxes({ ...axes, [k]: e.target.value })}>${Object.entries(AXES).map(([id, [name]]) => html`<option key=${id} value=${id}>${name}</option>`)}</select></label>`)}
      <label class="field" style="min-width:170px"><span>Colour by</span><select value=${axes.color} onChange=${(e) => onAxes({ ...axes, color: e.target.value })}>${colorKeys.map(([id, name]) => html`<option key=${id} value=${id}>${name}</option>`)}</select></label>
      <span class="faint" style="font-size:12px;margin-left:auto">${points.length} of ${rows.length} runs have both numbers · filters on the left apply</span>
    </div>
    <${Legend} items=${cats.slice(0, 9).map((c, i) => ({ label: i === 8 ? 'other' : c, color: seriesColor(i) }))} />
    <${Scatter} points=${points} xLabel=${AXES[axes.x][0]} yLabel=${AXES[axes.y][0]} xFmt=${xfmt} yFmt=${yfmt} height=${440} onClick=${(p) => go(['run', p.id])} />
    <p class="muted" style="max-width:70ch">Each dot is a run. Runs on different suites measure different things — filter to one suite before reading across the page.</p>
  </div>`;
}
