import { useTranslation } from 'react-i18next';
import { getTypeColor } from '../lib/graphColors';
import { formatObjectDisplayName } from '../lib/objectName';
import type { GraphNode } from '../hooks/useSubgraph';

/**
 * Typ-Objektliste — der zweite Inhaltsmodus des rechten Explorer-Panels
 * (Verfeinerung B). Öffnet über das Hamburger-Affordance eines Typ-Chips und
 * zeigt die Objekte dieses Typs **im aktuellen Graphen** (deckungsgleich mit dem
 * Chip-Zähler). Klick auf einen Eintrag → Detail-View; MouseHover → der zugehörige
 * Knoten wird im Graphen transient hervorgehoben (`onHoverItem`).
 *
 * Teilt sich den Panel-Slot mit dem Node-Inspect (mutually exclusive, vom Parent
 * gesteuert) und denselben CSS-Rahmen (`explorer-inspect-panel`).
 */

export type TypeListSort = 'name' | 'file';
/** Richtungs-Filter relativ zum Fokus: eingehend / ausgehend / beide. */
export type TypeListDir = 'in' | 'out' | 'both';

interface ExplorerTypeListPanelProps {
  /** User-resized panel width in px (drag handle); falls back to the CSS default. */
  width?: number;
  type: string;
  /** Bereits sortierte Objekte des Typs (vom Parent gefiltert + sortiert). */
  items: GraphNode[];
  sort: TypeListSort;
  onSortChange: (s: TypeListSort) => void;
  /** Aktiver Richtungs-Filter + Zähler je Richtung (vom Parent berechnet). */
  dir: TypeListDir;
  dirCounts: { in: number; out: number; total: number };
  /**
   * Pro Knoten-ID: Richtung relativ zum Fokus (←/→/↔) + Rolle der Fokus-Kante.
   * Fehlt für den Fokus selbst und indirekte Knoten (>1 Hop) → kein Pfeil.
   */
  dirInfo: Map<string, { dir: TypeListDir; role: string | null }>;
  /**
   * Datei des Fokus-Knotens (kann im Graph-Tab vom URL-Objekt abweichen, wenn
   * der User „als Fokus setzen" genutzt hat). Einträge derselben Datei blenden
   * den Dateinamen aus (Platzersparnis); nur datei-fremde zeigen ihn.
   */
  focusFile: string | null;
  /** Nur einblenden, wenn beide Richtungen vertreten sind (sonst sinnlos). */
  showDir: boolean;
  onDirChange: (d: TypeListDir) => void;
  onClose: () => void;
  onOpenDetails: (uuid: string, file?: string | null) => void;
  /** Hover-Vorschau: composite Graph-Key (node.id) bzw. null beim Verlassen. */
  onHoverItem: (graphId: string | null) => void;
  /**
   * Exclude-Toggle je Zeile (composite Graph-Key). Vom Parent NUR gesetzt,
   * wenn Trace-Modus aktiv UND der Panel-Typ ausschließbar ist (EXCLUDABLE_TYPES
   * — ein Gate pro Panel-Instanz, das Panel zeigt genau einen Typ). undefined ⇒
   * die Liste rendert wie bisher (Subgraph-Modus / nicht-ausschließbare Typen).
   */
  onToggleExclude?: (graphId: string) => void;
}

const SORTS: TypeListSort[] = ['name', 'file'];

