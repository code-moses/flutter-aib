// Start runs and follow them. A runner is checked first; a priced run needs a spend cap and a yes.
import { html, useState, useEffect, useMemo, useRef, useStore, api, useAsync, go, href, toast, pref, setStore, loadRuns, fmtMs, fmtTok, fmtUsd, fmtInt, fmtNum, fmtDate, ago, cls } from '../lib.js';
import { PageHead, Section, Chip, Loading, ErrorBox, Empty, Modal, Field, Tabs, Seg } from '../ui.js';

const KINDS = ['hybrid', 'intent', 'semantics', 'genui', 'prepared'];

export function LaunchView({ query }) {
  const s = useStore();
  if (!s.info?.framework) return html`<div><${PageHead} kicker="V · Launch" title="Runs" /><${Empty}>Starting runs needs the framework: start the UI with <code>--root</code> pointing at a checkout that has an <code>aib_mcp.yaml</code>.</${Empty}></div>`;
  const [tab, setTab] = useState(query.tab || 'new');
  const [sel, setSel] = useState(query.job || null);
  useEffect(() => { if (query.tab) setTab(query.tab); if (query.job) setSel(query.job); }, [query.tab, query.job]);
  return html`<div>
    <${PageHead} kicker="V · Launch" title="Runs" sub="Jobs run on this machine through the configured runners. Runs on the same model host queue behind each other so latencies stay comparable.">
      <span class="faint mono" style="font-size:12px">spent today ${fmtUsd(s.spent ?? 0)} of ${fmtUsd(s.info.budget?.maxUsdPerDay)}</span>
    </${PageHead}>
    <${Tabs} tabs=${[{ id: 'new', label: 'New run' }, { id: 'jobs', label: 'Jobs', count: s.jobs.length || null }, { id: 'doctor', label: 'Preflight' }]} value=${tab} onChange=${setTab} />
    <div style="margin-top:20px">
      <!-- The form stays mounted while another tab shows: switching tabs must not cost what was typed. -->
      <div style=${{ display: tab === 'new' ? '' : 'none' }}><${NewRun} query=${query} onStarted=${(j) => { setSel(j.job); setTab('jobs'); }} /></div>
      ${tab === 'jobs' && html`<${Jobs} sel=${sel} onSel=${setSel} />`}
      ${tab === 'doctor' && html`<${Doctor} />`}
    </div>
  </div>`;
}

const FORM_DEFAULTS = { config: '', agent: 'hybrid', suite: '', reps: '', seed: '', out: '', study: '', tasks: [], otel: 'off', otelUrl: '', otelContent: false };

