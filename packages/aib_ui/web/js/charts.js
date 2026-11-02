// Hand-drawn SVG charts. Colours are the validated categorical slots (--s1…--s8)
// assigned in fixed order; a ninth series folds into neutral ink. Every mark has a
// hover tooltip; every chart sits next to numbers (a table or a label) so colour
// is never the only channel.
import { html, useState, useEffect, useRef, useMemo, fmtNum, isNum, quantile } from './lib.js';
import { tip } from './ui.js';

export const seriesColor = (i) => (i < 8 ? `var(--s${i + 1})` : 'var(--ink-3)');

/** Measures the element it is attached to. A callback ref, so a chart that swaps its root (an empty
 * placeholder for the real <svg> and back) is observed again instead of keeping the first width. */
export function useWidth(initial = 640) {
  const [el, setEl] = useState(null);
  const [w, setW] = useState(initial);
  useEffect(() => {
    if (!el) return;
    const measure = (width) => setW(Math.max(160, Math.floor(width)));
    measure(el.getBoundingClientRect().width || initial);
    const ro = new ResizeObserver(([e]) => measure(e.contentRect.width));
    ro.observe(el);
    return () => ro.disconnect();
  }, [el]);
  return [setEl, w];
}

/** "Nice" ticks across [lo, hi]. */
export function ticks(lo, hi, count = 5) {
  if (!isNum(lo) || !isNum(hi)) return [0, 1];
  if (lo === hi) { hi = lo + 1; }
  const span = hi - lo, raw = span / count, mag = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * mag).find((s) => s >= raw) || mag * 10;
  const out = [];
  for (let t = Math.ceil(lo / step) * step; t <= hi + step * 1e-6; t += step) out.push(+t.toFixed(10));
  return out;
}

export function Legend({ items }) {
  return html`<div class="legend">${items.map((it) => html`<span key=${it.label} title=${it.title || ''}><i style=${{ background: it.color }}></i>${it.label}</span>`)}</div>`;
}

/** One-axis scatter (optionally with CI whiskers). points: {id,x,y,color,label,xlo,xhi,ylo,yhi,r,tipRows} */
export function Scatter({ points, xLabel, yLabel, xFmt = fmtNum, yFmt = fmtNum, height = 300, onClick, xDomain, yDomain, logX = false, selected }) {
  const [ref, W] = useWidth();
  const m = { l: 52, r: 14, t: 10, b: 38 };
  const pts = points.filter((p) => isNum(p.x) && isNum(p.y));
  if (!pts.length) return html`<div class="empty" ref=${ref}>no data</div>`;
  const xv = pts.flatMap((p) => [p.x, p.xlo, p.xhi]).filter(isNum), yv = pts.flatMap((p) => [p.y, p.ylo, p.yhi]).filter(isNum);
  const tx = (v) => (logX ? Math.log10(Math.max(v, 1e-9)) : v);
  let [x0, x1] = xDomain || [Math.min(...xv), Math.max(...xv)];
  let [y0, y1] = yDomain || [Math.min(...yv), Math.max(...yv)];
  if (!xDomain) { const pad = (x1 - x0) * 0.06 || 1; x0 = logX ? x0 / 1.2 : Math.min(0, x0) === 0 && x0 >= 0 && x0 < (x1 - x0) * 0.4 ? 0 : x0 - pad; x1 = logX ? x1 * 1.2 : x1 + pad; }
  if (!yDomain) { const pad = (y1 - y0) * 0.08 || 0.1; y0 = y0 >= 0 && y0 - pad < 0 ? 0 : y0 - pad; y1 = y1 + pad; }
  const w = W - m.l - m.r, hh = height - m.t - m.b;
  const X = (v) => m.l + ((tx(v) - tx(x0)) / (tx(x1) - tx(x0) || 1)) * w;
  const Y = (v) => m.t + hh - ((v - y0) / (y1 - y0 || 1)) * hh;
  const xt = logX ? ticks(Math.log10(Math.max(x0, 1e-9)), Math.log10(x1), 4).map((t) => 10 ** t) : ticks(x0, x1, Math.max(3, Math.floor(w / 110)));
  const yt = ticks(y0, y1, 5);
  return html`<svg ref=${ref} class="chart" viewBox="0 0 ${W} ${height}" height=${height} role="img" aria-label=${`${yLabel} against ${xLabel}`}>
    ${yt.map((t) => html`<g key=${'y' + t}><line class="grid" x1=${m.l} x2=${W - m.r} y1=${Y(t)} y2=${Y(t)} /><text class="m" x=${m.l - 8} y=${Y(t) + 4} text-anchor="end">${yFmt(t)}</text></g>`)}
    ${xt.map((t) => html`<g key=${'x' + t}><line class="grid" x1=${X(t)} x2=${X(t)} y1=${m.t} y2=${m.t + hh} /><text class="m" x=${X(t)} y=${m.t + hh + 15} text-anchor="middle">${xFmt(t)}</text></g>`)}
    <line class="axis" x1=${m.l} x2=${W - m.r} y1=${m.t + hh} y2=${m.t + hh} />
    <text x=${m.l + w / 2} y=${height - 4} text-anchor="middle">${xLabel}</text>
    <text transform=${`translate(12 ${m.t + hh / 2}) rotate(-90)`} text-anchor="middle">${yLabel}</text>
    ${pts.map((p) => html`<g key=${p.id}>
      ${isNum(p.xlo) && isNum(p.xhi) && html`<line x1=${X(p.xlo)} x2=${X(p.xhi)} y1=${Y(p.y)} y2=${Y(p.y)} stroke=${p.color} stroke-width="1.5" opacity=".55" />`}
      ${isNum(p.ylo) && isNum(p.yhi) && html`<line y1=${Y(p.ylo)} y2=${Y(p.yhi)} x1=${X(p.x)} x2=${X(p.x)} stroke=${p.color} stroke-width="1.5" opacity=".55" />`}
      <circle cx=${X(p.x)} cy=${Y(p.y)} r=${p.r || 5.5} fill=${p.color} stroke="var(--paper)" stroke-width="2" opacity=${selected && selected !== p.id ? 0.35 : 1} />
      <circle class="hit" cx=${X(p.x)} cy=${Y(p.y)} r=${Math.max(10, (p.r || 5.5) + 4)}
        onMouseMove=${(e) => tip.show(e, html`<b>${p.label}</b><div class="row"><span>${xLabel}</span><span class="m">${xFmt(p.x)}</span></div><div class="row"><span>${yLabel}</span><span class="m">${yFmt(p.y)}</span></div>${p.tipRows || ''}`)}
        onMouseLeave=${tip.hide} onClick=${() => onClick && onClick(p)} />
      ${p.direct && html`<text x=${X(p.x) + 9} y=${Y(p.y) + 4} style="fill:var(--ink)">${p.direct}</text>`}
    </g>`)}
  </svg>`;
}

