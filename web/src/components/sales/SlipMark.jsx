import { useEffect, useRef, useState } from 'react';

/*
 * The director's hand-drawn mark on a slip photo (109, 2026-11-06, the user):
 * a green tick for received, a red cross for a query, drawn by finger or mouse
 * straight on the slip, as on WhatsApp before. Points are kept 0..1 of the photo,
 * so the mark sits in the same place at any size; the stamp (initials, time)
 * sits in the corner.
 */
export const MARK_COLOR = { green: '#22c55e', red: '#ef4444' };
const lineWidth = w => Math.max(3, w * 0.014);

function paint(ctx, w, h, strokes, color) {
  ctx.clearRect(0, 0, w, h);
  ctx.strokeStyle = MARK_COLOR[color] ?? color;
  ctx.lineWidth = lineWidth(w);
  ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  for (const s of strokes) {
    if (!s.length) continue;
    ctx.beginPath();
    ctx.moveTo(s[0][0] * w, s[0][1] * h);
    for (const [x, y] of s.slice(1)) ctx.lineTo(x * w, y * h);
    if (s.length === 1) ctx.lineTo(s[0][0] * w + 0.1, s[0][1] * h);
    ctx.stroke();
  }
}

/** The slip photo with the mark over it; `pen` set (green|red) lets the user draw */
export function SlipCanvas({ url, strokes, color, pen, onStrokes, stamp }) {
  const img = useRef(null);
  const cvs = useRef(null);
  const drawing = useRef(null);
  const base = useRef([]);   // the strokes before the one being drawn
  const [size, setSize] = useState({ w: 0, h: 0 });
  useEffect(() => {
    const el = img.current; if (!el) return undefined;
    const ro = new ResizeObserver(() => setSize({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    return () => ro.disconnect();
  }, [url]);
  useEffect(() => {
    const c = cvs.current; if (!c || !size.w) return;
    const r = window.devicePixelRatio || 1;
    c.width = size.w * r; c.height = size.h * r;
    const ctx = c.getContext('2d'); ctx.setTransform(r, 0, 0, r, 0, 0);
    paint(ctx, size.w, size.h, strokes, pen || color);
  }, [size, strokes, pen, color]);
  const at = e => {
    const b = cvs.current.getBoundingClientRect();
    const k = v => Math.round(Math.min(1, Math.max(0, v)) * 1000) / 1000;
    return [k((e.clientX - b.left) / b.width), k((e.clientY - b.top) / b.height)];
  };
  const down = e => { if (!pen) return; e.preventDefault(); cvs.current.setPointerCapture(e.pointerId); base.current = strokes; drawing.current = [at(e)]; onStrokes([...base.current, drawing.current]); };
  const move = e => {
    if (!pen || !drawing.current) return;
    const p = at(e), last = drawing.current.at(-1);
    if (Math.hypot(p[0] - last[0], p[1] - last[1]) < 0.004) return;
    drawing.current = [...drawing.current, p];
    onStrokes([...base.current, drawing.current]);
  };
  const up = () => { drawing.current = null; };
  return (
    <div className={`slip-canvas${pen ? ' is-drawing' : ''}`}>
      <img ref={img} src={url} alt="Proof of payment" className="pp-photo" draggable={false} onLoad={e => setSize({ w: e.target.clientWidth, h: e.target.clientHeight })} />
      <canvas ref={cvs} style={{ width: size.w, height: size.h }} onPointerDown={down} onPointerMove={move} onPointerUp={up} onPointerCancel={up} />
      {stamp && <span className="slip-stamp" style={{ color: MARK_COLOR[color] }}>{stamp.who} · {stamp.at}</span>}
    </div>
  );
}

/** The slip with its mark and stamp, as one picture to keep on the device */
export async function markedSlipBlob(url, mark, stampText) {
  const im = new Image();
  im.crossOrigin = 'anonymous';
  im.src = url;
  await im.decode();
  const w = im.naturalWidth, h = im.naturalHeight;
  const c = document.createElement('canvas'); c.width = w; c.height = h;
  const ctx = c.getContext('2d');
  ctx.drawImage(im, 0, 0);
  const layer = document.createElement('canvas'); layer.width = w; layer.height = h;
  paint(layer.getContext('2d'), w, h, mark.strokes || [], mark.color);
  ctx.drawImage(layer, 0, 0);
  if (stampText) {
    const fs = Math.max(14, Math.round(w * 0.035));
    ctx.font = `700 ${fs}px sans-serif`;
    ctx.fillStyle = MARK_COLOR[mark.color];
    ctx.textAlign = 'right';
    ctx.fillText(stampText, w - fs * 0.6, h - fs * 0.6);
  }
  return new Promise(res => c.toBlob(res, 'image/jpeg', 0.92));
}
