// Judge calibration, labelled by hand: one episode at a time with everything around it —
// the task, what the user said later, what the agent said, the record the judge was given,
// the full trace with the model's thinking and tool calls — and a yes/no per rubric question.
// Answers go straight into the set's labels.csv, which `aib calibrate` reads unchanged.
import { html, useState, useEffect, useMemo, useRef, useStore, api, useAsync, go, href, lib, fmtDate, fmtInt, cls, toast, loadRuns } from '../lib.js';
import { PageHead, Section, Chip, Loading, ErrorBox, Empty, JsonView, Modal, Field, Seg, useKeys, Copy } from '../ui.js';
import { buildTrace, Step, Event } from './trace.js';

const YES = 'yes', NO = 'no', OPEN = '?';
const isAnswered = (v) => v === YES || v === NO;
const judgeSaysYes = (judge, id) => judge && judge.votes && (judge.votes[id] ?? 0) * 2 > (judge.k ?? 1);

export function LabelView({ path, query }) {
  return path ? html`<${LabelSet} path=${path} query=${query} />` : html`<${LabelSets} />`;
}

// ---------------------------------------------------------------------------
// The sets in this folder

function LabelSets() {
  const sets = useAsync(() => api('label/sets', { query: { dir: lib() } }), [lib()]);
  const [creating, setCreating] = useState(false);
  return html`<div>
    <${PageHead} kicker="Judge calibration" title="Label"
      sub="Answer the rubric questions yourself, episode by episode, then compare with the judge (Cohen's κ per criterion).">
      <button class="btn" onClick=${() => setCreating(true)}>New set…</button>
    </${PageHead}>
    ${sets.loading && html`<${Loading} what="looking for calibration sets" />`}
    <${ErrorBox} error=${sets.error} />
    ${sets.data && !sets.data.sets.length && html`<${Empty}>No calibration set in this folder yet. A set is a folder with a <code>sample.json</code>, as <code>aib labelsheet</code> writes it; make one with “New set…”.</${Empty}>`}
    ${sets.data?.sets.length > 0 && html`<table class="t"><thead><tr><th>set</th><th>runs</th><th class="n">episodes</th><th class="n">answered</th><th>judge</th><th>calibrated</th></tr></thead><tbody>
      ${sets.data.sets.map((s) => html`<tr key=${s.path} style="cursor:pointer" onClick=${() => go(['label'], { path: s.path })}>
        <td><a href=${href(['label'], { path: s.path })}>${s.name}</a></td>
        <td class="muted" style="font-size:12px">${(s.runs || []).map((r) => r.split('/').pop()).join(', ')}</td>
        <td class="n">${s.episodes}</td>
        <td class="n">${s.answered} / ${s.answers}</td>
        <td class="mono" style="font-size:12px">${(s.judges || []).join(', ')}</td>
        <td class="muted">${s.calibratedAt ? fmtDate(s.calibratedAt) : '—'}</td></tr>`)}
    </tbody></table>`}
    ${creating && html`<${NewSet} onClose=${() => setCreating(false)} />`}
  </div>`;
}

