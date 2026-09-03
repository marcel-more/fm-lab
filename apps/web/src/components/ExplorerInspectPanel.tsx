import { useTranslation } from 'react-i18next';
import { getTypeColor } from '../lib/graphColors';
import { formatObjectDisplayName } from '../lib/objectName';
import { useTriggerEventFormat } from '../lib/triggerEvents';
import { triggerSubroleLabel } from '../lib/graphEdgeLabels';
import type { GraphNode } from '../hooks/useSubgraph';
import { EXCLUDABLE_TYPES } from '../hooks/useTrace';

/**
 * Inspect panel for the selected graph node.
 *
 * Shows the node's metadata and its neighbors *currently in the graph* (derived
 * from the loaded edges — no extra round-trip) plus the primary actions:
 * open in DetailView, set as focus, expand one hop (fetches & merges), and —
 * for hubs — collapse the fan-out.
 */

export type InspectNeighbor = {
  node: GraphNode;
  role: string;
  /** `out` = selected → neighbor (uses); `in` = neighbor → selected (used by). */
  direction: 'out' | 'in';
  /** Distinct Subroles der gefalteten Parallel-Kanten (z. B. Trigger-Events). */
  subroles: string[];
};

interface ExplorerInspectPanelProps {
  /** User-resized panel width in px (drag handle); falls back to the CSS default. */
  width?: number;
  node: GraphNode;
  neighbors: InspectNeighbor[];
  expanding: boolean;
  onClose: () => void;
  onOpenDetails: (uuid: string, file?: string | null) => void;
  onSetFocus: (uuid: string, file?: string | null) => void;
  /** Lazy-Expand: rohe uuid + file (Klon-Disambiguierung des Nachbar-Fetch). */
  onExpand: (uuid: string, file?: string | null) => void;
  /** Hub-Collapse: composite Graph-Key (node.id), reine Cytoscape-Operation. */
  onCollapse: (graphId: string) => void;
  onSelectNeighbor: (node: GraphNode) => void;
  /**
   * Trace-Modus öffnen (selektiver Ablauf-Graph ab diesem Knoten). Optional —
   * v1 nur für Script/Layout sinnvoll; der Button erscheint nur bei diesen Typen.
   */
  onTrace?: (uuid: string, file?: string | null) => void;
  /**
   * Knoten im aktiven Trace ausschließen/wieder einschließen (Composite-
   * Graph-Key node.id). Nur im Trace-Modus gesetzt; Button nur für Script/Layout
   * (die einzigen Typen mit Expansionswirkung) und nie für den Start.
   */
  onToggleExclude?: (graphId: string) => void;
  /** true = der Knoten steht aktuell auf der Exclude-Liste (URL-Wahrheit). */
  nodeExcluded?: boolean;
}

/** v1-Startobjekte des Trace (Feld/Variable/CF folgen in v2). */
const TRACEABLE_TYPES = new Set(['Script', 'Layout']);

