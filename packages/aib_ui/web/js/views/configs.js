// Agent configs ("arms"): read them, check that they build, diff two, derive a new one, see which runs used them.
import { html, useState, useMemo, useEffect, useStore, api, useAsync, go, href, toast, pref, fmtPct, fmtTok, fmtNum, runLabel, cls, debounce, groupBy, setStore } from '../lib.js';
import { PageHead, Section, Chip, Loading, ErrorBox, Empty, Seg, YamlView, JsonView, Modal, Field, Copy, Tabs } from '../ui.js';
import { trunc } from '../charts.js';

const KINDS = ['hybrid', 'intent', 'semantics', 'genui', 'prepared'];

export function ConfigsView({ name, query }) {
  const s = useStore();
  if (!s.info?.framework) return html`<div><${PageHead} kicker="III · Configurations" title="Agent configs" /><${Empty}>Start the UI with <code>--root</code> pointing at a checkout that has an <code>aib_mcp.yaml</code> to read and derive agent configs.</${Empty}></div>`;
  const [rev, setRev] = useState(0);
  const list = useAsync(() => api('fw/configs'), [rev]);
  const [q, setQ] = useState('');
  const [derive, setDerive] = useState(null);
  if (list.loading) return html`<${Loading} />`;
  if (list.error) return html`<${ErrorBox} error=${list.error} />`;
  const configs = list.data.configs.filter((c) => !q || JSON.stringify(c).toLowerCase().includes(q.toLowerCase()));
  const pinned = configs.filter((c) => !c.name.startsWith('experiments/')), exp = configs.filter((c) => c.name.startsWith('experiments/'));
  const item = (c) => html`<a key=${c.name} href=${href(['configs', ...c.name.split('/')])} class=${cls('cfg', name === c.name && 'on')} style=${{ display: 'block', padding: '5px 10px', textDecoration: 'none', borderLeft: '3px solid ' + (name === c.name ? 'var(--ink)' : 'transparent'), background: name === c.name ? 'var(--mark)' : '' }}>
    <div class="mono" style="font-size:12.5px">${c.name.replace('experiments/', '')}</div><div class="faint" style="font-size:11.5px">${c.model || (c.error ? 'unreadable' : c.blocks?.join(' · '))}</div></a>`;
  return html`<div>
    <${PageHead} kicker="III · Configurations" title="Agent configs" sub="Pinned arms and the experiments derived from them. A config is a YAML file; a run records its hash.">
      <button class="btn solid" onClick=${() => setDerive({ base: name || 'hybrid_union' })}>New arm…</button>
    </${PageHead}>
    <div class="split" style="grid-template-columns:260px minmax(0,1fr)">
      <aside class="facets"><input type="search" placeholder="Search configs…" value=${q} onInput=${(e) => setQ(e.target.value)} />
        <h3 style="margin:14px 0 4px">Pinned <span class="faint">${pinned.length}</span></h3>${pinned.map(item)}
        <h3 style="margin:14px 0 4px">Experiments <span class="faint">${exp.length}</span></h3>${exp.map(item)}</aside>
      <div>${name ? html`<${ConfigDetail} key=${name} name=${name} onDerive=${(base) => setDerive({ base })} />` : html`<${Empty}>Choose a config on the left.</${Empty}>`}</div>
    </div>
    ${derive && html`<${DeriveModal} base=${derive.base} configs=${list.data.configs} onClose=${() => setDerive(null)} onDone=${(n) => { setDerive(null); setRev((r) => r + 1); go(['configs', ...n.split('/')]); }} />`}
  </div>`;
}

