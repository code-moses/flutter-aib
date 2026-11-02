// Small shared components: tooltip, modal, tabs, chips, JSON/YAML viewers, folder picker.
import { html, useState, useEffect, useRef, useCallback, api, store, setLibrary, useAsync, fmtInt, verdictOf, cls, pref } from './lib.js';

// ---------------------------------------------------------------------------
// Tooltip (one element, positioned from the pointer)

let tipSet = () => {};
export const tip = {
  show(e, content) { tipSet({ x: e.clientX, y: e.clientY, content }); },
  hide() { tipSet(null); },
};
export function TipHost() {
  const [t, set] = useState(null);
  useEffect(() => { tipSet = set; return () => { tipSet = () => {}; }; }, []);
  if (!t) return null;
  const left = t.x + 16 + 300 > innerWidth ? t.x - 16 - 300 : t.x + 16;
  const top = Math.min(t.y + 14, innerHeight - 90);
  return html`<div class="tip" style=${{ left: Math.max(6, left) + 'px', top: top + 'px' }}>${t.content}</div>`;
}
/** Hover text for ordinary elements. */
export const hint = (text) => ({ onMouseMove: (e) => tip.show(e, text), onMouseLeave: tip.hide });

// ---------------------------------------------------------------------------

export function Loading({ what = 'loading' }) { return html`<div class="loading"><span class="spinner"></span>&nbsp; ${what}…</div>`; }
export function ErrorBox({ error }) { return error ? html`<div class="err">${String(error)}</div>` : null; }
export function Empty({ children }) { return html`<div class="empty">${children}</div>`; }

export function PageHead({ kicker, title, sub, children }) {
  return html`<header class="ph"><div><div class="kicker">${kicker}</div><h1>${title}</h1>${sub && html`<div class="sub">${sub}</div>`}</div>${children && html`<div class="acts">${children}</div>`}</header>`;
}
export function Section({ no, title, hint: hintText, children, actions }) {
  return html`<section class="sec"><header>${no && html`<span class="no">${no}</span>`}<h2>${title}</h2>${hintText && html`<span class="hint">${hintText}</span>`}${actions && html`<span class="sp">${actions}</span>`}</header>${children}</section>`;
}

export function Tabs({ tabs, value, onChange }) {
  return html`<div class="tabs" role="tablist">${tabs.map((t) => html`<button key=${t.id} role="tab" aria-selected=${value === t.id} class=${value === t.id ? 'on' : ''} onClick=${() => onChange(t.id)}>${t.label}${t.count != null && html`<span class="c">${t.count}</span>`}</button>`)}</div>`;
}
export function Seg({ options, value, onChange }) {
  return html`<span class="seg">${options.map((o) => html`<button key=${o.id ?? o} class=${(o.id ?? o) === value ? 'on' : ''} onClick=${() => onChange(o.id ?? o)} title=${o.title || ''}>${o.label ?? o}</button>`)}</span>`;
}

export function Verdict({ v, label = true }) {
  const d = verdictOf(v);
  return html`<span class=${'verdict ' + d.cls}><span class="g" aria-hidden="true">${d.glyph}</span>${label && d.label}</span>`;
}

export function Chip({ children, on, onClick, onRemove, tag, color, title }) {
  return html`<span class=${cls('chip', tag && 'tag', on && 'on')} onClick=${onClick} title=${title} style=${{ cursor: onClick ? 'pointer' : 'default' }}>${color && html`<span class="sw" style=${{ background: color }}></span>`}${children}${onRemove && html`<span class="x" onClick=${(e) => { e.stopPropagation(); onRemove(); }} aria-label="remove">×</span>`}</span>`;
}

export function Modal({ title, onClose, children, footer, wide }) {
  useEffect(() => {
    const f = (e) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', f);
    return () => window.removeEventListener('keydown', f);
  }, [onClose]);
  return html`<div class="scrim" onMouseDown=${(e) => e.target === e.currentTarget && onClose()}>
    <div class=${cls('modal', wide && 'wide')} role="dialog" aria-label=${title}>
      <header><h2>${title}</h2><button class="btn ghost sm" onClick=${onClose}>close <span class="kbd">esc</span></button></header>
      <div class="body">${children}</div>
      ${footer && html`<footer>${footer}</footer>`}
    </div>
  </div>`;
}