function NewRun({ query, onStarted }) {
  const s = useStore();
  const runners = Object.entries(s.info.runners);
  const configs = useAsync(() => api('fw/configs'), []);
  const suites = useAsync(() => api('fw/suites'), []);
  // What was typed is kept across tabs and reloads; a link with ?config= wins for that field.
  const [f, setF] = useState(() => ({
    ...FORM_DEFAULTS,
    runner: runners.find(([, r]) => r.suite)?.[0] || runners[0]?.[0] || '',
    ...pref.get('launch.form', {}),
    ...(query.config ? { config: query.config } : {}),
    ...(query.agent ? { agent: query.agent } : {}),
  }));
  const set = (patch) => setF((o) => { const n = { ...o, ...patch }; pref.set('launch.form', n); return n; });
  const recipe = s.info.runners[f.runner] || Object.values(s.info.runners)[0];
  const suiteName = recipe?.suite || f.suite || (recipe?.kind === 'inProcess' ? 'mock_v1' : suites.data?.suites?.find((x) => x.valid)?.suite);
  const suiteInfo = useAsync(() => (suiteName ? api('fw/suite', { query: { name: suiteName } }) : null), [suiteName]);
  const check = useAsync(() => (f.runner ? api('fw/runner/check', { query: { runner: f.runner } }) : null), [f.runner]);
  const [est, setEst] = useState(null);
  const [confirm, setConfirm] = useState(null);
  const [err, setErr] = useState(null);
  useEffect(() => { setEst(null); setErr(null); }, [f.runner, f.config, f.agent, f.suite, f.reps, f.tasks.join()]);
  const body = (extra = {}) => ({
    runner: f.runner, config: f.config, agent: f.agent, suite: recipe?.suite ? undefined : suiteName, reps: f.reps ? +f.reps : undefined, seed: f.seed ? +f.seed : undefined,
    tasks: f.tasks, out: f.out || undefined, study: f.study || undefined,
    otel: f.otel === 'ui' ? true : f.otel === 'url' && f.otelUrl.trim() ? f.otelUrl.trim() : undefined, otelCaptureContent: f.otel !== 'off' && f.otelContent, ...extra,
  });
  const estimate = async () => {
    setEst({ loading: true }); setErr(null);
    try { const e = await api('fw/estimate', { method: 'POST', body: body() }); setEst(e); return e; }
    catch (e) { setEst(null); setErr(e.message); return null; }
  };
  const budget = s.info.budget || {};
  // Starting asks for the estimate itself: whether the run is priced decides what the dialog must ask.
  const openConfirm = async () => {
    const e = est && !est.loading ? est : await estimate();
    if (!e) return;
    const high = e.costUsd?.high;
    const suggestion = high ? Math.min(budget.maxUsdPerJob ?? 10, Math.max(0.5, Math.ceil(high * 1.5 * 100) / 100)) : Math.min(budget.maxUsdPerJob ?? 10, 2);
    setConfirm({ cap: String(suggestion), est: e });
  };
  const start = async () => {
    try {
      const paid = confirm.est.paidModels?.length > 0;
      const job = await api('fw/run', { method: 'POST', body: body({ approved: true, maxUsd: paid ? +confirm.cap : undefined }) });
      toast('job ' + job.job + ' ' + job.state); setConfirm(null); onStarted(job);
    } catch (e) { setErr(e.message); setConfirm(null); }
  };
  const cfgList = configs.data?.configs || [];
  const toggleTask = (id) => set({ tasks: f.tasks.includes(id) ? f.tasks.filter((x) => x !== id) : [...f.tasks, id] });
  const blocked = check.data && check.data.ok === false;
  const cEst = confirm?.est;
  const cPaid = cEst?.paidModels?.length > 0;
  const capNum = +confirm?.cap;
  const capOk = !cPaid || (capNum > 0 && capNum <= (budget.maxUsdPerJob ?? Infinity));
  return html`<div class="split" style="grid-template-columns:minmax(0,520px) minmax(0,1fr);gap:40px">
    <div style="display:grid;gap:14px">
      <${Field} label="Runner" hint=${recipe?.kind === 'inProcess' ? 'in process, no app needed' : 'runs the app test as a subprocess'}><select value=${f.runner} onChange=${(e) => set({ runner: e.target.value })}>${runners.map(([k, r]) => html`<option key=${k} value=${k}>${k}${r.suite ? ' — ' + r.suite : ''}</option>`)}</select></${Field}>
      ${blocked && html`<div class="err"><b>This runner cannot start.</b><div style="margin-top:4px;white-space:pre-wrap">${check.data.message}</div><div style="margin-top:8px"><button class="btn sm" onClick=${check.reload}>Check again</button></div></div>`}
      <${Field} label="Agent config (arm)"><select value=${f.config} onChange=${(e) => set({ config: e.target.value })}><option value="">— choose —</option>${cfgList.filter((c) => !c.error).map((c) => html`<option key=${c.name} value=${c.name}>${c.name}${c.model ? ' · ' + c.model : ''}</option>`)}</select></${Field}>
      <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px">
        <${Field} label="Build as"><select value=${f.agent} onChange=${(e) => set({ agent: e.target.value })}>${KINDS.map((k) => html`<option key=${k}>${k}</option>`)}</select></${Field}>
        <${Field} label="Repetitions"><input type="number" min="1" value=${f.reps} onInput=${(e) => set({ reps: e.target.value })} placeholder="suite default" /></${Field}>
        <${Field} label="Seed"><input type="number" value=${f.seed} onInput=${(e) => set({ seed: e.target.value })} placeholder="default" /></${Field}>
      </div>
      ${!recipe?.suite && html`<${Field} label="Suite"><select value=${suiteName || ''} onChange=${(e) => set({ suite: e.target.value, tasks: [] })}>${(suites.data?.suites || []).filter((x) => x.valid).map((x) => html`<option key=${x.suite}>${x.suite}</option>`)}</select></${Field}>`}
      <${Field} group label=${`Tasks ${f.tasks.length ? `(${f.tasks.length} chosen)` : '(all)'}`} hint="Leave empty to run the whole suite. The holdout is never offered.">
        ${suiteInfo.loading ? html`<${Loading} />` : suiteInfo.data ? html`<div style="max-height:200px;overflow:auto;border:1px solid var(--rule-2);background:var(--panel)">${suiteInfo.data.tasks.map((t) => html`<label key=${t.id} style="display:grid;grid-template-columns:18px 1fr;padding:3px 8px;border-bottom:1px solid var(--rule);cursor:pointer;font-size:12.5px"><input type="checkbox" checked=${f.tasks.includes(t.id)} onChange=${() => toggleTask(t.id)} /><span>${t.title} <span class="faint mono" style="font-size:11px">${t.id}</span></span></label>`)}</div>` : ''}
      </${Field}>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;align-items:start">
        <${Field} label="Output folder" hint="under results/. An existing one is resumed."><input type="text" value=${f.out} onInput=${(e) => set({ out: e.target.value })} placeholder="auto-named" class="mono" /></${Field}>
        <${Field} label="Study tag"><input type="text" value=${f.study} onInput=${(e) => set({ study: e.target.value })} placeholder="optional" /></${Field}>
      </div>
      <${Field} group label="OpenTelemetry export" hint=${f.otel === 'ui' ? "Spans arrive on this UI's /v1/traces — see Telemetry. Exporting adds a little overhead to timing metrics; keep it off for runs you compare on latency." : f.otel === 'url' ? 'Any OTLP/HTTP traces endpoint, e.g. a collector or Jaeger.' : 'Nothing is exported.'}>
        <div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap"><${Seg} options=${[{ id: 'off', label: 'off' }, { id: 'ui', label: 'to this UI' }, { id: 'url', label: 'to an endpoint' }]} value=${f.otel} onChange=${(v) => set({ otel: v })} />
          ${f.otel === 'url' && html`<input type="text" class="mono" placeholder="http://localhost:4318/v1/traces" value=${f.otelUrl} onInput=${(e) => set({ otelUrl: e.target.value })} style="flex:1;min-width:220px" />`}
          ${f.otel !== 'off' && html`<label style="display:flex;gap:6px;align-items:center;font-size:12.5px"><input type="checkbox" checked=${f.otelContent} onChange=${(e) => set({ otelContent: e.target.checked })} /> include payloads</label>`}</div>
      </${Field}>
      <div style="display:flex;gap:10px;align-items:center"><button class="btn" disabled=${!f.config || est?.loading} onClick=${estimate}>${est?.loading ? 'estimating…' : 'Estimate'}</button><button class="btn solid" disabled=${!f.config || blocked || est?.loading} onClick=${openConfirm} title=${blocked ? 'the runner cannot start — see above' : ''}>Start the run…</button>
        <button class="btn ghost sm" style="margin-left:auto" onClick=${() => { setF({ ...FORM_DEFAULTS, runner: f.runner }); pref.set('launch.form', null); }}>Reset the form</button></div>
      ${err && html`<${ErrorBox} error=${err} />`}
    </div>
    <div>
      <h3>Estimate</h3>
      ${!est ? html`<div class="faint">Press <b>Estimate</b> to see episodes, hosts, and — from earlier runs of this arm or its base — tokens, cost and time. Starting a run estimates it first.</div>` : est.loading ? html`<${Loading} />` : html`<div>
        <div class="kpis"><div class="kpi"><div class="l">Episodes</div><div class="v">${est.episodes}</div></div>
          <div class="kpi"><div class="l">Wall clock</div><div class="v">${est.wallClockMinutes != null ? fmtMs(est.wallClockMinutes * 60000) : '—'}</div></div>
          <div class="kpi"><div class="l">Tokens</div><div class="v">${est.perEpisode?.tokens ? fmtTok(est.perEpisode.tokens * est.episodes) : '—'}</div></div>
          <div class="kpi"><div class="l">Cost</div><div class="v">${est.costUsd ? fmtUsd(est.costUsd.expected) : est.paidModels?.length ? '?' : '$0'}</div><div class="d">${est.costUsd ? `up to ${fmtUsd(est.costUsd.high)}` : ''}</div></div></div>
        <dl class="kv" style="margin-top:12px"><dt>suite</dt><dd>${est.suite}</dd><dt>model hosts</dt><dd>${(est.hosts || []).join(', ') || '— (none, runs at once)'}</dd><dt>priced models</dt><dd>${(est.paidModels || []).join(', ') || 'none'}</dd><dt>estimated from</dt><dd>${est.basis?.runs?.length ? `${est.basis.runs.length} earlier run(s) of ${est.basis.arm} — ${est.basis.episodes} episodes` : 'no earlier run of this arm or its base'}</dd></dl>
      </div>`}
    </div>
    ${confirm && html`<${Modal} title="Start this run?" onClose=${() => setConfirm(null)} footer=${html`<button class="btn ghost" onClick=${() => setConfirm(null)}>Cancel</button><button class="btn solid" disabled=${!capOk} onClick=${start}>${cPaid ? `Approve up to ${fmtUsd(capNum || 0)} and start` : 'Start'}</button>`}>
      <dl class="kv"><dt>arm</dt><dd>${f.config} (as ${f.agent})</dd><dt>runner</dt><dd>${f.runner}</dd><dt>suite</dt><dd>${suiteName}</dd><dt>tasks</dt><dd>${f.tasks.length || 'all'} · ${cEst.episodes} episodes</dd><dt>repetitions</dt><dd>${f.reps || 'default'}</dd><dt>output</dt><dd>results/${f.out || '<auto>'}</dd></dl>
      ${cPaid ? html`<div class="note" style="border-left-color:var(--warn)">This arm uses priced models (${cEst.paidModels.join(', ')}). ${cEst.costUsd ? `Estimate ${fmtUsd(cEst.costUsd.low)}–${fmtUsd(cEst.costUsd.high)}.` : 'No estimate: no earlier run of this arm.'} The job stops itself when it has spent the cap below.</div>
        <${Field} label="Spend cap (USD) — required" hint=${`The job is stopped at this amount. At most ${fmtUsd(budget.maxUsdPerJob)} per job and ${fmtUsd(budget.maxUsdPerDay)} per day (${fmtUsd(s.spent ?? 0)} spent today).${cEst.costUsd ? '' : ' Pre-filled with a cautious default, since there is no estimate.'}`}>
          <input type="number" min="0.01" step="0.1" value=${confirm.cap} onInput=${(e) => setConfirm({ ...confirm, cap: e.target.value })} style=${{ borderColor: capOk ? '' : 'var(--crit)', maxWidth: '180px' }} autofocus /></${Field}>
        ${!capOk && html`<div class="err">Enter a cap above $0${budget.maxUsdPerJob ? ` and up to ${fmtUsd(budget.maxUsdPerJob)}` : ''}.</div>`}` : html`<div class="note">Local models only — no spend.</div>`}
    </${Modal}>`}
  </div>`;
}