/** Rows of dots (one row per group) on a shared value axis, with median and IQR. */
export function Strip({ groups, fmt = fmtNum, height, onClick, domain, label }) {
  const [ref, W] = useWidth();
  const rowH = 30, m = { l: Math.min(180, Math.max(90, W * 0.22)), r: 16, t: 6, b: 22 };
  const H = height || m.t + m.b + groups.length * rowH;
  const all = groups.flatMap((g) => g.values.map((v) => v.v)).filter(isNum);
  if (!all.length) return html`<div class="empty" ref=${ref}>no values</div>`;
  let [lo, hi] = domain || [Math.min(...all), Math.max(...all)];
  if (!domain) { if (lo > 0 && lo < (hi - lo) * 0.5) lo = 0; if (hi === lo) hi = lo + 1; }
  const w = W - m.l - m.r, X = (v) => m.l + ((v - lo) / (hi - lo)) * w;
  const xt = ticks(lo, hi, Math.max(3, Math.floor(w / 100)));
  return html`<svg ref=${ref} class="chart" viewBox="0 0 ${W} ${H}" height=${H} role="img" aria-label=${label || 'distribution'}>
    ${xt.map((t) => html`<g key=${t}><line class="grid" x1=${X(t)} x2=${X(t)} y1=${m.t} y2=${H - m.b} /><text class="m" x=${X(t)} y=${H - 6} text-anchor="middle">${fmt(t)}</text></g>`)}
    ${groups.map((g, gi) => {
      const y = m.t + gi * rowH + rowH / 2;
      const vs = g.values.map((o) => o.v).filter(isNum);
      const q1 = quantile(vs, 0.25), q2 = quantile(vs, 0.5), q3 = quantile(vs, 0.75);
      return html`<g key=${g.label}>
        <text x=${m.l - 10} y=${y + 4} text-anchor="end" style="fill:var(--ink)">${trunc(g.label, Math.floor((m.l - 12) / 6.4))}</text>
        ${vs.length > 1 && html`<line x1=${X(q1)} x2=${X(q3)} y1=${y} y2=${y} stroke=${g.color} stroke-width="8" opacity=".22" stroke-linecap="butt" />`}
        ${g.values.filter((o) => isNum(o.v)).map((o, i) => html`<circle key=${i} cx=${X(o.v)} cy=${y + jitter(i, g.values.length) * 7} r="3.4" fill=${g.color} stroke="var(--paper)" stroke-width="1.2"
          onMouseMove=${(e) => tip.show(e, html`<b>${o.label || g.label}</b><div class="row"><span>${label || 'value'}</span><span class="m">${fmt(o.v)}</span></div>`)} onMouseLeave=${tip.hide} onClick=${() => onClick && onClick(o, g)} style="cursor:pointer" />`)}
        ${isNum(q2) && html`<line x1=${X(q2)} x2=${X(q2)} y1=${y - 11} y2=${y + 11} stroke="var(--ink)" stroke-width="2" />`}
      </g>`;
    })}
  </svg>`;
}
const jitter = (i, n) => (n < 4 ? 0 : (((i * 2654435761) >>> 0) % 1000) / 1000 - 0.5);
export const trunc = (s, n) => (s == null ? '' : String(s).length > n ? String(s).slice(0, Math.max(1, n - 1)) + '…' : String(s));

