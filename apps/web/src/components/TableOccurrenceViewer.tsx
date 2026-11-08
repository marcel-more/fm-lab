import React, { useMemo, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { usePersistentState } from '../hooks/usePersistentState';
import { buildObjectPath } from '../lib/navigation';
import { operatorSymbol } from '../lib/relationshipOperator';
import {
  contextModel,
  filterSortSiblings,
  groupRelationships,
  groupUsage,
  IN_PAGE_USAGE_FILTER,
  RELATIONSHIP_OPTIONS,
  relationshipHasOption,
  siblingViews,
  summarizeAnchors,
  toHexColor,
  type RelationshipOption,
  type RelationshipView,
  type SiblingScope,
  type SiblingSortKey,
  type SideOptions,
  type TableOccurrenceRow,
} from '../lib/tableOccurrenceDetail';
import { DisclosureChevron } from './DisclosureChevron';
import './TableOccurrenceViewer.css';

interface TableOccurrenceViewerProps {
  data: Array<Record<string, unknown>>;
  /** false = catalog older than schema 1.38.0 (no usage tables), null = unknown. */
  usageAvailable: boolean | null;
}

/** Relationship lists above this size get a search field. */
const SEARCH_THRESHOLD = 8;
/*
 * Tables are never cut: every row is rendered (Ctrl+F finds everything),
 * navigation runs through search, chips, sorting and the count rows of the
 * definition card.
 */

type RelSortKey = 'partner' | 'rel';

/**
 * Structured detail view of a table occurrence — the profile of the TO; name,
 * file, UUID and the link into the relationship graph live in the
 * ObjectHeader above and are not repeated here.
 *  - Definition: data source (current file or a named one, incl. one that
 *    points back at this file), base table with the file it lives in, colour
 *    and view mode in the relationship graph. "External" is never shown as
 *    such — it would mix up where the TO and where its base table live.
 *    Below them three count rows: relationships and other occurrences (each
 *    opens and scrolls to its section further down) and the layouts based on
 *    this TO (opens the references tab filtered to layouts).
 *  - Usage: usage class (neutral badge) + counts per category; each chip opens
 *    the references tab filtered to that category, single usages stay there.
 *  - TO group: connected component in the file's relationship graph, the
 *    nearest layout context (with the step count; from two steps on the path
 *    opens as a vertical list) and the layout anchors. No diagram here — the
 *    relationship graph is the graphical view.
 *  - Relationships: one block per relationship, normalised so this TO is the
 *    left side (operators mirrored), options of both sides as symbols.
 *    Tables are always complete (sticky header, "n of m" when filtered).
 *    The usage chip of cascade deletes filters that list instead (the
 *    references tab does not list cascade rows on their own).
 *  - Other occurrences of the same base table, solution-wide: one table with
 *    search, sorting and a scope filter (all / this file / other files); the
 *    file column stays empty for this file.
 *  - Both list sections collapse behind a disclosure chevron (closed by
 *    default); the last state of each is remembered in the browser
 *    (localStorage) across TOs. An empty list stays open with the toggle
 *    disabled. A usage chip or a count row of the definition card opens its
 *    target section.
 */
export const TableOccurrenceViewer: React.FC<TableOccurrenceViewerProps> = ({ data, usageAvailable }) => {
  const { t } = useTranslation(['detail', 'common']);
  const { uuid: currentUuid } = useParams<{ uuid: string }>();

  const rows = data as unknown as TableOccurrenceRow[];
  const meta = rows.find((r) => r.section === 'meta');
  const usageClass = rows.find((r) => r.section === 'usage_class') ?? null;
  const usageGroups = useMemo(() => groupUsage(rows), [rows]);
  const relationships = useMemo(() => groupRelationships(rows), [rows]);
  const context = useMemo(() => contextModel(rows), [rows]);
  const anchorSummary = useMemo(() => (context ? summarizeAnchors(context.anchors) : null), [context]);
  const [anchorsOpen, setAnchorsOpen] = useState(false);
  const [pathOpen, setPathOpen] = useState(false);
  const ownFile = meta?.file_name ?? null;
  const siblings = useMemo(() => siblingViews(rows, ownFile), [rows, ownFile]);

  const [search, setSearch] = useState('');
  const [sortKey, setSortKey] = useState<RelSortKey>('partner');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc');
  const [relOption, setRelOption] = useState<RelationshipOption | null>(null);
  const relSectionRef = useRef<HTMLElement>(null);
  // Browser-local, persistent open state of the two list sections (same
  // pattern as the layout properties panel) — default: closed.
  const [relOpenPref, setRelOpenPref] = usePersistentState<'0' | '1'>(
    'fmlab.to.relationshipsOpen', '0', ['0', '1'] as const,
  );
  const [sibOpenPref, setSibOpenPref] = usePersistentState<'0' | '1'>(
    'fmlab.to.siblingsOpen', '0', ['0', '1'] as const,
  );

  const [sibScope, setSibScope] = useState<SiblingScope>('all');
  const [sibSearch, setSibSearch] = useState('');
  const [sibSortKey, setSibSortKey] = useState<SiblingSortKey>('file');
  const [sibSortDir, setSibSortDir] = useState<'asc' | 'desc'>('asc');
  const sibSectionRef = useRef<HTMLElement>(null);
  const visibleSiblings = useMemo(
    () => filterSortSiblings(siblings, sibScope, sibSearch, sibSortKey, sibSortDir),
    [siblings, sibScope, sibSearch, sibSortKey, sibSortDir],
  );

  const searchLower = search.trim().toLowerCase();
  const visibleRelationships = useMemo(() => {
    const filtered = relationships.filter((rel) =>
      (!relOption || relationshipHasOption(rel, relOption))
      && (!searchLower
        || [rel.partnerName, rel.partnerBaseTable, ...rel.predicates.flatMap((p) => [p.selfField, p.partnerField])]
          .some((v) => (v ?? '').toLowerCase().includes(searchLower))));
    const sorted = [...filtered].sort((a, b) => {
      const cmp = sortKey === 'rel'
        ? a.relId - b.relId
        : (a.partnerName ?? '').localeCompare(b.partnerName ?? '') || a.relId - b.relId;
      return sortDir === 'asc' ? cmp : -cmp;
    });
    return sorted;
  }, [relationships, searchLower, sortKey, sortDir, relOption]);

  if (!meta) return <div className="no-references">{t('common:noData')}</div>;

  const file = meta.file_name ?? null;
  const isExternal = meta.to_type === 'External';
  const k = (key: string, defaultValue: string, opts?: Record<string, unknown>) =>
    t(`detail:tableOccurrence.${key}`, { defaultValue, ...opts }) as string;

  const objLink = (label: React.ReactNode, uuid: string | null | undefined, targetFile: string | null | undefined, className?: string) =>
    uuid
      ? <Link to={buildObjectPath(uuid, currentUuid ?? null, targetFile ?? null)} className={className ?? 'fm-to-link'}>{label}</Link>
      : <span className={className}>{label}</span>;

  const selfPath = (extras: Record<string, string>) =>
    buildObjectPath(currentUuid ?? '', null, file, extras);

  // ── Definition ──
  const color = toHexColor(meta.color_r, meta.color_g, meta.color_b);
  const viewLabel = meta.view_state
    ? k(`view.${meta.view_state}`, meta.view_state)
    : null;

  // Count rows of the definition card. `layout_context` counts the layouts
  // whose context is this TO — the same set the references tab lists under
  // its "Layout" type filter.
  const layoutCount = usageGroups
    .flatMap((g) => g.items)
    .find((i) => i.category === 'layout_context')?.users ?? 0;
  // Open the section first, scroll on the next frame: a collapsed page may be
  // too short to bring the heading to the top until the content is rendered.
  const openAndJump = (ref: React.RefObject<HTMLElement>, open: () => void) => {
    open();
    requestAnimationFrame(() => ref.current?.scrollIntoView({ behavior: 'smooth', block: 'start' }));
  };
  const countLink = (count: number, title: string, onClick: () => void) =>
    count > 0
      ? <button type="button" className="fm-to-link fm-to-link-btn fm-to-num-link" title={title} onClick={onClick}>{count}</button>
      : <span className="fm-to-muted">0</span>;

  const definition = (
    <section className="fm-to-card" aria-labelledby="fm-to-def-head">
      <h3 id="fm-to-def-head" className="fm-to-card-head">{k('definitionHeading', 'Definition')}</h3>
      <dl className="fm-to-dl">
        {/* Order and wording follow FileMaker's "Specify Table" dialog: first the
            data source (current file or a named data source), then the table.
            "External" (TO_Type) is not shown as such — it only says "through a
            data source", which may even point back at this very file. Where the
            base table lives is stated explicitly on the base table row. */}
        <dt>{k('dataSource', 'Datenquelle')}</dt>
        <dd>
          {!isExternal ? (
            <span title={k('dataSourceCurrentTitle', 'Die Basistabelle wird ohne Datenquelle direkt aus dieser Datei verwendet')}>
              {k('dataSourceCurrent', 'aktuelle Datei')}
            </span>
          ) : meta.ds_name ? (
            <>
              <span>{meta.ds_name}</span>
              {meta.ds_type && <span className="fm-to-muted"> · {meta.ds_type}</span>}
              {meta.ds_path && <code className="fm-to-path">{meta.ds_path}</code>}
              <div className="fm-to-ds-state">
                {meta.ds_resolved_self
                  ? <span className="fm-to-warn">↺ {k('dsSelf', 'verweist auf diese Datei selbst')}</span>
                  : meta.ds_resolved_imported && meta.ds_resolved_file
                    ? <span className="fm-to-ok">✓ {k('dsResolved', 'Datei „{{file}}“ im Katalog', { file: meta.ds_resolved_file })}</span>
                    : <span className="fm-to-warn">{k('dsUnresolved', 'Zieldatei nicht importiert')}</span>}
              </div>
            </>
          ) : <span className="fm-to-muted">—</span>}
        </dd>

        <dt>{k('baseTable', 'Basistabelle')}</dt>
        <dd>
          {meta.bt_name
            ? objLink(meta.bt_name, meta.bt_uuid, meta.bt_file)
            : <span className="fm-to-muted">{k('baseTableUnresolved', '— nicht auflösbar —')}</span>}
          {meta.bt_file && (meta.bt_cross_file
            ? (
              <>
                <span className="fm-to-muted"> {k('inFile', 'in Datei „{{file}}“', { file: meta.bt_file })}</span>
                <span className="fm-to-badge fm-to-badge--accent">{t('detail:baseTable.scopeCrossFile', { defaultValue: 'Cross-File' })}</span>
              </>
            )
            : <span className="fm-to-muted"> {k('inThisFile', 'in dieser Datei')}</span>)}
        </dd>

        {(color || viewLabel) && (
          <>
            <dt>{k('diagram', 'Beziehungsdiagramm')}</dt>
            <dd className="fm-to-diagram">
              {color && (
                <span className="fm-to-swatch-wrap" title={color}>
                  <span className="fm-to-swatch" style={{ background: color }} aria-hidden="true" />
                  <code>{color}</code>
                </span>
              )}
              {viewLabel && <span>{k('viewLabel', 'Ansicht: {{view}}', { view: viewLabel })}</span>}
            </dd>
          </>
        )}

        {/* Count rows: in-page links to the list sections below, layouts into
            the references tab (same set as its "Layout" type filter). */}
        <dt>{k('relationshipsHeading', 'Beziehungen')}</dt>
        <dd>{countLink(relationships.length, k('defJumpTitle', 'Zum Abschnitt weiter unten'), () => openAndJump(relSectionRef, () => setRelOpenPref('1')))}</dd>

        {meta.bt_name && (<>
          <dt>{k('siblingsJump', 'Weitere Auftreten')}</dt>
          <dd>{countLink(siblings.length, k('defJumpTitle', 'Zum Abschnitt weiter unten'), () => openAndJump(sibSectionRef, () => setSibOpenPref('1')))}</dd>
        </>)}

        {usageAvailable !== false && (<>
          <dt>{k('ctxColLayouts', 'Layouts')}</dt>
          <dd>
            {layoutCount > 0
              ? (
                <Link
                  to={selfPath({ tab: 'references', types: 'Layout' })}
                  className="fm-to-link fm-to-num-link"
                  title={k('defLayoutsTitle', 'Layouts, die auf dieser TO basieren — in den Referenzen zeigen')}
                >
                  {layoutCount}
                </Link>
              )
              : <span className="fm-to-muted">0</span>}
          </dd>
        </>)}
      </dl>
    </section>
  );

  // Filter the relationship list to one option and bring it into view.
  const showRelationshipsWith = (opt: RelationshipOption) => {
    setRelOption(opt);
    setSearch('');
    openAndJump(relSectionRef, () => setRelOpenPref('1'));
  };

  // Row count next to a section heading: "(132)", filtered "(12 of 132)" — so
  // an active search or chip never makes the table look complete.
  const sectionCount = (shown: number, total: number) => (
    <span className={`fm-to-count${shown < total ? ' fm-to-count--filtered' : ''}`}>
      ({shown < total ? k('countFiltered', '{{shown}} von {{total}}', { shown, total }) : total})
    </span>
  );

  // ── Usage ──
  const cls = usageClass?.usage_class ?? null;
  const isNotUsed = cls === 'unused' || cls === 'dead_branch' || cls === 'dead_island';
  const classDetail = (() => {
    if (!usageClass || !cls) return null;
    if (cls === 'relationship_bridge') {
      return usageClass.usage_reason === 'cascade_delete'
        ? k('reason.cascade_delete', 'An einer Beziehung mit Kaskadenlöschung beteiligt — wird gebraucht.')
        : k('reason.path', 'Liegt auf dem Beziehungspfad zwischen genutzten TOs (z. B. Verbindungs-TO einer n:m-Beziehung) — wird gebraucht.');
    }
    if (cls === 'dead_branch') {
      return (
        <>
          {k('deadBranch', 'Teil eines toten Asts ({{count}} TOs) unter Anker', { count: usageClass.dead_group_size ?? 1 })}{' '}
          {usageClass.anchor_to_name
            ? objLink(usageClass.anchor_to_name, usageClass.anchor_to_uuid, file)
            : '—'}
        </>
      );
    }
    if (cls === 'dead_island') {
      return k('deadIsland', 'TO-Gruppe ohne genutzte TO ({{count}} TOs).', { count: usageClass.dead_group_size ?? 1 });
    }
    if (cls === 'unused') {
      return relationships.length === 0
        ? k('unusedNoRel', 'Keine statisch sichtbare Nutzung, keine Beziehung.')
        : k('unused', 'Keine statisch sichtbare Nutzung.');
    }
    return null;
  })();

  const usage = (
    <section className="fm-to-card" aria-labelledby="fm-to-usage-head">
      <h3 id="fm-to-usage-head" className="fm-to-card-head">{k('usageHeading', 'Nutzung')}</h3>
      {usageAvailable === false ? (
        <div className="fm-to-notice" role="note">{t('detail:hierarchyTree.toUsageUnavailable')}</div>
      ) : (
        <>
          {cls && (
            <div className="fm-to-class">
              <span className={`fm-to-class-badge fm-to-class-badge--${isNotUsed ? 'open' : 'used'}`}>
                {k(`class.${cls}`, cls)}
              </span>
              {classDetail && <span className="fm-to-class-detail">{classDetail}</span>}
            </div>
          )}
          {isNotUsed && (
            <p className="fm-to-hint">
              {k('reviewHint', 'Prüfkandidat, keine Löschempfehlung — dynamische Referenzen (GetField, Evaluate, ExecuteSQL) bleiben unsichtbar.')}{' '}
              <Link to={selfPath({ tab: 'tests' })} className="fm-to-link">{k('toTests', 'Details im Tests-Tab')}</Link>
            </p>
          )}
          {usageClass?.low_confidence && (
            <p className="fm-to-hint fm-to-hint--warn">
              {k('lowConfidence', 'Datei ohne DDR-Info: Formelnutzung per Textsuche ermittelt, Klasse unbestätigt.')}
            </p>
          )}
          {usageGroups.length > 0 && (
            <div className="fm-to-usage-groups">
              {usageGroups.map((g) => (
                <div className="fm-to-usage-row" key={g.id}>
                  <span className="fm-to-usage-label">{k(`group.${g.id}`, g.id)}</span>
                  <span className="fm-to-chips">
                    {g.items.map((item) => {
                      const label = (
                        <>
                          {k(`category.${item.category}`, item.category)}
                          <span className="fm-to-chip-count">
                            {item.users === item.refs ? item.refs : `${item.users} · ${item.refs}`}
                          </span>
                        </>
                      );
                      // Categories the references tab does not list on their own
                      // filter the relationship list below instead.
                      const inPage = IN_PAGE_USAGE_FILTER[item.category];
                      if (inPage) {
                        return (
                          <button
                            key={item.category}
                            type="button"
                            className="fm-to-chip"
                            title={k('chipTitleInPage', '{{users}} Objekte — in den Beziehungen unten zeigen', { users: item.users })}
                            onClick={() => showRelationshipsWith(inPage)}
                          >
                            {label}
                          </button>
                        );
                      }
                      return (
                        <Link
                          key={item.category}
                          to={selfPath({ tab: 'references', roles: item.roleKeys.join(',') })}
                          className="fm-to-chip"
                          title={k('chipTitle', '{{users}} Objekte · {{refs}} Fundstellen — in den Referenzen zeigen', { users: item.users, refs: item.refs })}
                        >
                          {label}
                        </Link>
                      );
                    })}
                  </span>
                </div>
              ))}
            </div>
          )}
          {usageGroups.length > 0 && (
            <div className="fm-to-usage-foot">
              <Link to={selfPath({ tab: 'references' })} className="fm-to-link">
                {k('allUsages', 'alle Fundstellen → Referenzen')}
              </Link>
            </div>
          )}
        </>
      )}
    </section>
  );

  // ── Relationships ──
  const optionSymbols = (o: SideOptions, own: boolean) => {
    const items: React.ReactNode[] = [];
    if (o.create) {
      items.push(
        <span key="c" className="fm-to-opt" title={k('optCreate', 'Erstellen von Datensätzen über diese Beziehung erlaubt')}>＋</span>,
      );
    }
    if (o.cascadeDelete) {
      items.push(
        <span
          key="d"
          className={`fm-to-opt${own ? ' fm-to-opt--warn' : ''}`}
          title={own
            ? k('optDeleteSelf', 'Kaskadenlöschung: Datensätze dieser TO werden gelöscht, wenn der Bezugsdatensatz gelöscht wird')
            : k('optDeletePartner', 'Kaskadenlöschung: Datensätze der Partner-TO werden gelöscht, wenn ein Datensatz dieser TO gelöscht wird')}
        >🗑</span>,
      );
    }
    if (o.sorted) {
      items.push(
        <span
          key="s"
          className="fm-to-opt"
          title={`${k('optSort', 'Sortiert')}${o.sortFields.length ? `: ${o.sortFields.join(', ')}` : ''}`}
        >⇅</span>,
      );
    }
    return items.length > 0 ? items : <span className="fm-to-muted">–</span>;
  };

  const toggleSort = (key: RelSortKey) => {
    if (key === sortKey) setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    else { setSortKey(key); setSortDir('asc'); }
  };
  const ariaSort = (key: RelSortKey) =>
    sortKey === key ? (sortDir === 'asc' ? 'ascending' : 'descending') : 'none';
  const sortHead = (key: RelSortKey, label: string) => (
    <th
      className="fm-to-th-sort"
      aria-sort={ariaSort(key)}
      tabIndex={0}
      onClick={() => toggleSort(key)}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleSort(key); } }}
    >
      {label}{sortKey === key ? (sortDir === 'asc' ? ' ▲' : ' ▼') : ''}
    </th>
  );

  const optionCounts = RELATIONSHIP_OPTIONS
    .map((opt) => ({ opt, count: relationships.filter((rel) => relationshipHasOption(rel, opt)).length }))
    .filter((o) => o.count > 0);

  // Partner sub line: base table (when it differs from the TO name) and, for a
  // TO reached through a data source, that data source.
  const partnerSubLine = (rel: RelationshipView): string | null => {
    const parts: string[] = [];
    if (rel.partnerBaseTable && rel.partnerBaseTable !== rel.partnerName) parts.push(rel.partnerBaseTable);
    if (rel.partnerType === 'External' && rel.partnerDataSource) {
      parts.push(k('viaDataSource', 'Datenquelle „{{ds}}“', { ds: rel.partnerDataSource }));
    }
    return parts.length > 0 ? parts.join(' · ') : null;
  };

  const relationshipBlock = (rel: RelationshipView) => (
    <tbody key={rel.relId} className={`fm-to-rel${rel.self.cascadeDelete ? ' fm-to-rel--cascade' : ''}`}>
      {rel.predicates.map((p, i) => (
        <tr key={p.index}>
          <td className="fm-to-pred-self">
            <span className="fm-to-and">{i > 0 ? k('and', 'UND') : ''}</span>
            {objLink(p.selfField ?? '—', p.selfFieldUuid, p.selfFieldFile)}
          </td>
          <td className="fm-to-op">{operatorSymbol(p.operator)}</td>
          <td className="fm-to-pred-partner">{objLink(p.partnerField ?? '—', p.partnerFieldUuid, p.partnerFieldFile)}</td>
          {i === 0 && (
            <>
              <td rowSpan={rel.predicates.length} className="fm-to-partner">
                {objLink(rel.partnerName ?? '—', rel.partnerUuid, rel.file, 'fm-to-link fm-to-partner-name')}
                {partnerSubLine(rel) && <div className="fm-to-partner-sub">{partnerSubLine(rel)}</div>}
              </td>
              <td rowSpan={rel.predicates.length} className="fm-to-opts">
                <span className="fm-to-opts-side">{optionSymbols(rel.self, true)}</span>
                <span className="fm-to-opts-sep" aria-hidden="true">|</span>
                <span className="fm-to-opts-side">{optionSymbols(rel.partner, false)}</span>
              </td>
              <td rowSpan={rel.predicates.length} className="fm-to-relid">
                {objLink(`#${rel.relId}`, rel.relUuid, rel.file)}
              </td>
            </>
          )}
        </tr>
      ))}
    </tbody>
  );

  // ── TO group & context path (relationship graph of this file) ──
  const contextSection = context ? (
    <section className="fm-to-card fm-to-context" aria-labelledby="fm-to-ctx-head">
      <h3 id="fm-to-ctx-head" className="fm-to-card-head">{k('ctxHeading', 'TO-Gruppe')}</h3>
      <dl className="fm-to-dl">
        <dt>{k('ctxGroup', 'Gruppe')}</dt>
        <dd>
          {context.groupSize <= 1
            ? <span className="fm-to-muted">{k('ctxSingle', 'nur diese TO — keine Beziehung')}</span>
            : (
              <>
                {k('ctxTos', '{{count}} TOs', { count: context.groupSize })}
                {' · '}
                {k('ctxLayouts', '{{count}} Layouts', { count: context.groupLayouts })}
              </>
            )}
        </dd>

        <dt>{k('ctxContext', 'Layout-Kontext')}</dt>
        <dd>
          {context.selfLayouts > 0 ? (
            <span>{k('ctxSelfAnchor', 'ist selbst Layout-Kontext ({{count}} Layouts)', { count: context.selfLayouts })}</span>
          ) : context.paths.length === 0 ? (
            <span className="fm-to-muted">{k('ctxAnchorsNone', 'kein Layout basiert auf einer TO dieser Gruppe')}</span>
          ) : (
            <>
              <span className="fm-to-nearest">
                <span className="fm-to-muted">{k('ctxNearest', 'nächster:')}</span>{' '}
                {context.paths.map((path, pi) => (
                  <React.Fragment key={path[0].uuid}>
                    {pi > 0 && ' · '}
                    {objLink(path[0].name, path[0].uuid, file)}
                  </React.Fragment>
                ))}
                {' · '}
                {k('ctxSteps', '{{count}} Schritte', { count: context.paths[0].length - 1 })}
                {context.paths[0].length > 2 && (
                  <>
                    {' '}
                    <button
                      type="button"
                      className="fm-to-anchor-more"
                      aria-expanded={pathOpen}
                      aria-controls="fm-to-path-list"
                      onClick={() => setPathOpen((o) => !o)}
                    >
                      {pathOpen ? k('ctxHidePath', 'Pfad ausblenden') : k('ctxShowPath', 'Pfad zeigen')}
                    </button>
                  </>
                )}
              </span>
              {/* Vertical step list: one TO per line, the join fields of the
                  relationship indented between them — readable at any length.
                  Shown from two steps on; a single step is the partner row of
                  the relationship table below. */}
              {pathOpen && context.paths[0].length > 2 && (
                <div id="fm-to-path-list" className="fm-to-vpaths">
                  {context.paths.map((path) => (
                    <ol key={path[0].uuid} className="fm-to-vpath">
                      {path.map((step, si) => (
                        <li key={`${step.uuid}-${si}`} className="fm-to-vpath-step">
                          {si > 0 && (
                            <div className="fm-to-vpath-hop">
                              <span aria-hidden="true">↓ </span>
                              {objLink(step.label ?? `#${step.relId}`, step.relUuid, file, 'fm-to-hop-link')}
                            </div>
                          )}
                          <div className="fm-to-vpath-to">
                            {si === path.length - 1
                              ? <strong>{step.name}</strong>
                              : objLink(step.name, step.uuid, file)}
                          </div>
                        </li>
                      ))}
                    </ol>
                  ))}
                </div>
              )}
            </>
          )}
        </dd>

        {anchorSummary && context.anchors.length > 0 && (<>
        <dt>{k('ctxAnchors', 'Anker')}</dt>
        <dd>
          {(
            <>
              <span className="fm-to-anchors">
                {anchorSummary.visible.map((a) => (
                  <span key={a.uuid} className="fm-to-anchor" title={k('ctxLayoutsTitle', '{{count}} Layouts', { count: a.layouts })}>
                    {a.uuid === currentUuid
                      ? <strong>{a.name}</strong>
                      : objLink(a.name, a.uuid, file)}
                    <span className="fm-to-chip-count"> {a.layouts}</span>
                  </span>
                ))}
                {anchorSummary.hidden.length > 0 && (
                  <button
                    type="button"
                    className="fm-to-anchor-more"
                    aria-expanded={anchorsOpen}
                    aria-controls="fm-to-anchor-list"
                    onClick={() => setAnchorsOpen((o) => !o)}
                  >
                    {anchorsOpen
                      ? k('ctxAnchorsLess', 'Liste schließen')
                      : anchorSummary.hiddenEachLayouts === 1
                        ? k('ctxMoreEachSingle', '+{{count}} weitere mit je 1 Layout', { count: anchorSummary.hidden.length })
                        : anchorSummary.hiddenEachLayouts != null
                          ? k('ctxMoreEach', '+{{count}} weitere mit je {{each}} Layouts', {
                            count: anchorSummary.hidden.length, each: anchorSummary.hiddenEachLayouts,
                          })
                        : k('ctxMoreTotal', '+{{count}} weitere mit zusammen {{total}} Layouts', {
                          count: anchorSummary.hidden.length, total: anchorSummary.hiddenLayouts,
                        })}
                  </button>
                )}
              </span>
              {anchorsOpen && (
                <table id="fm-to-anchor-list" className="fm-to-table fm-to-anchor-table">
                  <thead>
                    <tr>
                      <th>{k('ctxAnchor', 'Anker')}</th>
                      <th className="fm-to-num">{k('ctxColLayouts', 'Layouts')}</th>
                      <th className="fm-to-num" title={k('ctxColDistanceTitle', 'Beziehungsschritte bis zu dieser TO')}>{k('ctxColDistance', 'Abstand')}</th>
                    </tr>
                  </thead>
                  <tbody>
                    {context.anchors.map((a) => (
                      <tr key={a.uuid}>
                        <td>{a.uuid === currentUuid ? <strong>{a.name}</strong> : objLink(a.name, a.uuid, file)}</td>
                        <td className="fm-to-num">{a.layouts}</td>
                        <td className="fm-to-num">{a.distance}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </>
          )}
        </dd>
        </>)}

      </dl>
      <p className="fm-to-hint">
        {k('ctxHint', 'Anker = TO, auf der Layouts basieren. „Nächster“ ist der Anker, von dem aus diese TO über die wenigsten Beziehungen erreicht wird.')}
      </p>
    </section>
  ) : null;

  // An empty list has nothing to hide: open, toggle disabled.
  const relOpen = relOpenPref === '1' || relationships.length === 0;
  const sibOpen = sibOpenPref === '1' || siblings.length === 0;

  const relationshipSection = (
    <section className="fm-to-section" aria-labelledby="fm-to-rel-head" ref={relSectionRef}>
      <h3 id="fm-to-rel-head" className="fm-to-section-head">
        <button
          type="button"
          className="fm-to-section-toggle"
          aria-expanded={relOpen}
          aria-controls="fm-to-rel-body"
          onClick={() => setRelOpenPref(relOpen ? '0' : '1')}
          disabled={relationships.length === 0}
        >
          <DisclosureChevron open={relOpen} />
          {k('relationshipsHeading', 'Beziehungen')}{' '}
          {sectionCount(visibleRelationships.length, relationships.length)}
        </button>
      </h3>
      {!relOpen ? null : relationships.length === 0 ? (
        <div className="fm-to-muted">{k('noRelationships', '— keine Beziehung —')}</div>
      ) : (
        <div id="fm-to-rel-body">
          {(relationships.length > SEARCH_THRESHOLD || optionCounts.length > 0) && (
            <div className="fm-to-toolbar">
              {relationships.length > SEARCH_THRESHOLD && (
                <input
                  type="search"
                  className="fm-to-search"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder={k('searchPlaceholder', 'Partner-TO oder Feld filtern…')}
                  aria-label={k('searchPlaceholder', 'Partner-TO oder Feld filtern…')}
                />
              )}
              {optionCounts.length > 0 && (
                <span className="fm-to-chips" role="group" aria-label={k('optionFilterAria', 'Nach Optionen filtern')}>
                  {optionCounts.map(({ opt, count }) => (
                    <button
                      key={opt}
                      type="button"
                      className={`fm-to-chip fm-to-chip--toggle${relOption === opt ? ' fm-to-chip--active' : ''}`}
                      aria-pressed={relOption === opt}
                      onClick={() => setRelOption(relOption === opt ? null : opt)}
                    >
                      {k(`option.${opt}`, opt)}
                      <span className="fm-to-chip-count">{count}</span>
                    </button>
                  ))}
                </span>
              )}
            </div>
          )}
          <div className="fm-to-table-wrap">
            <table className="fm-to-table">
              <thead>
                <tr>
                  <th>{k('colSelf', 'Diese TO')}</th>
                  <th aria-label={k('colOperator', 'Operator')} />
                  <th>{k('colPartnerField', 'Partner-Feld')}</th>
                  {sortHead('partner', k('colPartner', 'Partner-TO'))}
                  <th title={k('colOptionsTitle', 'Optionen: diese TO | Partner-TO')}>{k('colOptions', 'Optionen')}</th>
                  {sortHead('rel', k('colRelationship', 'Beziehung'))}
                </tr>
              </thead>
              {visibleRelationships.map(relationshipBlock)}
            </table>
          </div>
          {visibleRelationships.length === 0 && (
            <div className="fm-to-muted fm-to-noresults">{t('detail:baseTable.noMatches', { defaultValue: 'Keine Treffer' })}</div>
          )}
          <p className="fm-to-legend">
            {k('legend', 'Optionen „diese TO | Partner-TO“: ＋ Erstellen erlaubt · 🗑 Kaskadenlöschung · ⇅ sortiert')}
          </p>
        </div>
      )}
    </section>
  );

  // ── Other occurrences of the same base table ──
  const localSiblings = siblings.filter((s) => s.local).length;
  const scopeCounts: Record<SiblingScope, number> = {
    all: siblings.length,
    file: localSiblings,
    other: siblings.length - localSiblings,
  };
  const toggleSibSort = (key: SiblingSortKey) => {
    if (key === sibSortKey) setSibSortDir((d) => (d === 'asc' ? 'desc' : 'asc'));
    else { setSibSortKey(key); setSibSortDir('asc'); }
  };
  const sibSortHead = (key: SiblingSortKey, label: string, title?: string) => (
    <th
      title={title}
      className="fm-to-th-sort"
      aria-sort={sibSortKey === key ? (sibSortDir === 'asc' ? 'ascending' : 'descending') : 'none'}
      tabIndex={0}
      onClick={() => toggleSibSort(key)}
      onKeyDown={(e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); toggleSibSort(key); } }}
    >
      {label}{sibSortKey === key ? (sibSortDir === 'asc' ? ' ▲' : ' ▼') : ''}
    </th>
  );

  const siblingSection = meta.bt_name ? (
    <section className="fm-to-section" aria-labelledby="fm-to-sib-head" ref={sibSectionRef}>
      <h3 id="fm-to-sib-head" className="fm-to-section-head">
        <button
          type="button"
          className="fm-to-section-toggle"
          aria-expanded={sibOpen}
          aria-controls="fm-to-sib-body"
          onClick={() => setSibOpenPref(sibOpen ? '0' : '1')}
          disabled={siblings.length === 0}
        >
          <DisclosureChevron open={sibOpen} />
          {k('siblingsHeading', 'Weitere Auftreten von „{{bt}}“', { bt: meta.bt_name })}{' '}
          {sectionCount(visibleSiblings.length, siblings.length)}
        </button>
        {meta.bt_uuid && (
          <span className="fm-to-head-link">
            {objLink(k('toBaseTable', 'zur Basistabelle'), meta.bt_uuid, meta.bt_file)}
          </span>
        )}
      </h3>
      {!sibOpen ? null : siblings.length === 0 ? (
        <div className="fm-to-muted">{k('siblingsNone', '— keine weiteren —')}</div>
      ) : (
        <div id="fm-to-sib-body">
          <div className="fm-to-toolbar">
            <input
              type="search"
              className="fm-to-search"
              value={sibSearch}
              onChange={(e) => setSibSearch(e.target.value)}
              placeholder={k('siblingsSearch', 'TO oder Datei filtern…')}
              aria-label={k('siblingsSearch', 'TO oder Datei filtern…')}
            />
            <span className="fm-to-chips" role="group" aria-label={k('siblingsScopeAria', 'Bereich')}>
              {(['all', 'file', 'other'] as const).map((scope) => (
                <button
                  key={scope}
                  type="button"
                  className={`fm-to-chip fm-to-chip--toggle${sibScope === scope ? ' fm-to-chip--active' : ''}`}
                  aria-pressed={sibScope === scope}
                  title={k(`scopeTitle.${scope}`, scope)}
                  onClick={() => setSibScope(scope)}
                  disabled={scopeCounts[scope] === 0 && sibScope !== scope}
                >
                  {k(`scope.${scope}`, scope)}
                  <span className="fm-to-chip-count">{scopeCounts[scope]}</span>
                </button>
              ))}
            </span>
          </div>
          <div className="fm-to-table-wrap">
            <table className="fm-to-table fm-to-sib-table">
              <thead>
                <tr>
                  {sibSortHead('name', k('colTo', 'Tabellenauftreten'))}
                  {sibSortHead('file', k('colDefinedIn', 'definiert in'), k('colDefinedInTitle', 'Datei, in deren Beziehungsdiagramm die TO liegt (leer = diese Datei)'))}
                  {sibSortHead('source', k('dataSource', 'Datenquelle'), k('colSourceTitle', 'Wie die TO die Basistabelle erreicht: aktuelle Datei oder über eine Datenquelle'))}
                </tr>
              </thead>
              <tbody>
                {visibleSiblings.map((s) => (
                  <tr key={`${s.file}\u0000${s.uuid ?? s.name}`} className="fm-to-sib-row-tr">
                    <td>{objLink(s.name || '—', s.uuid, s.file)}</td>
                    <td className="fm-to-muted">{s.local ? '' : s.file}</td>
                    <td className="fm-to-muted">
                      {s.dataSource == null
                        ? k('dataSourceCurrent', 'aktuelle Datei')
                        : (
                          <>
                            {s.dataSource}
                            {s.dataSourceSelf && (
                              <span className="fm-to-warn" title={k('dsSelfSibling', 'Datenquelle verweist auf die eigene Datei')}> ↺</span>
                            )}
                          </>
                        )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          {visibleSiblings.length === 0 && (
            <div className="fm-to-muted fm-to-noresults">{t('detail:baseTable.noMatches', { defaultValue: 'Keine Treffer' })}</div>
          )}
        </div>
      )}
    </section>
  ) : null;


  return (
    <div className="object-detail fm-to" aria-label={k('ariaLabel', 'Tabellenauftreten-Details')}>
      <div className="fm-to-top">
        {definition}
        {usage}
      </div>
      {contextSection}
      {relationshipSection}
      {siblingSection}
    </div>
  );
};