function Jobs({ sel, onSel }) {
  const s = useStore();
  const jobs = s.jobs;
  const job = jobs.find((j) => j.job === sel) || jobs[0];
  if (!jobs.length) return html`<${Empty}>No job yet in this server session.</${Empty}>`;
  return html`<div class="split" style="grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:32px">
    <table class="t compact"><thead><tr><th>Job</th><th>State</th><th style="width:120px">Progress</th><th class="r">Spend</th></tr></thead><tbody>
      ${jobs.map((j) => html`<tr key=${j.job} class=${cls('row-link', job?.job === j.job && 'sel')} onClick=${() => onSel(j.job)}>
        <td><div class="nm">${j.label}</div><div class="sub mono">${j.job} · ${j.kind} · ${ago(j.createdAt)}</div></td>
        <td><span class=${'state ' + j.state}>${j.state}</span></td>
        <td><${Progress} j=${j} /></td><td class="n">${j.spendUsd ? fmtUsd(j.spendUsd) : '—'}</td></tr>`)}
    </tbody></table>
    ${job && html`<${JobDetail} key=${job.job} job=${job} />`}
  </div>`;
}

/** Runs report episodes done; a judging job reports nothing until it ends, so it shows elapsed time instead of a made-up bar. */
export function Progress({ j }) {
  const active = j.state === 'running' || j.state === 'queued';
  if (j.kind === 'evaluate') {
    return html`<div><div class=${cls('prog', j.state === 'running' && 'run')}><i style=${{ width: j.state === 'running' || j.state === 'succeeded' ? '100%' : '0%' }}></i></div><div class="faint mono" style="font-size:11px">${j.state === 'queued' ? 'waiting for the host' : j.state === 'running' ? html`<${Elapsed} since=${j.startedAt} />` : j.state}</div></div>`;
  }
  const pct = j.episodes.total ? j.episodes.done / j.episodes.total : 0;
  return html`<div><div class=${cls('prog', j.state === 'running' && 'run')}><i style=${{ width: (j.state === 'succeeded' ? 100 : pct * 100) + '%' }}></i></div><div class="faint mono" style="font-size:11px">${j.episodes.done}/${j.episodes.total}</div></div>`;
}
export function Elapsed({ since }) {
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((n) => n + 1), 1000); return () => clearInterval(t); }, []);
  return since ? `${fmtMs(Date.now() - new Date(since))} elapsed` : '';
}