/** Horizontal bars. rows: {label, value, color, sub, lo, hi, id} */
export function HBars({ rows, max, fmt = fmtNum, labelW, onClick, height = 24, label }) {
  const [ref, W] = useWidth();
  const lw = labelW || Math.min(220, Math.max(100, W * 0.3)), rw = 64;
  const M = max ?? Math.max(...rows.map((r) => r.hi ?? r.value ?? 0), 1e-9);
  const H = rows.length * height + 4, bw = W - lw - rw;
  return html`<svg ref=${ref} class="chart" viewBox="0 0 ${W} ${H}" height=${H} role="img" aria-label=${label || 'bars'}>
    ${rows.map((r, i) => {
      const y = i * height + 3, v = r.value, bwv = isNum(v) ? Math.max(0, (v / M) * bw) : 0;
      return html`<g key=${r.id || r.label} style=${{ cursor: onClick ? 'pointer' : 'default' }} onClick=${() => onClick && onClick(r)}
        onMouseMove=${(e) => tip.show(e, html`<b>${r.label}</b><div class="row"><span>${label || 'value'}</span><span class="m">${fmt(v)}</span></div>${isNum(r.lo) ? html`<div class="row"><span>95% CI</span><span class="m">${fmt(r.lo)} – ${fmt(r.hi)}</span></div>` : ''}${r.sub ? html`<div style="opacity:.75">${r.sub}</div>` : ''}`)} onMouseLeave=${tip.hide}>
        <rect x="0" y=${y - 2} width=${W} height=${height} fill="transparent" />
        <text x=${lw - 10} y=${y + height / 2 + 1} text-anchor="end" style="fill:var(--ink)">${trunc(r.label, Math.floor((lw - 12) / 6.3))}</text>
        <rect x=${lw} y=${y + 4} width=${bw} height=${height - 12} fill="var(--sunk)" />
        ${isNum(v) && html`<path d=${barPath(lw, y + 4, bwv, height - 12)} fill=${r.color || 'var(--s1)'} />`}
        ${isNum(r.lo) && html`<line x1=${lw + (r.lo / M) * bw} x2=${lw + (r.hi / M) * bw} y1=${y + height / 2 - 2} y2=${y + height / 2 - 2} stroke="var(--ink)" stroke-width="1.5" />`}
        <text class="m" x=${W - rw + 8} y=${y + height / 2 + 1} style="fill:var(--ink)">${fmt(v)}</text>
      </g>`;
    })}
  </svg>`;
}
// A bar rounded only at its data end.
function barPath(x, y, w, h) {
  if (w <= 0) return '';
  const r = Math.min(3, w, h / 2);
  return `M${x} ${y}H${x + w - r}Q${x + w} ${y} ${x + w} ${y + r}V${y + h - r}Q${x + w} ${y + h} ${x + w - r} ${y + h}H${x}Z`;
}

