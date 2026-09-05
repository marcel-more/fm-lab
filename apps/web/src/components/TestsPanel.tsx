import React, { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useApiLang } from '../hooks';
import {
  getTestsContext, listTests, runTest,
  type TestListItem, type TestRunFinding, type TestRunMemberResult,
  type TestRunSummary, type TestsContext,
} from '../api/testsApi';
import {
  getCachedRuns, getTestsStoreVersion, loadSectionState, loadTestsSettings,
  putCachedRun, saveSectionState, saveTestsSettings, subscribeTestsStore,
  type CachedRun, type TestsSettings,
} from '../lib/testsStore';
import { dispatchAction, resolveAction } from '../dashboard/actions';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import './TestsPanel.css';

/**
 * "Tests" tab of the object detail view.
 *
 * Three levels: sections (test folders, folder.json order) → test rows →
 * member rows/findings. Platform tests (testType 'platform') collapse into ONE
 * consolidated section with per-solution target-environment chips.
 * Result states are server-derived and aggregated bottom-up; runs
 * are cached per (solution, object, test, profile, catalog fingerprint) in
 * sessionStorage and shown instantly on re-entry. Users can pick shipped
 * profiles and disable tests they don't need — display-only, persisted per
 * solution in localStorage.
 */

interface TestsPanelProps {
  objectUuid: string;
  objectType: string;
  fileName: string | null;
}

type StateKey = 'error' | 'warning' | 'neutral' | 'ok' | 'skipped' | 'failed';

const STATE_ORDER: StateKey[] = ['error', 'warning', 'failed', 'neutral', 'ok', 'skipped'];
const STATE_TOKEN: Record<StateKey, string> = {
  error: '●', warning: '▲', neutral: '◦', ok: '✓', skipped: '—', failed: '⚡',
};
const PLATFORM_SECTION_KEY = '__platform';

function severityClass(sev?: string | null): string {
  switch ((sev || '').toLowerCase()) {
    case 'critical':
    case 'error': return 'tests-sev-error';
    case 'warning': return 'tests-sev-warning';
    default: return 'tests-sev-info';
  }
}

function emptySummary(): TestRunSummary {
  return { error: 0, warning: 0, neutral: 0, ok: 0, skipped: 0, failed: 0 };
}

function addSummary(into: TestRunSummary, s: TestRunSummary | undefined): void {
  if (!s) return;
  for (const k of STATE_ORDER) into[k] += s[k] || 0;
}

/** Rank of a test's worst state — drives the "most notable first" toggle. */
function worstRank(s: TestRunSummary | undefined): number {
  if (!s) return STATE_ORDER.length + 1;
  for (let i = 0; i < STATE_ORDER.length; i++) {
    if (s[STATE_ORDER[i]] > 0) return i;
  }
  return STATE_ORDER.length;
}

/**
 * Text einer Finding-Zeile. Dashboards liefern `message`; Query-Templates
 * benennen die Spalte `_message`, weil die generische Query-Tabelle Spalten mit
 * `_`-Präfix ausblendet — die Zeile bleibt hier trotzdem lesbar.
 */
function findingMessage(f: TestRunFinding): string {
  return String(f.message ?? f._message ?? '');
}

function findingMatches(f: TestRunFinding, q: string): boolean {
  return findingMessage(f).toLowerCase().includes(q)
    || String(f.script_name ?? '').toLowerCase().includes(q);
}

function runMatchesQuery(run: CachedRun | undefined, q: string): boolean {
  if (!run) return false;
  return run.result.results.some(m => (m.findings?.rows || []).some(f => findingMatches(f, q)));
}

/** Chip label for a platform test — titles follow "Platform: <target>". */
function platformLabel(test: TestListItem): string {
  return test.title.replace(/^Platform:\s*/i, '');
}

/**
 * Member refs of a platform test's compat aspect (axis a), declared by the
 * shipped `compat` profile. Tests without one carry no binding member —
 * `null` means "every member counts as compat".
 */
function compatMemberRefs(test: TestListItem): ReadonlySet<string> | null {
  const profile = test.profiles.find(p => p.id === 'compat');
  if (profile?.members) return new Set(profile.members);
  // Binding-only sets (e.g. the OS-binding set) ship a 'specific' profile and
  // no 'compat' profile — they have no compat aspect at all.
  if (test.profiles.some(p => p.id === 'specific')) return new Set();
  return null;
}

// ---------------------------------------------------------------------------
// Presentational bits
// ---------------------------------------------------------------------------

const SummaryTokens: React.FC<{ summary?: TestRunSummary; showValueFor?: number | null }> = ({ summary }) => {
  if (!summary) return null;
  return (
    <span className="tests-tokens" aria-hidden="false">
      {STATE_ORDER.filter(k => summary[k] > 0).map(k => (
        <span key={k} className={`tests-token tests-state-${k}`}>
          {STATE_TOKEN[k]} {summary[k]}
        </span>
      ))}
    </span>
  );
};

/**
 * One member (rule) row. Two operating modes:
 * - hierarchy (default): the line click jumps to the member's findings target
 *   (`memberJump`), expanding is the ▸ button's job.
 * - flat (`flatContext` set): the row stands alone in the flat result list, so
 *   the line click toggles the findings instead and the title carries the
 *   origin path (section › bundle) — navigation happens on the finding rows.
 */