function NewSet({ onClose }) {
  const s = useStore();
  useEffect(() => { if (!s.runs) loadRuns(); }, []);
  const runs = (s.runs?.runs || []).filter((r) => r.evaluated && r.judge?.id);
  const [picked, setPicked] = useState([]);
  const [size, setSize] = useState(50);
  const [seed, setSeed] = useState(42);
  const [out, setOut] = useState(`judge-calibration-${new Date().toISOString().slice(0, 10)}`);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const judges = new Set(runs.filter((r) => picked.includes(r.dir)).map((r) => r.judge.id));
  const create = async () => {
    setBusy(true); setErr(null);
    try {
      const res = await api('label/create', { method: 'POST', query: { dir: lib() }, body: { runs: picked, out, sample: size, seed } });
      toast(`${res.episodes} of ${res.population} judged episodes sampled · ${res.criteria} questions`);
      (res.warnings || []).forEach((w) => toast(w, 6000));
      go(['label'], { path: res.path });
    } catch (e) { setErr(e.message); } finally { setBusy(false); }
  };
  return html`<${Modal} title="New calibration set" onClose=${onClose} wide
    footer=${html`<button class="btn" disabled=${busy || !picked.length || !out} onClick=${create}>${busy ? 'sampling…' : 'Create set'}</button>`}>
    <p class="muted" style="margin-top:0">A seeded sample of judged episodes, spread over tasks and over what the judge answered (the judge's answers decide the stratum only and stay hidden while you label). Only runs one judge scored can be calibrated together.</p>
    <${Field} label=${`Judged runs in this folder (${runs.length})`} group>
      <div style="max-height:280px;overflow:auto;border:1px solid var(--rule);padding:6px 10px">
        ${!runs.length && html`<div class="faint">No judged run here. Judge a run first (Run → evaluate with judge, or <code>aib evaluate --judge</code>).</div>`}
        ${runs.map((r) => html`<label key=${r.dir} style="display:flex;gap:8px;align-items:baseline;padding:2px 0">
          <input type="checkbox" checked=${picked.includes(r.dir)} onChange=${(e) => setPicked(e.target.checked ? [...picked, r.dir] : picked.filter((d) => d !== r.dir))} />
          <span>${r.name}</span><span class="faint mono" style="font-size:11.5px">${r.suite} · ${r.traces} episodes · ${r.judge.id}</span></label>`)}
      </div></${Field}>
    ${judges.size > 1 && html`<div class="err">These runs were scored by different judges (${[...judges].join(', ')}); calibration will refuse to pool them.</div>`}
    <div class="grid3" style="margin-top:10px">
      <${Field} label="Episodes to sample"><input type="number" min="1" value=${size} onInput=${(e) => setSize(+e.target.value)} /></${Field}>
      <${Field} label="Seed"><input type="number" value=${seed} onInput=${(e) => setSeed(+e.target.value)} /></${Field}>
      <${Field} label="Folder (in this library)"><input value=${out} onInput=${(e) => setOut(e.target.value)} /></${Field}>
    </div>
    <${ErrorBox} error=${err} />
  </${Modal}>`;
}

// ---------------------------------------------------------------------------
// One set