function JobDetail({ job }) {
  const [lines, setLines] = useState([]);
  const box = useRef(null);
  const active = job.state === 'running' || job.state === 'queued';
  useEffect(() => {
    let live = true, t;
    const tick = async () => { try { const r = await api('fw/job/log', { query: { id: job.job, tail: 300 } }); if (live) setLines(r.lines); } catch { /* holdout jobs hide their log */ } if (live && active) t = setTimeout(tick, 1500); };
    tick(); return () => { live = false; clearTimeout(t); };
  }, [job.job, active]);
  useEffect(() => { if (box.current) box.current.scrollTop = box.current.scrollHeight; }, [lines]);
  const cancel = async () => { try { await api('fw/job/cancel', { method: 'POST', body: { id: job.job } }); toast('stopping…'); } catch (e) { toast(e.message); } };
  const rel = job.runDir;
  const st = useStore();
  const lib = (st.library || st.info.defaultLibrary || '').replace(/\/$/, '');
  const abs = rel && (rel.startsWith('/') ? rel : st.info.root + '/' + rel);
  const inLib = abs && abs.startsWith(lib + '/') ? abs.slice(lib.length + 1) : null;
  return html`<div>
    <div style="display:flex;justify-content:space-between;align-items:baseline"><h2 style="margin:0">${job.label}</h2><span class=${'state ' + job.state}>${job.state}</span></div>
    <div class="faint mono" style="font-size:11.5px;margin:2px 0 10px">${job.job} · ${job.kind}${job.study ? ' · study ' + job.study : ''}</div>
    <${Progress} j=${job} />
    ${job.kind === 'evaluate' && active && html`<div class="note" style="margin-top:10px">Judging scores every rubric criterion with the judge model and writes the verdicts when it is done. The framework reports no progress in between, so this shows elapsed time rather than a bar. Judging ${job.episodes.total} episodes takes a while on a local model; you can leave this page.</div>`}
    <dl class="kv" style="margin:12px 0"><dt>started</dt><dd>${job.startedAt ? fmtDate(job.startedAt) : 'queued'}</dd>${job.endedAt && html`<dt>ended</dt><dd>${fmtDate(job.endedAt)}${job.startedAt ? ` (${fmtMs(new Date(job.endedAt) - new Date(job.startedAt))})` : ''}</dd>`}<dt>hosts</dt><dd>${job.hosts.join(', ') || '—'}</dd><dt>spend</dt><dd>${fmtUsd(job.spendUsd)}${job.maxUsd ? ' of ' + fmtUsd(job.maxUsd) : ''}</dd>${job.runDir && html`<dt>run directory</dt><dd>${job.runDir}</dd>`}${job.stopReason && html`<dt>stopped</dt><dd>${job.stopReason}</dd>`}</dl>
    ${job.error && html`<${ErrorBox} error=${job.error} />`}
    <div style="display:flex;gap:8px;margin-bottom:10px">
      ${active && html`<button class="btn danger" onClick=${cancel}>Stop the job</button>`}
      ${inLib && html`<button class="btn solid" onClick=${async () => { await loadRuns({ quiet: true }); go(['run', inLib]); }}>Open the run →</button>`}
    </div>
    ${job.result && html`<details><summary class="muted" style="cursor:pointer">result</summary><pre class="code wrap">${JSON.stringify(job.result, null, 2)}</pre></details>`}
    <h3 style="margin-top:12px">Log</h3>
    <div class="log" ref=${box}>${lines.length ? lines.join('\n') : '(no output yet)'}</div>
  </div>`;
}

