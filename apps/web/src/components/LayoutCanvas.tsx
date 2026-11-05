import { forwardRef, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { LayoutData, LayoutObject } from '../hooks/useLayoutData';
import { useLayoutSearch } from '../hooks/useLayoutSearch';
import { HighlightRing, LayoutObjectShape, SelectionRing, type LabelMode } from './LayoutObjectShape';
import { LayoutObjectTooltip } from './LayoutObjectTooltip';
import { LayoutTypeFilter } from './LayoutTypeFilter';
import { buildObjectPath } from '../lib/navigation';
import { resolveCrossNavTarget } from '../lib/layoutObjectNav';

type Props = {
  data: LayoutData;
  /**
   * Cross-Reference Highlight:
   * Externe UUID-Vorauswahl, die als weicher Filter wirkt, solange der User
   * nicht selbst sucht oder einen Typ-Filter setzt.
   */
  externalMatchUuids?: Set<string> | null;
  /**
   * Callback, der bei explizitem User-Eingriff (Suche tippen, Typ-Filter
   * aktivieren) gefeuert wird. Entfernt typischerweise den `?ref=`-Param aus
   * der URL und beendet damit den Referenz-Modus.
   */
  onClearRef?: () => void;
  /**
   * Meldet die Anzahl der tatsächlich im Canvas hervorgehobenen Ref-Treffer
   * nach oben (RefOriginPill) — nur solange die externe Ref-Vorauswahl den
   * Filter treibt; eigene Suche/Typ-Filter beenden den Ref-Modus ohnehin.
   */
  onLiveMatchCount?: (count: number) => void;
};

/**
 * Imperatives Handle für die ESC-Stack-Verdrahtung in LayoutView.
 * Status-Getter werden bei jedem ESC-Druck live aufgerufen.
 */
export type LayoutCanvasHandle = {
  hasTooltip: () => boolean;
  closeTooltip: () => void;
  hasSearchState: () => boolean;
  clearSearch: () => void;
  hasFilters: () => boolean;
  clearFilters: () => void;
};

const PADDING = 40;
const MIN_SCALE = 0.1;
const MAX_SCALE = 5;
const PAN_MARGIN = 40;

type ViewTransform = { tx: number; ty: number; scale: number };

function computeViewport(objects: LayoutObject[], parts: LayoutData['parts']) {
  if (objects.length === 0 && parts.length === 0) {
    return { minX: 0, minY: 0, maxX: 800, maxY: 600 };
  }
  let minX = 0, minY = 0, maxX = 800, maxY = 600;
  for (const o of objects) {
    if (o.abs_left < minX) minX = o.abs_left;
    if (o.abs_top < minY) minY = o.abs_top;
    if (o.abs_right > maxX) maxX = o.abs_right;
    if (o.abs_bottom > maxY) maxY = o.abs_bottom;
  }
  for (const p of parts) {
    if (p.part_absolute < minY) minY = p.part_absolute;
    const bottom = p.part_absolute + p.part_size;
    if (bottom > maxY) maxY = bottom;
  }
  return { minX, minY, maxX, maxY };
}

const PART_FILL: Record<string, string> = {
  Header: '#f0f4ff',
  Footer: '#fff8f0',
};

export const LayoutCanvas = forwardRef<LayoutCanvasHandle, Props>(({ data, externalMatchUuids, onClearRef, onLiveMatchCount }, externalRef) => {
  const { t } = useTranslation(['common', 'detail']);
  const navigate = useNavigate();
  // Aktuelle Detail-View-UUID — wird als Origin für Cross-Nav-Klicks mitgegeben.
  // Auf der Vollbild-Layout-View (/layout/:uuid) ist es das Layout selbst;
  // bei eingebetteter Nutzung in der DetailView ist es das Detail-Objekt.
  const { uuid: currentUuid } = useParams<{ uuid: string }>();
  const containerRef = useRef<HTMLDivElement>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);
  const [transform, setTransform] = useState<ViewTransform>({ tx: 0, ty: 0, scale: 1 });
  const dragRef = useRef<{ startX: number; startY: number; tx: number; ty: number } | null>(null);
  const [labelMode, setLabelMode] = useState<LabelMode>('name');
  const [filterDetailsMode, setFilterDetailsMode] = useState(false);
  const [hoverState, setHoverState] = useState<{ uuid: string; x: number; y: number } | null>(null);

  const search = useLayoutSearch(data.objects, externalMatchUuids ?? null, onClearRef);

  // Ref-getriebener Match-Report für die RefOriginPill: back_references liefert
  // für LayoutObject-Refs keine Container-Matches (matchCount 0), der Canvas
  // kennt die echte Trefferzahl. Nur melden, solange weder Suche noch Typ-Filter
  // aktiv sind — sonst gehört die Fundmenge dem User, nicht der Referenz.
  const refDriven = !!(externalMatchUuids && externalMatchUuids.size > 0)
    && search.query === '' && search.activeTypes.size === 0 && search.activeCalc.size === 0;
  const refMatchCount = refDriven ? search.matches.length : null;
  useEffect(() => {
    if (refMatchCount !== null) onLiveMatchCount?.(refMatchCount);
  }, [refMatchCount, onLiveMatchCount]);

  const viewport = useMemo(
    () => computeViewport(data.objects, data.parts),
    [data.objects, data.parts]
  );
  const objectsByUuid = useMemo(() => {
    const m = new Map<string, LayoutObject>();
    for (const o of data.objects) m.set(o.object_uuid, o);
    return m;
  }, [data.objects]);

  const fitToViewport = useCallback(() => {
    if (!containerRef.current) return;
    const rect = containerRef.current.getBoundingClientRect();
    const w = viewport.maxX - viewport.minX + 2 * PADDING;
    const h = viewport.maxY - viewport.minY + 2 * PADDING;
    if (w <= 0 || h <= 0 || rect.width <= 0 || rect.height <= 0) return;
    const scale = Math.min(rect.width / w, rect.height / h, MAX_SCALE);
    const tx = -viewport.minX * scale + PADDING * scale;
    const ty = -viewport.minY * scale + PADDING * scale;
    setTransform({ tx, ty, scale });
  }, [viewport]);

  const reset100 = () => {
    if (!containerRef.current) return;
    const rect = containerRef.current.getBoundingClientRect();
    const tx = rect.width / 2 - (viewport.minX + viewport.maxX) / 2;
    const ty = rect.height / 2 - (viewport.minY + viewport.maxY) / 2;
    setTransform({ tx, ty, scale: 1 });
  };

  // Initial: Fit to viewport beim Wechsel des Layouts
  useEffect(() => {
    const id = requestAnimationFrame(fitToViewport);
    return () => cancelAnimationFrame(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [data.layoutName]);

  // Auto-Pan auf selektiertes Objekt — gleiche Logik wie RelationshipGraph.
  useEffect(() => {
    if (!search.selectedUuid || !containerRef.current) return;
    const o = objectsByUuid.get(search.selectedUuid);
    if (!o) return;
    const rect = containerRef.current.getBoundingClientRect();
    const screenX = o.abs_left * transform.scale + transform.tx;
    const screenY = o.abs_top * transform.scale + transform.ty;
    const screenW = (o.abs_right - o.abs_left) * transform.scale;
    const screenH = (o.abs_bottom - o.abs_top) * transform.scale;
    const outOfView =
      screenX < PAN_MARGIN ||
      screenY < PAN_MARGIN ||
      screenX + screenW > rect.width - PAN_MARGIN ||
      screenY + screenH > rect.height - PAN_MARGIN;
    if (!outOfView) return;
    const targetTx = rect.width / 2 - (o.abs_left + (o.abs_right - o.abs_left) / 2) * transform.scale;
    const targetTy = rect.height / 2 - (o.abs_top + (o.abs_bottom - o.abs_top) / 2) * transform.scale;
    setTransform(prev => ({ ...prev, tx: targetTx, ty: targetTy }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search.selectedUuid, transform.scale, objectsByUuid]);

  const onMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    if ((e.target as Element).closest('.layout-object')) return;
    dragRef.current = {
      startX: e.clientX,
      startY: e.clientY,
      tx: transform.tx,
      ty: transform.ty,
    };
    setHoverState(null);
  };

  const onMouseMove = (e: React.MouseEvent) => {
    if (!dragRef.current) return;
    const dx = e.clientX - dragRef.current.startX;
    const dy = e.clientY - dragRef.current.startY;
    setTransform(prev => ({ ...prev, tx: dragRef.current!.tx + dx, ty: dragRef.current!.ty + dy }));
  };

  const endDrag = () => {
    dragRef.current = null;
  };

  const onWheel = (e: React.WheelEvent) => {
    e.preventDefault();
    if (!containerRef.current) return;
    const rect = containerRef.current.getBoundingClientRect();
    const cx = e.clientX - rect.left;
    const cy = e.clientY - rect.top;
    const delta = -e.deltaY * 0.001;
    setTransform(prev => {
      const nextScale = Math.min(MAX_SCALE, Math.max(MIN_SCALE, prev.scale * (1 + delta)));
      const ratio = nextScale / prev.scale;
      const tx = cx - (cx - prev.tx) * ratio;
      const ty = cy - (cy - prev.ty) * ratio;
      return { tx, ty, scale: nextScale };
    });
  };

  // Klick-Semantik (Primär = Detail, Modifier = Ziel): Primärklick öffnet für
  // ALLE Objekttypen die LayoutObject-Detail (die Zwischeninstanz trägt Hide/
  // Trigger/CF-Logik); Alt-Klick (macOS ⌥) springt zum gehoisteten Ziel
  // (Feld/Script/Portal-TO/Go-to-Layout). `file` geht in beide Pfade mit —
  // Klon-Disambiguierung, kein AMBIGUOUS_UUID-409 mehr.
  const handleObjectClick = (o: LayoutObject, opts?: { modifier?: boolean }) => {
    const target = opts?.modifier ? resolveCrossNavTarget(o) : o.object_uuid;
    // Layout-UUID als Origin mitgeben — der Ziel-View weiß, woher der Klick kam.
    navigate(buildObjectPath(target, currentUuid ?? null, data.fileName || null));
  };

  const handleShapeMouseEnter = useCallback((uuid: string, x: number, y: number) => {
    if (dragRef.current) return;
    setHoverState({ uuid, x, y });
  }, []);

  const handleShapeMouseMove = useCallback((x: number, y: number) => {
    if (dragRef.current) return;
    setHoverState(prev => prev ? { ...prev, x, y } : prev);
  }, []);

  const handleShapeMouseLeave = useCallback(() => {
    setHoverState(null);
  }, []);

  // Live-Refs für den imperative Handle, damit useEscapeStack keinen
  // re-attach pro State-Änderung braucht.
  const searchStateRef = useRef(search);
  searchStateRef.current = search;
  const hoverStateRef = useRef(hoverState);
  hoverStateRef.current = hoverState;

  useImperativeHandle(externalRef, () => ({
    hasTooltip: () => hoverStateRef.current !== null,
    closeTooltip: () => setHoverState(null),
    // Bewusst nur query prüfen — selectedUuid wird bei matches.length===1 vom
    // useLayoutSearch-Effekt automatisch wieder gesetzt; das würde Stage 2 in
    // einer Endlos-Schleife festhalten und Stage 3 (Filter) nie erreichen.
    // Selektion verschwindet von selbst, sobald die Folge-Stage Filter räumt.
    hasSearchState: () => searchStateRef.current.query !== '',
    clearSearch: () => {
      searchStateRef.current.setQuery('');
      // Vorhandene Selektion zusätzlich wegräumen, damit der ESC-Druck
      // sichtbar wirkt; bleibt durch matches-Effekt nur bestehen, wenn
      // Filter restriktiv sind (Stage 3 räumt das im nächsten Druck).
      searchStateRef.current.clear();
    },
    hasFilters: () => searchStateRef.current.activeTypes.size > 0
      || searchStateRef.current.activeCalc.size > 0,
    clearFilters: () => searchStateRef.current.clearTypes(),
  }), []);

  const onSearchKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    // ESC bewusst nicht lokal abfangen — globaler ESC-Stack auf LayoutView-Ebene
    // regelt die Stufenlogik (Tooltip → Suche/Selektion → Filter → Zurück).
    if (e.key === 'Tab') {
      e.preventDefault();
      if (e.shiftKey) search.selectPrev();
      else search.selectNext();
    } else if (e.key === 'Enter' && search.selectedUuid) {
      e.preventDefault();
      const o = objectsByUuid.get(search.selectedUuid);
      // Enter → LayoutObject-Detail; Alt+Enter → gehoistetes Ziel.
      if (o) handleObjectClick(o, { modifier: e.altKey });
    }
  };

  const onSearchChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    search.setQuery(e.target.value);
  };

  const hoverObject = hoverState ? objectsByUuid.get(hoverState.uuid) : null;
  const filterActive = search.filterActive;

  // Inventar-Deeplinks der Calc-Chips: Layout-Scope über file + scope_uuids
  // (= L_UUID). Die Queries akzeptieren beide Params (S-Block auf ly.L_UUID).
  const layoutUuid = data.meta?.layout_uuid ?? data.parts[0]?.layout_uuid ?? null;
  const calcInventoryUrls = useMemo(() => {
    if (!layoutUuid) return undefined;
    const scope = `?file=${encodeURIComponent(data.fileName)}&scope_uuids=${encodeURIComponent(layoutUuid)}`;
    return {
      cf: `/dashboard/conditional_formatting_inventory${scope}`,
      hide: `/dashboard/hide_condition_inventory${scope}`,
      trigger: `/dashboard/script_trigger_inventory${scope}`,
      tooltip: `/dashboard/tooltip_inventory${scope}`,
      display: `/dashboard/layout_calculation_inventory${scope}`,
    };
  }, [layoutUuid, data.fileName]);

  return (
    <div className="layout-canvas-wrapper">
      <div className="layout-toolbar">
        <div className="layout-toolbar-row">
          <div className="layout-search">
            <input
              ref={searchInputRef}
              type="search"
              placeholder={t('detail:layoutCanvas.searchPlaceholder') as string}
              value={search.query}
              onChange={onSearchChange}
              onKeyDown={onSearchKeyDown}
              title={t('detail:layoutCanvas.searchTitle') as string}
              aria-label={t('detail:layoutCanvas.searchAria') as string}
            />
            {filterActive && (
              <span className="layout-match-count">
                {t('detail:layoutCanvas.matchCount', { count: search.matches.length })}
              </span>
            )}
          </div>

          <div className="layout-label-toggle" role="group" aria-label={t('detail:layoutCanvas.labelGroupAria') as string}>
            <button
              type="button"
              className={`layout-toggle-btn${labelMode === 'name' ? ' active' : ''}`}
              onClick={() => setLabelMode('name')}
              title={t('detail:layoutCanvas.labelNameTitle') as string}
            >{t('detail:layoutCanvas.labelName')}</button>
            <button
              type="button"
              className={`layout-toggle-btn${labelMode === 'type' ? ' active' : ''}`}
              onClick={() => setLabelMode('type')}
              title={t('detail:layoutCanvas.labelTypeTitle') as string}
            >{t('detail:layoutCanvas.labelType')}</button>
          </div>

          <button onClick={fitToViewport} type="button" title={t('common:actions.fitToViewport') as string}>{t('common:actions.fit')}</button>
          <button onClick={reset100} type="button" title={t('common:actions.originalSize') as string}>100%</button>
          <span className="layout-stats">
            {t('detail:layoutCanvas.stats', {
              count: data.objects.length,
              zoom: (transform.scale * 100).toFixed(0),
            })}
          </span>
        </div>

        <LayoutTypeFilter
          objects={data.objects}
          activeTypes={search.activeTypes}
          onToggle={search.toggleType}
          onSetTypes={search.setTypes}
          onClear={search.clearTypes}
          detailsMode={filterDetailsMode}
          onToggleDetailsMode={() => setFilterDetailsMode(p => !p)}
          activeCalc={search.activeCalc}
          onToggleCalc={search.toggleCalc}
          calcInventoryUrls={calcInventoryUrls}
        />
      </div>

      <div
        ref={containerRef}
        className="layout-canvas"
        onMouseDown={onMouseDown}
        onMouseMove={onMouseMove}
        onMouseUp={endDrag}
        onMouseLeave={endDrag}
        onWheel={onWheel}
        style={{ cursor: dragRef.current ? 'grabbing' : 'grab' }}
      >
        <svg width="100%" height="100%" style={{ display: 'block', userSelect: 'none' }}>
          <g transform={`translate(${transform.tx},${transform.ty}) scale(${transform.scale})`}>
            {/* Layout-Parts als Hintergrund-Streifen */}
            {data.parts.map(p => (
              <g key={p.part_kind}>
                <rect
                  x={viewport.minX - 5}
                  y={p.part_absolute}
                  width={viewport.maxX - viewport.minX + 10}
                  height={p.part_size}
                  fill={PART_FILL[p.part_type] ?? '#f8f9fa'}
                  fillOpacity={0.4}
                  stroke="#cccccc"
                  strokeWidth={0.5}
                  strokeDasharray="4,2"
                />
                <text
                  x={viewport.minX - 2}
                  y={p.part_absolute + 12}
                  fontSize={11}
                  fontWeight="bold"
                  fill="#999"
                  fontFamily='-apple-system, "Segoe UI", Arial, sans-serif'
                  pointerEvents="none"
                >
                  {p.part_type}
                </text>
              </g>
            ))}

            {/* Layout-Objekte */}
            {data.objects.map(o => {
              const isMatch = filterActive && search.matchUuids.has(o.object_uuid);
              const isDimmed = filterActive && !search.matchUuids.has(o.object_uuid);
              const displayMode = isMatch ? 'highlight' : (isDimmed ? 'dim' : 'normal');
              return (
                <LayoutObjectShape
                  key={o.object_uuid}
                  object={o}
                  displayMode={displayMode}
                  labelMode={labelMode}
                  onMouseEnter={handleShapeMouseEnter}
                  onMouseMove={handleShapeMouseMove}
                  onMouseLeave={handleShapeMouseLeave}
                  onClick={handleObjectClick}
                />
              );
            })}

            {/* Highlight-Ringe (orange) als Overlay — *nach* allen Objekten gerendert,
                damit sie auch über (halb-)verdeckte Treffer sichtbar bleiben.
                Selektiertes Objekt wird ausgespart, da der rote Selektions-Ring darüberliegt. */}
            {filterActive && data.objects.map(o => {
              if (!search.matchUuids.has(o.object_uuid)) return null;
              if (search.selectedUuid === o.object_uuid) return null;
              return <HighlightRing key={`hl-${o.object_uuid}`} object={o} />;
            })}

            {/* Selektions-Ring (rot) als Top-Layer-Overlay — höchster Z-Index. */}
            {search.selectedUuid && objectsByUuid.get(search.selectedUuid) && (
              <SelectionRing object={objectsByUuid.get(search.selectedUuid)!} />
            )}
          </g>
        </svg>

        {hoverObject && hoverState && !dragRef.current && (
          <LayoutObjectTooltip object={hoverObject} x={hoverState.x} y={hoverState.y} />
        )}
      </div>
    </div>
  );
});

LayoutCanvas.displayName = 'LayoutCanvas';
