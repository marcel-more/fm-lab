/**
 * Pan & zoom for a rendered Mermaid SVG (pele output) inside a viewport element.
 *
 * pele's own zoom fits to the width only and needs Ctrl/⌘ for the wheel; the
 * data-trace way view wants a map-like behaviour instead:
 *   - initial view and `fit()`: the whole diagram is visible (contain), centred;
 *   - mouse wheel zooms around the pointer;
 *   - click & drag pans (a drag of more than a few pixels suppresses the click
 *     that follows, so dragging over a node does not open it);
 *   - `zoomBy()` for buttons (around the viewport centre).
 *
 * Option `readableScale`: when the fitted diagram would be smaller than this
 * scale (long one-line chains), the initial view starts at that scale at the
 * left edge, vertically centred — the start of a left-to-right way stays
 * readable; `fit()` still shows the whole diagram.
 *
 * The SVG keeps its natural size (width/height attributes) and is moved with a
 * CSS transform; the viewport clips (`overflow: hidden`). The caller mounts the
 * diagram with pele's zoom switched off and calls `attach()` after each render.
 */

export interface PanZoom {
  /** Bind to the freshly rendered SVG (after every pele render) and fit it. */
  attach(svg: SVGSVGElement): void;
  /** Whole diagram visible, centred. */
  fit(): void;
  /** Zoom by a factor around the viewport centre. */
  zoomBy(factor: number): void;
  /** True right after a drag — the click that ends the drag is swallowed. */
  readonly dragging: boolean;
  destroy(): void;
}

const MIN_SCALE = 0.02;
const MAX_SCALE = 6;
const DRAG_THRESHOLD = 4;

export function createPanZoom(viewport: HTMLElement, opts: { readableScale?: number } = {}): PanZoom {
  const readable = opts.readableScale ?? 0;
  let svg: SVGSVGElement | null = null;
  let natW = 0;
  let natH = 0;
  let s = 1;
  let x = 0;
  let y = 0;
  let minScale = MIN_SCALE;
  let touched = false; // the user zoomed/panned → keep the view on resize
  let dragging = false;

  const apply = () => {
    if (svg) svg.style.transform = `translate(${x}px, ${y}px) scale(${s})`;
  };

  const fitScale = () => {
    const w = viewport.clientWidth;
    const h = viewport.clientHeight;
    if (!natW || !natH || !w || !h) return 1;
    return Math.min(w / natW, h / natH, 1);
  };

  const fit = () => {
    if (!svg) return;
    s = fitScale();
    minScale = Math.max(MIN_SCALE, s / 2);
    x = (viewport.clientWidth - natW * s) / 2;
    y = (viewport.clientHeight - natH * s) / 2;
    touched = false;
    apply();
  };

  /** Initial view: fit, or — if that is too small to read — readable at the left edge. */
  const startView = () => {
    if (!svg) return;
    const f = fitScale();
    if (!readable || f >= readable) {
      fit();
      return;
    }
    s = readable;
    minScale = Math.max(MIN_SCALE, f / 2);
    x = 8;
    y = (viewport.clientHeight - natH * s) / 2;
    touched = false;
    apply();
  };

  /** Zoom to `next` keeping the viewport point (px, py) fixed. */
  const zoomAt = (next: number, px: number, py: number) => {
    const clamped = Math.min(MAX_SCALE, Math.max(minScale, next));
    if (!svg || clamped === s) return;
    x = px - ((px - x) * clamped) / s;
    y = py - ((py - y) * clamped) / s;
    s = clamped;
    touched = true;
    apply();
  };

  const onWheel = (e: WheelEvent) => {
    if (!svg) return;
    e.preventDefault();
    // Lines/pages → pixels; clamp so a fast wheel does not jump.
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? viewport.clientHeight : 1;
    const delta = Math.max(-120, Math.min(120, e.deltaY * unit));
    const r = viewport.getBoundingClientRect();
    zoomAt(s * Math.exp(-delta * 0.0025), e.clientX - r.left, e.clientY - r.top);
  };

  let pointer: { id: number; x: number; y: number; moved: number } | null = null;
  const onDown = (e: PointerEvent) => {
    if (!svg || (e.pointerType === 'mouse' && e.button !== 0)) return;
    // Controls (buttons) sit above the viewport content — not a drag start.
    if ((e.target as Element | null)?.closest?.('button')) return;
    pointer = { id: e.pointerId, x: e.clientX, y: e.clientY, moved: 0 };
    dragging = false;
  };
  const onMove = (e: PointerEvent) => {
    if (!pointer || e.pointerId !== pointer.id) return;
    const dx = e.clientX - pointer.x;
    const dy = e.clientY - pointer.y;
    pointer.x = e.clientX;
    pointer.y = e.clientY;
    pointer.moved += Math.abs(dx) + Math.abs(dy);
    if (!dragging && pointer.moved > DRAG_THRESHOLD) {
      dragging = true;
      try {
        viewport.setPointerCapture?.(e.pointerId);
      } catch {
        /* pointer already gone (e.g. released outside) — pan without capture */
      }
      viewport.classList.add('is-panning');
    }
    if (dragging) {
      x += dx;
      y += dy;
      touched = true;
      apply();
    }
  };
  const onUp = (e: PointerEvent) => {
    if (!pointer || e.pointerId !== pointer.id) return;
    pointer = null;
    viewport.classList.remove('is-panning');
    if (dragging) {
      // The click event follows pointerup synchronously — reset afterwards.
      window.setTimeout(() => { dragging = false; }, 0);
    }
  };
  const onClickCapture = (e: MouseEvent) => {
    if (dragging) {
      e.stopPropagation();
      e.preventDefault();
    }
  };

  viewport.addEventListener('wheel', onWheel, { passive: false });
  viewport.addEventListener('pointerdown', onDown);
  viewport.addEventListener('pointermove', onMove);
  viewport.addEventListener('pointerup', onUp);
  viewport.addEventListener('pointercancel', onUp);
  viewport.addEventListener('click', onClickCapture, true);

  // Keep the whole diagram in view while the user has not moved it (window
  // resize, full screen on/off); a moved view stays where it is.
  const ro = typeof ResizeObserver !== 'undefined'
    ? new ResizeObserver(() => { if (!touched) startView(); })
    : null;
  ro?.observe(viewport);

  return {
    attach(next: SVGSVGElement) {
      svg = next;
      const vb = svg.viewBox?.baseVal;
      natW = Number(svg.getAttribute('width')) || vb?.width || svg.getBBox().width;
      natH = Number(svg.getAttribute('height')) || vb?.height || svg.getBBox().height;
      svg.style.maxWidth = 'none';
      svg.style.width = `${natW}px`;
      svg.style.height = `${natH}px`;
      svg.style.transformOrigin = '0 0';
      svg.style.position = 'absolute';
      svg.style.left = '0';
      svg.style.top = '0';
      startView();
    },
    fit,
    zoomBy(factor: number) {
      zoomAt(s * factor, viewport.clientWidth / 2, viewport.clientHeight / 2);
    },
    get dragging() {
      return dragging;
    },
    destroy() {
      ro?.disconnect();
      viewport.removeEventListener('wheel', onWheel);
      viewport.removeEventListener('pointerdown', onDown);
      viewport.removeEventListener('pointermove', onMove);
      viewport.removeEventListener('pointerup', onUp);
      viewport.removeEventListener('pointercancel', onUp);
      viewport.removeEventListener('click', onClickCapture, true);
    },
  };
}