function LabelSet({ path, query }) {
  const set = useAsync(() => api('label/set', { query: { path } }), [path]);
  const [items, setItems] = useState(null);
  const [at, setAt] = useState(0);
  const [focus, setFocus] = useState(0);
  const [filter, setFilter] = useState('all');
  const [revealAll, setRevealAll] = useState(false);
  const [calib, setCalib] = useState(null);
  const [calibrating, setCalibrating] = useState(false);
  useEffect(() => {
    if (!set.data) return;
    setItems(set.data.items);
    const first = set.data.items.findIndex((i) => !doneOf(i));
    setAt(query?.at != null ? +query.at : first < 0 ? 0 : first);
  }, [set.data]);

  const visible = useMemo(() => (items || []).map((it, i) => ({ it, i })).filter(({ it }) => filter === 'all' || (filter === 'open' && !doneOf(it)) || (filter === 'disagree' && disagreements(it) > 0)), [items, filter]);
  const item = items?.[at];
  const questions = item ? item.rubrics.flatMap((r) => r.criteria.map((c) => ({ ...c, rubric: r.name }))) : [];
  useEffect(() => { setFocus(Math.max(0, questions.findIndex((q) => !isAnswered(q.label)))); }, [at, items?.length]);

  const move = (d) => {
    const pos = visible.findIndex((v) => v.i === at);
    const next = visible[pos + d] ?? (pos < 0 ? visible[0] : null);
    if (next) setAt(next.i);
  };
  const answer = async (q, value) => {
    const prev = q.label;
    const update = (v) => setItems((xs) => xs.map((x, i) => (i !== at ? x : { ...x, rubrics: x.rubrics.map((r) => r.name !== q.rubric ? r : { ...r, criteria: r.criteria.map((c) => (c.id === q.id ? { ...c, label: v } : c)) }) })));
    update(value);
    try {
      await api('label/save', { method: 'POST', body: { path, labelId: item.labelId, criterion: q.key, label: value } });
    } catch (e) { update(prev); toast('not saved: ' + e.message); }
  };
  const answerFocused = (value) => {
    const q = questions[focus];
    if (!q) return;
    answer(q, value);
    const nextOpen = questions.findIndex((x, i) => i > focus && !isAnswered(x.label));
    if (nextOpen >= 0) setFocus(nextOpen);
    else if (focus < questions.length - 1) setFocus(focus + 1);
  };
  const saveNote = async (note) => {
    setItems((xs) => xs.map((x, i) => (i === at ? { ...x, note } : x)));
    try { await api('label/save', { method: 'POST', body: { path, labelId: item.labelId, note } }); } catch (e) { toast('note not saved: ' + e.message); }
  };
  const calibrate = async () => {
    setCalibrating(true);
    try { setCalib(await api('label/calibrate', { method: 'POST', body: { path } })); } catch (e) { toast(e.message, 6000); } finally { setCalibrating(false); }
  };

  useKeys({
    y: () => answerFocused(YES), n: () => answerFocused(NO), u: () => answerFocused(OPEN),
    j: () => setFocus((f) => Math.min(questions.length - 1, f + 1)), k: () => setFocus((f) => Math.max(0, f - 1)),
    ']': () => move(1), '[': () => move(-1), ArrowRight: () => move(1), ArrowLeft: () => move(-1),
  }, [at, focus, items, visible]);

  if (set.loading) return html`<${Loading} what="reading the set and its runs" />`;
  if (set.error) return html`<div><${PageHead} kicker="Label" title="Not readable" /><${ErrorBox} error=${set.error} /></div>`;
  if (!items) return null;
  const answered = items.reduce((n, it) => n + countOf(it).done, 0), total = items.reduce((n, it) => n + countOf(it).all, 0);
  const allDone = answered === total && total > 0;

  return html`<div>
    <${PageHead} kicker=${html`<a href=${href(['label'])}>Label</a> · ${set.data.name}`} title="Judge calibration"
      sub=${html`${items.length} episodes · ${answered} / ${total} answered · seed ${set.data.seed} · judge <span class="mono">${(set.data.judges || []).join(', ')}</span>`}>
      <${Seg} options=${[{ id: 'all', label: 'all' }, { id: 'open', label: 'open' }, { id: 'disagree', label: 'disagreements', title: 'needs the judge revealed' }]} value=${filter} onChange=${setFilter} />
      <label style="display:flex;gap:4px;align-items:center;font-size:12px" title="Shows the judge's answers on every episode, answered or not. Labelling with them visible is no longer blind."><input type="checkbox" checked=${revealAll} onChange=${(e) => setRevealAll(e.target.checked)} />show judge everywhere</label>
      <button class="btn" disabled=${!allDone || calibrating} onClick=${calibrate} title=${allDone ? 'aib calibrate over this set' : 'answer every question first'}>${calibrating ? 'calibrating…' : 'Calibrate'}</button>
    </${PageHead}>
    ${(set.data.warnings || []).map((w, i) => html`<div key=${i} class="note" style="margin-bottom:8px">${w}</div>`)}
    <div class="prog" style="margin:-6px 0 16px"><i style=${{ width: (total ? (answered / total) * 100 : 0) + '%', background: 'var(--ink)' }}></i></div>
    ${(calib || set.data.calibration) && html`<${CalibrationPanel} result=${calib} stored=${set.data.calibration} />`}

    <div class="label-grid">
      <aside class="label-list">
        ${visible.map(({ it, i }) => {
          const c = countOf(it), dis = (revealAll || c.done === c.all) ? disagreements(it) : 0;
          return html`<button key=${it.labelId} class=${cls('label-row', i === at && 'on')} onClick=${() => setAt(i)}>
            <span class="mono">${i + 1}</span>
            <span><b>${it.taskId}</b><small>${it.run} · rep ${it.repetition}</small></span>
            <span class=${cls('label-count', c.done === c.all && 'done')}>${c.done}/${c.all}${dis ? html` <em title="you and the judge disagree">≠${dis}</em>` : ''}</span></button>`;
        })}
        ${!visible.length && html`<div class="faint" style="padding:8px">nothing matches</div>`}
      </aside>
      ${item ? html`<${Episode} key=${item.labelId} item=${item} index=${at} count=${items.length} focus=${focus} setFocus=${setFocus} answer=${answer} saveNote=${saveNote} revealAll=${revealAll} move=${move} traceOpen=${query?.trace != null} />` : html`<${Empty}>Pick an episode.</${Empty}>`}
    </div>
  </div>`;
}

const countOf = (it) => {
  const qs = it.rubrics.flatMap((r) => r.criteria);
  return { all: qs.length, done: qs.filter((q) => isAnswered(q.label)).length };
};
const doneOf = (it) => { const c = countOf(it); return c.done === c.all; };
const disagreements = (it) => it.rubrics.reduce((n, r) => n + r.criteria.filter((c) => r.judge && isAnswered(c.label) && (c.label === YES) !== judgeSaysYes(r.judge, c.id)).length, 0);