/** A labelled control. A `group` of several controls (a segmented button, a list of checkboxes) is not a
 * <label>: a label hands every click on its padding to its first control. */
export function Field({ label, children, hint: h, group }) {
  const Tag = group ? 'div' : 'label';
  return html`<${Tag} class="field" role=${group ? 'group' : undefined}><span>${label}</span>${children}${h && html`<span class="faint" style="font-size:11.5px">${h}</span>`}</${Tag}>`;
}

/** Keyboard shortcuts that stay quiet inside inputs. */
export function useKeys(map, deps = []) {
  useEffect(() => {
    const f = (e) => {
      const t = e.target;
      if (t && (/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName) || t.isContentEditable)) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const fn = map[e.key];
      if (fn) { e.preventDefault(); fn(e); }
    };
    window.addEventListener('keydown', f);
    return () => window.removeEventListener('keydown', f);
  }, deps);
}

// ---------------------------------------------------------------------------
// JSON viewer: collapsible, long strings clipped.

export function JsonView({ value, open = 1, maxStr = 600 }) {
  return html`<div class="json">${node(value, 0, open, maxStr)}</div>`;
}
function Str({ s, maxStr }) {
  const [full, setFull] = useState(false);
  const long = s.length > maxStr;
  const shown = full || !long ? s : s.slice(0, maxStr);
  return html`<span class="s pre">"${shown}${long && !full ? '…' : ''}"</span>${long && html` <a href="javascript:void 0" class="faint" onClick=${() => setFull(!full)}>${full ? 'less' : `+${fmtInt(s.length - maxStr)} chars`}</a>`}`;
}
function node(v, depth, open, maxStr) {
  if (v === null) return html`<span class="z">null</span>`;
  if (typeof v === 'string') return html`<${Str} s=${v} maxStr=${maxStr} />`;
  if (typeof v === 'number') return html`<span class="n">${String(v)}</span>`;
  if (typeof v === 'boolean') return html`<span class="b">${String(v)}</span>`;
  const isArr = Array.isArray(v);
  const entries = isArr ? v.map((x, i) => [i, x]) : Object.entries(v);
  if (!entries.length) return html`<span class="z">${isArr ? '[]' : '{}'}</span>`;
  const inline = entries.length <= 4 && entries.every(([, x]) => x === null || typeof x !== 'object') && JSON.stringify(v).length < 90;
  if (inline) {
    return html`<span>${isArr ? '[' : '{'}${entries.map(([k, x], i) => html`<span key=${k}>${i ? ', ' : ''}${!isArr && html`<span class="k">${k}: </span>`}${node(x, depth + 1, open, maxStr)}</span>`)}${isArr ? ']' : '}'}</span>`;
  }
  return html`<details open=${depth < open}>
    <summary><span class="z">${isArr ? `[${entries.length}]` : `{${entries.length}}`}</span></summary>
    <div class="ind">${entries.map(([k, x]) => html`<div key=${k}><span class="k">${isArr ? '' : k + ': '}</span>${node(x, depth + 1, open, maxStr)}</div>`)}</div>
  </details>`;
}

/** YAML text with comments and keys tinted; no parsing. */
export function YamlView({ text, highlightLines }) {
  const lines = String(text).split('\n');
  return html`<pre class="code yaml">${lines.map((l, i) => {
    const mm = /^(\s*(?:- )?)([A-Za-z0-9_.\-"']+)(:)(.*)$/.exec(l);
    const hl = highlightLines && highlightLines.has(i);
    let inner;
    if (/^\s*#/.test(l)) inner = html`<span class="c">${l}</span>`;
    else if (mm) inner = html`${mm[1]}<span class="k">${mm[2]}</span>${mm[3]}<span class="v">${mm[4]}</span>`;
    else inner = l;
    return html`<div key=${i} class=${hl ? 'diffrow' : ''}>${inner || ' '}</div>`;
  })}</pre>`;
}

export function KV({ data, keys }) {
  const ks = keys || Object.keys(data);
  return html`<dl class="kv">${ks.filter((k) => data[k] !== undefined && data[k] !== null && data[k] !== '').map((k) => html`<${KVRow} key=${k} k=${k} v=${data[k]} />`)}</dl>`;
}
function KVRow({ k, v }) {
  return html`<dt>${k}</dt><dd>${typeof v === 'object' ? JSON.stringify(v) : String(v)}</dd>`;
}