const MemberRow: React.FC<{ member: TestRunMemberResult; query: string; flatContext?: string }> = ({ member, query, flatContext }) => {
  const { t } = useTranslation(['nav']);
  const navigate = useNavigate();
  const [expanded, setExpanded] = useState(false);
  const value = member.defaultResult?.value;
  const q = query.trim().toLowerCase();
  const allRows = member.findings?.rows || [];
  const rows = q ? allRows.filter(f => findingMatches(f, q)) : allRows;
  const hasFindings = allRows.length > 0;
  const state = (member.runStatus === 'failed' ? 'failed' : member.resultState) as StateKey | undefined;
  // A finding row is a direct deep link when the bundle's declarative row
  // action resolves against it — the same jump the dashboard row click makes.
  // Rows whose target column is empty (e.g. aggregate findings) stay plain.
  const findingClickable = useCallback((f: TestRunFinding): boolean => {
    const resolved = resolveAction(member.rowAction, f);
    if (!resolved) return false;
    return resolved.action !== 'openObject' || Boolean(resolved.args.uuid);
  }, [member.rowAction]);
  const openFinding = useCallback((f: TestRunFinding) => {
    dispatchAction(member.rowAction, f, { navigate });
  }, [member.rowAction, navigate]);
  // Click on the WHOLE collapsed member line: open the layout with ALL findings
  // of this rule marked at once (`?marks=` — literal UUID list, no origin
  // resolution). Layout targets only — multi-step marking in the script viewer
  // is a different mechanism (`?step=` is a single scroll anchor). With exactly
  // one finding this degrades to the single-finding jump so the origin pill
  // resolution applies. Per-row message context (ref_msgid / ref_arg_*) is
  // dropped in the multi jump — one row's message would mislabel the set.
  const memberJump = useMemo(() => {
    const spec = member.rowAction;
    const rows = member.findings?.rows || [];
    if (!spec || spec.action !== 'openObject' || rows.length === 0) return null;
    if (String(spec.args?.type ?? '') !== 'Layout') return null;
    const resolved = rows
      .map(f => ({ f, r: resolveAction(spec, f) }))
      .filter((x): x is { f: TestRunFinding; r: NonNullable<ReturnType<typeof resolveAction>> } =>
        x.r !== null && Boolean(x.r.args.uuid));
    if (resolved.length === 0) return null;
    // Object scope guarantees one shared nav_uuid — guard against mixed targets anyway.
    const navUuid = String(resolved[0].r.args.uuid);
    if (resolved.some(x => String(x.r.args.uuid) !== navUuid)) return null;
    const marks = [...new Set(resolved.map(x => String(x.r.args.ref ?? '')).filter(Boolean))];
    if (resolved.length === 1 || marks.length < 2) {
      return { kind: 'single' as const, row: resolved[0].f };
    }
    const args: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(resolved[0].r.args)) {
      if (k === 'ref' || k === 'ref_msgid' || k.startsWith('ref_arg_')) continue;
      args[k] = v;
    }
    args.marks = marks.join(',');
    return { kind: 'multi' as const, args };
  }, [member.rowAction, member.findings]);
  const jumpAllFindings = useCallback(() => {
    if (!memberJump) return;
    if (memberJump.kind === 'single') {
      dispatchAction(member.rowAction, memberJump.row, { navigate });
    } else {
      // Args are fully resolved literals — dispatch without a substitution row.
      dispatchAction({ action: 'openObject', args: memberJump.args }, undefined, { navigate });
    }
  }, [memberJump, member.rowAction, navigate]);
  const flat = flatContext !== undefined;
  const lineInteractive = flat ? hasFindings : memberJump !== null;
  const activateLine = flat ? () => setExpanded(e => !e) : jumpAllFindings;
  return (
    <div className={`tests-member-row${member.runStatus === 'skipped' ? ' tests-member-skipped' : ''}`}>
      <div
        className={`tests-member-line${lineInteractive ? ' tests-member-line-link' : ''}`}
        // Buttons/selects inside the line keep their own handlers — the line
        // click only fires on the non-interactive remainder of the row.
        onClick={lineInteractive ? e => {
          if ((e.target as HTMLElement).closest('button, select, a')) return;
          activateLine();
        } : undefined}
        onKeyDown={lineInteractive ? e => {
          if (e.key === 'Enter' && e.target === e.currentTarget) activateLine();
        } : undefined}
        role={lineInteractive ? (flat ? 'button' : 'link') : undefined}
        tabIndex={lineInteractive ? 0 : undefined}
        aria-expanded={flat && hasFindings ? expanded : undefined}
        title={flat ? flatContext : memberJump ? (t('nav:testsPanel.openMemberFindings') as string) : undefined}
      >
        <button
          className="tests-member-expand"
          onClick={() => setExpanded(e => !e)}
          disabled={!hasFindings}
          aria-expanded={expanded}
          title={hasFindings ? (t('nav:testsPanel.showFindings') as string) : undefined}
        >
          {hasFindings ? (expanded ? '▾' : '▸') : '·'}
        </button>
        {state && (
          <span className={`tests-token tests-state-${state}`} aria-hidden="true">{STATE_TOKEN[state]}</span>
        )}
        <span className="tests-member-ref" title={member.ref}>{member.title || member.ref}</span>
        {member.runStatus === 'failed' ? (
          <span className="tests-member-error" title={member.error}>
            {t('nav:testsPanel.memberError')}
          </span>
        ) : member.runStatus === 'skipped' ? (
          <span className="tests-member-value tests-state-skipped" title={member.skipMessage || undefined}>
            {member.skipReason === 'object-type'
              ? t('nav:testsPanel.memberSkippedObjectType')
              : t('nav:testsPanel.memberSkipped')}
          </span>
        ) : (
          <span
            className={`tests-member-value ${Number(value) > 0 ? severityClass(member.severity) : 'tests-sev-ok'}`}
            title={member.defaultResult?.meaning || undefined}
          >
            {value === null || value === undefined ? '—' : String(value)}
          </span>
        )}
        <button
          className="tests-member-open"
          onClick={() => navigate(member.openTarget)}
          title={t('nav:testsPanel.openMember') as string}
        >
          ↗
        </button>
      </div>
      {expanded && hasFindings && (
        <ul className="tests-findings">
          {rows.map((f, i) => {
            const clickable = findingClickable(f);
            return (
              <li
                key={i}
                className={`${severityClass(f.severity as string)}${clickable ? ' tests-finding-link' : ''}`}
                onClick={clickable ? () => openFinding(f) : undefined}
                onKeyDown={clickable ? e => { if (e.key === 'Enter') openFinding(f); } : undefined}
                role={clickable ? 'link' : undefined}
                tabIndex={clickable ? 0 : undefined}
                title={clickable ? (t('nav:testsPanel.openFinding') as string) : undefined}
              >
                {f.step_no != null && <span className="tests-finding-step">#{String(f.step_no)}</span>}
                <span>{findingMessage(f)}</span>
              </li>
            );
          })}
          {q && rows.length < allRows.length && (
            <li className="tests-findings-truncated">
              {t('nav:testsPanel.findingsFiltered', { shown: rows.length, total: allRows.length })}
            </li>
          )}
          {member.findings!.truncated && (
            <li className="tests-findings-truncated">{t('nav:testsPanel.truncated')}</li>
          )}
        </ul>
      )}
    </div>
  );
};