// ---------------------------------------------------------------------------

function Episode({ item, index, count, focus, setFocus, answer, saveNote, revealAll, move, traceOpen }) {
  const c = countOf(item);
  const [peek, setPeek] = useState(false);
  const reveal = revealAll || peek || c.done === c.all;
  const said = closingText(item);
  let qi = -1;
  return html`<div class="label-main">
    <div style="display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;margin-bottom:10px">
      <span class="mono faint">${index + 1} / ${count}</span>
      <b style="font:500 20px var(--serif)">${item.title || item.taskId}</b>
      <span class="mono" style="font-size:12px">${item.labelId}</span>
      <span style="margin-left:auto;display:flex;gap:6px">
        <button class="btn ghost sm" onClick=${() => move(-1)} title="previous ([ or ←)">← prev</button>
        <button class="btn ghost sm" onClick=${() => move(1)} title="next (] or →)">next →</button>
      </span>
    </div>
    <div class="chips" style="margin-bottom:12px">
      <${Chip}>agent <b>${item.agentId}</b></${Chip}>${item.model && html`<${Chip}>model <b>${item.model}</b></${Chip}>`}
      <${Chip}>rep ${item.repetition}</${Chip}><${Chip}>ended <b>${item.endReason}</b></${Chip}>
      ${item.verdict && html`<${Chip}>score ${item.verdict.score?.toFixed?.(2)}</${Chip}>`}
    </div>

    ${item.holdout ? html`<div class="note">Holdout task: its text is hidden (start the UI with <code>--show-holdout</code> to see it).</div>`
      : html`<blockquote class="label-quote">${item.instruction}<footer>the task, as given to the agent</footer></blockquote>`}
    ${item.turns.length > 0 && html`<div class="label-turns">${item.turns.map((t, i) => html`<div key=${i} class="event user"><span>👤</span><span><b>${t.when === 'after done' ? 'User, after the agent said it was done' : 'User, while the agent worked'}</b>${t.simulated ? ' (simulated)' : ''}${t.delivered === false ? ' (not delivered)' : ''}: <span style="font:italic 15px var(--serif)">“${(t.text || '').trim()}”</span></span></div>`)}
      <div class="faint" style="font-size:12px;margin-top:2px">The closing statement answers the last of these.</div></div>`}

    <div class="label-said">
      <div class="lbl">What the agent said last <span class="faint">${item.endReason === 'abort' ? '(it aborted)' : ''}</span></div>
      <div class="said">${said || html`<span class="faint">(no text)</span>`}</div>
    </div>

    <div class="label-qs">
      ${item.rubrics.map((r) => html`<div key=${r.name} class="label-rubric">
        <div class="lbl">Rubric <span class="mono">${r.name}</span>
          ${!reveal && r.judge && html`<button class="btn ghost sm" style="margin-left:auto" onClick=${() => setPeek(true)} title="labelling after this is no longer blind for this episode">reveal judge</button>`}</div>
        ${r.scope && html`<div class="label-scope">${r.scope}</div>`}
        ${r.criteria.map((q) => {
          qi++;
          const me = qi, j = r.judge, js = j ? judgeSaysYes(j, q.id) : null;
          const agree = reveal && j && isAnswered(q.label) ? (q.label === YES) === js : null;
          return html`<div key=${q.id} class=${cls('label-q', focus === me && 'focus', agree === false && 'disagree')} onClick=${() => setFocus(me)}>
            <div class="qtext"><span class="mono faint">${q.id}</span> ${q.question}</div>
            <div class="qans">
              <button class=${cls('btn sm', q.label === YES ? 'picked' : 'ghost')} onClick=${(e) => { e.stopPropagation(); setFocus(me); answer({ ...q, rubric: r.name }, YES); }}>yes <span class="kbd">y</span></button>
              <button class=${cls('btn sm', q.label === NO ? 'picked' : 'ghost')} onClick=${(e) => { e.stopPropagation(); setFocus(me); answer({ ...q, rubric: r.name }, NO); }}>no <span class="kbd">n</span></button>
              ${reveal && j && html`<span class="judge" title=${'judge votes ' + (j.votes?.[q.id] ?? 0) + ' of ' + j.k}>judge: <b>${js ? 'yes' : 'no'}</b> ${j.votes?.[q.id] ?? 0}/${j.k}${agree === false ? html` <em>≠</em>` : agree ? ' ✓' : ''}</span>`}
            </div>
          </div>`;
        })}
        ${reveal && r.judge && html`<${JudgeDetail} judge=${r.judge} criteria=${r.criteria} />`}
      </div>`)}
      <${Note} key=${item.labelId} value=${item.note || ''} onSave=${saveNote} />
    </div>

    ${item.rubrics.filter((r) => r.evidence && Object.keys(r.evidence).length).slice(0, 1).map((r) => html`<${Record} key="rec" evidence=${r.evidence} />`)}
    <${Artifact} rubrics=${item.rubrics} />
    <${FullTrace} item=${item} initiallyOpen=${traceOpen} />
  </div>`;
}