function ConfigDetail({ name, onDerive }) {
  const s = useStore();
  const cfg = useAsync(() => api('fw/config', { query: { name } }), [name]);
  const [kind, setKind] = useState(pref.get('cfg.kind', 'hybrid'));
  const [check, setCheck] = useState(null);
  const [other, setOther] = useState('');
  const [diff, setDiff] = useState(null);
  const [tab, setTab] = useState('yaml');
  const configs = useAsync(() => api('fw/configs'), []);
  useEffect(() => { setCheck(null); setDiff(null); }, [name]);
  const used = (s.runs?.runs || []).filter((r) => r.launch?.config === name || r.facets.config?.includes(name));
  useEffect(() => { if (used[0]?.agents[0]?.id && KINDS.includes(used[0].agents[0].id)) setKind(used[0].agents[0].id); }, [name]);
  if (cfg.loading) return html`<${Loading} />`;
  if (cfg.error) return html`<${ErrorBox} error=${cfg.error} />`;
  const c = cfg.data;
  const header = (c.yaml.match(/^(?:#.*\n?|\s*\n)+/) || [''])[0].split('\n').map((l) => l.replace(/^#\s?/, '')).join('\n').trim();
  const body = c.yaml.slice((c.yaml.match(/^(?:#.*\n?|\s*\n)+/) || [''])[0].length);
  const validate = async () => { setCheck({ loading: true }); try { setCheck(await api('fw/config/validate', { method: 'POST', body: { agent: kind, name } })); } catch (e) { setCheck({ error: e.message }); } };
  const runDiff = async (b) => { setOther(b); if (!b) return setDiff(null); setDiff({ loading: true }); try { setDiff(await api('fw/config/diff', { method: 'POST', body: { a: name, b, agent: kind } })); } catch (e) { setDiff({ error: e.message }); } };
  return html`<div>
    <h2 style="font-size:26px;margin-bottom:2px" class="mono">${name}</h2>
    <div class="faint mono" style="font-size:11.5px">${c.path} · hash ${c.hash}</div>
    ${header && html`<div style="margin:14px 0;padding:10px 16px;border-left:3px solid var(--mark);font:italic 400 16px/1.5 var(--serif);white-space:pre-wrap;max-width:80ch;background:var(--panel)">${header}</div>`}
    <div style="display:flex;gap:10px;align-items:end;flex-wrap:wrap;margin:14px 0">
      <label class="field" style="width:150px"><span>Build as</span><select value=${kind} onChange=${(e) => { setKind(e.target.value); pref.set('cfg.kind', e.target.value); setCheck(null); }}>${KINDS.map((k) => html`<option key=${k}>${k}</option>`)}</select></label>
      <button class="btn" onClick=${validate}>Check it builds</button>
      <button class="btn" onClick=${() => onDerive(name)}>Derive from this…</button>
      <button class="btn" onClick=${() => go(['launch'], { config: name, agent: kind })}>Run it →</button>
      <label class="field" style="width:240px;margin-left:auto"><span>Diff against</span><select value=${other} onChange=${(e) => runDiff(e.target.value)}><option value="">— pick a config —</option>${(configs.data?.configs || []).filter((x) => x.name !== name).map((x) => html`<option key=${x.name}>${x.name}</option>`)}</select></label>
    </div>
    ${check && (check.loading ? html`<${Loading} />` : check.error ? html`<${ErrorBox} error=${check.error} />` : html`<div class=${check.built ? 'note' : 'err'} style=${check.built ? { borderLeftColor: 'var(--good)' } : {}}>${check.built ? html`✓ builds as <b>${check.agent}</b> · model ${check.model || '—'} · config hash <span class="mono">${check.agentConfigHash}</span>${check.promptHash ? html` · prompt <span class="mono">${check.promptHash}</span>` : ''}` : check.error}</div>`)}
    ${diff && (diff.loading ? html`<${Loading} />` : diff.error ? html`<${ErrorBox} error=${diff.error} />` : html`<div style="margin:10px 0"><h3>${name} → ${diff.b}</h3>
      ${diff.changes.length ? html`<table class="t compact"><tbody>${diff.changes.map((ch) => html`<tr key=${ch.path} class="diffrow"><td class="mono">${ch.path}</td><td class="mono" style="color:var(--ink-3);text-decoration:line-through">${JSON.stringify(ch.before)}</td><td class="mono"><b>${JSON.stringify(ch.after)}</b></td></tr>`)}</tbody></table>` : html`<div class="faint">identical configuration</div>`}
      ${diff.vary && html`<div class="faint" style="font-size:12px;margin-top:6px">to compare runs of these two, name in <code>vary</code>: ${diff.vary.length ? diff.vary.join(', ') : 'nothing'}</div>`}</div>`)}
    <${Tabs} tabs=${[{ id: 'yaml', label: 'YAML' }, { id: 'parsed', label: 'Parsed' }, { id: 'runs', label: 'Runs', count: used.length }]} value=${tab} onChange=${setTab} />
    <div style="margin-top:16px">
      ${tab === 'yaml' && html`<div><div style="display:flex;justify-content:flex-end;margin-bottom:6px"><${Copy} text=${c.yaml} /></div><${YamlView} text=${body} /></div>`}
      ${tab === 'parsed' && html`<div><h3>Blocks</h3><div class="chips" style="margin-bottom:12px">${Object.entries(c.blocks).map(([k, h]) => html`<${Chip} key=${k} tag title="block hash">${k} · ${h}</${Chip}>`)}</div><${JsonView} value=${c.config} open=${2} /></div>`}
      ${tab === 'runs' && (used.length ? html`<table class="t compact"><tbody>${used.map((r) => html`<tr key=${r.id} class="row-link" onClick=${() => go(['run', r.id])}><td class="nm">${r.name}</td><td>${r.suite}</td><td class="n">${r.stats?.episodes ?? r.traces}</td><td class="n">${r.stats?.success != null ? fmtPct(r.stats.success) : '—'}</td><td class="n">${fmtTok(r.stats?.tokens)}</td><td class="n faint">${(r.createdAt || '').slice(0, 10)}</td></tr>`)}</tbody></table>
        <div class="dock" style="position:static"><span>${used.length} runs used this arm</span><button class="btn solid" style="margin-left:auto" disabled=${used.length < 1} onClick=${() => go(['compare'], { runs: used.slice(0, 6).map((r) => r.id).join('|') })}>Compare them →</button></div>` : html`<${Empty}>No run in the opened folder was launched with this config.</${Empty}>`)}
    </div>
  </div>`;
}

function DeriveModal({ base, configs, onClose, onDone }) {
  const s = useStore();
  const [b, setB] = useState(base);
  const src = useAsync(() => api('fw/config', { query: { name: b } }), [b]);
  const [yaml, setYaml] = useState('');
  const [kind, setKind] = useState(pref.get('cfg.kind', 'hybrid'));
  const [nm, setNm] = useState('');
  const [hyp, setHyp] = useState('');
  const [prev, setPrev] = useState(null);
  const [many, setMany] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  useEffect(() => { if (src.data) { setYaml(src.data.yaml); setPrev(null); } }, [src.data]);
  const preview = useMemo(() => debounce(async (y, k, bb) => { try { setPrev(await api('fw/config/preview', { method: 'POST', body: { base: bb, agent: k, yaml: y } })); } catch (e) { setPrev({ error: e.message }); } }, 450), []);
  useEffect(() => { if (yaml && src.data) preview(yaml, kind, b); }, [yaml, kind, b, src.data]);
  const changes = prev?.changes || [];
  const nameOk = /^[a-z0-9][a-z0-9_.\-]*$/.test(nm);
  const blocked = !prev || prev.error || !prev.check?.built || !changes.length || !nameOk || !hyp.trim() || (!prev.allowed && !many);
  const save = async () => {
    setBusy(true); setErr(null);
    try { const out = await api('fw/config/derive', { method: 'POST', body: { base: b, agent: kind, yaml, name: nm, hypothesis: hyp, allowMany: many } }); toast('wrote ' + out.path); onDone(out.name); }
    catch (e) { setErr(e.message); setBusy(false); }
  };
  return html`<${Modal} title="A new arm" onClose=${onClose} wide footer=${html`<span class="faint" style="margin-right:auto;font-size:12px">writes <code>suites/agents/experiments/${nm || '<name>'}.yaml</code> — arms are never overwritten</span><button class="btn ghost" onClick=${onClose}>Cancel</button><button class="btn solid" disabled=${blocked || busy} onClick=${save}>${busy ? 'writing…' : 'Write the arm'}</button>`}>
    <div style="display:grid;grid-template-columns:1fr 1fr 150px;gap:12px">
      <${Field} label="Start from"><select value=${b} onChange=${(e) => setB(e.target.value)}>${configs.map((c) => html`<option key=${c.name}>${c.name}</option>`)}</select></${Field}>
      <${Field} label="Name" hint="lowercase, digits, _ . -"><input type="text" value=${nm} onInput=${(e) => setNm(e.target.value)} placeholder="tc_my_idea" class="mono" style=${{ borderColor: nm && !nameOk ? 'var(--crit)' : '' }} /></${Field}>
      <${Field} label="Build as"><select value=${kind} onChange=${(e) => setKind(e.target.value)}>${KINDS.map((k) => html`<option key=${k}>${k}</option>`)}</select></${Field}>
    </div>
    <${Field} label="Hypothesis" hint="What should change, and which metric would show it. It becomes the header of the file."><textarea rows="2" value=${hyp} onInput=${(e) => setHyp(e.target.value)} style="font-family:var(--sans)" placeholder="Constrained decoding should cut invalid_tool_call_count without costing tokens."></textarea></${Field}>
    <div style="display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr);gap:16px">
      <${Field} label="Configuration (YAML) — edit it directly">${src.loading ? html`<${Loading} />` : html`<textarea rows="22" value=${yaml} onInput=${(e) => setYaml(e.target.value)} spellcheck="false" style="tab-size:2"></textarea>`}</${Field}>
      <div>
        <h3>What this changes</h3>
        ${!prev ? html`<${Loading} what="checking" />` : prev.error ? html`<${ErrorBox} error=${prev.error} />` : html`<div>
          ${changes.length ? html`<table class="t compact"><tbody>${changes.map((c) => html`<tr key=${c.path}><td class="mono" style="font-size:11.5px">${c.path}</td><td class="mono" style="font-size:11.5px"><span style="color:var(--ink-3);text-decoration:line-through">${c.before === null ? '∅' : JSON.stringify(c.before)}</span> → <b>${c.after === null ? '∅' : JSON.stringify(c.after)}</b></td></tr>`)}</tbody></table>` : html`<div class="faint">no change yet</div>`}
          <div class=${prev.check?.built ? 'note' : 'err'} style=${{ marginTop: '10px', ...(prev.check?.built ? { borderLeftColor: 'var(--good)' } : {}) }}>${prev.check?.built ? `✓ builds as ${kind} · hash ${prev.check.agentConfigHash}` : prev.check?.error}</div>
          ${changes.length > prev.maxChangedPaths && html`<div class="note" style="margin-top:10px;border-left-color:var(--warn)"><b>${changes.length} paths</b> change; the framework's rule is ${prev.maxChangedPaths} per arm, so a comparison stays attributable to one change.
            <label style="display:flex;gap:6px;margin-top:6px;align-items:center"><input type="checkbox" checked=${many} onChange=${(e) => setMany(e.target.checked)} /> I want a multi-change arm anyway</label></div>`}
        </div>`}
        ${err && html`<${ErrorBox} error=${err} />`}
      </div>
    </div>
  </${Modal}>`;
}
