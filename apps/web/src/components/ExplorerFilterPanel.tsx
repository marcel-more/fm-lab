import { useMemo, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import { getTypeColor } from '../lib/graphColors';
import type { FilterMode, ColorMode, GraphPartition } from './ExplorerGraph';
import type { SubgraphDirection } from '../hooks/useSubgraph';
import type { DepthBucket } from '../hooks/useDepthProfile';

/** One community present in the current graph — drives the color-lens legend. */
export interface CommunityLegendItem {
  id: number;
  name: string | null;
  count: number;
  color: string;
}

/**
 * Control surface for the Graph Explorer.
 *
 * The focus is set elsewhere (DetailView button / deep-link / double-tap), so
 * this panel carries no global search. The **name filter** (text) and the
 * **file filter** (dropdown) are *soft* client-side lenses on the loaded
 * subgraph; their non-matches are dimmed or hidden per the shared mode toggle.
 * The **type chips** are a *hard exclusion set* — clicking a chip deselects that
 * type (hides it); all others stay on. Each chip also carries a hamburger
 * affordance (Verfeinerung B) that opens the type's object list. Depth/direction
 * re-fetch; the depth control shows the reachable max + can extend past 4.
 */

export interface ExplorerFilterPanelProps {
  /** User-resized panel width in px (drag handle); falls back to the CSS default. */
  width?: number;
  /** Label of the current focus node (read-only context). */
  focusLabel: string | null;
  /** Focus node identity for the „⧉ Details"-Link (null = kein Fokus). */
  focusUuid: string | null;
  focusFile: string | null;
  /** Client-side name filter value. */
  nameFilter: string;
  /** Selected file (null = all files). */
  selectedFile: string | null;
  /** How name/file non-matches are treated (dim = default, hide). */
  filterMode: FilterMode;
  depth: number;
  /** Effektiver Schieberegler-Maximalwert (4 oder erweitert bis hardCap). */
  depthMax: number;
  /** Max. erreichbare Tiefe (Exzentrizität) ab dem Fokus; null = unbekannt. */
  maxDepth: number | null;
  /** true → die echte Exzentrizität liegt evtl. über dem Walk-Deckel („von N+"). */
  maxDepthHitCap: boolean;
  /** Opt-in: Regler über 4 hinaus erweitert. */
  depthExtended: boolean;
  /** Erweiterung anbieten (nur wenn maxDepth > 4). */
  canExtendDepth: boolean;
  /** Knotenzahl je Tiefe (kumulativ) — Vorab-Last/Clipping-Hinweis; null = unbekannt. */
  depthCumulative: DepthBucket[] | null;
  /** Backend-Deckel node_limit — Schwelle des Clipping-Hinweises. */
  nodeLimit: number;
  direction: SubgraphDirection;
  /** Stabile Konnektivitäts-Partition der geladenen Knoten (null = leer). */
  partition: GraphPartition | null;
  /** Deselected types (exclusion set) — empty = all types shown. */
  deselectedTypes: string[];
  /** Types to render as chips (graph types ∪ deselected), with counts. */
  availableTypes: { type: string; count: number }[];
  /** Distinct files present in the current graph. */
  availableFiles: string[];
  /** Datei-Gruppierung aktiv — Knoten in Compound-Boxen je Datei. */
  groupByFile: boolean;
  /** Verfeinerung C: ein server-seitiger Typ-Filter ist aktiv (committed). */
  serverTypesActive: boolean;
  /** Show the Type↔Community color-lens toggle + legend (standalone only). */
  showColorMode: boolean;
  /** Active node color lens. */
  colorMode: ColorMode;
  /** Communities present in the current graph (legend; only used in community mode). */
  communities: CommunityLegendItem[];
  /** Currently selected community (hull + dims others), or null. */
  selectedCommunity: number | null;
  /** „⧉ Details" — Detail-View des Fokus-Objekts öffnen. */
  onOpenFocusDetails: (uuid: string, file?: string | null) => void;
  /** Hamburger eines Typ-Chips → Objektliste dieses Typs öffnen. */
  onOpenTypeList: (type: string) => void;
  onNameFilterChange: (v: string) => void;
  onSelectedFileChange: (file: string | null) => void;
  /** Datei-Gruppierung (Compound-Boxen) an/aus. */
  onGroupByFileChange: (v: boolean) => void;
  onFilterModeChange: (m: FilterMode) => void;
  onColorModeChange: (m: ColorMode) => void;
  /** Toggle a community as selected. */
  onSelectCommunity: (id: number) => void;
  /** Hover preview of a community hull (id) / clear (null). */
  onHoverCommunity: (id: number | null) => void;
  onDepthChange: (d: number) => void;
  /** Opt-in-Erweiterung des Reglers über 4 hinaus an/aus. */
  onExtendDepthChange: (extended: boolean) => void;
  onDirectionChange: (d: SubgraphDirection) => void;
  onToggleType: (type: string) => void;
  /** Lade-Umfang „Alle Typen": Client-Abwahl UND Server-Filter zurücksetzen (lädt neu). */
  onShowAllTypes: () => void;
  /** Lade-Umfang „Nur gewählte Typen": aktuelle Auswahl server-seitig laden (lädt neu). */
  onApplyServerTypes: () => void;
  /**
   * Trace-Modus: ersetzt die Traversierungs-Steuerung (Tiefe + Richtung) durch
   * die Trace-Kontrollen (Budgets, Schalter, Legende). Die Client-Lenses
   * (Name, Datei, Typ, dim/hide, Färbung) bleiben unverändert aktiv.
   */
  traceControls?: ReactNode;
}

const DIRECTIONS: SubgraphDirection[] = ['out', 'in', 'both'];
const FILTER_MODES: FilterMode[] = ['dim', 'hide'];
const COLOR_MODES: ColorMode[] = ['type', 'community'];

export function ExplorerFilterPanel(props: ExplorerFilterPanelProps) {
  const {
    width,
    focusLabel, focusUuid, focusFile, nameFilter, selectedFile, filterMode,
    depth, depthMax, maxDepth, maxDepthHitCap, depthExtended, canExtendDepth, depthCumulative, nodeLimit,
    direction, partition,
    deselectedTypes, availableTypes, availableFiles, groupByFile, serverTypesActive,
    showColorMode, colorMode, communities, selectedCommunity,
    onOpenFocusDetails, onOpenTypeList,
    onNameFilterChange, onSelectedFileChange, onGroupByFileChange, onFilterModeChange, onColorModeChange,
    onSelectCommunity, onHoverCommunity,
    onDepthChange, onExtendDepthChange, onDirectionChange, onToggleType, onShowAllTypes, onApplyServerTypes,
    traceControls,
  } = props;
  const { t } = useTranslation(['explorer']);

  const deselectedSet = useMemo(() => new Set(deselectedTypes), [deselectedTypes]);
  // The shared dim/hide mode is meaningful while any soft filter — name, file, or
  // a community selection — is active.
  const softFilterActive =
    nameFilter.trim() !== '' || selectedFile !== null || selectedCommunity !== null;

  // The display name a legend entry shows (heuristic name or "Community N").
  const communityLabel = (c: CommunityLegendItem) =>
    c.name ?? (t('filter.communityUnnamed', { id: c.id }) as string);

  // The search box also narrows the community list.
  const visibleCommunities = useMemo(() => {
    const nf = nameFilter.trim().toLowerCase();
    if (!nf) return communities;
    return communities.filter((c) => communityLabel(c).toLowerCase().includes(nf));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [communities, nameFilter]);

  // Vorab-Last der aktuell gewählten Tiefe (kumulative Knotenzahl) → Clipping-Hinweis.
  const depthLoad = useMemo(() => {
    if (!depthCumulative) return null;
    const bucket = depthCumulative.find((b) => b.depth === depth);
    return bucket ? bucket.cumulative : null;
  }, [depthCumulative, depth]);

  return (
    <aside
      className="explorer-filter-panel"
      style={width ? { width } : undefined}
      aria-label={t('filter.ariaLabel') as string}
    >
      {/* Current focus + direct jump to its detail view (Verfeinerung A) */}
      <div className="explorer-filter-section">
        <span className="explorer-filter-label">{t('filter.focus')}</span>
        <div className="explorer-focus-row">
          <div className="explorer-focus-display" title={focusLabel ?? undefined}>
            {focusLabel ?? <span className="explorer-focus-empty">{t('filter.noFocus')}</span>}
          </div>
          {focusUuid && (
            <button
              type="button"
              className="explorer-focus-details"
              onClick={() => onOpenFocusDetails(focusUuid, focusFile)}
              title={t('filter.openDetails') as string}
              aria-label={t('filter.openDetails') as string}
            >
              ⧉ {t('filter.detailsShort')}
            </button>
          )}
        </div>
      </div>

      {/* Client-side name filter */}
      <div className="explorer-filter-section">
        <label className="explorer-filter-label" htmlFor="explorer-name-filter">
          {t('filter.nameFilter')}
        </label>
        <div className="explorer-search-box">
          <input
            id="explorer-name-filter"
            type="text"
            value={nameFilter}
            placeholder={t('filter.nameFilterPlaceholder') as string}
            onChange={(e) => onNameFilterChange(e.target.value)}
            autoComplete="off"
          />
          {nameFilter && (
            <button
              type="button"
              className="explorer-search-clear"
              onClick={() => onNameFilterChange('')}
              aria-label={t('filter.clearNameFilter') as string}
              title={t('filter.clearNameFilter') as string}
            >
              ✕
            </button>
          )}
        </div>
      </div>

      {/* File filter — only shown when the graph spans more than one file.
          Die „gruppieren"-Checkbox sitzt inline rechts neben dem Abschnitts-Titel
          (über der Auswahlliste): Knoten werden in Compound-Boxen je Datei gelegt. */}
      {availableFiles.length > 1 && (
        <div className="explorer-filter-section">
          <div className="explorer-filter-label-row">
            <label className="explorer-filter-label" htmlFor="explorer-file-filter">
              {t('filter.file')}
            </label>
            <label className="explorer-group-toggle" title={t('filter.groupByFileHint') as string}>
              <input
                type="checkbox"
                checked={groupByFile}
                onChange={(e) => onGroupByFileChange(e.target.checked)}
              />
              {t('filter.groupByFile')}
            </label>
          </div>
          <select
            id="explorer-file-filter"
            className="explorer-file-select"
            value={selectedFile ?? ''}
            onChange={(e) => onSelectedFileChange(e.target.value || null)}
          >
            <option value="">{t('filter.allFiles')}</option>
            {availableFiles.map((f) => (
              <option key={f} value={f}>{f}</option>
            ))}
          </select>
        </div>
      )}

      {/* Shared dim/hide mode for the soft (name + file) filters */}
      {softFilterActive && (
        <div className="explorer-filter-section">
          <span className="explorer-filter-label">{t('filter.filterMode')}</span>
          <div
            className="explorer-segmented explorer-segmented-sm"
            role="radiogroup"
            aria-label={t('filter.filterMode') as string}
          >
            {FILTER_MODES.map((m) => (
              <button
                key={m}
                type="button"
                role="radio"
                aria-checked={filterMode === m}
                className={`explorer-segment${filterMode === m ? ' is-active' : ''}`}
                onClick={() => onFilterModeChange(m)}
                title={t(`filter.filterModeHints.${m}`) as string}
              >
                {t(`filter.filterModes.${m}`)}
              </button>
            ))}
          </div>
        </div>
      )}

      {/* Trace-Modus: Budgets/Schalter/Legende ersetzen Tiefe + Richtung. */}
      {traceControls ?? (<>
      {/* Depth — slider + reachable max + opt-in extension + load/clipping hint */}
      <div className="explorer-filter-section">
        <label className="explorer-filter-label" htmlFor="explorer-depth">
          {t('filter.depth')}: <strong>{depth}</strong>
          {maxDepth !== null && maxDepth > 0 && (
            <span className="explorer-depth-of">
              {' '}{t('filter.depthOf', { max: `${maxDepth}${maxDepthHitCap ? '+' : ''}` })}
            </span>
          )}
        </label>
        <input
          id="explorer-depth"
          type="range"
          min={1}
          max={depthMax}
          step={1}
          value={depth}
          onChange={(e) => onDepthChange(Number(e.target.value))}
        />
        <div className="explorer-depth-extra">
          {canExtendDepth && (
            <label className="explorer-depth-extend" title={t('filter.extendDepthHint') as string}>
              <input
                type="checkbox"
                checked={depthExtended}
                onChange={(e) => onExtendDepthChange(e.target.checked)}
              />
              {t('filter.extendDepth')}
            </label>
          )}
          {depthLoad !== null && (
            <span className={`explorer-depth-load${depthLoad > nodeLimit ? ' is-clipped' : ''}`}>
              {depthLoad > nodeLimit
                ? t('filter.depthClipped', { limit: nodeLimit, count: depthLoad })
                : t('filter.depthLoad', { count: depthLoad })}
            </span>
          )}
        </div>
        {/* Aufschlüsselung der geladenen Knoten — konsistente Zerlegung, die sich zur
            „geladen"-Summe addiert (verbunden + Inseln + isoliert). Beschreibt dieselbe
            Menge wie der Lade-/Clipping-Hinweis darüber. */}
        {partition && partition.loaded > 0 && (
          <p className="explorer-connectivity-hint">
            {[
              t('filter.partLoaded', { count: partition.loaded, defaultValue: '{{count}} geladen' }),
              t('filter.partConnected', { count: partition.connectedToFocus, defaultValue: '{{count}} verbunden' }),
              partition.island > 0
                ? t('filter.partIsland', {
                    count: partition.island,
                    defaultValue_one: '{{count}} Insel',
                    defaultValue_other: '{{count}} Inseln',
                    defaultValue: '{{count}} Inseln',
                  })
                : null,
              partition.isolated > 0
                ? t('filter.partIsolated', { count: partition.isolated, defaultValue: '{{count}} isoliert' })
                : null,
            ]
              .filter(Boolean)
              .join(' · ')}
          </p>
        )}
      </div>

      {/* Direction */}
      <div className="explorer-filter-section">
        <span className="explorer-filter-label">{t('filter.direction')}</span>
        <div className="explorer-segmented" role="radiogroup" aria-label={t('filter.direction') as string}>
          {DIRECTIONS.map((d) => (
            <button
              key={d}
              type="button"
              role="radio"
              aria-checked={direction === d}
              className={`explorer-segment${direction === d ? ' is-active' : ''}`}
              onClick={() => onDirectionChange(d)}
              title={t(`filter.directionHints.${d}`) as string}
            >
              {t(`filter.directions.${d}`)}
            </button>
          ))}
        </div>
      </div>
      </>)}

      {/* Color lens — Type ↔ Community recolor + community legend. */}
      {showColorMode && (
        <div className="explorer-filter-section">
          <span className="explorer-filter-label">{t('filter.colorMode')}</span>
          <div
            className="explorer-segmented explorer-segmented-sm"
            role="radiogroup"
            aria-label={t('filter.colorMode') as string}
          >
            {COLOR_MODES.map((m) => (
              <button
                key={m}
                type="button"
                role="radio"
                aria-checked={colorMode === m}
                className={`explorer-segment${colorMode === m ? ' is-active' : ''}`}
                onClick={() => onColorModeChange(m)}
                title={t(`filter.colorModeHints.${m}`) as string}
              >
                {t(`filter.colorModes.${m}`)}
              </button>
            ))}
          </div>

          {colorMode === 'community' && visibleCommunities.length > 0 && (
            <ul className="explorer-community-legend" onMouseLeave={() => onHoverCommunity(null)}>
              {visibleCommunities.map((c) => {
                const active = selectedCommunity === c.id;
                return (
                  <li key={c.id}>
                    <button
                      type="button"
                      className={`explorer-community-legend-item${active ? ' is-active' : ''}`}
                      title={communityLabel(c)}
                      aria-pressed={active}
                      onClick={() => onSelectCommunity(c.id)}
                      onMouseEnter={() => onHoverCommunity(c.id)}
                      onFocus={() => onHoverCommunity(c.id)}
                      onBlur={() => onHoverCommunity(null)}
                    >
                      <span className="explorer-type-dot" style={{ background: c.color }} />
                      <span className="explorer-community-legend-name">{communityLabel(c)}</span>
                      <span className="explorer-chip-count">{c.count}</span>
                    </button>
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      )}

      {/* Type chips — each chip = dot/hamburger button (open list) + toggle (filter).
          Davor der Lade-Umfang-Schalter (Achse A): „Alle Typen" lädt alles (Chip-Abwahl
          dimmt), „Nur gewählte Typen" lädt nur die ausgewählten Typen server-seitig neu. */}
      {availableTypes.length > 0 && (
        <div className="explorer-filter-section">
          <span className="explorer-filter-label">{t('filter.types')}</span>
          <div
            className="explorer-segmented explorer-segmented-sm"
            role="radiogroup"
            aria-label={t('filter.loadScope', { defaultValue: 'Typen laden' }) as string}
          >
            <button
              type="button"
              role="radio"
              aria-checked={!serverTypesActive}
              className={`explorer-segment${!serverTypesActive ? ' is-active' : ''}`}
              onClick={onShowAllTypes}
              title={t('filter.loadAllHint', { defaultValue: 'Alle Typen laden; Chip-Abwahl blendet nur aus' }) as string}
            >
              {t('filter.loadAll', { defaultValue: 'Alle Typen' })}
            </button>
            <button
              type="button"
              role="radio"
              aria-checked={serverTypesActive}
              className={`explorer-segment${serverTypesActive ? ' is-active' : ''}`}
              onClick={onApplyServerTypes}
              title={t('filter.loadSelectedHint', { defaultValue: 'Nur die gewählten Typen laden (lädt neu)' }) as string}
            >
              {t('filter.loadSelected', { defaultValue: 'Nur gewählte Typen' })}
            </button>
          </div>
          <div className="explorer-chips">
            {availableTypes.map(({ type, count }) => {
              // Exclusion model: a chip is active (shown) unless it's deselected.
              const active = !deselectedSet.has(type);
              return (
                <div
                  key={type}
                  className={`explorer-chip${active ? ' is-active' : ''}`}
                  style={active ? { borderColor: getTypeColor(type) } : undefined}
                >
                  <button
                    type="button"
                    className="explorer-chip-dot-btn"
                    onClick={() => onOpenTypeList(type)}
                    aria-label={t('filter.openTypeList', { type }) as string}
                    title={t('filter.openTypeList', { type }) as string}
                  >
                    <span className="explorer-type-dot" style={{ background: getTypeColor(type) }} />
                    <span className="explorer-chip-hamburger" aria-hidden="true">☰</span>
                  </button>
                  <button
                    type="button"
                    className="explorer-chip-toggle"
                    aria-pressed={active}
                    onClick={() => onToggleType(type)}
                    aria-label={t(active ? 'filter.hideType' : 'filter.showType', { type }) as string}
                  >
                    {type}
                    <span className="explorer-chip-count">{count}</span>
                  </button>
                </div>
              );
            })}
          </div>
        </div>
      )}
    </aside>
  );
}