function closingText(item) {
  const a = item.rubrics[0]?.artifact || {};
  return a.summary || a.reason || a.message || item.endMessage || (Object.keys(a).length ? JSON.stringify(a) : '');
}

function JudgeDetail({ judge, criteria }) {
  const answers = judge.answers || [], why = judge.rationales || [];
  if (!answers.length && !why.length) return html`<div class="faint" style="font-size:12px;margin-top:4px">Only the vote counts were stored for this run (judged before answers and reasons were kept). Re-judge it to see why.</div>`;
  return html`<details class="label-judge" open><summary>The judge's ${answers.length || why.length} consultations <span class="faint mono">${judge.judgeId || ''}</span></summary>
    ${(answers.length ? answers : why).map((_, i) => html`<div key=${i} class="consult">
      <span class="mono faint">#${i + 1}</span>
      <span class="chips">${criteria.map((c) => html`<${Chip} key=${c.id}>${c.id} <b>${answers[i]?.[c.id] ? 'yes' : 'no'}</b></${Chip}>`)}</span>
      ${why[i] && html`<div class="why">${why[i]}</div>`}
    </div>`)}
  </details>`;
}

function Note({ value, onSave }) {
  const [v, setV] = useState(value);
  return html`<div style="margin-top:10px"><textarea rows="2" placeholder="note on this episode (a rubric defect, an unclear case…) — saved when you leave the field" value=${v} onInput=${(e) => setV(e.target.value)} onBlur=${() => v !== value && onSave(v)} style="width:100%"></textarea></div>`;
}

/** The digest the judge was shown, uncut, user messages where they were said. */
function Record({ evidence }) {
  const actions = evidence.actions || [];
  return html`<${Section} no="R" title="The record the judge was given" hint=${`${actions.length} entries · ended ${evidence.endedBecause} · ${evidence.anyChangeToTheApp ? 'the app changed' : 'nothing in the app changed'}`}
    actions=${html`<${Copy} text=${JSON.stringify(evidence, null, 2)} label="copy JSON" />`}>
    <ol class="label-record">
      ${actions.map((a, i) => a.user != null
        ? html`<li key=${i} class="user"><b>user</b> <span class="faint">(${a.when || 'later'})</span> <span style="font:italic 15px var(--serif)">“${a.user}”</span>${a.agentHadSaid && html`<div class="faint" style="font-size:12px">after the agent had said: “${a.agentHadSaid}”</div>`}</li>`
        : html`<li key=${i}><span class="mono"><b>${a.did}</b></span>${a.result && html` <span class=${a.result === 'ok' ? 'faint' : 'bad'}>→ ${a.result}</span>`}${a.changedTheApp && html` <span style="color:var(--s3)">✱ changed the app</span>`}
            ${['with', 'returned', 'error'].filter((k) => a[k] != null).map((k) => html`<div key=${k} class="kv-line"><span class="faint">${k}</span><${Value} text=${a[k]} /></div>`)}</li>`)}
    </ol>
    ${evidence.finalState && html`<div class="kv-line"><span class="faint">final state</span><${Value} text=${evidence.finalState} /></div>`}
  </${Section}>`;
}

/** A JSON string from the record: parsed and folded when it is JSON, else shown as text. */
function Value({ text }) {
  let parsed = null;
  try { parsed = JSON.parse(text); } catch { /* not JSON, or cut by the digest */ }
  return parsed != null && typeof parsed === 'object' ? html`<${JsonView} value=${parsed} open=${1} maxStr=${4000} />` : html`<span class="mono" style="font-size:12px;white-space:pre-wrap;word-break:break-word">${text}</span>`;
}