/** A single 100% bar of counts, 2px gaps, with a legend row. parts: {label,value,color} */
export function Proportion({ parts, height = 14, onClick }) {
  const total = parts.reduce((a, p) => a + p.value, 0) || 1;
  return html`<div>
    <div style=${{ display: 'flex', gap: '2px', height: height + 'px' }}>
      ${parts.filter((p) => p.value > 0).map((p) => html`<div key=${p.label} style=${{ flex: p.value, background: p.color, cursor: onClick ? 'pointer' : 'default' }}
        onMouseMove=${(e) => tip.show(e, html`<b>${p.label}</b><div class="row"><span>episodes</span><span class="m">${p.value}</span></div><div class="row"><span>share</span><span class="m">${((p.value / total) * 100).toFixed(0)}%</span></div>`)} onMouseLeave=${tip.hide} onClick=${() => onClick && onClick(p)}></div>`)}
    </div>
  </div>`;
}

/** Vertical stacked bars per step (the trace scrubber). steps: {stack:[{value,color,label}], id} */
export function StepBars({ steps, selected, onSelect, height = 84, fmt = fmtNum, unit = '', baselineLabel }) {
  const [ref, W] = useWidth();
  const m = { l: 40, r: 6, t: 4, b: 16 };
  const max = Math.max(1e-9, ...steps.map((s) => s.stack.reduce((a, b) => a + (b.value || 0), 0)));
  const w = W - m.l - m.r, hh = height - m.t - m.b, bw = Math.max(2, Math.min(28, w / Math.max(1, steps.length) - 2));
  const slot = w / Math.max(1, steps.length);
  const yt = ticks(0, max, 2);
  return html`<svg ref=${ref} class="chart" viewBox="0 0 ${W} ${height}" height=${height} role="img" aria-label=${unit}>
    ${yt.map((t) => html`<g key=${t}><line class="grid" x1=${m.l} x2=${W - m.r} y1=${m.t + hh - (t / max) * hh} y2=${m.t + hh - (t / max) * hh} /><text class="m" x=${m.l - 6} y=${m.t + hh - (t / max) * hh + 4} text-anchor="end">${fmt(t)}</text></g>`)}
    ${steps.map((s, i) => {
      let acc = 0;
      const x = m.l + i * slot + (slot - bw) / 2;
      return html`<g key=${s.id ?? i} style="cursor:pointer" onClick=${() => onSelect && onSelect(i)}
        onMouseMove=${(e) => tip.show(e, html`<b>${s.label}</b>${s.stack.map((p) => html`<div class="row"><span>${p.label}</span><span class="m">${fmt(p.value)}</span></div>`)}`)} onMouseLeave=${tip.hide}>
        <rect x=${m.l + i * slot} y=${m.t} width=${slot} height=${hh} fill=${selected === i ? 'var(--mark)' : 'transparent'} />
        ${s.stack.map((p, k) => {
          const hgt = ((p.value || 0) / max) * hh;
          const y = m.t + hh - acc - hgt; acc += hgt;
          return hgt > 0 ? html`<rect key=${k} x=${x} y=${y} width=${bw} height=${Math.max(0, hgt - (k < s.stack.length - 1 ? 1 : 0))} fill=${p.color} />` : null;
        })}
        ${(steps.length <= 40 || i % Math.ceil(steps.length / 20) === 0) && html`<text class="m" x=${x + bw / 2} y=${height - 3} text-anchor="middle" style=${{ fill: selected === i ? 'var(--ink)' : '' }}>${i + 1}</text>`}
      </g>`;
    })}
  </svg>`;
}

