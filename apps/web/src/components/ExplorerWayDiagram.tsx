import { useCallback, useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { MermaidError, MermaidHandle } from '../lib/mermaid/renderMermaid';
import { createPanZoom, type PanZoom } from '../lib/mermaid/panZoom';
import type { WayMermaid } from '../lib/traceWays';

/**
 * Mermaid view of one way of a trace (flow or data mode; way 0 = overview), an
 * overlay above the Explorer canvas. The host hands in the loader: the source
 * comes from the server (`ways_mermaid=true`), fetched once per trace params
 * and cached for the page life by the trace hooks; pele renders it in the
 * browser (lazy chunk, shared with the dashboard primitive). A click on a node
 * hands the mapped id to the host (graph id, flow-trace step key or entry-group
 * key), which selects it in the canvas or opens its details. Resting the
 * pointer on a node (or focusing it by keyboard) hands the same id to
 * `onHoverNode`, which highlights the matching canvas node; leaving it,
 * switching the way or closing the overlay hands `null`.
 *
 * Navigation: own pan & zoom (lib/mermaid/panZoom — wheel zooms around the
 * pointer, drag pans, whole diagram visible at start) instead of pele's zoom;
 * buttons full screen · + · − · fit at the top right.
 *
 * Height: a grip on the top edge drags the overlay taller or lower (share of
 * the canvas height, remembered per browser like the side panel widths; a
 * double click restores the default). Hidden in full screen.
 */

/** Overlay height as a share of the canvas (%) — default and drag bounds. */
const DIAGRAM_HEIGHT_DEFAULT = 60;
const DIAGRAM_HEIGHT_MIN = 20;
const DIAGRAM_HEIGHT_MAX = 95;
const DIAGRAM_HEIGHT_KEY = 'fmlab.explorer.diagramHeight';

function readDiagramHeight(): number {
  try {
    const v = Number(localStorage.getItem(DIAGRAM_HEIGHT_KEY));
    return Number.isFinite(v) && v >= DIAGRAM_HEIGHT_MIN && v <= DIAGRAM_HEIGHT_MAX ? v : DIAGRAM_HEIGHT_DEFAULT;
  } catch {
    return DIAGRAM_HEIGHT_DEFAULT;
  }
}


interface ExplorerWayDiagramProps {
  /** Identity of the diagram (trace params + way + direction) — a change reloads. */
  loadKey: string;
  /** Loads the way's source; null = the server has no diagram for this way. */
  load: () => Promise<WayMermaid | null>;
  title: string;
  onClose: () => void;
  onPickNode: (id: string) => void;
  /** Pointer / focus on a mapped node (its id) or off it (null) — canvas preview. */
  onHoverNode?: (id: string | null) => void;
  /** Minimum scale of the initial view (long chains start readable at the left); omitted = fit. */
  readableScale?: number;
}

export function ExplorerWayDiagram({ loadKey, load, title, onClose, onPickNode, onHoverNode, readableScale }: ExplorerWayDiagramProps) {
  const { t } = useTranslation(['explorer']);
  const [way, setWay] = useState<WayMermaid | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [renderError, setRenderError] = useState<MermaidError | null>(null);
  const [copied, setCopied] = useState(false);
  // Vollbild: das Overlay füllt das Browserfenster; ✕ bzw. Esc stellt die
  // vorige Größe wieder her (Pan & Zoom passt die Ansicht beim Größenwechsel an).
  const [fullscreen, setFullscreen] = useState(false);
  useEffect(() => {
    if (!fullscreen) return undefined;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      // Vor dem Escape-Stack der Ansicht (der sonst zurück navigiert).
      e.stopPropagation();
      e.preventDefault();
      setFullscreen(false);
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [fullscreen]);

  // Höhe per Anfasser an der Oberkante (Anteil des Canvas, in localStorage gemerkt).
  const sectionRef = useRef<HTMLElement>(null);
  const [heightPct, setHeightPct] = useState(readDiagramHeight);
  useEffect(() => {
    try { localStorage.setItem(DIAGRAM_HEIGHT_KEY, String(heightPct)); } catch { /* ignore */ }
  }, [heightPct]);
  const onResizeStart = useCallback((e: React.PointerEvent) => {
    const host = sectionRef.current?.offsetParent as HTMLElement | null;
    const section = sectionRef.current;
    if (!host || !section || host.clientHeight === 0) return;
    e.preventDefault();
    const startY = e.clientY;
    const startPx = section.getBoundingClientRect().height;
    const hostPx = host.clientHeight;
    const prevCursor = document.body.style.cursor;
    const prevSelect = document.body.style.userSelect;
    document.body.style.cursor = 'row-resize';
    document.body.style.userSelect = 'none';
    const onMove = (ev: PointerEvent) => {
      const pct = ((startPx + startY - ev.clientY) / hostPx) * 100;
      setHeightPct(Math.round(Math.min(DIAGRAM_HEIGHT_MAX, Math.max(DIAGRAM_HEIGHT_MIN, pct)) * 10) / 10);
    };
    const onUp = () => {
      document.body.style.cursor = prevCursor;
      document.body.style.userSelect = prevSelect;
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
    };
    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp);
  }, []);
  const boxRef = useRef<HTMLDivElement>(null);
  const handleRef = useRef<MermaidHandle | null>(null);
  const panZoomRef = useRef<PanZoom | null>(null);

  // Pan & Zoom lebt so lange wie die Box; nach jedem Rendern an das neue SVG binden.
  useEffect(() => {
    const el = boxRef.current;
    if (!el) return undefined;
    const pz = createPanZoom(el, { readableScale });
    panZoomRef.current = pz;
    return () => {
      pz.destroy();
      panZoomRef.current = null;
    };
  }, []);
  const afterRender = useCallback((el: HTMLElement, ids: Record<string, string>) => {
    const svg = el.querySelector<SVGSVGElement>(':scope > svg');
    if (svg) panZoomRef.current?.attach(svg);
    el.querySelectorAll<SVGGElement>('.pele-node[data-id]').forEach((g) => {
      if (!ids[g.getAttribute('data-id') || '']) return;
      g.classList.add('explorer-data-diagram-node');
      g.setAttribute('tabindex', '0');
      g.setAttribute('role', 'button');
    });
  }, []);

  useEffect(() => {
    let cancelled = false;
    setWay(null);
    setLoadError(null);
    load()
      .then((w) => {
        if (cancelled) return;
        if (w && w.text) setWay(w);
        else setLoadError(t('trace.ways.diagramMissing') as string);
      })
      .catch((err: unknown) => {
        if (!cancelled) setLoadError(err instanceof Error ? err.message : String(err));
      });
    return () => {
      cancelled = true;
    };
    // `loadKey` encodes every input of `load`.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [loadKey]);

  useEffect(() => {
    const el = boxRef.current;
    if (!el || !way) return undefined;
    let cancelled = false;
    setRenderError(null);
    import('../lib/mermaid/renderMermaid')
      .then(({ mountMermaid }) => {
        if (cancelled) return undefined;
        if (handleRef.current) {
          return handleRef.current.update(way.text).then(() => afterRender(el, way.ids));
        }
        return mountMermaid(el, way.text, {
          zoom: false,
          onError: (e) => { if (!cancelled) setRenderError(e); },
          onRender: (target) => afterRender(target, way.ids),
        }).then((h) => {
          if (cancelled) h.destroy();
          else handleRef.current = h;
        });
      })
      .catch((e: unknown) => {
        if (!cancelled) setRenderError({ code: 'unknown', message: String((e as Error)?.message ?? e), line: 0, column: 0, snippet: '' });
      });
    return () => {
      cancelled = true;
    };
  }, [way, afterRender]);

  useEffect(() => () => {
    handleRef.current?.destroy();
    handleRef.current = null;
  }, []);

  /** Mapped id of the diagram node under `target`; null outside a mapped node. */
  const nodeIdOf = (target: EventTarget | null): string | null => {
    if (!way) return null;
    const g = (target as Element | null)?.closest?.('.pele-node[data-id]');
    return (g && way.ids[g.getAttribute('data-id') || '']) || null;
  };

  const activate = (target: EventTarget | null) => {
    const id = nodeIdOf(target);
    if (!id) return false;
    onPickNode(id);
    return true;
  };

  // Hover preview: report only changes; the latest callback lives in a ref so
  // the reset on way change / unmount reaches the current host.
  const hoverRef = useRef<string | null>(null);
  const onHoverRef = useRef(onHoverNode);
  onHoverRef.current = onHoverNode;
  const hover = (id: string | null) => {
    if (hoverRef.current === id) return;
    hoverRef.current = id;
    onHoverRef.current?.(id);
  };
  useEffect(() => () => {
    if (hoverRef.current === null) return;
    hoverRef.current = null;
    onHoverRef.current?.(null);
  }, [way]);

  const copy = async () => {
    if (!way) return;
    try {
      await navigator.clipboard.writeText(way.text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1500);
    } catch {
      /* clipboard unavailable — no feedback */
    }
  };

  return (
    <section
      ref={sectionRef}
      className={`explorer-data-diagram${fullscreen ? ' is-fullscreen' : ''}`}
      style={fullscreen ? undefined : { height: `${heightPct}%` }}
      aria-label={title}
      role={fullscreen ? 'dialog' : undefined}
      aria-modal={fullscreen ? true : undefined}
    >
      {!fullscreen && (
        <div
          className="explorer-data-diagram-resizer"
          role="separator"
          aria-orientation="horizontal"
          aria-label={t('trace.ways.resizeDiagram') as string}
          title={t('trace.ways.resizeDiagram') as string}
          onPointerDown={onResizeStart}
          onDoubleClick={() => setHeightPct(DIAGRAM_HEIGHT_DEFAULT)}
        />
      )}
      <div className="explorer-data-diagram-head">
        <h3 title={title}>{title}</h3>
        <button type="button" className="explorer-focus-details" onClick={copy} disabled={!way} title={t('trace.ways.copySourceHint') as string}>
          {copied ? t('trace.ways.copied') : t('trace.ways.copySource')}
        </button>
        {/* Im Vollbild schließt nur das ✕ am Diagramm (zurück zur vorigen Größe). */}
        {!fullscreen && (
          <button type="button" className="explorer-inspect-close" onClick={onClose} aria-label={t('common:close', { defaultValue: 'Schließen' }) as string}>
            ✕
          </button>
        )}
      </div>
      {!way && !loadError && <p className="explorer-data-hint">{t('loading')}</p>}
      {loadError && <p className="explorer-data-error" role="alert">{loadError}</p>}
      {renderError && (
        <div className="explorer-data-error" role="alert">
          <strong>{t('trace.ways.diagramError')}</strong>
          {renderError.line > 0 && <> · {renderError.line}:{renderError.column}</>}
          <pre>{renderError.snippet || renderError.message}</pre>
        </div>
      )}
      <div className="explorer-data-diagram-stage">
        <div
          ref={boxRef}
          className="explorer-data-diagram-box"
          onClick={(e) => { activate(e.target); }}
          // Maus-Events wie die Wege-Listen (mouseleave → null): Pointer-Events
          // feuern vor den Maus-Events derselben Bewegung, das mouseleave der
          // Liste löschte sonst die eben gesetzte Vorschau. Kein Wechsel, solange
          // gezogen wird (Pan des Diagramms).
          onMouseOver={(e) => { if (e.buttons === 0) hover(nodeIdOf(e.target)); }}
          onMouseLeave={() => hover(null)}
          onFocus={(e) => hover(nodeIdOf(e.target))}
          onBlur={() => hover(null)}
          onKeyDown={(e) => {
            if ((e.key === 'Enter' || e.key === ' ') && activate(e.target)) e.preventDefault();
          }}
        />
        {/* Bedienleiste rechts oben: Vollbild, darunter + · − · Einpassen. */}
        <div className="explorer-data-diagram-ctl">
          <div className="explorer-data-diagram-fs">
            <CtlButton
              label={t(fullscreen ? 'trace.ways.fullscreenExit' : 'trace.ways.fullscreen') as string}
              path={fullscreen ? 'M6 6l12 12M18 6L6 18' : 'M15 3h6v6M21 3l-7 7M9 21H3v-6M3 21l7-7'}
              pressed={fullscreen}
              onClick={() => setFullscreen((f) => !f)}
            />
          </div>
          <div className="explorer-data-diagram-fs">
            <CtlButton label={t('trace.ways.zoomIn') as string} path="M5 12h14M12 5v14" onClick={() => panZoomRef.current?.zoomBy(1.25)} />
            <CtlButton label={t('trace.ways.zoomOut') as string} path="M5 12h14" onClick={() => panZoomRef.current?.zoomBy(0.8)} />
            <CtlButton label={t('trace.ways.zoomFit') as string} path="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" onClick={() => panZoomRef.current?.fit()} />
          </div>
        </div>
      </div>
    </section>
  );
}

/** Icon button of the diagram's control bar (24 px, stroke icon). */
function CtlButton(props: { label: string; path: string; pressed?: boolean; onClick: () => void }) {
  const { label, path, pressed, onClick } = props;
  return (
    <button type="button" onClick={onClick} aria-pressed={pressed} aria-label={label} title={label}>
      <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d={path} />
      </svg>
    </button>
  );
}
