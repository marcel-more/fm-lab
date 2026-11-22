import { useCallback, useState, type ReactNode } from 'react';
import { useTranslation } from 'react-i18next';
import type { OpenTarget } from '../hooks/useSubgraph';
import { getTypeColor } from '../lib/graphColors';
import { formatObjectDisplayName } from '../lib/objectName';

/**
 * Shared scaffold of the way lists in the Explorer's right slot (flow and data
 * trace): the panel frame (head with count, overview and close, cut hint,
 * optional tabs), a way row (selectable head, body, nested child ways), the
 * node chip and the open/closed state of expandable groups. The row renderers
 * per mode live in ExplorerDataWaysPanel and ExplorerFlowWaysPanel.
 */

/** Resolved display info of a node id (trace node or ref). */
export type WayNodeInfo = {
  id: string;
  uuid: string;
  label: string;
  type: string;
  file: string | null;
  flowRole: string | null;
  stepIndex: number | null;
  scriptUuid: string | null;
  ownerUuid: string | null;
  ownerType: string | null;
  /** In the loaded graph (selectable in the canvas) vs. only a ref. */
  inGraph: boolean;
  /** Server- or client-resolved jump target (layout of a layout object, script of a step, …). */
  open?: OpenTarget;
};

/** Node chip: type dot (role colour if known), name, hover preview, click pick. */
export function WayNodeChip(props: {
  info: WayNodeInfo | null;
  fallback?: string;
  roleColors?: Record<string, string>;
  onHover: (id: string | null) => void;
  onPick: (info: WayNodeInfo) => void;
}) {
  const { info, fallback, roleColors, onHover, onPick } = props;
  if (!info) return <span className="explorer-data-node is-missing">{fallback ?? '—'}</span>;
  const color = info.flowRole ? roleColors?.[info.flowRole] : undefined;
  const name = formatObjectDisplayName(info.type, info.label);
  return (
    <button
      type="button"
      className="explorer-data-node"
      title={info.file ? `${name} · ${info.file}` : name}
      onMouseEnter={() => onHover(info.inGraph ? info.id : null)}
      onMouseLeave={() => onHover(null)}
      onFocus={() => onHover(info.inGraph ? info.id : null)}
      onBlur={() => onHover(null)}
      onClick={(e) => {
        e.stopPropagation();
        onPick(info);
      }}
    >
      <span className="explorer-type-dot" style={{ background: color ?? getTypeColor(info.type) }} />
      <span className="explorer-data-node-label">{name}</span>
    </button>
  );
}

/** Open/closed state of expandable groups, keyed by the caller. */
export function useOpenGroups(initial?: Iterable<string>) {
  const [open, setOpen] = useState<Set<string>>(() => new Set(initial));
  const toggle = useCallback((key: string) => {
    setOpen((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  }, []);
  const ensure = useCallback((key: string) => {
    setOpen((prev) => (prev.has(key) ? prev : new Set(prev).add(key)));
  }, []);
  return { open, toggle, ensure };
}

/** One way: a selectable head, the body below and the nested child ways. */
export function WayItem(props: {
  selected: boolean;
  depth: number;
  head: ReactNode;
  children?: ReactNode;
  nested?: ReactNode;
  onToggle: () => void;
  /** DOM id (scroll target, e.g. from a diagram click). */
  domId?: string;
  /** Extra class (e.g. `is-context`: ancestor of a search hit, not a hit itself). */
  className?: string;
}) {
  const { selected, depth, head, children, nested, onToggle, domId, className } = props;
  return (
    <li
      id={domId}
      className={`explorer-data-way${selected ? ' is-selected' : ''}${className ? ` ${className}` : ''}`}
      style={{ marginLeft: depth * 12 }}
    >
      <div
        className="explorer-data-way-head"
        role="button"
        tabIndex={0}
        aria-pressed={selected}
        onClick={onToggle}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            onToggle();
          }
        }}
      >
        {head}
      </div>
      {children !== undefined && <div className="explorer-data-way-body">{children}</div>}
      {nested}
    </li>
  );
}

/** Panel frame of a way list. */
export function ExplorerWaysPanel(props: {
  width?: number;
  title: string;
  count: number;
  overviewHint: string;
  onOverview: () => void;
  onClose: () => void;
  onHoverNode: (id: string | null) => void;
  /** Ways shown vs. found (cut by `ways_limit`). */
  cut?: { shown: number; total: number } | null;
  /** Optional row below the head (tabs). */
  tabs?: ReactNode;
  className?: string;
  children: ReactNode;
}) {
  const { width, title, count, overviewHint, onOverview, onClose, onHoverNode, cut, tabs, className, children } = props;
  const { t } = useTranslation(['explorer', 'common']);
  return (
    <aside
      className={`explorer-inspect-panel explorer-data-panel${className ? ` ${className}` : ''}`}
      style={width ? { width } : undefined}
      aria-label={title}
      onMouseLeave={() => onHoverNode(null)}
    >
      <div className="explorer-inspect-head">
        <h2 className="explorer-inspect-title">
          {title}{' '}
          <span className="explorer-chip-count">{count}</span>
        </h2>
        <button type="button" className="explorer-focus-details" onClick={onOverview} title={overviewHint}>
          {t('trace.ways.overview')}
        </button>
        <button type="button" className="explorer-inspect-close" onClick={onClose} aria-label={t('common:close', { defaultValue: 'Schließen' }) as string}>
          ✕
        </button>
      </div>
      {tabs}
      {cut && cut.total > cut.shown && (
        <p className="explorer-data-hint is-warning">{t('trace.ways.waysCut', { shown: cut.shown, total: cut.total })}</p>
      )}
      {children}
    </aside>
  );
}