interface TestRowProps {
  test: TestListItem;
  run?: CachedRun;
  runError?: string;
  /** Any run in flight — disables every run button (sequential execution). */
  runDisabled: boolean;
  /** THIS test is currently running — drives the button label. */
  isRunning: boolean;
  disabled: boolean;
  profileId: string;
  query: string;
  onRun: (test: TestListItem) => void;
  onToggleDisabled: (testId: string) => void;
  onSelectProfile: (testId: string, profileId: string) => void;
}

const TestRow: React.FC<TestRowProps> = ({
  test, run, runError, runDisabled, isRunning, disabled, profileId, query,
  onRun, onToggleDisabled, onSelectProfile,
}) => {
  const { t } = useTranslation(['nav']);
  const [expanded, setExpanded] = useState(false);
  const summary = run?.result.summary;
  // Platform rows show the two aspects separately: compat member states as
  // tokens (as before), the binding aspect as ONE neutral chip with the
  // platform-specific script count — never mixed into the compat tokens.
  let aspectSplit: { compat: TestRunSummary; specificScripts: number | null } | null = null;
  const compatRefs = test.testType === 'platform' ? compatMemberRefs(test) : null;
  if (run && compatRefs) {
    const compat = emptySummary();
    let scripts: number | null = null;
    for (const m of run.result.results) {
      if (compatRefs.has(m.ref)) {
        const key = (m.runStatus === 'failed' ? 'failed'
          : m.runStatus === 'skipped' ? 'skipped' : m.resultState) as StateKey | undefined;
        if (key) compat[key] += 1;
      } else if (m.runStatus === 'ran') {
        const value = Number(m.defaultResult?.value);
        if (Number.isFinite(value)) scripts = (scripts ?? 0) + value;
      }
    }
    aspectSplit = { compat, specificScripts: scripts };
  }
  return (
    <div className={`tests-row${disabled ? ' tests-row-disabled' : ''}`}>
      <div className="tests-row-line">
        <button
          className="tests-member-expand"
          onClick={() => setExpanded(e => !e)}
          aria-expanded={expanded}
        >
          {expanded ? '▾' : '▸'}
        </button>
        <span className="tests-row-title" title={test.description || undefined}>{test.title}</span>
        <span className={`tests-type-badge tests-type-${test.testType}`}>{test.testType}</span>
        {test.validation.status === 'warnings' && (
          <span
            className="tests-validation-badge"
            title={test.validation.warnings.map(w => `${w.rule}: ${w.message}`).join('\n')}
          >
            ⚠
          </span>
        )}
        {test.profiles.length > 0 && (
          <select
            className="tests-profile-select"
            value={profileId}
            onChange={e => onSelectProfile(test.id, e.target.value)}
            aria-label={t('nav:testsPanel.profileLabel') as string}
            title={t('nav:testsPanel.profileLabel') as string}
          >
            <option value="">{t('nav:testsPanel.profileAll', { count: test.memberCount })}</option>
            {test.profiles.map(p => (
              <option key={p.id} value={p.id}>
                {p.title} ({p.memberCount}/{test.memberCount})
              </option>
            ))}
          </select>
        )}
        <span className="tests-row-result">
          {summary
            ? (aspectSplit
              ? (
                <>
                  <SummaryTokens summary={aspectSplit.compat} />
                  {aspectSplit.specificScripts != null && (
                    <span className="tests-token tests-state-neutral">
                      {STATE_TOKEN.neutral} {t('nav:testsPanel.platformSpecificScripts', { count: aspectSplit.specificScripts })}
                    </span>
                  )}
                </>
              )
              : <SummaryTokens summary={summary} />)
            : <span className="tests-row-membercount">{t('nav:testsPanel.memberCount', { count: test.memberCount })}</span>}
        </span>
        <button
          className="tests-run-button"
          onClick={() => onRun(test)}
          disabled={runDisabled}
          title={run ? (t('nav:testsPanel.rerun') as string) : undefined}
        >
          {isRunning ? t('nav:testsPanel.running') : run ? t('nav:testsPanel.rerun') : t('nav:testsPanel.run')}
        </button>
        <button
          className="tests-disable-button"
          onClick={() => onToggleDisabled(test.id)}
          title={t(disabled ? 'nav:testsPanel.enableTest' : 'nav:testsPanel.disableTest') as string}
        >
          {disabled ? '＋' : '⊘'}
        </button>
      </div>
      {expanded && (
        <div className="tests-row-body">
          {test.description && <p className="tests-card-description">{test.description}</p>}
          {runError && <ErrorMessage message={runError} />}
          {run && (
            <div className="tests-card-results">
              {run.result.results.map((m, i) => (
                <MemberRow key={`${m.ref}-${i}`} member={m} query={query} />
              ))}
              <div className="tests-card-meta">
                {t('nav:testsPanel.duration', { ms: run.result.meta.durationMs })}
                {' · '}
                {t('nav:testsPanel.resultsFrom', { time: new Date(run.at).toLocaleTimeString() })}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Platform matrix — client-side join of per-platform findings over steps
// ---------------------------------------------------------------------------

interface MatrixData {
  platforms: { id: string; label: string }[];
  rows: { key: string; label: string; cells: Record<string, StateKey | undefined> }[];
  truncated: boolean;
}

function buildMatrix(tests: TestListItem[], runFor: (t: TestListItem) => CachedRun | undefined): MatrixData | null {
  // The matrix is a COMPATIBILITY matrix: it feeds only from the compat-aspect
  // member runs. Binding findings (neutral, partly without step_uuid) would
  // pollute the step×environment join, so specific members are filtered out.
  const compatResults = (test: TestListItem, run: CachedRun): TestRunMemberResult[] => {
    const refs = compatMemberRefs(test);
    // Second guard on the member-id convention: only platform_compat_* members
    // carry the step×environment shape the matrix joins over (binding members
    // — platform_specific_* — are neutral and partly step-free).
    return run.result.results.filter(m => m.ref.startsWith('platform_compat_') && (!refs || refs.has(m.ref)));
  };
  const withRuns = tests.filter(t => {
    const r = runFor(t);
    return r && compatResults(t, r).some(m => (m.findings?.rows || []).length > 0);
  });
  if (withRuns.length < 2) return null;
  const platforms = withRuns.map(t => ({ id: t.id, label: platformLabel(t) }));
  const rows = new Map<string, { key: string; label: string; cells: Record<string, StateKey | undefined> }>();
  let truncated = false;
  for (const test of withRuns) {
    const run = runFor(test)!;
    for (const m of compatResults(test, run)) {
      if (m.findings?.truncated) truncated = true;
      for (const f of m.findings?.rows || []) {
        const key = String(f.step_uuid || `${f.script_name ?? ''}#${f.step_no ?? ''}#${findingMessage(f)}`);
        const label = `${f.script_name ?? ''}${f.step_no != null ? ` · #${f.step_no}` : ''}`;
        const row = rows.get(key) || { key, label, cells: {} };
        const sev = (String(f.severity || '').toLowerCase() === 'error' ? 'error'
          : String(f.severity || '').toLowerCase() === 'warning' ? 'warning' : 'neutral') as StateKey;
        const prev = row.cells[test.id];
        if (!prev || STATE_ORDER.indexOf(sev) < STATE_ORDER.indexOf(prev)) row.cells[test.id] = sev;
        rows.set(key, row);
      }
    }
  }
  if (rows.size === 0) return null;
  return { platforms, rows: [...rows.values()], truncated };
}

/**
 * OS-binding distribution (OS sub-axis) — renders as its own strip with the
 * os_profile groups instead of a runtime column inside the compat matrix.
 */
function osBindingProfiles(
  tests: TestListItem[],
  runFor: (t: TestListItem) => CachedRun | undefined,
): { profile: string; count: number }[] | null {
  const test = tests.find(t => t.id === 'platform-os-binding');
  if (!test) return null;
  const run = runFor(test);
  if (!run) return null;
  const counts = new Map<string, number>();
  for (const m of run.result.results) {
    for (const f of m.findings?.rows || []) {
      const profile = f.os_profile != null ? String(f.os_profile) : '';
      if (profile) counts.set(profile, (counts.get(profile) || 0) + 1);
    }
  }
  if (counts.size === 0) return null;
  return [...counts.entries()]
    .map(([profile, count]) => ({ profile, count }))
    .sort((a, b) => b.count - a.count || a.profile.localeCompare(b.profile));
}

/** OS axis display order — OS names are proper nouns, never localized. */
const OS_MATRIX_OS: { id: 'macos' | 'windows' | 'linux' | 'ios'; label: string }[] = [
  { id: 'macos', label: 'macOS' },
  { id: 'windows', label: 'Windows' },
  { id: 'linux', label: 'Linux' },
  { id: 'ios', label: 'iOS' },
];

interface OsMatrixData {
  members: { ref: string; title: string }[];
  rows: { os: string; label: string; cells: Record<string, number> }[];
}

/**
 * Consolidated OS matrix of the platform-os-binding set: rows = OS, columns =
 * the set's evidence members (steps / functions / plug-ins), cells = distinct
 * scripts bound to that OS. Built from the shared per-OS boolean flags every
 * member's findings carry, applying the OS-SPECIFIC rule: only bindings
 * confined to at most TWO operating systems count (a desktop-only script
 * counts for macOS and Windows; a broad "everything except Linux"
 * restriction counts for none — it would otherwise contaminate the per-OS
 * cells with scripts that have nothing OS-typical about them). Skipped
 * members (missing reference/plugin spec) are left out instead of rendering
 * an empty column.
 */
function osBindingMatrix(
  tests: TestListItem[],
  runFor: (t: TestListItem) => CachedRun | undefined,
): OsMatrixData | null {
  const test = tests.find(t => t.id === 'platform-os-binding');
  if (!test) return null;
  const run = runFor(test);
  if (!run) return null;
  const members: { ref: string; title: string }[] = [];
  const perMember = new Map<string, Map<string, Set<string>>>();
  for (const m of run.result.results) {
    if (m.runStatus === 'skipped') continue;
    members.push({ ref: m.ref, title: m.title || m.ref });
    const byOs = new Map<string, Set<string>>();
    for (const f of m.findings?.rows || []) {
      const uuid = f.nav_uuid != null ? String(f.nav_uuid) : null;
      if (!uuid) continue;
      const supported = OS_MATRIX_OS.filter(({ id }) => f[id] === true);
      if (supported.length > 2) continue; // not OS-specific
      for (const { id } of supported) {
        if (!byOs.has(id)) byOs.set(id, new Set());
        byOs.get(id)!.add(uuid);
      }
    }
    perMember.set(m.ref, byOs);
  }
  if (members.length === 0) return null;
  const rows = OS_MATRIX_OS.map(({ id, label }) => {
    const cells: Record<string, number> = {};
    for (const m of members) cells[m.ref] = perMember.get(m.ref)?.get(id)?.size || 0;
    return { os: id, label, cells };
  });
  if (!rows.some(r => Object.values(r.cells).some(n => n > 0))) return null;
  return { members, rows };
}

// ---------------------------------------------------------------------------
// Panel
// ---------------------------------------------------------------------------

interface Section {
  key: string;
  label: string;
  order: number;
  isPlatform: boolean;
  tests: TestListItem[];
}

export const TestsPanel: React.FC<TestsPanelProps> = ({ objectUuid, objectType, fileName }) => {
  const { t } = useTranslation(['nav']);
  const lang = useApiLang();
  const [tests, setTests] = useState<TestListItem[] | null>(null);
  const [listError, setListError] = useState<string | null>(null);
  const [context, setContext] = useState<TestsContext | null>(null);
  const [running, setRunning] = useState<string | null>(null);
  const [runningAll, setRunningAll] = useState(false);
  const [runErrors, setRunErrors] = useState<Record<string, string>>({});
  const [query, setQuery] = useState('');
  const [typeFilter, setTypeFilter] = useState<ReadonlySet<string>>(new Set());
  const [stateFilter, setStateFilter] = useState<ReadonlySet<StateKey>>(new Set());
  const [sortByResult, setSortByResult] = useState(false);
  const [showDisabled, setShowDisabled] = useState<Record<string, boolean>>({});
  const [settings, setSettings] = useState<TestsSettings>(() => loadTestsSettings(null));
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});

  const solution = context?.solution ?? null;
  const fingerprint = context?.catalogFingerprint ?? null;

  // Context (cache key) + test list. The solution context drives settings and
  // section state, so both hydrate once the context call answers.
  useEffect(() => {
    let cancelled = false;
    setTests(null);
    setListError(null);
    setContext(null);
    Promise.all([
      getTestsContext(),
      listTests({ objectType, scope: 'object' }, lang),
    ])
      .then(([ctx, rows]) => {
        if (cancelled) return;
        setContext(ctx);
        setSettings(loadTestsSettings(ctx.solution));
        setCollapsed(loadSectionState(ctx.solution, objectType));
        setTests(rows.filter(r => r.validation.status !== 'errors'));
      })
      .catch(err => { if (!cancelled) setListError((err as Error).message); });
    return () => { cancelled = true; };
  }, [objectType, lang]);

  const updateSettings = useCallback((update: (s: TestsSettings) => TestsSettings) => {
    setSettings(prev => {
      const next = update(prev);
      saveTestsSettings(solution, next);
      return next;
    });
  }, [solution]);

  const profileOf = useCallback((test: TestListItem): string => {
    const chosen = settings.profileByTest[test.id] || '';
    return chosen && test.profiles.some(p => p.id === chosen) ? chosen : '';
  }, [settings.profileByTest]);

  // Result cache: read-through view keyed by test id + selected profile.
  const storeVersion = useSyncExternalStore(subscribeTestsStore, getTestsStoreVersion);
  const cachedRuns = useMemo(() => {
    if (!solution || !fingerprint) return {} as Record<string, CachedRun>;
    return getCachedRuns(solution, objectUuid, fileName || '', fingerprint);
    // storeVersion invalidates the memo when runs are added/pruned.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [solution, fingerprint, objectUuid, fileName, storeVersion]);

  const runFor = useCallback(
    (test: TestListItem): CachedRun | undefined => cachedRuns[`${test.id}|${profileOf(test)}`],
    [cachedRuns, profileOf],
  );

  const handleRun = useCallback(async (test: TestListItem) => {
    setRunning(test.id);
    setRunErrors(prev => ({ ...prev, [test.id]: '' }));
    const profile = profileOf(test);
    try {
      const result = await runTest(test.id, {
        uuid: objectUuid,
        file: fileName || undefined,
        object_type: objectType,
        include: 'findings',
        profile: profile || undefined,
      }, lang);
      const fp = result.meta.catalogFingerprint || fingerprint;
      const sol = result.meta.solution || solution;
      if (sol && fp) {
        putCachedRun(sol, objectUuid, fileName || '', test.id, profile, fp, result);
        // The catalog changed mid-session → adopt the fresh fingerprint so the
        // new entry (and only it) is visible.
        if (fp !== fingerprint || sol !== solution) {
          setContext({ solution: sol, catalogFingerprint: fp, catalogMtimeMs: result.meta.catalogMtimeMs ?? null });
        }
      }
    } catch (err) {
      setRunErrors(prev => ({ ...prev, [test.id]: (err as Error).message }));
    } finally {
      setRunning(null);
    }
  }, [objectUuid, objectType, fileName, lang, profileOf, fingerprint, solution]);

  const toggleDisabled = useCallback((testId: string) => {
    updateSettings(s => ({
      ...s,
      disabledTests: s.disabledTests.includes(testId)
        ? s.disabledTests.filter(id => id !== testId)
        : [...s.disabledTests, testId],
    }));
  }, [updateSettings]);

  const selectProfile = useCallback((testId: string, profileId: string) => {
    updateSettings(s => {
      const profileByTest = { ...s.profileByTest };
      if (profileId) profileByTest[testId] = profileId;
      else delete profileByTest[testId];
      return { ...s, profileByTest };
    });
  }, [updateSettings]);

  const togglePlatform = useCallback((testId: string) => {
    updateSettings(s => ({
      ...s,
      platforms: s.platforms.includes(testId)
        ? s.platforms.filter(id => id !== testId)
        : [...s.platforms, testId],
    }));
  }, [updateSettings]);

  const toggleSection = useCallback((key: string, defaultCollapsed: boolean) => {
    setCollapsed(prev => {
      const cur = prev[key] ?? defaultCollapsed;
      const next = { ...prev, [key]: !cur };
      saveSectionState(solution, objectType, next);
      return next;
    });
  }, [solution, objectType]);

  // Sections: folder-grouped, platform tests consolidated.
  const sections = useMemo<Section[]>(() => {
    if (!tests) return [];
    const byKey = new Map<string, Section>();
    for (const test of tests) {
      const isPlatform = test.testType === 'platform';
      const key = isPlatform ? PLATFORM_SECTION_KEY : (test.folder || '__none');
      let section = byKey.get(key);
      if (!section) {
        section = {
          key,
          label: isPlatform
            ? (test.folder_label || (t('nav:testsPanel.platformSection') as string))
            : (test.folder_label || test.folder || (t('nav:testsPanel.otherSection') as string)),
          order: isPlatform ? Number.MAX_SAFE_INTEGER : (test.folder_order ?? Number.MAX_SAFE_INTEGER - 1),
          isPlatform,
          tests: [],
        };
        byKey.set(key, section);
      }
      section.tests.push(test);
    }
    return [...byKey.values()].sort((a, b) => (a.order - b.order) || a.label.localeCompare(b.label, lang));
  }, [tests, lang, t]);

  // Visibility pipeline: user activation → type filter → text → state filter.
  const isActive = useCallback((test: TestListItem, section: Section): boolean => {
    if (settings.disabledTests.includes(test.id)) return false;
    if (section.isPlatform && !settings.platforms.includes(test.id)) return false;
    return true;
  }, [settings]);

  // Type + text predicate, kept separate from the state predicate: it is also
  // the stable base for the chip counts and run-all — an active state chip
  // must not shrink the other chips' counts.
  const matchesMeta = useCallback((test: TestListItem): boolean => {
    if (typeFilter.size > 0 && !typeFilter.has(test.testType)) return false;
    const q = query.trim().toLowerCase();
    if (q) {
      const inMeta = test.title.toLowerCase().includes(q)
        || (test.description || '').toLowerCase().includes(q)
        || test.keywords.some(k => k.toLowerCase().includes(q));
      if (!inMeta && !runMatchesQuery(runFor(test), q)) return false;
    }
    return true;
  }, [typeFilter, query, runFor]);

  const matchesState = useCallback((test: TestListItem): boolean => {
    if (stateFilter.size === 0) return true;
    const summary = runFor(test)?.result.summary;
    if (!summary) return false;
    return [...stateFilter].some(k => summary[k] > 0);
  }, [stateFilter, runFor]);

  const matchesFilters = useCallback(
    (test: TestListItem): boolean => matchesMeta(test) && matchesState(test),
    [matchesMeta, matchesState],
  );

  const visibleActiveTests = useMemo(() => {
    const out: TestListItem[] = [];
    for (const section of sections) {
      for (const test of section.tests) {
        if (isActive(test, section) && matchesFilters(test)) out.push(test);
      }
    }
    return out;
  }, [sections, isActive, matchesFilters]);

  // Active tests after type + text filter but BEFORE the state filter —
  // basis for the summary chips, the "not run" count and run-all.
  const metaActiveTests = useMemo(() => {
    const out: TestListItem[] = [];
    for (const section of sections) {
      for (const test of section.tests) {
        if (isActive(test, section) && matchesMeta(test)) out.push(test);
      }
    }
    return out;
  }, [sections, isActive, matchesMeta]);

  // Any active result/type chip switches the panel into the flat result list.
  const flatMode = stateFilter.size > 0 || typeFilter.size > 0;

  // Flat result list: the matching member rows (level 3 — one row per rule
  // result, chip counts and row count add up), sorted worst-first, hierarchy
  // order as tiebreaker. Members exist only for cached runs — tests without a
  // run stay in the "not run" count instead.
  const flatMembers = useMemo<{ key: string; member: TestRunMemberResult; context: string }[]>(() => {
    if (!flatMode) return [];
    const q = query.trim().toLowerCase();
    const out: { key: string; member: TestRunMemberResult; context: string; rank: number; pos: number }[] = [];
    let pos = 0;
    for (const section of sections) {
      for (const test of section.tests) {
        if (!isActive(test, section)) continue;
        if (typeFilter.size > 0 && !typeFilter.has(test.testType)) continue;
        const run = runFor(test);
        if (!run) continue;
        run.result.results.forEach((member, i) => {
          pos += 1;
          const state = (member.runStatus === 'failed' ? 'failed'
            : member.runStatus === 'skipped' ? 'skipped' : member.resultState) as StateKey | undefined;
          if (stateFilter.size > 0 && (!state || !stateFilter.has(state))) return;
          if (q && !(member.title || member.ref).toLowerCase().includes(q)
            && !(member.findings?.rows || []).some(f => findingMatches(f, q))) return;
          out.push({
            key: `${test.id}|${member.ref}|${i}`,
            member,
            context: `${section.label} › ${test.title}`,
            rank: state ? STATE_ORDER.indexOf(state) : STATE_ORDER.length,
            pos,
          });
        });
      }
    }
    return out.sort((a, b) => (a.rank - b.rank) || (a.pos - b.pos));
  }, [flatMode, sections, isActive, typeFilter, stateFilter, query, runFor]);

  const flatHasRuns = useMemo(
    () => metaActiveTests.some(test => runFor(test) !== undefined),
    [metaActiveTests, runFor],
  );

  // Aggregated summary bar: runs of the meta-filtered active tests.
  const totals = useMemo(() => {
    const sum = emptySummary();
    let ran = 0;
    for (const test of metaActiveTests) {
      const run = runFor(test);
      if (run) { addSummary(sum, run.result.summary); ran += 1; }
    }
    return { sum, ran, notRun: metaActiveTests.length - ran };
  }, [metaActiveTests, runFor]);

  const newestRunAt = useMemo(() => {
    let newest = 0;
    for (const test of metaActiveTests) {
      const run = runFor(test);
      if (run && run.at > newest) newest = run.at;
    }
    return newest || null;
  }, [metaActiveTests, runFor]);

  const typeCounts = useMemo(() => {
    const counts = new Map<string, number>();
    for (const section of sections) {
      for (const test of section.tests) {
        if (!isActive(test, section)) continue;
        counts.set(test.testType, (counts.get(test.testType) || 0) + 1);
      }
    }
    return counts;
  }, [sections, isActive]);

  const toggleType = useCallback((type: string) => {
    setTypeFilter(prev => {
      const next = new Set(prev);
      if (next.has(type)) next.delete(type); else next.add(type);
      return next;
    });
  }, []);

  const toggleState = useCallback((key: StateKey) => {
    setStateFilter(prev => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key); else next.add(key);
      return next;
    });
  }, []);

  // Sequential run keeps server load bounded; results appear progressively.
  // Runs over the state-independent set — with a state chip active, run-all
  // would otherwise iterate an empty (or misleadingly small) selection.
  const handleRunAll = useCallback(async () => {
    setRunningAll(true);
    try {
      for (const test of metaActiveTests) {
        // eslint-disable-next-line no-await-in-loop
        await handleRun(test);
      }
    } finally {
      setRunningAll(false);
    }
  }, [metaActiveTests, handleRun]);

  if (listError) return <ErrorMessage message={listError} />;
  if (tests === null) return <LoadingSpinner message={t('nav:testsPanel.loading') as string} />;

  if (tests.length === 0) {
    return (
      <div className="tests-panel-empty">
        <p>{t('nav:testsPanel.empty', { type: objectType })}</p>
        <Link to="/tests">{t('nav:testsPanel.openOverview')}</Link>
      </div>
    );
  }

  const busy = running !== null || runningAll;

  const renderSection = (section: Section) => {
    const defaultCollapsed = section.isPlatform;
    const isCollapsed = collapsed[section.key] ?? defaultCollapsed;
    const activeTests = section.tests.filter(test => isActive(test, section));
    const visibleTests = activeTests.filter(matchesFilters);
    const disabledTests = section.tests.filter(test => settings.disabledTests.includes(test.id));
    const inactivePlatforms = section.isPlatform
      ? section.tests.filter(test => !settings.platforms.includes(test.id) && !settings.disabledTests.includes(test.id))
      : [];

    const sectionSummary = emptySummary();
    let sectionRan = 0;
    for (const test of visibleTests) {
      const run = runFor(test);
      if (run) { addSummary(sectionSummary, run.result.summary); sectionRan += 1; }
    }

    const sortedTests = sortByResult
      ? [...visibleTests].sort((a, b) => worstRank(runFor(a)?.result.summary) - worstRank(runFor(b)?.result.summary))
      : visibleTests;

    const matrix = section.isPlatform && !isCollapsed ? buildMatrix(activeTests, runFor) : null;
    const osProfiles = section.isPlatform && !isCollapsed ? osBindingProfiles(activeTests, runFor) : null;
    const osMatrix = section.isPlatform && !isCollapsed ? osBindingMatrix(activeTests, runFor) : null;

    return (
      <section key={section.key} className="tests-section">
        <header className="tests-section-header">
          <button
            className="tests-section-toggle"
            onClick={() => toggleSection(section.key, defaultCollapsed)}
            aria-expanded={!isCollapsed}
          >
            {isCollapsed ? '▸' : '▾'} {section.label}
          </button>
          {section.isPlatform && (
            <span className="tests-platform-chips">
              {section.tests
                .filter(test => settings.platforms.includes(test.id))
                .map(test => (
                  <button
                    key={test.id}
                    className="tests-chip active"
                    onClick={() => togglePlatform(test.id)}
                    title={t('nav:testsPanel.platformRemove') as string}
                  >
                    {platformLabel(test)} ×
                  </button>
                ))}
              {inactivePlatforms.length > 0 && (
                <select
                  className="tests-platform-add"
                  value=""
                  onChange={e => { if (e.target.value) togglePlatform(e.target.value); }}
                  aria-label={t('nav:testsPanel.platformAdd') as string}
                >
                  <option value="">{t('nav:testsPanel.platformAdd')}</option>
                  {inactivePlatforms.map(test => (
                    <option key={test.id} value={test.id}>{platformLabel(test)}</option>
                  ))}
                </select>
              )}
            </span>
          )}
          <span className="tests-section-summary">
            {sectionRan > 0 && <SummaryTokens summary={sectionSummary} />}
            {visibleTests.length - sectionRan > 0 && (
              <span className="tests-notrun">
                {t('nav:testsPanel.notRun', { count: visibleTests.length - sectionRan })}
              </span>
            )}
          </span>
        </header>
        {!isCollapsed && (
          <div className="tests-section-body">
            {section.isPlatform && settings.platforms.length === 0 && (
              <p className="tests-platform-hint">{t('nav:testsPanel.platformNone')}</p>
            )}
            {sortedTests.map(test => (
              <TestRow
                key={test.id}
                test={test}
                run={runFor(test)}
                runError={runErrors[test.id] || undefined}
                runDisabled={busy}
                isRunning={running === test.id}
                disabled={false}
                profileId={profileOf(test)}
                query={query}
                onRun={handleRun}
                onToggleDisabled={toggleDisabled}
                onSelectProfile={selectProfile}
              />
            ))}
            {matrix && (
              <div className="tests-matrix-wrap">
                <table className="tests-matrix">
                  <thead>
                    <tr>
                      <th>{t('nav:testsPanel.matrixStep')}</th>
                      {matrix.platforms.map(p => <th key={p.id}>{p.label}</th>)}
                    </tr>
                  </thead>
                  <tbody>
                    {matrix.rows.map(row => (
                      <tr key={row.key}>
                        <td>{row.label}</td>
                        {matrix.platforms.map(p => {
                          const cell = row.cells[p.id];
                          return (
                            <td key={p.id} className={cell ? `tests-state-${cell}` : ''}>
                              {cell ? STATE_TOKEN[cell] : ''}
                            </td>
                          );
                        })}
                      </tr>
                    ))}
                  </tbody>
                </table>
                {matrix.truncated && (
                  <p className="tests-findings-truncated">{t('nav:testsPanel.truncated')}</p>
                )}
              </div>
            )}
            {osProfiles && (
              <div className="tests-os-binding">
                <span className="tests-os-binding-label">{t('nav:testsPanel.osBindingLabel')}</span>
                {osProfiles.map(p => (
                  <span key={p.profile} className="tests-token tests-state-neutral">
                    {p.profile} × {p.count}
                  </span>
                ))}
              </div>
            )}
            {osMatrix && (
              <div className="tests-matrix-wrap tests-os-matrix">
                <table className="tests-matrix">
                  <thead>
                    <tr>
                      <th>{t('nav:testsPanel.osMatrixOs')}</th>
                      {osMatrix.members.map(m => <th key={m.ref} title={m.ref}>{m.title}</th>)}
                    </tr>
                  </thead>
                  <tbody>
                    {osMatrix.rows.map(row => (
                      <tr key={row.os}>
                        <td>{row.label}</td>
                        {osMatrix.members.map(m => (
                          <td key={m.ref} className="num">
                            {row.cells[m.ref] > 0 ? row.cells[m.ref] : ''}
                          </td>
                        ))}
                      </tr>
                    ))}
                  </tbody>
                </table>
                <p className="tests-os-matrix-hint">{t('nav:testsPanel.osMatrixHint')}</p>
              </div>
            )}
            {disabledTests.length > 0 && (
              <div className="tests-section-footer">
                <button
                  className="tests-footer-toggle"
                  onClick={() => setShowDisabled(prev => ({ ...prev, [section.key]: !prev[section.key] }))}
                >
                  {t('nav:testsPanel.disabledCount', { count: disabledTests.length })}
                  {' '}
                  {showDisabled[section.key] ? t('nav:testsPanel.hideDisabled') : t('nav:testsPanel.showDisabled')}
                </button>
                {showDisabled[section.key] && disabledTests.map(test => (
                  <TestRow
                    key={test.id}
                    test={test}
                    run={undefined}
                    runDisabled={busy}
                    isRunning={false}
                    disabled
                    profileId={profileOf(test)}
                    query={query}
                    onRun={handleRun}
                    onToggleDisabled={toggleDisabled}
                    onSelectProfile={selectProfile}
                  />
                ))}
              </div>
            )}
          </div>
        )}
      </section>
    );
  };

  return (
    <div className="tests-panel">
      <div className="tests-summary-bar">
        <div className="tests-summary-tokens" role="group" aria-label={t('nav:testsPanel.stateFilterAria') as string}>
          {STATE_ORDER.map(key => (
            <button
              key={key}
              className={`tests-chip tests-state-chip${stateFilter.has(key) ? ' active' : ''}`}
              onClick={() => toggleState(key)}
              aria-pressed={stateFilter.has(key)}
              title={t(`nav:testsPanel.state_${key}`) as string}
            >
              <span className={`tests-token tests-state-${key}`}>{STATE_TOKEN[key]}</span>
              <span className="tests-chip-count">{totals.sum[key]}</span>
            </button>
          ))}
          {flatMode && (
            <button
              className="tests-chip tests-filter-reset"
              onClick={() => { setStateFilter(new Set()); setTypeFilter(new Set()); }}
              title={t('nav:testsPanel.filterReset') as string}
              aria-label={t('nav:testsPanel.filterReset') as string}
            >
              ×
            </button>
          )}
          {totals.notRun > 0 && (
            <span className="tests-notrun">{t('nav:testsPanel.notRun', { count: totals.notRun })}</span>
          )}
        </div>
        <div className="tests-summary-meta">
          {newestRunAt && (
            <span>{t('nav:testsPanel.resultsFrom', { time: new Date(newestRunAt).toLocaleTimeString() })}</span>
          )}
          {context?.catalogMtimeMs && (
            <span>{t('nav:testsPanel.catalogFrom', { time: new Date(context.catalogMtimeMs).toLocaleString() })}</span>
          )}
        </div>
      </div>
      <div className="tests-toolbar">
        <div className="tests-toolbar-chips" role="group" aria-label={t('nav:testsPanel.typeFilterAria') as string}>
          {[...typeCounts.entries()].map(([type, count]) => (
            <button
              key={type}
              className={`tests-chip${typeFilter.has(type) ? ' active' : ''}`}
              onClick={() => toggleType(type)}
              aria-pressed={typeFilter.has(type)}
            >
              <span className={`tests-chip-bullet tests-type-${type}`} aria-hidden="true" />
              {type}
              <span className="tests-chip-count">{count}</span>
            </button>
          ))}
        </div>
        {!flatMode && (
          <label className="tests-sort-toggle">
            <input
              type="checkbox"
              checked={sortByResult}
              onChange={e => setSortByResult(e.target.checked)}
            />
            {t('nav:testsPanel.sortByResult')}
          </label>
        )}
        <input
          type="search"
          className="tests-toolbar-search"
          value={query}
          onChange={e => setQuery(e.target.value)}
          placeholder={t('nav:testsPanel.searchPlaceholder') as string}
          aria-label={t('nav:testsPanel.searchPlaceholder') as string}
        />
        <button
          className="tests-run-button tests-run-all"
          onClick={handleRunAll}
          disabled={busy || metaActiveTests.length === 0}
        >
          {runningAll
            ? t('nav:testsPanel.running')
            : t('nav:testsPanel.runAll', { count: metaActiveTests.length })}
        </button>
      </div>
      {flatMode ? (
        flatMembers.length > 0 ? (
          <div className="tests-flat-list">
            {flatMembers.map(fm => (
              <MemberRow key={fm.key} member={fm.member} query={query} flatContext={fm.context} />
            ))}
          </div>
        ) : (
          <div className="tests-panel-empty">
            <p>{t(flatHasRuns ? 'nav:testsPanel.noMatch' : 'nav:testsPanel.noResultsYet')}</p>
          </div>
        )
      ) : (
        <>
          {visibleActiveTests.length === 0 && (
            <div className="tests-panel-empty">
              <p>{t('nav:testsPanel.noMatch')}</p>
            </div>
          )}
          {sections.map(renderSection)}
        </>
      )}
    </div>
  );
};