export function ExplorerTypeListPanel(props: ExplorerTypeListPanelProps) {
  const { width, type, items, sort, onSortChange, dir, dirCounts, dirInfo, focusFile, showDir, onDirChange, onClose, onOpenDetails, onHoverItem, onToggleExclude } = props;
  const { t } = useTranslation(['explorer', 'common']);

  const dirGlyph = (d: TypeListDir) => (d === 'in' ? '←' : d === 'out' ? '→' : '↔');
  const dirLabel = (d: TypeListDir) =>
    d === 'in'
      ? (t('typeList.dirIn', { defaultValue: 'Eingehend' }) as string)
      : d === 'out'
        ? (t('typeList.dirOut', { defaultValue: 'Ausgehend' }) as string)
        : (t('typeList.dirBoth', { defaultValue: 'Beide' }) as string);

  const dirOpts: Array<{ key: TypeListDir; glyph: string; label: string; count: number }> = [
    { key: 'in', glyph: '←', label: t('typeList.dirIn', { defaultValue: 'Eingehend' }) as string, count: dirCounts.in },
    { key: 'out', glyph: '→', label: t('typeList.dirOut', { defaultValue: 'Ausgehend' }) as string, count: dirCounts.out },
    { key: 'both', glyph: '↔', label: t('typeList.dirBoth', { defaultValue: 'Beide' }) as string, count: dirCounts.total },
  ];

  return (
    <aside
      className="explorer-inspect-panel explorer-typelist-panel"
      style={width ? { width } : undefined}
      aria-label={t('typeList.ariaLabel', { type }) as string}
      onMouseLeave={() => onHoverItem(null)}
    >
      <div className="explorer-inspect-head">
        <span className="explorer-type-dot" style={{ background: getTypeColor(type) }} />
        <h2 className="explorer-inspect-title" title={type}>
          {type} <span className="explorer-chip-count">{items.length}</span>
        </h2>
        <button type="button" className="explorer-inspect-close" onClick={onClose} aria-label={t('common:back') as string}>
          ✕
        </button>
      </div>

      <div className="explorer-typelist-sort">
        <span className="explorer-filter-label">{t('typeList.sortBy')}</span>
        <div className="explorer-segmented explorer-segmented-sm" role="radiogroup" aria-label={t('typeList.sortBy') as string}>
          {SORTS.map((s) => (
            <button
              key={s}
              type="button"
              role="radio"
              aria-checked={sort === s}
              className={`explorer-segment${sort === s ? ' is-active' : ''}`}
              onClick={() => onSortChange(s)}
            >
              {t(`typeList.sort.${s}`)}
            </button>
          ))}
        </div>

        {showDir && (
          <div className="explorer-typelist-dir">
            <span className="explorer-filter-label">{t('typeList.directionLabel', { defaultValue: 'Richtung' })}</span>
            <div
              className="explorer-segmented explorer-segmented-sm"
              role="radiogroup"
              aria-label={t('typeList.directionAria', { defaultValue: 'Nach Richtung filtern' }) as string}
            >
              {dirOpts.map((o) => (
                <button
                  key={o.key}
                  type="button"
                  role="radio"
                  aria-checked={dir === o.key}
                  aria-label={`${o.label} (${o.count})`}
                  title={`${o.label} (${o.count})`}
                  // Leere Richtung deaktivieren — sonst führt ein Klick zu einer
                  // irreführend leeren Liste. 'both' ist immer wählbar.
                  disabled={o.key !== 'both' && o.count === 0}
                  className={`explorer-segment${dir === o.key ? ' is-active' : ''}`}
                  onClick={() => onDirChange(o.key)}
                >
                  <span className="explorer-dir-glyph" aria-hidden="true">{o.glyph}</span>
                  <span className="explorer-dir-count">{o.count}</span>
                </button>
              ))}
            </div>
          </div>
        )}
      </div>

      <div className="explorer-typelist-items">
        {items.length === 0 ? (
          <p className="explorer-inspect-empty">{t('typeList.empty')}</p>
        ) : (
          <ul>
            {items.map((n) => {
              // Fokus-Knoten: kein Pfeil, stattdessen Fisheye-Glyph (◉).
              // Direkte Nachbarn: Richtungspfeil + rohe Rolle (Klartext nur bei
              // genug Panel-Breite via Container Query, Rolle stets im Tooltip).
              const info = n.isFocus ? null : dirInfo.get(n.id);
              const glyphTitle = info
                ? (info.role ? `${dirLabel(info.dir)} · ${info.role}` : dirLabel(info.dir))
                : undefined;
              const excluded = n.isExcluded === true;
              return (
                // Haupt-Button + optionaler Exclude-Icon-Button als GESCHWISTER
                // im <li> (ein Toggle IM Detail-Button wäre verschachteltes
                // Interaktiv-Element). Hover-/Fokus-Vorschau auf <li>-Ebene, damit
                // beide Elemente die Canvas-Hervorhebung tragen (Focus/Blur bubbeln).
                <li
                  key={n.id}
                  className={excluded ? 'is-excluded' : undefined}
                  onMouseEnter={() => onHoverItem(n.id)}
                  onFocus={() => onHoverItem(n.id)}
                  onBlur={() => onHoverItem(null)}
                >
                  <button
                    type="button"
                    className={`explorer-neighbor${n.isFocus ? ' is-focus' : ''}`}
                    aria-current={n.isFocus ? 'true' : undefined}
                    onClick={() => onOpenDetails(n.uuid, n.file ?? null)}
                    title={n.label}
                  >
                    <span className="explorer-type-dot" style={{ background: getTypeColor(n.type) }} />
                    <span className="explorer-neighbor-label">{formatObjectDisplayName(n.type, n.label)}</span>
                    {info?.role && <span className="explorer-neighbor-role-label">{info.role}</span>}
                    {n.file && n.file !== focusFile && <span className="explorer-neighbor-role">{n.file}</span>}
                    {n.isFocus ? (
                      <span
                        className="explorer-neighbor-dir is-focus-glyph"
                        aria-hidden="true"
                        title={t('typeList.focus', { defaultValue: 'Fokus-Objekt' }) as string}
                      >
                        ◉
                      </span>
                    ) : info ? (
                      <span className="explorer-neighbor-dir" title={glyphTitle}>{dirGlyph(info.dir)}</span>
                    ) : null}
                  </button>
                  {/* Nie für den Fokus/Start (Server-Guard existiert, UI konsistent
                      zum InspectPanel); bestehende trace.*-Keys, keine neuen Locales. */}
                  {onToggleExclude && !n.isFocus && (
                    <button
                      type="button"
                      className="explorer-typelist-exclude"
                      aria-pressed={excluded}
                      aria-label={t(excluded ? 'trace.includeAction' : 'trace.excludeAction') as string}
                      title={t(excluded ? 'trace.removeExcludeHint' : 'trace.excludeHint') as string}
                      onClick={() => onToggleExclude(n.id)}
                    >
                      <span aria-hidden="true">{excluded ? '⊕' : '⊘'}</span>
                    </button>
                  )}
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </aside>
  );
}