/** Forest plot: deltas with CIs around zero. rows: {label, delta, lo, hi, sig, color, sub} */
export function Forest({ rows, fmt = fmtNum, label }) {
  const [ref, W] = useWidth();
  const rowH = 28, m = { l: Math.min(240, Math.max(110, W * 0.3)), r: 16, t: 4, b: 22 };
  const H = m.t + m.b + rows.length * rowH;
  const vals = rows.flatMap((r) => [r.lo, r.hi, r.delta]).filter(isNum);
  if (!vals.length) return html`<div class="empty" ref=${ref}>no paired tasks</div>`;
  const ext = Math.max(...vals.map(Math.abs), 1e-9) * 1.08;
  const w = W - m.l - m.r, X = (v) => m.l + ((v + ext) / (2 * ext)) * w;
  const xt = ticks(-ext, ext, Math.max(3, Math.floor(w / 110)));
  return html`<svg ref=${ref} class="chart" viewBox="0 0 ${W} ${H}" height=${H} role="img" aria-label=${label || 'differences'}>
    ${xt.map((t) => html`<g key=${t}><line class="grid" x1=${X(t)} x2=${X(t)} y1=${m.t} y2=${H - m.b} /><text class="m" x=${X(t)} y=${H - 6} text-anchor="middle">${fmt(t)}</text></g>`)}
    <line x1=${X(0)} x2=${X(0)} y1=${m.t} y2=${H - m.b} stroke="var(--ink)" stroke-width="1.5" />
    ${rows.map((r, i) => {
      const y = m.t + i * rowH + rowH / 2;
      return html`<g key=${r.label} onMouseMove=${(e) => tip.show(e, html`<b>${r.label}</b><div class="row"><span>Δ</span><span class="m">${fmt(r.delta)}</span></div>${isNum(r.lo) ? html`<div class="row"><span>95% CI</span><span class="m">${fmt(r.lo)} … ${fmt(r.hi)}</span></div>` : ''}${r.sub ? html`<div style="opacity:.75">${r.sub}</div>` : ''}`)} onMouseLeave=${tip.hide}>
        <rect x="0" y=${y - rowH / 2} width=${W} height=${rowH} fill="transparent" />
        <text x=${m.l - 10} y=${y + 4} text-anchor="end" style="fill:var(--ink)">${trunc(r.label, Math.floor((m.l - 12) / 6.3))}</text>
        ${isNum(r.lo) && html`<line x1=${X(r.lo)} x2=${X(r.hi)} y1=${y} y2=${y} stroke=${r.color || 'var(--ink)'} stroke-width="2" /><line x1=${X(r.lo)} x2=${X(r.lo)} y1=${y - 4} y2=${y + 4} stroke=${r.color || 'var(--ink)'} stroke-width="2"/><line x1=${X(r.hi)} x2=${X(r.hi)} y1=${y - 4} y2=${y + 4} stroke=${r.color || 'var(--ink)'} stroke-width="2"/>`}
        ${isNum(r.delta) && html`<circle cx=${X(r.delta)} cy=${y} r="5" fill=${r.sig ? r.color || 'var(--ink)' : 'var(--paper)'} stroke=${r.color || 'var(--ink)'} stroke-width="2" />`}
      </g>`;
    })}
  </svg>`;
}

/** Histogram of values. */
export function Hist({ values, bins = 14, color = 'var(--s1)', fmt = fmtNum, height = 110 }) {
  const [ref, W] = useWidth();
  const v = values.filter(isNum);
  if (!v.length) return html`<div class="empty" ref=${ref}>no values</div>`;
  const lo = Math.min(...v), hi = Math.max(...v), span = hi - lo || 1, n = Math.min(bins, Math.max(3, new Set(v).size));
  const counts = Array(n).fill(0);
  v.forEach((x) => { counts[Math.min(n - 1, Math.floor(((x - lo) / span) * n))]++; });
  const m = { l: 6, r: 6, t: 4, b: 18 }, w = W - m.l - m.r, hh = height - m.t - m.b, M = Math.max(...counts), bw = w / n;
  return html`<svg ref=${ref} class="chart" viewBox="0 0 ${W} ${height}" height=${height}>
    ${counts.map((c, i) => html`<rect key=${i} x=${m.l + i * bw + 1} y=${m.t + hh - (c / M) * hh} width=${bw - 2} height=${(c / M) * hh} fill=${color}
      onMouseMove=${(e) => tip.show(e, html`<b>${fmt(lo + (i / n) * span)} – ${fmt(lo + ((i + 1) / n) * span)}</b><div class="row"><span>episodes</span><span class="m">${c}</span></div>`)} onMouseLeave=${tip.hide} />`)}
    <line class="axis" x1=${m.l} x2=${W - m.r} y1=${m.t + hh} y2=${m.t + hh} />
    <text class="m" x=${m.l} y=${height - 3}>${fmt(lo)}</text><text class="m" x=${W - m.r} y=${height - 3} text-anchor="end">${fmt(hi)}</text>
  </svg>`;
}

/** Tiny inline bar for tables: value 0..1. */
export function Meter({ value, color = 'var(--ink)', width = 64 }) {
  return html`<span class="mini-track" style=${{ width: width + 'px' }}><i class="mini-bar" style=${{ width: Math.max(0, Math.min(1, value || 0)) * 100 + '%', background: color, display: 'block', height: '4px', marginTop: '1px' }}></i></span>`;
}

/** Sequential colour for 0..1 (one hue, light → dark). */
export function seqColor(t) {
  if (!isNum(t)) return 'var(--sunk)';
  const i = Math.max(0, Math.min(6, Math.round(t * 6)));
  return `var(--seq-${i})`;
}
export const seqText = (t) => (isNum(t) && t > 0.55 ? 'var(--seq-ink-hi)' : 'var(--ink)');
