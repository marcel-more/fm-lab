const environment = require('../config/environment');
const dashboardCleanup = require('./dashboard-cleanup');
const testCleanup = require('./test-cleanup');
const updateBackupImport = require('./update-backup-import');

/**
 * Automatic cleanup at server start — runs the dashboard and the test cleanup
 * once before the API serves any request, so leftovers of an older template
 * layout never show up as duplicates after an update.
 *
 * Why at start and without a question: old copies of moved files stay behind
 * wherever an update did not remove them — files copied over an old folder,
 * own files at old places, a stopped `git pull` completed by tools/update.sh.
 * A locally edited copy at a tracked path would block the next pull that
 * deletes it. Modified old copies live on as own versions under Custom
 * (`<id>-local`); everything else moves to `…-removed/<stamp>/` with the
 * run's `cleanup.json`
 * (`trigger: 'startup'`). Nothing is deleted. Afterwards edited shipped units
 * that tools/update.sh saved become own versions too (update-backup-import.js).
 * The overview shows the result once (`lastRun({ trigger: 'startup' })`,
 * `lastImport(kind)`).
 *
 * Never blocks the start: a failing routine is logged and skipped.
 * STARTUP_CLEANUP_ENABLED=false turns it off (the manual cleanup stays).
 */

const ROUTINES = [
  { kind: 'dashboards', cleanup: dashboardCleanup },
  { kind: 'tests', cleanup: testCleanup },
];

/** → [{ kind, moved, forked, errors, removed_dir } | { kind, skipped: reason }] */
async function runStartupCleanup({ log = console } = {}) {
  if (!environment.templates.startupCleanup) return [];
  const results = [];
  for (const { kind, cleanup } of ROUTINES) {
    try {
      const preview = cleanup.preview();
      if (!preview.inventory || preview.items.length === 0) continue;
      const report = await cleanup.run({ trigger: 'startup' });
      results.push({
        kind,
        moved: report.summary.total,
        forked: report.summary.forked,
        errors: report.errors,
        removed_dir: report.removed_dir,
      });
      if (report.errors.length) {
        log.warn(`Startup cleanup (${kind}): ${report.errors.length} problem(s), nothing moved — ${report.errors[0].from}: ${report.errors[0].message}`);
      } else if (report.summary.total) {
        const { to_removed: removed, to_custom: toCustom, forked } = report.summary;
        const parts = [];
        if (removed) parts.push(`${removed} leftover(s) of an earlier version moved → rest-api/templates/${report.removed_dir}`);
        if (toCustom) parts.push(`${toCustom} own item(s) moved to Custom`);
        if (forked) parts.push(`${forked} edited copy/copies kept as own version under Custom`);
        log.log(`Startup cleanup (${kind}): ${parts.join(', ')}`);
      }
    } catch (err) {
      results.push({ kind, skipped: err.message });
      log.warn(`Startup cleanup (${kind}) skipped: ${err.message}`);
    }
  }
  // Edited shipped dashboards/tests that tools/update.sh saved → own versions.
  try {
    for (const r of updateBackupImport.importUpdateBackups()) {
      results.push({ kind: 'update-backup', backup: r.backup, forked: r.forks.length, skipped: r.skipped });
      if (r.forks.length) {
        log.log(`Update backup ${r.backup}: ${r.forks.length} edited version(s) kept as own version under Custom (${r.forks.map(f => f.fork_id).join(', ')})`);
      }
    }
  } catch (err) {
    log.warn(`Update backup import skipped: ${err.message}`);
  }
  return results;
}

module.exports = { runStartupCleanup };
