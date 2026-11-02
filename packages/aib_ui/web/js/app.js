import { html, render, useState, useEffect, useStore, useRoute, store, setStore, loadInfo, loadRuns, loadCatalog, api, href, parseHash, pref } from './lib.js';
import { TipHost, FolderPicker, Loading, ErrorBox } from './ui.js';
import { LibraryView } from './views/library.js';

// Views load on demand: the library is the front door, the rest wait until visited.
const lazy = (loader, name) => {
  let comp = null, err = null;
  return function Lazy(props) {
    const [, bump] = useState(0);
    useEffect(() => { if (!comp && !err) loader().then((m) => { comp = m[name]; bump((n) => n + 1); }, (e) => { err = e; bump((n) => n + 1); }); }, []);
    if (err) return html`<${ErrorBox} error=${err.message} />`;
    return comp ? html`<${comp} ...${props} />` : html`<${Loading} />`;
  };
};
const RunView = lazy(() => import('./views/run.js'), 'RunView');
const TraceView = lazy(() => import('./views/trace.js'), 'TraceView');
const CompareView = lazy(() => import('./views/compare.js'), 'CompareView');
const ConfigsView = lazy(() => import('./views/configs.js'), 'ConfigsView');
const SuitesView = lazy(() => import('./views/suites.js'), 'SuitesView');
const LaunchView = lazy(() => import('./views/launch.js'), 'LaunchView');
const TelemetryView = lazy(() => import('./views/telemetry.js'), 'TelemetryView');
const LabelView = lazy(() => import('./views/label.js'), 'LabelView');

const NAV = [
  ['runs', 'I', 'Runs', []],
  ['compare', 'II', 'Compare', ['compare']],
  ['configs', 'III', 'Configs', ['configs']],
  ['suites', 'IV', 'Suites', ['suites']],
  ['launch', 'V', 'Launch', ['launch']],
  ['telemetry', 'VI', 'Telemetry', ['telemetry']],
  ['label', 'VII', 'Label', ['label']],
];

function Shell() {
  const s = useStore();
  const route = useRoute();
  const [picker, setPicker] = useState(false);
  const [theme, setTheme] = useState(document.documentElement.dataset.theme || '');
  const top = route.path[0] || '';
  useEffect(() => { window.scrollTo(0, 0); }, [route.path.join('/')]);

  // Poll jobs while the framework is attached.
  useEffect(() => {
    if (!s.info?.framework) return;
    let live = true;
    const tick = async () => { try { const j = await api('fw/jobs'); if (live) setStore({ jobs: j.jobs, spent: j.spentTodayUsd }); } catch { /* ignore */ } };
    tick(); const t = setInterval(tick, 3000);
    return () => { live = false; clearInterval(t); };
  }, [s.info?.framework]);

  // Spans arriving now: the Telemetry entry says so.
  useEffect(() => {
    let live = true;
    const tick = async () => { try { const i = await api('otel/info'); if (live) setStore({ otel: i }); } catch { /* ignore */ } };
    tick(); const t = setInterval(tick, 3000);
    return () => { live = false; clearInterval(t); };
  }, []);
  const spansNow = s.otel?.lastAt && Date.now() - new Date(s.otel.lastAt) < 45000;
  const running = s.jobs.filter((j) => j.state === 'running' || j.state === 'queued').length;
  const cycle = () => {
    const next = theme === '' ? 'dark' : theme === 'dark' ? 'light' : '';
    setTheme(next);
    if (next) document.documentElement.dataset.theme = next; else delete document.documentElement.dataset.theme;
    try { next ? localStorage.setItem('aib.theme', next) : localStorage.removeItem('aib.theme'); } catch { /* ignore */ }
  };

  let page;
  if (top === 'run' && route.path[2] === 'ep') page = html`<${TraceView} key=${route.path.join('/')} run=${route.path[1]} episode=${route.path[3]} query=${route.query} />`;
  else if (top === 'run') page = html`<${RunView} key=${route.path[1]} id=${route.path[1]} query=${route.query} />`;
  else if (top === 'compare') page = html`<${CompareView} query=${route.query} />`;
  else if (top === 'configs') page = html`<${ConfigsView} name=${route.path.slice(1).join('/')} query=${route.query} />`;
  else if (top === 'suites') page = html`<${SuitesView} name=${route.path[1]} />`;
  else if (top === 'telemetry') page = html`<${TelemetryView} id=${route.path[1]} query=${route.query} />`;
  else if (top === 'label') page = html`<${LabelView} key=${route.query?.path || ''} path=${route.query?.path} query=${route.query} />`;
  else if (top === 'launch') page = html`<${LaunchView} query=${route.query} />`;
  else page = html`<${LibraryView} />`;

  return html`<div class="shell">
    <nav class="rail" aria-label="Main">
      <a class="brand" href="#/"><svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" height="32" fill="var(--ink)"/><path d="M7 24h6V12H7zM14 24h6V7h-6zM21 24h5v-8h-5z" fill="var(--mark)"/></svg><span><b>aib</b><small>benchmark ledger</small></span></a>
      <div class="nav">
        ${NAV.map(([id, no, label, paths]) => html`<a key=${id} href=${id === 'runs' ? '#/' : '#/' + id} class=${(id === 'runs' ? (top === '' || top === 'run') : top === id) ? 'on' : ''}>
          <i>${no}</i><span>${label}</span>${id === 'launch' && running > 0 ? html`<span class="badge">${running}</span>` : id === 'telemetry' && spansNow ? html`<span class="badge" title="spans received in the last 45 s">● live</span>` : html`<span></span>`}</a>`)}
      </div>
      <div class="foot">
        <div><div class="faint" style="font:600 9.5px var(--sans);letter-spacing:.14em;text-transform:uppercase;margin-bottom:3px">Folder</div>
          <div class="path" onClick=${() => setPicker(true)} title="Open another folder">${(s.library || s.info?.defaultLibrary || '').replace(s.info?.home || '\u0000', '~')}</div></div>
        <div style="display:flex;justify-content:space-between;align-items:center">
          <span class="faint" style="font-size:11.5px">${s.info?.framework ? 'framework attached' : 'browse-only'}</span>
          <button class="btn ghost sm" onClick=${cycle} title="Theme: auto → dark → light">${theme === 'dark' ? '☾ dark' : theme === 'light' ? '☀ light' : '◐ auto'}</button>
        </div>
      </div>
    </nav>
    <main class="main">${page}</main>
    ${picker && html`<${FolderPicker} onClose=${() => setPicker(false)} />`}
    <${TipHost} />
    ${s.toast && html`<div class="toast" role="status">${s.toast}</div>`}
  </div>`;
}

(async () => {
  await loadCatalog();
  try { await loadInfo(); } catch (e) { document.getElementById('app').textContent = 'Cannot reach the AIB server: ' + e.message; return; }
  render(html`<${Shell} />`, document.getElementById('app'));
  loadRuns();
})();
