import { useEffect, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  getCleanup, runCleanup,
  type CleanupItem, type CleanupKind, type CleanupLastRun, type CleanupReport, type CleanupUpdateImport,
} from '../api/maintenanceApi';
import { ensureSummaryLoaded } from '../lib/resultsStore';
import { showToast } from '../lib/toastStore';

type Phase = 'idle' | 'running' | 'done';

/** Items of an old query location (f1–f4) — counted apart on the dashboard overview. */
const isOldQueryLocation = (item: CleanupItem) => /^f[1-4]$/.test(item.case);

// Stamp of the last automatic run the viewer closed, per kind (per browser).
const STARTUP_SEEN_PREFIX = 'fmlab.cleanup.startupSeen.';

function startupSeen(kind: CleanupKind): string | null {
  try {
    return window.localStorage.getItem(`${STARTUP_SEEN_PREFIX}${kind}`);
  } catch {
    return null;
  }
}

/** One key for the pair of runs a notice reports — a newer run of either shows it again. */
const seenKey = (run: CleanupLastRun | null, imp: CleanupUpdateImport | null) => `${run?.stamp ?? ''}|${imp?.stamp ?? ''}`;

function markStartupSeen(kind: CleanupKind, stamp: string): void {
  try {
    window.localStorage.setItem(`${STARTUP_SEEN_PREFIX}${kind}`, stamp);
  } catch {
    /* quota/private mode — the notice simply shows again after a reload */
  }
}

/**
 * Hint box above an overview: content left over from an older template layout
 * — `kind="dashboards"` on `/dashboard` (old dashboard folders, queries at the
 * old locations `sql-custom/` …), `kind="tests"` on `/tests` (tests away from
 * their shipped path, own tests in the shipped tree). Checks once per mount and
 * renders nothing on a clean installation. The preview lists every move; old
 * copies that differ from the shipped one can be left in place; an edited old
 * copy also lives on as an own version under Custom. After the run the box
 * confirms what moved where, the overview and the result summary reload.
 *
 * Without findings it reports the automatic run at server start once (what an
 * update moved, which edited copies became own versions) until it is closed.
 */