// ---------------------------------------------------------------------------
// Folder picker: browses the machine the server runs on.

export function FolderPicker({ onClose }) {
  const info = store.info;
  const [path, setPath] = useState(store.library || info?.defaultLibrary || info?.home);
  const [text, setText] = useState(path);
  const q = useAsync(() => api('fs', { query: { path } }), [path]);
  const go = (p) => { setPath(p); setText(p); };
  const recents = info?.user?.recents || [];
  const choose = async () => { await setLibrary(q.data.path); onClose(); };
  return html`<${Modal} title="Open a folder of runs" onClose=${onClose} wide
    footer=${html`<span class="muted" style="margin-right:auto">${q.data ? (q.data.runsHere ? `${q.data.runsHere} run${q.data.runsHere > 1 ? 's' : ''} directly in here` : 'runs are found up to four levels down') : ''}</span><button class="btn ghost" onClick=${onClose}>Cancel</button><button class="btn solid" disabled=${!q.data} onClick=${choose}>Use this folder</button>`}>
    <div class="note">A run is a directory with a <code>run_manifest.json</code>. Pick the folder that contains them — for this checkout that is <code>results/</code>. Nothing in it is modified.</div>
    <form onSubmit=${(e) => { e.preventDefault(); go(text); }} style="display:flex;gap:8px">
      <input type="text" class="mono" value=${text} onInput=${(e) => setText(e.target.value)} spellcheck="false" aria-label="folder path" />
      <button class="btn">Go</button>
    </form>
    <div class="chips">
      ${info?.defaultLibrary && html`<${Chip} onClick=${() => go(info.defaultLibrary)}>checkout results</${Chip}>`}
      ${info?.home && html`<${Chip} onClick=${() => go(info.home)}>home</${Chip}>`}
      ${recents.map((r) => html`<${Chip} key=${r} tag onClick=${() => go(r)} title=${r}>${r.split('/').slice(-2).join('/')}</${Chip}>`)}
    </div>
    ${q.error && html`<${ErrorBox} error=${q.error} />`}
    ${q.data && html`<div class="fs-list">
      ${q.data.parent && html`<button onClick=${() => go(q.data.parent)}><span>↰</span><span>..</span><span></span></button>`}
      ${q.data.entries.map((e) => html`<button key=${e.path} onClick=${() => go(e.path)}>
        <span>${e.isRun ? '◆' : '▸'}</span><span class="mono">${e.name}</span>${e.isRun ? html`<span class="runs">run</span>` : e.runs ? html`<span class="runs">${e.runs} runs</span>` : html`<span></span>`}
      </button>`)}
      ${!q.data.entries.length && html`<div class="empty" style="border:0">no sub-folders</div>`}
    </div>`}
  </${Modal}>`;
}

// ---------------------------------------------------------------------------

/** Editable tag chips for a run (stored beside the app, never in the run). */
export function TagEditor({ tags, onChange, suggestions = [] }) {
  const [val, setVal] = useState('');
  const add = () => { const t = val.trim(); if (t && !tags.includes(t)) onChange([...tags, t]); setVal(''); };
  const listId = useRef('tags' + Math.random().toString(36).slice(2)).current;
  return html`<span class="chips" style="align-items:center">
    ${tags.map((t) => html`<${Chip} key=${t} tag onRemove=${() => onChange(tags.filter((x) => x !== t))}>${t}</${Chip}>`)}
    <input type="text" list=${listId} placeholder="+ tag" value=${val} onInput=${(e) => setVal(e.target.value)} onKeyDown=${(e) => e.key === 'Enter' && add()} onBlur=${add} style="width:90px;padding:1px 6px;font-size:12px" />
    <datalist id=${listId}>${suggestions.map((s) => html`<option key=${s} value=${s}></option>`)}</datalist>
  </span>`;
}

export function Copy({ text, label = 'copy' }) {
  const [done, setDone] = useState(false);
  return html`<button class="btn ghost sm" onClick=${() => { navigator.clipboard?.writeText(text); setDone(true); setTimeout(() => setDone(false), 1200); }}>${done ? 'copied' : label}</button>`;
}
