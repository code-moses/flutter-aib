// Suites: what a run can be asked to do. Descriptions carry no ground truth.
import { html, useState, useMemo, useStore, api, useAsync, go, href, groupBy, fmtInt, cls, fmtTok, fmtMs } from '../lib.js';
import { PageHead, Section, Chip, Loading, ErrorBox, Empty } from '../ui.js';
import { trunc, HBars } from '../charts.js';

export function SuitesView({ name }) {
  const s = useStore();
  if (!s.info?.framework) return html`<div><${PageHead} kicker="IV · Suites" title="Task suites" /><${Empty}>Start the UI with <code>--root</code> pointing at a checkout to read its suites.</${Empty}></div>`;
  const list = useAsync(() => api('fw/suites'), []);
  if (list.loading) return html`<${Loading} />`;
  if (list.error) return html`<${ErrorBox} error=${list.error} />`;
  const suites = list.data.suites;
  return html`<div>
    <${PageHead} kicker="IV · Suites" title="Task suites" sub="A suite is a set of tasks with oracles. Tags group tasks so a run can be sliced by the kind of work." />
    <div class="split" style="grid-template-columns:260px minmax(0,1fr)">
      <aside class="facets">${suites.map((x) => html`<a key=${x.suite} href=${href(['suites', x.suite])} style=${{ display: 'block', padding: '8px 10px', textDecoration: 'none', borderLeft: '3px solid ' + (name === x.suite ? 'var(--ink)' : 'transparent'), background: name === x.suite ? 'var(--mark)' : '', borderBottom: '1px solid var(--rule)' }}>
        <div style="font-weight:500">${x.suite} ${!x.valid && html`<span style="color:var(--crit-ink)">✕</span>`}</div>
        <div class="faint" style="font-size:12px">${x.tasks} tasks · ${(x.languages || []).join(', ')} · ${x.defaultRepetitions}× default</div></a>`)}</aside>
      <div>${name ? html`<${SuiteDetail} key=${name} name=${name} meta=${suites.find((x) => x.suite === name)} />` : html`<${Empty}>Choose a suite.</${Empty}>`}</div>
    </div>
  </div>`;
}

function SuiteDetail({ name, meta }) {
  const d = useAsync(() => api('fw/suite', { query: { name } }), [name]);
  const [tag, setTag] = useState(null);
  const [q, setQ] = useState('');
  const runs = (useStore().runs?.runs || []).filter((r) => r.suite === name);
  if (d.loading) return html`<${Loading} />`;
  if (d.error) return html`<${ErrorBox} error=${d.error} />`;
  const suite = d.data;
  const tags = useMemo(() => { const m = new Map(); suite.tasks.forEach((t) => (t.tags || []).forEach((g) => m.set(g, (m.get(g) || 0) + 1))); return [...m].sort((a, b) => a[0].localeCompare(b[0])); }, [suite]);
  const groups = groupBy(tags, ([g]) => (g.includes(':') ? g.split(':')[0] : 'kind'));
  const tasks = suite.tasks.filter((t) => (!tag || t.tags?.includes(tag)) && (!q || JSON.stringify(t).toLowerCase().includes(q.toLowerCase())));
  return html`<div>
    <h2 style="font-size:28px">${suite.name}</h2>
    <div class="faint mono" style="font-size:11.5px">hash ${suite.hash?.slice(0, 16)} · ${suite.tasks.length} tasks${suite.split ? ` shown (${suite.split.holdout} held out from tuning)` : ''}</div>
    <div class="kpis" style="margin:14px 0"><div class="kpi"><div class="l">Tasks</div><div class="v">${suite.tasks.length}</div></div><div class="kpi"><div class="l">Repetitions</div><div class="v">${suite.defaultRepetitions ?? '—'}</div></div><div class="kpi"><div class="l">Languages</div><div class="v" style="font-size:22px">${(suite.languages || []).join(' · ') || '—'}</div></div><div class="kpi"><div class="l">Runs of it</div><div class="v">${runs.length}</div><div class="d">in the opened folder</div></div></div>
    <${Section} title="Tags" hint="click to filter the tasks">
      ${[...groups].map(([g, ts]) => html`<div key=${g} style="display:grid;grid-template-columns:90px 1fr;gap:10px;margin-bottom:6px;align-items:baseline"><span class="faint" style="font:600 10px var(--sans);letter-spacing:.12em;text-transform:uppercase">${g}</span><div class="chips">${ts.map(([t, n]) => html`<${Chip} key=${t} tag on=${tag === t} onClick=${() => setTag(tag === t ? null : t)}>${t.includes(':') ? t.split(':')[1] : t} <span class="faint">${n}</span></${Chip}>`)}</div></div>`)}
    </${Section}>
    <${Section} title="Tasks" hint=${tasks.length + ' shown'} actions=${html`<input type="search" placeholder="filter…" value=${q} onInput=${(e) => setQ(e.target.value)} style="width:200px" />`}>
      ${tasks.map((t) => html`<article key=${t.id} style="border-top:1px solid var(--rule-2);padding:12px 0">
        <div style="display:flex;gap:10px;align-items:baseline;flex-wrap:wrap"><h2 style="font-size:17px;margin:0">${t.title}</h2><span class="mono faint" style="font-size:11.5px">${t.id}</span></div>
        <p style="margin:5px 0 7px;font:italic 400 15.5px/1.5 var(--serif);max-width:82ch">“${t.instruction}”</p>
        <div class="chips">${(t.tags || []).map((g) => html`<${Chip} key=${g} tag>${g}</${Chip}>`)}${t.optimalSteps != null && html`<${Chip}>optimal ${t.optimalSteps}</${Chip}>`}<${Chip}>≤${t.budget?.maxSteps} steps</${Chip}><${Chip}>≤${fmtTok(t.budget?.maxTokens)} tokens</${Chip}><${Chip}>≤${fmtMs((t.budget?.maxWallClockSeconds || 0) * 1000)}</${Chip}>${(t.criteria || []).map((c) => html`<${Chip} key=${c}>${c}</${Chip}>`)}</div>
      </article>`)}
    </${Section}>
  </div>`;
}
