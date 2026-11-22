import { useEffect, useMemo, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import type { CallSiteGuard, FlowEntryGroup, FlowWay, TraceResponse } from '../hooks/useTrace';
import { getTypeColor } from '../lib/graphColors';
import { useTriggerEventFormat } from '../lib/triggerEvents';
import { triggerSubroleLabel } from '../lib/graphEdgeLabels';
import { buildWayTree, expandWayPath, searchWays, stepRefTarget } from '../lib/traceWays';
import { ExplorerWaysPanel, WayItem, WayNodeChip, useOpenGroups, type WayNodeInfo } from './ExplorerWaysPanel';

/**
 * Right-hand panel of the flow trace: the ways of the script trace (SD2, SD15).
 *
 * Tabs in the order of the data-flow trace (origin first): "Reached from"
 * (`up`, default) | "Calls" (`down`).
 *
 * - "Calls" (`down`): one way per reached script (call tree over
 *   `parentWayId`; children collapsed, counter = subtree) — target, calling
 *   step with its condition, short chain, flags, effects of the target.
 * - "Reached from" (`up`): one way per entry script, grouped by entry kind —
 *   entry chips with counters (layouts on click), short chain to the start.
 *
 * Tabs switch without reloading (both directions arrive in one response).
 * Selecting a way highlights its path in the canvas; every way opens its
 * Mermaid diagram; steps open the script at that step. A search field keeps
 * the ways whose target (down) or entry script (up) carries the text in its
 * name, with their ancestors as context — deep call trees stay findable.
 */

/** Role colours of the flow-trace chips (Explorer tones, see graph-trace-mermaid.js). */
export const FLOW_TRACE_ROLE_COLORS: Readonly<Record<string, string>> = Object.freeze({
  start: '#f59e0b',
  step: '#0ea5e9',
  entry: '#ec4899',
  boundary: '#94a3b8',
  blind: '#ef4444',
});

/** Effect roles in display order (template `effects`). */
const EFFECT_ORDER = [
  'sets_field', 'reads_field', 'navigates_to_layout', 'navigates_to_to', 'sets_variable', 'reads_variable',
  'finds_in_field', 'sorts_by_field', 'navigates_to_field', 'inputs_to_field', 'imports_to_field',
  'exports_from_field', 'references_field', 'sorts_by_valuelist', 'installs_menuset',
  'calls_customfunction', 'calls_pluginfunction', 'calls_function',
];

/** Call-tree levels that indent; deeper levels stay flush (level badge). */
const INDENT_LEVELS = 4;

const ENTRY_ORDER = ['button', 'trigger', 'menu', 'file', 'root', 'budget', 'excluded'];

/** Resolver id → display info for the flow trace (canvas node, ref or bare id). */
export function makeFlowNodeInfo(data: TraceResponse | null): (id: string | null) => WayNodeInfo | null {
  const byId = new Map((data?.nodes ?? []).map((n) => [n.id, n]));
  const refs = data?.trace.refs ?? {};
  return (id) => {
    if (!id) return null;
    const sep = id.indexOf('::');
    const file = sep === -1 ? null : id.slice(sep + 2);
    const uuid = (sep === -1 ? id : id.slice(0, sep)).split('#')[0];
    const n = byId.get(id);
    if (n) {
      return {
        id, uuid: n.uuid, label: n.label, type: n.type, file: n.file,
        flowRole: n.isFocus ? 'start' : null, stepIndex: null, scriptUuid: null,
        ownerUuid: null, ownerType: null, inGraph: true,
        open: n.open ?? { type: n.type, uuid: n.uuid, file: n.file },
      };
    }
    const r = refs[id];
    if (r) {
      const isStep = r.type === 'ScriptStep' || r.type === 'DynamicCall';
      return {
        id, uuid, label: r.label ?? uuid, type: r.type ?? 'Object', file: r.file ?? file,
        flowRole: r.type === 'DynamicCall' ? 'blind' : isStep ? 'step' : r.flowRole ?? null,
        stepIndex: r.stepIndex ?? null, scriptUuid: r.script ?? null,
        ownerUuid: null, ownerType: null, inGraph: false,
        open: isStep && r.script ? stepRefTarget(id, r.script) : r.open ?? { type: r.type ?? 'Object', uuid, file: r.file ?? file },
      };
    }
    return {
      id, uuid, label: uuid, type: 'Object', file, flowRole: null, stepIndex: null, scriptUuid: null,
      ownerUuid: null, ownerType: null, inGraph: false,
    };
  };
}

/** Condition of a call site as the catalog's step names write it (If / Else If / Else). */
export function guardText(g: CallSiteGuard | undefined | null): { short: string; full: string } | null {
  if (!g) return null;
  const head = g.kind === 'if' ? 'If' : g.kind === 'elseif' ? 'Else If' : g.kind === 'else' ? 'Else' : g.kind;
  if (g.kind === 'else') return { short: head, full: head };
  return { short: `${head} ${g.text ?? ''}`.trim(), full: `${head} ${g.textFull ?? g.text ?? ''}`.trim() };
}

interface ExplorerFlowWaysPanelProps {
  width?: number;
  data: TraceResponse;
  dir: 'up' | 'down';
  onDirChange: (dir: 'up' | 'down') => void;
  nodeInfo: (id: string | null) => WayNodeInfo | null;
  selectedWayId: string | null;
  /** Entry group to open (diagram click on an entry node): `<wayId>|<kind>|<event>`. */
  openGroupKey: string | null;
  /** „Quelle verfolgen" aufwärts: aufgeklappte Weg-IDs, Deckel, Aktion. */
  expandedWayIds: string[];
  canExpandMore: boolean;
  onExpandWay: (wayId: string) => void;
  onSelectWay: (way: FlowWay | null) => void;
  onShowMermaid: (wayNo: number) => void;
  onHoverNode: (id: string | null) => void;
  /** List pick: canvas node → highlight, else jump; `navigate` = always jump. */
  onPickNode: (info: WayNodeInfo, navigate?: boolean) => void;
  onOpenTrace: (uuid: string, file: string | null) => void;
  onClose: () => void;
}

export function ExplorerFlowWaysPanel(props: ExplorerFlowWaysPanelProps) {
  const {
    width, data, dir, onDirChange, nodeInfo, selectedWayId, openGroupKey, expandedWayIds, canExpandMore, onExpandWay,
    onSelectWay, onShowMermaid, onHoverNode, onPickNode, onOpenTrace, onClose,
  } = props;
  const { t } = useTranslation(['explorer', 'common']);
  const formatTriggerEvent = useTriggerEventFormat();
  // Ereignis wie im Canvas: Trigger-Events lokalisiert, Button-/Menü-Aktion als Text.
  const formatEvent = (ev: string) => triggerSubroleLabel(ev, formatTriggerEvent, {
    buttonAction: t('edge.buttonAction', { defaultValue: 'Button-Aktion' }) as string,
    menuAction: t('edge.menuAction', { defaultValue: 'Menü-Aktion' }) as string,
    represents: t('edge.represents', { defaultValue: 'repräsentiert' }) as string,
  });
  const up = dir === 'up';
  const allWays = useMemo(() => data.trace.ways ?? [], [data]);
  const ways = useMemo(() => allWays.filter((w) => w.dir === dir), [allWays, dir]);
  const stats = data.trace.stats;
  const shown = stats.ways?.[dir] ?? ways.length;
  const total = stats.waysTotal?.[dir] ?? shown;

  const typeOf = useMemo(() => {
    const byId = new Map(data.nodes.map((n) => [n.id, n.type]));
    const refs = data.trace.refs ?? {};
    return (id: string) => byId.get(id) ?? refs[id]?.type ?? null;
  }, [data]);

  const { roots, children } = useMemo(() => buildWayTree(ways), [ways]);
  const { open: openGroups, toggle: toggleGroup, ensure: ensureGroup } = useOpenGroups(
    ENTRY_ORDER.map((k) => `group|${k}`),
  );

  // Selection from outside (diagram click, deep link `way=`, canvas): open the
  // ancestors in the call tree and scroll the way into view. The row exists
  // only after the opened levels rendered — scroll once it is in the DOM.
  const pendingScroll = useRef<string | null>(null);
  useEffect(() => {
    if (!selectedWayId) return;
    const byId = new Map(ways.map((w) => [w.wayId, w]));
    let cur = byId.get(selectedWayId);
    if (!cur) return;
    const seen = new Set<string>();
    while (cur?.parentWayId && !seen.has(cur.parentWayId)) {
      seen.add(cur.parentWayId);
      ensureGroup(`tree|${cur.parentWayId}`);
      cur = byId.get(cur.parentWayId);
    }
    // Gruppe aufwärts = Einstiegsart des obersten Wegs (Kind-Wege hängen darunter)
    const primary = (cur ?? byId.get(selectedWayId))?.entryGroups?.[0]?.kind;
    if (primary) ensureGroup(`group|${primary}`);
    pendingScroll.current = selectedWayId;
  }, [selectedWayId, ways, ensureGroup]);
  // After every render (declared after the reveal effect: same commit first).
  useEffect(() => {
    const id = pendingScroll.current;
    if (!id) return;
    const el = document.getElementById(`flow-way-${id}`);
    if (!el) return;
    pendingScroll.current = null;
    el.scrollIntoView({ block: 'nearest' });
  });

  useEffect(() => {
    if (openGroupKey) ensureGroup(openGroupKey);
  }, [openGroupKey, ensureGroup]);

  // Search: a hit is a way whose target script (down) or entry script (up)
  // carries the text in its name; hits and their ancestors stay visible,
  // ancestors only as context. Covers the loaded ways (ways_limit).
  const [query, setQuery] = useState('');
  const startKey = `${data.trace.start?.uuid ?? ''}::${data.trace.start?.file ?? ''}`;
  useEffect(() => setQuery(''), [startKey]);
  const search = useMemo(() => {
    const refs = data.trace.refs ?? {};
    return searchWays(
      ways,
      (w) => (w.kind === 'dynamic' ? (refs[w.target]?.name ?? '') : (nodeInfo(w.target)?.label ?? '')),
      query,
    );
  }, [query, ways, nodeInfo, data]);
  const hidden = (w: FlowWay) => search !== null && !search.keep.has(w.wayId);
  const contextClass = (w: FlowWay) => (search && !search.hits.has(w.wayId) ? 'is-context' : undefined);

  const chip = (id: string | null) => (
    <WayNodeChip info={nodeInfo(id)} roleColors={FLOW_TRACE_ROLE_COLORS} onHover={onHoverNode} onPick={(i) => onPickNode(i)} />
  );

  /** Short chain of scripts/layouts on the full path (steps left out). */
  const shortChain = (w: FlowWay) => {
    const { pathNodes } = expandWayPath(allWays, w, typeOf);
    const names = pathNodes
      .filter((id) => {
        const ty = typeOf(id);
        return ty !== 'ScriptStep' && ty !== 'DynamicCall';
      })
      .map((id) => nodeInfo(id)?.label ?? id);
    const full = names.join(' → ');
    const cut = names.length > 4 ? [names[0], '…', ...names.slice(-2)] : names;
    return { full, short: cut.join(' → '), n: names.length };
  };

  const flagChips = (w: FlowWay) => {
    const f = w.flags ?? { conditions: 0 };
    const out: { key: string; text: string; hint: string; warn?: boolean }[] = [];
    if ((f.conditions ?? 0) === 0) {
      out.push({ key: 'always', text: t('trace.flow.flags.always'), hint: t('trace.flow.flags.alwaysHint') });
    } else {
      out.push({
        key: 'cond', text: t('trace.flow.flags.conditions', { count: f.conditions }),
        hint: t('trace.flow.flags.conditionsHint'),
      });
    }
    if (f.loop) out.push({ key: 'loop', text: `↻ ${t('trace.flow.flags.loop')}`, hint: t('trace.flow.flags.loopHint') });
    if (f.server) out.push({ key: 'server', text: t('trace.flow.flags.server'), hint: t('trace.flow.flags.serverHint') });
    if (f.crossFile) out.push({ key: 'file', text: `${t('trace.flow.flags.crossFile')} ↗`, hint: t('trace.flow.flags.crossFileHint') });
    if (f.param) out.push({ key: 'param', text: t('trace.flow.flags.param'), hint: t('trace.flow.flags.paramHint') });
    if (f.unreachable) {
      out.push({ key: 'dead', text: t('trace.flow.flags.unreachable'), hint: t('trace.flow.flags.unreachableHint'), warn: true });
    }
    if (w.precision === 'approx') {
      out.push({ key: 'approx', text: `≈ ${t('trace.flow.flags.approx')}`, hint: t('trace.flow.flags.approxHint'), warn: true });
    } else if (w.precision === 'dynamic') {
      out.push({ key: 'dyn', text: t('trace.flow.flags.dynamic'), hint: t('trace.flow.flags.dynamicHint'), warn: true });
    }
    return (
      <div className="explorer-flow-flags">
        {out.map((c) => (
          <span key={c.key} className={`explorer-flow-flag${c.warn ? ' is-warn' : ''}`} title={c.hint}>{c.text}</span>
        ))}
      </div>
    );
  };

  /** Effects of a script (canvas node): one line, expandable to the touched objects. */
  const effectsRow = (w: FlowWay) => {
    const node = data.nodes.find((n) => n.id === w.target);
    const eff = node?.effects;
    if (!eff) return null;
    const roles = EFFECT_ORDER.filter((r) => (eff[r] ?? 0) > 0)
      .concat(Object.keys(eff).filter((r) => !EFFECT_ORDER.includes(r) && eff[r] > 0));
    if (roles.length === 0) return null;
    const key = `eff|${w.wayId}`;
    const open = openGroups.has(key);
    // Script in a file without DDR info: reads from formulas are missing there —
    // the whole line is marked, a read that drops to zero would leave no count to mark.
    const noDdr = !!node?.file && (data.trace.blindSpots?.noDdr?.files ?? []).includes(node.file);
    const effText = (r: string) => t(`trace.flow.effect.${r}`, { count: eff[r], defaultValue: `${r} ${eff[r]}` });
    const line = roles.map(effText).join(' · ') + (noDdr ? ` ${t('trace.flow.effectNoDdr')}` : '');
    return (
      <div className="explorer-data-row">
        <span className="explorer-data-row-label">{t('trace.flow.effects')}</span>
        <span className="explorer-data-row-items">
          <button
            type="button"
            className={`explorer-flow-effects${open ? ' is-open' : ''}`}
            aria-expanded={open}
            onClick={() => toggleGroup(key)}
            title={(noDdr ? t('trace.flow.effectNoDdrHint') : t('trace.flow.effectsHint')) as string}
          >
            <span aria-hidden="true">{open ? '▾' : '▸'}</span> {line}
          </button>
          {open && (
            <ul className="explorer-data-entry-list">
              {roles.map((r) => {
                const targets = data.edges.filter((e) => e.source === w.target && e.role === r).map((e) => e.target);
                return (
                  <li key={r}>
                    <span className="explorer-flow-effect-role">{effText(r)}</span>
                    {[...new Set(targets)].slice(0, 12).map((id) => <div key={id}>{chip(id)}</div>)}
                    {eff[r] > targets.length && (
                      <span className="explorer-data-more">{t('trace.flow.effectsOutside', { count: eff[r] - new Set(targets).size })}</span>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </span>
      </div>
    );
  };

  const guardSpan = (g: CallSiteGuard | undefined) => {
    const gt = guardText(g);
    return gt ? <span className="explorer-flow-guard" title={gt.full}>{gt.short}</span> : null;
  };

  // ── down: call tree ──────────────────────────────────────────────────────
  const renderDown = (w: FlowWay, depth: number) => {
    if (hidden(w)) return null;
    const selected = w.wayId === selectedWayId;
    const allKids = children.get(w.wayId) ?? [];
    // While searching only the kept children show, opened; the toggle hides.
    const kids = search ? allKids.filter((k) => !hidden(k)) : allKids;
    const treeKey = `tree|${w.wayId}`;
    const treeOpen = search ? kids.length > 0 : openGroups.has(treeKey);
    const target = nodeInfo(w.target);
    const refs = data.trace.refs ?? {};
    // The section ends …, step, target (call) or …, step, layout, target (cascade).
    const p = w.pathNodes;
    const layoutId = w.kind === 'cascade' ? p[p.length - 2] : null;
    const stepId = w.kind === 'cascade' ? p[p.length - 3] : w.kind === 'dynamic' ? w.target : p[p.length - 2];
    const stepRef = stepId ? refs[stepId] : undefined;
    const step = stepRef && (stepRef.type === 'ScriptStep' || stepRef.type === 'DynamicCall') ? nodeInfo(stepId) : null;
    const chain = w.level > 1 ? shortChain(w) : null;
    const eventText = w.event ? formatEvent(w.event) : null;
    return (
      <WayItem
        key={w.wayId}
        domId={`flow-way-${w.wayId}`}
        selected={selected}
        depth={depth}
        className={contextClass(w)}
        onToggle={() => onSelectWay(selected ? null : w)}
        head={(
          <>
            <span className="explorer-data-way-no">#{w.wayNo}</span>
            {w.level > 1 && (
              <span className="explorer-data-badge" title={t('trace.flow.depthHint') as string}>{t('trace.flow.depth', { level: w.level })}</span>
            )}
            <span className="explorer-flow-target" title={target?.file ? `${target.label} · ${target.file}` : target?.label}>
              {w.kind === 'dynamic' ? (refs[w.target]?.name ?? t('trace.flow.unresolvedName')) : target?.label}
            </span>
            {/* dynamic: Titel und Kennzeichen sagen es schon */}
            {w.kind !== 'call' && w.kind !== 'dynamic' && (
              <span className="explorer-data-badge" title={t(`trace.flow.kindHint.${w.kind}`, { defaultValue: '' }) as string}>
                {eventText ?? t(`trace.flow.kind.${w.kind}`, { defaultValue: w.kind })}
              </span>
            )}
            {kids.length > 0 && !search && (
              <button
                type="button"
                className={`explorer-flow-tree-toggle${treeOpen ? ' is-open' : ''}`}
                aria-expanded={treeOpen}
                title={t('trace.flow.subtreeHint', { count: w.nDesc }) as string}
                onClick={(e) => {
                  e.stopPropagation();
                  toggleGroup(treeKey);
                }}
              >
                <span aria-hidden="true">{treeOpen ? '▾' : '▸'}</span> {w.nDesc}
              </button>
            )}
          </>
        )}
        nested={kids.length > 0 && treeOpen
          // Each nested list sits inside its parent row — one indent step per
          // level up to level 4; deeper levels keep the width (level badge).
          ? <ul className="explorer-data-ways">{kids.map((k) => renderDown(k, k.level <= INDENT_LEVELS ? 1 : 0))}</ul>
          : undefined}
      >
        {step && (
          <div className="explorer-data-row">
            <span className="explorer-data-row-label">{t('trace.flow.callStep')}</span>
            <span className="explorer-data-row-items">
              {chip(stepId)}
              {guardSpan(stepRef?.site?.guard)}
              {stepRef?.site?.passesParam && (
                <span className="explorer-flow-guard" title={stepRef.site.passesParam}>
                  {t('trace.flow.param')}: {stepRef.site.passesParam}
                </span>
              )}
            </span>
          </div>
        )}
        {layoutId && (
          <div className="explorer-data-row">
            <span className="explorer-data-row-label">{t('trace.flow.layout')}</span>
            <span className="explorer-data-row-items">{chip(layoutId)}</span>
          </div>
        )}
        {/* Trigger of the start layout: the owner (layout object, field, layout) */}
        {w.kind === 'trigger' && w.eventOwner && (
          <div className="explorer-data-row">
            <span className="explorer-data-row-label">{t('trace.flow.eventOwner')}</span>
            <span className="explorer-data-row-items">{chip(w.eventOwner)}</span>
          </div>
        )}
        {w.kind === 'dynamic' && stepRef?.blindKind && (
          <p className="explorer-data-hint">{t(`trace.flow.blindKind.${stepRef.blindKind}`, { defaultValue: stepRef.blindKind })}</p>
        )}
        {chain && <div className="explorer-flow-chain" title={chain.full}>{chain.short}</div>}
        {flagChips(w)}
        {effectsRow(w)}
        <div className="explorer-data-way-actions">
          <button type="button" onClick={() => onShowMermaid(w.wayNo)} title={t('trace.ways.diagramHint') as string}>
            {t('trace.ways.diagram')}
          </button>
          {step && (
            <button type="button" onClick={() => onPickNode(step, true)} title={t('trace.flow.openStepHint') as string}>
              {t('trace.flow.openStep')}
            </button>
          )}
          {target && target.type === 'Script' && (
            <button type="button" onClick={() => onOpenTrace(target.uuid, target.file)} title={t('trace.flow.traceFromHereHint') as string}>
              {t('trace.flow.traceFromHere')}
            </button>
          )}
        </div>
      </WayItem>
    );
  };

  // ── up: ways grouped by entry kind ───────────────────────────────────────
  const entryChipText = (g: FlowEntryGroup) => {
    if (g.kind === 'root' || g.kind === 'budget' || g.kind === 'excluded') {
      return t(`trace.flow.entryKind.${g.kind}`, { count: g.n }) as string;
    }
    const kind = t(`trace.flow.entryKind.${g.kind}`, { count: g.n, defaultValue: g.kind }) as string;
    const event = g.event ? formatEvent(g.event) : null;
    const layouts = g.nLayouts > 0 ? ` · ${t('trace.flow.onLayouts', { count: g.nLayouts })}` : '';
    return `${g.n} ${kind}${event ? ` (${event})` : ''}${layouts}`;
  };

  const renderUp = (w: FlowWay, depth: number) => {
    if (hidden(w)) return null;
    const selected = w.wayId === selectedWayId;
    const entry = nodeInfo(w.target);
    const chain = w.level > 0 ? shortChain(w) : null;
    const kids = (children.get(w.wayId) ?? []).filter((k) => !hidden(k));
    const expanded = expandedWayIds.includes(w.wayId);
    // „Quelle verfolgen": an Button-, Trigger- und Budget-Einstiegen;
    // Kind-Wege nicht weiter (der Server kennt nur die Wege des Aufwärts-Walks).
    const followable = !w.parentWayId
      && (w.entryGroups ?? []).some((g) => g.kind === 'button' || g.kind === 'trigger' || g.kind === 'budget');
    return (
      <WayItem
        key={w.wayId}
        domId={`flow-way-${w.wayId}`}
        selected={selected}
        depth={depth}
        className={contextClass(w)}
        onToggle={() => onSelectWay(selected ? null : w)}
        nested={kids.length > 0
          ? <ul className="explorer-data-ways">{kids.map((k) => renderUp(k, 1))}</ul>
          : undefined}
        head={(
          <>
            <span className="explorer-data-way-no">#{w.wayNo}</span>
            <span className="explorer-flow-target" title={entry?.file ? `${entry.label} · ${entry.file}` : entry?.label}>
              {entry?.label}
            </span>
            <span className="explorer-data-badge" title={t('trace.flow.levelHint') as string}>
              {w.level === 0 ? t('trace.flow.isStart') : t('trace.flow.level', { count: w.level })}
            </span>
          </>
        )}
      >
        {(w.entryGroups ?? []).length > 0 && (
          <div className="explorer-data-entries">
            {(w.entryGroups ?? []).map((g) => {
              const key = `${w.wayId}|${g.kind}|${g.event ?? ''}`;
              const open = openGroups.has(key);
              const expandable = g.layouts.length > 0 || g.sample.length > 0;
              const boundary = g.kind === 'root' || g.kind === 'budget' || g.kind === 'excluded';
              return (
                <div key={key} className="explorer-data-entry">
                  <button
                    type="button"
                    className={`explorer-data-entry-chip${open ? ' is-open' : ''}${boundary ? ' is-boundary' : ''}`}
                    aria-expanded={expandable ? open : undefined}
                    disabled={!expandable}
                    onClick={() => toggleGroup(key)}
                    title={(boundary
                      ? t(`trace.flow.entryKindHint.${g.kind}`)
                      : t('trace.ways.entryChipHint')) as string}
                  >
                    {entryChipText(g)}
                  </button>
                  {open && expandable && (
                    <ul className="explorer-data-entry-list">
                      {g.layouts.map((l) => (
                        <li key={`${l.uuid}::${l.file ?? ''}`}>
                          <button
                            type="button"
                            className="explorer-data-node"
                            onClick={() => onPickNode({
                              id: `${l.uuid}::${l.file ?? ''}`, uuid: l.uuid, label: l.name, type: 'Layout', file: l.file,
                              flowRole: null, stepIndex: null, scriptUuid: null, ownerUuid: null, ownerType: null, inGraph: false,
                              open: { type: 'Layout', uuid: l.uuid, file: l.file },
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
                      {g.sample.map((id) => <li key={id}>{chip(id)}</li>)}
                      {g.n > g.sample.length && g.sample.length > 0 && (
                        <li className="explorer-data-more">{t('trace.ways.moreItems', { count: g.n - g.sample.length })}</li>
                      )}
                    </ul>
                  )}
                </div>
              );
            })}
          </div>
        )}
        {chain && <div className="explorer-flow-chain" title={chain.full}>{chain.short}</div>}
        {flagChips(w)}
        {expanded && kids.length === 0 && !search && (
          <p className="explorer-data-hint">{t('trace.flow.followSourceNone')}</p>
        )}
        <div className="explorer-data-way-actions">
          <button type="button" onClick={() => onShowMermaid(w.wayNo)} title={t('trace.ways.diagramHint') as string}>
            {t('trace.ways.diagram')}
          </button>
          {followable && !expanded && (
            <button
              type="button"
              onClick={() => onExpandWay(w.wayId)}
              disabled={!canExpandMore}
              title={t('trace.flow.followSourceHint') as string}
            >
              {t('trace.flow.followSource')}
            </button>
          )}
          {entry && w.level > 0 && (
            <button type="button" onClick={() => onPickNode(entry, true)} title={t('trace.flow.openEntryHint') as string}>
              {t('trace.flow.openEntry')}
            </button>
          )}
          {entry && entry.type === 'Script' && w.level > 0 && (
            <button type="button" onClick={() => onOpenTrace(entry.uuid, entry.file)} title={t('trace.flow.traceFromHereHint') as string}>
              {t('trace.flow.traceFromHere')}
            </button>
          )}
        </div>
      </WayItem>
    );
  };

  const upGroups = useMemo(() => {
    if (!up) return [];
    const m = new Map<string, FlowWay[]>();
    // Nur oberste Wege gruppieren; „Quelle verfolgen"-Wege hängen unter ihrem Eltern-Weg.
    for (const w of roots) {
      const k = w.entryGroups?.[0]?.kind ?? 'root';
      const list = m.get(k) ?? [];
      list.push(w);
      m.set(k, list);
    }
    const kinds = [...m.keys()].sort((a, b) => {
      const ia = ENTRY_ORDER.indexOf(a);
      const ib = ENTRY_ORDER.indexOf(b);
      return (ia === -1 ? 99 : ia) - (ib === -1 ? 99 : ib) || a.localeCompare(b);
    });
    return kinds.map((k) => ({ kind: k, ways: m.get(k) ?? [] }));
  }, [up, roots]);

  const tabs = (
    <div className="explorer-segmented explorer-flow-tabs" role="tablist" aria-label={t('trace.flow.tabsLabel') as string}>
      {(['up', 'down'] as const).map((d) => (
        <button
          key={d}
          type="button"
          role="tab"
          aria-selected={dir === d}
          className={`explorer-segment${dir === d ? ' is-active' : ''}`}
          onClick={() => onDirChange(d)}
          title={t(`trace.flow.tab.${d}Hint`) as string}
        >
          {t(`trace.flow.tab.${d}`)}{' '}
          <span className="explorer-chip-count">{stats.ways?.[d] ?? 0}</span>
        </button>
      ))}
    </div>
  );

  return (
    <ExplorerWaysPanel
      width={width}
      title={t('trace.flow.waysTitle') as string}
      count={shown}
      overviewHint={t(up ? 'trace.flow.overviewUpHint' : 'trace.flow.overviewDownHint') as string}
      onOverview={() => onShowMermaid(0)}
      onClose={onClose}
      onHoverNode={onHoverNode}
      cut={{ shown, total }}
      tabs={tabs}
      className="explorer-flow-panel"
    >
      <section className="explorer-data-section explorer-data-ways-section">
        {ways.length > 1 && (
          <div className="explorer-search-box explorer-flow-search">
            <input
              type="text"
              value={query}
              aria-label={t('trace.flow.search') as string}
              placeholder={t('trace.flow.searchPlaceholder') as string}
              onChange={(e) => setQuery(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Escape' && query) {
                  e.stopPropagation();
                  setQuery('');
                }
              }}
              autoComplete="off"
            />
            {query && (
              <button
                type="button"
                className="explorer-search-clear"
                onClick={() => setQuery('')}
                aria-label={t('trace.flow.searchClear') as string}
                title={t('trace.flow.searchClear') as string}
              >
                ✕
              </button>
            )}
          </div>
        )}
        {search && (
          <p className="explorer-data-hint">
            {search.hits.size > 0 ? t('trace.flow.searchHits', { count: search.hits.size }) : t('trace.flow.searchNone')}
          </p>
        )}
        {ways.length === 0 ? (
          <p className="explorer-inspect-empty">{t(up ? 'trace.flow.noWaysUp' : 'trace.flow.noWaysDown')}</p>
        ) : up ? (
          upGroups.map((g) => {
            const key = `group|${g.kind}`;
            if (search && g.ways.every(hidden)) return null;
            const open = search ? true : openGroups.has(key);
            return (
              <div key={g.kind} className="explorer-flow-group">
                <button
                  type="button"
                  className={`explorer-data-usage-head${open ? ' is-open' : ''}`}
                  aria-expanded={open}
                  onClick={() => toggleGroup(key)}
                >
                  <span aria-hidden="true">{open ? '▾' : '▸'}</span>
                  <span className="explorer-data-usage-kind">{t(`trace.flow.entryGroup.${g.kind}`, { defaultValue: g.kind })}</span>
                  <span className="explorer-chip-count">{search ? g.ways.filter((w) => !hidden(w)).length : g.ways.length}</span>
                </button>
                {open && <ul className="explorer-data-ways">{g.ways.map((w) => renderUp(w, 0))}</ul>}
              </div>
            );
          })
        ) : (
          <ul className="explorer-data-ways">{roots.map((w) => renderDown(w, 0))}</ul>
        )}
      </section>
    </ExplorerWaysPanel>
  );
}