function Doctor() {
  const suites = useAsync(() => api('fw/suites'), []);
  const configs = useAsync(() => api('fw/configs'), []);
  const [suite, setSuite] = useState('');
  const [cfgs, setCfgs] = useState([]);
  const [out, setOut] = useState(null);
  const run = async () => { setOut({ loading: true }); try { setOut(await api('fw/doctor', { query: { suite, configs: cfgs.join(',') } })); } catch (e) { setOut({ error: e.message }); } };
  return html`<div style="max-width:760px;display:grid;gap:14px">
    <div class="note">Checks that the suite loads, the model host is up with the pinned models, and API keys are present (reported as present or not, never their value).</div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">
      <${Field} label="Suite"><select value=${suite} onChange=${(e) => setSuite(e.target.value)}><option value="">— none —</option>${(suites.data?.suites || []).filter((s) => s.valid).map((s) => html`<option key=${s.suite}>${s.suite}</option>`)}</select></${Field}>
      <${Field} label="Configs to check" hint="ctrl/cmd-click for several"><select multiple size="4" value=${cfgs} onChange=${(e) => setCfgs([...e.target.selectedOptions].map((o) => o.value))}>${(configs.data?.configs || []).map((c) => html`<option key=${c.name}>${c.name}</option>`)}</select></${Field}>
    </div>
    <div><button class="btn solid" onClick=${run}>Run preflight</button></div>
    ${out?.loading && html`<${Loading} />`}${out?.error && html`<${ErrorBox} error=${out.error} />`}
    ${out && !out.loading && !out.error && html`<pre class="code wrap">${JSON.stringify(out, null, 2)}</pre>`}
  </div>`;
}