export function CleanupNotice({ kind }: { kind: CleanupKind }) {
  const { t } = useTranslation(['dashboard']);
  const [items, setItems] = useState<CleanupItem[]>([]);
  const [keep, setKeep] = useState<Set<string>>(() => new Set());
  const [open, setOpen] = useState(false);
  const [phase, setPhase] = useState<Phase>('idle');
  const [report, setReport] = useState<CleanupReport | null>(null);
  const [dismissed, setDismissed] = useState(false);
  const [startup, setStartup] = useState<CleanupLastRun | null>(null);
  const [imported, setImported] = useState<CleanupUpdateImport | null>(null);

  useEffect(() => {
    let cancelled = false;
    getCleanup(kind)
      .then(preview => {
        if (cancelled) return;
        setItems(preview.items);
        const last = preview.last_startup_run?.summary.total ? preview.last_startup_run : null;
        const imp = preview.last_update_import?.forks.length ? preview.last_update_import : null;
        if ((last || imp) && startupSeen(kind) !== seenKey(last, imp)) {
          setStartup(last);
          setImported(imp);
        }
      })
      .catch(() => { /* no hint without an answer — the overview works as before */ });
    return () => { cancelled = true; };
  }, [kind]);

  if (dismissed || (items.length === 0 && !report && !startup && !imported)) return null;

  if (items.length === 0 && !report && (startup || imported)) {
    const forkIds = [...(startup?.forks ?? []), ...(imported?.forks ?? [])].map(f => f.fork_id);
    // Own dashboards/tests moved to Custom are not leftovers: count them apart from
    // the old copies that went to the removed folder.
    const startupRemoved = startup?.summary.to_removed ?? 0;
    const startupCustom = startup?.summary.to_custom ?? 0;
    const close = () => {
      markStartupSeen(kind, seenKey(startup, imported));
      setDismissed(true);
    };
    return (
      <div className="dash-cleanup dash-cleanup--done" role="status">
        <p className="dash-cleanup__text">
          {startup && startupRemoved > 0 && t('dashboard:cleanup.startup', { count: startupRemoved, dir: startup.removed_dir })}
          {startupCustom > 0 && (
            <> {t(kind === 'tests' ? 'dashboard:cleanup.doneCustomTests' : 'dashboard:cleanup.doneCustom', { count: startupCustom })}.</>
          )}
          {forkIds.length > 0 && (
            <> {t('dashboard:cleanup.startupForks', { count: forkIds.length, ids: forkIds.join(', ') })}</>
          )}
          {(startupRemoved > 0 || forkIds.length > 0) && (
            <span className="dash-cleanup__hint">{t('dashboard:cleanup.doneHint')}</span>
          )}
        </p>
        <button type="button" className="dash-folderbar__link" onClick={close}>
          {t('dashboard:cleanup.close')}
        </button>
      </div>
    );
  }

  const toggleKeep = (from: string) => {
    setKeep(prev => {
      const next = new Set(prev);
      if (next.has(from)) next.delete(from);
      else next.add(from);
      return next;
    });
  };

  const run = async () => {
    setPhase('running');
    try {
      const result = await runCleanup(kind, [...keep]);
      setReport(result);
      setPhase('done');
      window.dispatchEvent(new Event('fmlab:reload-dashboard'));
      void ensureSummaryLoaded(true);
    } catch (err) {
      setPhase('idle');
      showToast({
        message: t('dashboard:cleanup.failed', { message: err instanceof Error ? err.message : String(err) }),
        tone: 'error',
      });
    }
  };

  if (phase === 'done' && report) {
    const toCustom = report.moved.filter(i => i.target === 'custom').length;
    const toRemoved = report.moved.length - toCustom;
    const forked = report.moved.filter(i => i.fork).length;
    const parts = [
      toCustom > 0
        ? t(kind === 'tests' ? 'dashboard:cleanup.doneCustomTests' : 'dashboard:cleanup.doneCustom', { count: toCustom })
        : null,
      toRemoved > 0 ? t('dashboard:cleanup.doneRemoved', { count: toRemoved, dir: report.removed_dir ?? '' }) : null,
      forked > 0 ? t('dashboard:cleanup.doneForked', { count: forked }) : null,
    ].filter(Boolean);
    return (
      <div className="dash-cleanup dash-cleanup--done" role="status">
        <p className="dash-cleanup__text">
          {parts.length ? parts.join(' · ') : t('dashboard:cleanup.doneNothing')}
          {toRemoved > 0 && <span className="dash-cleanup__hint">{t('dashboard:cleanup.doneHint')}</span>}
        </p>
        {report.errors.length > 0 && (
          <ul className="dash-cleanup__errors">
            {report.errors.map(e => <li key={e.from}><code>{e.from}</code> — {e.message}</li>)}
          </ul>
        )}
        <button type="button" className="dash-folderbar__link" onClick={() => setDismissed(true)}>
          {t('dashboard:cleanup.close')}
        </button>
      </div>
    );
  }

  let found: string;
  if (kind === 'tests') {
    found = t('dashboard:cleanup.foundTests', { count: items.length });
  } else {
    const oldQueries = items.filter(isOldQueryLocation).length;
    const dashboards = items.length - oldQueries;
    found = [
      dashboards > 0 ? t('dashboard:cleanup.found', { count: dashboards }) : null,
      oldQueries > 0 ? t('dashboard:cleanup.foundQueries', { count: oldQueries }) : null,
    ].filter(Boolean).join(' ');
  }

  const busy = phase === 'running';
  const moving = items.length - keep.size;
  return (
    <section
      className="dash-cleanup"
      aria-label={t(kind === 'tests' ? 'dashboard:cleanup.labelTests' : 'dashboard:cleanup.label') as string}
    >
      <div className="dash-cleanup__head">
        <p className="dash-cleanup__text">{found}</p>
        <button type="button" className="dash-folderbar__link" aria-expanded={open} onClick={() => setOpen(o => !o)}>
          {t(open ? 'dashboard:cleanup.hideDetails' : 'dashboard:cleanup.showDetails')}
        </button>
        <button type="button" className="dash-cleanup__run" onClick={run} disabled={busy || moving === 0}>
          {busy ? t('dashboard:cleanup.running') : t('dashboard:cleanup.run')}
        </button>
      </div>
      {open && (
        <ul className="dash-cleanup__list">
          {items.map(item => (
            <li key={item.from} className={`dash-cleanup__item${keep.has(item.from) ? ' dash-cleanup__item--kept' : ''}`}>
              {item.modified ? (
                <input
                  type="checkbox"
                  checked={!keep.has(item.from)}
                  onChange={() => toggleKeep(item.from)}
                  disabled={busy}
                  aria-label={t('dashboard:cleanup.moveThis', { path: item.from }) as string}
                  title={t('dashboard:cleanup.keepHint') as string}
                />
              ) : (
                <span className="dash-cleanup__nocheck" aria-hidden="true" />
              )}
              <code className="dash-cleanup__path">{item.from}</code>
              <span className="dash-cleanup__arrow" aria-hidden="true">→</span>
              <code className="dash-cleanup__path">
                {item.target === 'custom' ? item.to : item.to.replace(/^([a-z-]+-removed)\/[^/]+\//, '$1/…/')}
              </code>
              <span className="dash-cleanup__case">{t(`dashboard:cleanup.case.${item.case}`)}</span>
              {item.modified && (
                <span className="dash-cleanup__tag" title={item.canonical ?? undefined}>{t('dashboard:cleanup.modified')}</span>
              )}
              {item.fork_id && <span className="dash-cleanup__tag">{t('dashboard:cleanup.forkTag', { id: item.fork_id })}</span>}
              {item.conflict && <span className="dash-cleanup__tag">{t('dashboard:cleanup.conflict')}</span>}
              {item.note === 'report_template' && (
                <span className="dash-cleanup__tag">{t('dashboard:cleanup.noteReportTemplate')}</span>
              )}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
