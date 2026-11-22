import { useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import type { DataEntryGroup, DataTraceDir, DataTraceResponse, DataWay } from '../hooks/useDataTrace';
import { DATA_FLOW_ROLE_COLORS, getTypeColor } from '../lib/graphColors';
import { useTriggerEventFormat } from '../lib/triggerEvents';
import { buildWayTree } from '../lib/traceWays';
import { ExplorerWaysPanel, WayItem, WayNodeChip, useOpenGroups, type WayNodeInfo } from './ExplorerWaysPanel';

/**
 * Right-hand panel of the data trace: the ways of the trace.
 *
 * - Origin (`up`): ways of level 1 — field × writer — with the entry groups as
 *   chips ("12 buttons · 3 triggers · input on 4 layouts", layouts on click),
 *   "follow source" (one level more for this way only; the new ways nest under
 *   their parent), a collapsed reset group and the overview diagram.
 * - Usage (`down`): the impact list (usage groups with counters, samples on
 *   click) above the ways (field × reader) with the reached fields.
 *
 * Tabs "Origin" (`up`, default) | "Usage" (`down`) at the same place and in the
 * same order as the flow trace's "Reached from" | "Calls". Unlike the flow
 * trace a tab switch reloads (one direction per response), so only the loaded
 * direction carries a counter.
 *
 * Selecting a way highlights its path in the canvas; every way opens its
 * Mermaid diagram; a writing step offers the flow trace of its script and
 * the script view at that step.
 */

/** Resolved display info of a node id (trace node or ref). */
export type DataNodeInfo = WayNodeInfo;

export function makeNodeInfo(data: DataTraceResponse | null): (id: string | null) => DataNodeInfo | null {
  const byId = new Map((data?.nodes ?? []).map((n) => [n.id, n]));
  const refs = data?.trace.refs ?? {};
  return (id) => {
    if (!id) return null;
    const n = byId.get(id);
    if (n) {
      return {
        id, uuid: n.uuid, label: n.label, type: n.type, file: n.file,
        flowRole: n.flowRole ?? null, stepIndex: n.stepIndex ?? null, scriptUuid: n.scriptUuid ?? null,
        ownerUuid: n.ownerUuid ?? null, ownerType: n.ownerType ?? null, inGraph: true, open: n.open,
      };
    }
    const r = refs[id];
    const sep = id.indexOf('::');
    const uuid = (sep === -1 ? id : id.slice(0, sep)).split('#')[0];
    if (r) {
      return {
        id, uuid, label: r.label, type: r.type, file: r.file, flowRole: r.flowRole,
        stepIndex: r.stepIndex, scriptUuid: r.scriptUuid, ownerUuid: r.ownerUuid, ownerType: r.ownerType, inGraph: false,
        open: r.open,
      };
    }
    return {
      id, uuid, label: uuid, type: 'Object', file: sep === -1 ? null : id.slice(sep + 2), flowRole: null,
      stepIndex: null, scriptUuid: null, ownerUuid: null, ownerType: null, inGraph: false,
    };
  };
}

interface ExplorerDataWaysPanelProps {
  width?: number;
  data: DataTraceResponse;
  /** Requested direction (URL) — may run ahead of `data` while the other direction loads. */
  dir: DataTraceDir;
  onDirChange: (dir: DataTraceDir) => void;
  /** Start type (Field · Variable) — selects the tab hints. */
  startType: string | null;
  nodeInfo: (id: string | null) => DataNodeInfo | null;
  selectedWayId: string | null;
  expandedWayIds: string[];
  /** "Follow source" is capped by the validator (20 way ids). */
  canExpandMore: boolean;
  onSelectWay: (way: DataWay | null) => void;
  onShowMermaid: (wayNo: number) => void;
  onExpandWay: (wayId: string) => void;
  /** Hover preview / pick of a node mentioned in the list. */
  onHoverNode: (id: string | null) => void;
  onPickNode: (info: DataNodeInfo) => void;
  onOpenFlowTrace: (scriptUuid: string, file: string | null) => void;
  onClose: () => void;
}

function NodeChip(props: {
  info: DataNodeInfo | null;
  fallback?: string;
  onHover: (id: string | null) => void;
  onPick: (info: DataNodeInfo) => void;
}) {
  return <WayNodeChip {...props} roleColors={DATA_FLOW_ROLE_COLORS} />;
}

export function ExplorerDataWaysPanel(props: ExplorerDataWaysPanelProps) {
  const {
    width, data, dir, onDirChange, startType, nodeInfo, selectedWayId, expandedWayIds, canExpandMore,
    onSelectWay, onShowMermaid, onExpandWay, onHoverNode, onPickNode, onOpenFlowTrace, onClose,
  } = props;
  const { t } = useTranslation(['explorer', 'common']);
  const formatEvent = useTriggerEventFormat();
  const up = data.trace.dir === 'up';
  const ways = data.trace.ways;
  const stats = data.trace.stats;

  // Ways as a tree: "follow source" ways nest under their parent way.
  const { roots, children } = useMemo(() => buildWayTree(ways), [ways]);

  const { open: openGroups, toggle: toggleGroup } = useOpenGroups();

  const entryChipText = (g: DataEntryGroup) => {
    const kind = t(`trace.data.entryKind.${g.kind}`, { count: g.n, defaultValue: g.kind }) as string;
    const event = g.event
      ? (g.kind === 'trigger' || g.kind === 'file' ? formatEvent(g.event) : g.event)
      : null;
    if (g.kind === 'input') return t('trace.data.inputOnLayouts', { count: g.nLayouts, n: g.n }) as string;
    return `${g.n} ${kind}${event ? ` (${event})` : ''}`;
  };

  const renderWay = (w: DataWay, depth: number) => {
    const writer = nodeInfo(w.writer);
    const field = nodeInfo(w.field);
    const selected = w.wayId === selectedWayId;
    const kids = children.get(w.wayId) ?? [];
    const expanded = expandedWayIds.includes(w.wayId);
    const canFollow = up && w.fields.length > 0 && !expanded && canExpandMore;
    const isStep = writer?.type === 'ScriptStep' && !!writer.scriptUuid;
    const kindLabel = w.writer === null
      ? (t('trace.data.manualEntry') as string)
      : w.writerKind
        ? (t(`trace.data.writerKind.${w.writerKind}`, { defaultValue: w.writerKind }) as string)
        : (t(`trace.data.flowKind.${w.writerFlowKind}`, { defaultValue: w.writerFlowKind }) as string);
    return (
      <WayItem
        key={w.wayId}
        selected={selected}
        depth={depth}
        onToggle={() => onSelectWay(selected ? null : w)}
        nested={kids.length > 0 ? <ul className="explorer-data-ways">{kids.map((k) => renderWay(k, depth + 1))}</ul> : undefined}
        head={(
          <>
            <span className="explorer-data-way-no">#{w.wayNo}</span>
            {w.level > 1 && <span className="explorer-data-badge" title={t('trace.data.levelHint') as string}>{t('trace.data.level', { level: w.level })}</span>}
            <span className="explorer-data-badge">{kindLabel}</span>
            {w.precision !== 'exact' && (
              <span className="explorer-data-badge is-approx" title={t('trace.data.approxHint') as string}>≈ {t('trace.data.approx')}</span>
            )}
            {w.noDdr && (
              <span className="explorer-data-badge is-approx" title={t('trace.data.noDdrWayHint') as string}>{t('trace.data.noDdrWay')}</span>
            )}
          </>
        )}
      >
          {(w.level > 1 || !up) && (
            <div className="explorer-data-row">
              <span className="explorer-data-row-label">
                {t(field?.type === 'Variable' ? 'trace.data.roles.variable' : 'trace.data.field')}
              </span>
              <NodeChip info={field} onHover={onHoverNode} onPick={onPickNode} />
            </div>
          )}
          <div className="explorer-data-row">
            <span className="explorer-data-row-label">{t(up ? 'trace.data.writer' : 'trace.data.reader')}</span>
            {writer
              ? <NodeChip info={writer} onHover={onHoverNode} onPick={onPickNode} />
              : <span className="explorer-data-node is-missing">{t('trace.data.manualEntry')}</span>}
          </div>
          {w.fields.length > 0 && (
            <div className="explorer-data-row">
              <span className="explorer-data-row-label">{t(up ? 'trace.data.sources' : 'trace.data.reached')}</span>
              <span className="explorer-data-row-items">
                {w.fields.slice(0, 6).map((f) => (
                  <NodeChip key={f.id} info={nodeInfo(f.id)} onHover={onHoverNode} onPick={onPickNode} />
                ))}
                {w.fields.length > 6 && <span className="explorer-data-more">+{w.fields.length - 6}</span>}
              </span>
            </div>
          )}
          {w.entryGroups.length > 0 && (
            <div className="explorer-data-entries">
              {w.entryGroups.map((g) => {
                const key = `${w.wayId}|${g.kind}|${g.event ?? ''}`;
                const open = openGroups.has(key);
                return (
                  <div key={key} className="explorer-data-entry">
                    <button
                      type="button"
                      className={`explorer-data-entry-chip${open ? ' is-open' : ''}`}
                      aria-expanded={open}
                      onClick={() => toggleGroup(key)}
                      title={t('trace.ways.entryChipHint') as string}
                    >
                      {entryChipText(g)}
                    </button>
                    {open && (
                      <ul className="explorer-data-entry-list">
                        {g.layouts.map((l) => (
                          <li key={`${l.uuid}::${l.file ?? ''}`}>
                            <button
                              type="button"
                              className="explorer-data-node"
                              onClick={() => onPickNode({
                                id: `${l.uuid}::${l.file ?? ''}`, uuid: l.uuid, label: l.name, type: 'Layout', file: l.file,
                                flowRole: null, stepIndex: null, scriptUuid: null, ownerUuid: null, ownerType: null, inGraph: false,
                              })}
                              title={l.file ? `${l.name} · ${l.file}` : l.name}
                            >
                              <span className="explorer-type-dot" style={{ background: getTypeColor('Layout') }} />
                              <span className="explorer-data-node-label">{l.name}</span>
                            </button>
                          </li>
                        ))}
                        {g.nLayouts > g.layouts.length && (
                          <li className="explorer-data-more">{t('trace.ways.moreLayouts', { count: g.nLayouts - g.layouts.length })}</li>
                        )}
                        {g.sample.map((id) => (
                          <li key={id}>
                            <NodeChip info={nodeInfo(id)} onHover={onHoverNode} onPick={onPickNode} />
                          </li>
                        ))}
                      </ul>
                    )}
                  </div>
                );
              })}
            </div>
          )}
          {up && w.nEntries === 0 && w.entryGroups.length === 0 && (
            <p className="explorer-data-hint">{t('trace.data.noEntries')}</p>
          )}
          <div className="explorer-data-way-actions">
            <button type="button" onClick={() => onShowMermaid(w.wayNo)} title={t('trace.ways.diagramHint') as string}>
              {t('trace.ways.diagram')}
            </button>
            {canFollow && (
              <button type="button" onClick={() => onExpandWay(w.wayId)} title={t('trace.data.followSourceHint') as string}>
                {t('trace.data.followSource')}
              </button>
            )}
            {isStep && writer && (
              <button
                type="button"
                onClick={() => onOpenFlowTrace(writer.scriptUuid as string, writer.file)}
                title={t('trace.data.flowTraceHint') as string}
              >
                {t('trace.data.flowTrace')}
              </button>
            )}
          </div>
      </WayItem>
    );
  };

  const reset = data.trace.resetGroup;
  const usage = data.trace.usageGroups ?? [];

  const hintSfx = startType === 'Variable' ? 'Variable' : '';
  const tabs = (
    <div className="explorer-segmented explorer-flow-tabs" role="tablist" aria-label={t('trace.flow.tabsLabel') as string}>
      {(['up', 'down'] as const).map((d) => (
        <button
          key={d}
          type="button"
          role="tab"
          aria-selected={dir === d}
          className={`explorer-segment${dir === d ? ' is-active' : ''}`}
          onClick={() => { if (d !== dir) onDirChange(d); }}
          title={t(`trace.data.${d === 'up' ? 'originHint' : 'usageHint'}${hintSfx}`) as string}
        >
          {t(d === 'up' ? 'trace.data.origin' : 'trace.data.usage')}
          {data.trace.dir === d && <>{' '}<span className="explorer-chip-count">{stats.ways}</span></>}
        </button>
      ))}
    </div>
  );

  return (
    <ExplorerWaysPanel
      width={width}
      title={t('trace.flow.waysTitle') as string}
      tabs={tabs}
      count={stats.ways}
      overviewHint={t('trace.data.overviewHint') as string}
      onOverview={() => onShowMermaid(0)}
      onClose={onClose}
      onHoverNode={onHoverNode}
      cut={{ shown: stats.ways, total: stats.waysTotal }}
    >
      {!up && usage.length > 0 && (
        <section className="explorer-data-section">
          <h3>{t('trace.data.impact')}</h3>
          <ul className="explorer-data-usage">
            {usage.map((g) => {
              const key = `usage|${g.kind}`;
              const open = openGroups.has(key);
              return (
                <li key={g.kind}>
                  <button
                    type="button"
                    className={`explorer-data-usage-head${open ? ' is-open' : ''}`}
                    aria-expanded={open}
                    onClick={() => toggleGroup(key)}
                    title={t(`trace.data.usageKindHint.${g.kind}`, { defaultValue: '' }) as string}
                  >
                    <span aria-hidden="true">{open ? '▾' : '▸'}</span>
                    <span className="explorer-data-usage-kind">{t(`trace.data.usageKind.${g.kind}`, { defaultValue: g.kind })}</span>
                    <span className="explorer-chip-count">{g.n}</span>
                  </button>
                  {open && (
                    <ul className="explorer-data-entry-list">
                      {g.sample.map((id) => (
                        <li key={id}>
                          <NodeChip info={nodeInfo(id)} onHover={onHoverNode} onPick={onPickNode} />
                        </li>
                      ))}
                      {g.n > g.sample.length && (
                        <li className="explorer-data-more">{t('trace.ways.moreItems', { count: g.n - g.sample.length })}</li>
                      )}
                    </ul>
                  )}
                </li>
              );
            })}
          </ul>
        </section>
      )}

      <section className="explorer-data-section explorer-data-ways-section">
        {!up && <h3>{t('trace.data.waysDown')}</h3>}
        {ways.length === 0 ? (
          <p className="explorer-inspect-empty">{t(up ? 'trace.data.noWaysUp' : 'trace.data.noWaysDown')}</p>
        ) : (
          <ul className="explorer-data-ways">{roots.map((w) => renderWay(w, 0))}</ul>
        )}
      </section>

      {up && reset && reset.n > 0 && (
        <section className="explorer-data-section">
          <button
            type="button"
            className={`explorer-data-usage-head${openGroups.has('reset') ? ' is-open' : ''}`}
            aria-expanded={openGroups.has('reset')}
            onClick={() => toggleGroup('reset')}
            title={t('trace.data.resetGroupHint') as string}
          >
            <span aria-hidden="true">{openGroups.has('reset') ? '▾' : '▸'}</span>
            <span className="explorer-data-usage-kind">{t('trace.data.resetGroup')}</span>
            <span className="explorer-chip-count">{reset.n}</span>
          </button>
          {openGroups.has('reset') && (
            <ul className="explorer-data-entry-list">
              {reset.ways.map((r) => (
                <li key={r.wayId}>
                  <NodeChip info={nodeInfo(r.writer)} onHover={onHoverNode} onPick={onPickNode} />
                </li>
              ))}
            </ul>
          )}
        </section>
      )}
    </ExplorerWaysPanel>
  );
}