export function ExplorerInspectPanel(props: ExplorerInspectPanelProps) {
  const { width, node, neighbors, expanding, onClose, onOpenDetails, onSetFocus, onExpand, onCollapse, onSelectNeighbor, onTrace, onToggleExclude, nodeExcluded = false } = props;
  const { t } = useTranslation(['explorer', 'common', 'types']);
  const formatTriggerEvent = useTriggerEventFormat();

  // Rolle + (lokalisierte) Subrole-Details einer Nachbar-Zeile — Trigger-Events
  // über die fm_spec-Referenz, andere Subroles roh.
  const roleDisplay = (role: string, subroles: string[]): string => {
    if (subroles.length === 0) return role;
    const strings = {
      buttonAction: t('edge.buttonAction', { defaultValue: 'Button-Aktion' }) as string,
      represents: t('edge.represents', { defaultValue: 'repräsentiert' }) as string,
    };
    const parts = role === 'triggers_script'
      ? subroles.map((s) => triggerSubroleLabel(s, formatTriggerEvent, strings))
      : subroles;
    return `${role} · ${parts.join(' · ')}`;
  };

  return (
    <aside
      className="explorer-inspect-panel"
      style={width ? { width } : undefined}
      aria-label={t('inspect.ariaLabel') as string}
    >
      <div className="explorer-inspect-head">
        <span className="explorer-type-dot" style={{ background: getTypeColor(node.type) }} />
        <h2 className="explorer-inspect-title" title={node.label}>{formatObjectDisplayName(node.type, node.label)}</h2>
        <button type="button" className="explorer-inspect-close" onClick={onClose} aria-label={t('common:back') as string}>
          ✕
        </button>
      </div>

      <dl className="explorer-inspect-meta">
        <div><dt>{t('inspect.type')}</dt><dd>{t(`types:objectTypes.${node.type}`, { defaultValue: node.type })}</dd></div>
        {node.file && <div><dt>{t('inspect.file')}</dt><dd>{node.file}</dd></div>}
        <div><dt>{t('inspect.degree')}</dt><dd>{node.degree}</dd></div>
        <div><dt>{t('inspect.depth')}</dt><dd>{node.depth}</dd></div>
        {node.isHub && <div><dt>{t('inspect.role')}</dt><dd>{t('inspect.hub')}</dd></div>}
        {node.communityName && <div><dt>{t('inspect.community')}</dt><dd>{node.communityName}</dd></div>}
      </dl>

      <div className="explorer-inspect-actions">
        <button type="button" className="explorer-inspect-action primary" onClick={() => onSetFocus(node.uuid, node.file ?? null)} disabled={node.isFocus}>
          {t('inspect.setFocus')}
        </button>
        <button type="button" className="explorer-inspect-action" onClick={() => onExpand(node.uuid, node.file ?? null)} disabled={expanding}>
          {expanding ? t('inspect.expanding') : t('inspect.expand')}
        </button>
        {node.isHub && (
          <button type="button" className="explorer-inspect-action" onClick={() => onCollapse(node.id)}>
            {t('inspect.collapseHub')}
          </button>
        )}
        {onTrace && TRACEABLE_TYPES.has(node.type) && (
          <button
            type="button"
            className="explorer-inspect-action"
            onClick={() => onTrace(node.uuid, node.file ?? null)}
            title={t('trace.actionHint') as string}
          >
            {/* Eigenname „Trace" bewusst unübersetzt. */}
            Trace
          </button>
        )}
        {onToggleExclude && EXCLUDABLE_TYPES.has(node.type) && !node.isFocus && (
          <button
            type="button"
            className="explorer-inspect-action"
            onClick={() => onToggleExclude(node.id)}
            title={t('trace.excludeHint') as string}
          >
            {nodeExcluded ? t('trace.includeAction') : t('trace.excludeAction')}
          </button>
        )}
        <button type="button" className="explorer-inspect-action" onClick={() => onOpenDetails(node.uuid, node.file ?? null)}>
          {t('inspect.openDetails')}
        </button>
      </div>

      <div className="explorer-inspect-neighbors">
        <h3>{t('inspect.neighbors', { count: neighbors.length })}</h3>
        {neighbors.length === 0 ? (
          <p className="explorer-inspect-empty">{t('inspect.noNeighbors')}</p>
        ) : (
          <ul>
            {neighbors.map(({ node: n, role, direction, subroles }) => (
              <li key={`${direction}-${n.id}-${role}`}>
                <button type="button" className="explorer-neighbor" onClick={() => onSelectNeighbor(n)}>
                  <span className="explorer-neighbor-dir" title={direction === 'out' ? t('inspect.uses') as string : t('inspect.usedBy') as string}>
                    {direction === 'out' ? '→' : '←'}
                  </span>
                  <span className="explorer-type-dot" style={{ background: getTypeColor(n.type) }} />
                  <span className="explorer-neighbor-label" title={n.label}>{formatObjectDisplayName(n.type, n.label)}</span>
                  <span className="explorer-neighbor-role" title={roleDisplay(role, subroles)}>{roleDisplay(role, subroles)}</span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </aside>
  );
}