function Artifact({ rubrics }) {
  const seen = new Set();
  const list = rubrics.filter((r) => { const k = JSON.stringify(r.artifact); if (seen.has(k)) return false; seen.add(k); return true; });
  return html`<${Section} no="A" title="The artifact under judgement" hint="exactly what the judge was asked about">
    ${list.map((r) => html`<div key=${r.name}><div class="faint" style="font-size:12px">${list.length > 1 ? r.name : ''}</div><${JsonView} value=${r.artifact} open=${3} maxStr=${4000} /></div>`)}
  </${Section}>`;
}

/** Every step of the episode, as the trace view shows it: thinking, tool calls, results. */
function FullTrace({ item, initiallyOpen }) {
  const [open, setOpen] = useState(!!initiallyOpen);
  const runName = item.runDir.split('/').pop();
  const ev = useAsync(() => (open ? api('trace', { query: { dir: item.traceLibrary, run: runName, episode: item.episodeId } }) : Promise.resolve(null)), [open, item.labelId]);
  const trace = useMemo(() => (ev.data ? buildTrace(ev.data.events) : null), [ev.data]);
  const [all, setAll] = useState(null);
  return html`<${Section} no="T" title="Full trace" hint="every step: what the model thought and said, the call, what the app answered"
    actions=${html`${open && trace && html`<button class="btn ghost sm" onClick=${() => setAll(all === true ? false : true)}>${all === true ? 'collapse all' : 'expand all'}</button>`}
      <button class="btn ghost sm" onClick=${() => setOpen(!open)}>${open ? 'hide' : 'show'}</button>`}>
    ${!open ? html`<div class="faint">${'Hidden until asked for, so a long trace does not slow the page.'}</div>`
      : ev.loading ? html`<${Loading} what="reading trace" />` : ev.error ? html`<${ErrorBox} error=${ev.error} />`
      : trace && html`<div class="steps">
        ${trace.steps.map((s) => html`<div key=${s.seq}><${Step} s=${s} sel=${false} openAll=${all} q="" onSelect=${() => {}} prev=${trace.steps[s.idx - 1]} /></div>`)}
        ${trace.tail.map((e, i) => html`<${Event} key=${'t' + i} e=${e} />`)}
        ${trace.end && html`<div class="event"><span>■</span><span><b>Ended</b>: ${trace.end.reason}${trace.end.message ? html` — <span style="font:italic 15px var(--serif)">“${trace.end.message}”</span>` : ''}</span></div>`}
      </div>`}
  </${Section}>`;
}

// ---------------------------------------------------------------------------

function CalibrationPanel({ result, stored }) {
  const json = result?.json || stored;
  if (!json) return null;
  const per = json.perRubric || {};
  const crit = json.perCriterion;
  const fmt = (x) => (x == null || Number.isNaN(x) ? '—' : Number(x).toFixed(3));
  const rows = Object.entries(per).length ? Object.entries(per) : crit ? [['all criteria', crit]] : [];
  return html`<${Section} no="κ" title="Calibration" hint=${result ? 'just now — written to calibration.md and calibration.json in the set' : 'as last written to calibration.json'}>
    ${rows.length > 0 && html`<table class="t compact" style="max-width:760px"><thead><tr><th>rubric</th><th class="n">n</th><th class="n">agreement</th><th class="n">κ</th><th>95% CI</th><th class="n">F1</th></tr></thead><tbody>
      ${rows.map(([name, c]) => html`<tr key=${name}><td class="mono">${name}</td><td class="n">${fmtInt(c.n)}</td><td class="n">${fmt(c.agreement)}</td>
        <td class="n"><b style=${{ color: c.kappa >= 0.61 ? 'var(--good-ink)' : c.kappa >= 0.41 ? 'var(--warn-ink)' : 'var(--crit-ink)' }}>${fmt(c.kappa)}</b></td>
        <td class="mono" style="font-size:12px">[${fmt(c.kappaCi?.[0])}, ${fmt(c.kappaCi?.[1])}]</td><td class="n">${fmt(c.f1)}</td></tr>`)}
    </tbody></table>`}
    <div class="faint" style="font-size:12px;margin-top:6px">Landis and Koch: ≥ 0.61 substantial (the bar for accepting a rubric), 0.41–0.60 moderate. Use the “disagreements” filter to go through every case.</div>
    ${result?.markdown && html`<details style="margin-top:8px"><summary class="faint" style="cursor:pointer">calibration.md</summary><pre class="code wrap" style="font-size:12px">${result.markdown}</pre></details>`}
  </${Section}>`;
}
