const fs = require('fs');
const path = require('path');
const environment = require('../config/environment');
const { fmlabDir } = require('../plugins/settings-store');
const engine = require('./template-cleanup');
const dashboardCleanup = require('./dashboard-cleanup');
const testCleanup = require('./test-cleanup');

/**
 * Own versions from update backups. tools/update.sh saves an edited shipped
 * dashboard or test as a whole unit to `.fmlab/update-backup/<stamp>/units/<path>`
 * before it puts the shipped file back (an edited tracked file would block the
 * update). At the next start this service turns each unit into an own version
 * under Custom — `<id>-local` with the new id and a title suffix — once per
 * backup folder: `imported.json` marks a folder as done and lists the result.
 * A unit identical to what this release ships needs no own version. The backup
 * itself stays untouched.
 *
 * Units (paths as saved by update.sh):
 *   rest-api/templates/dashboards/<rel>/        bundle (manifest.json) → dashboards-custom/<id>-local/
 *   rest-api/templates/dashboards/<rel>.sql     single-file dashboard  → dashboards-custom/<id>-local.sql
 *   rest-api/templates/tests/<rel>/             test (test.json)       → tests-custom/<id>-local/
 *
 * Old places of shipped dashboards up to v0.9.16 (an update that deletes them
 * stops at an edited copy, update.sh saves it):
 *   rest-api/templates/dashboards-custom/<rel>/ bundle                 → dashboards-custom/<id>-local/
 *   rest-api/templates/sql-custom/<name>.sql    query, now single-file → dashboards-custom/<name>-local.sql
 * Their shipped version lives elsewhere now, so "identical" is decided by the
 * frozen index (`templates/frozen-legacy.json`, the blobs of that release);
 * without the index the unit is taken as edited — update.sh saved it as such.
 */

const BACKUP_DIR = 'update-backup';
const MARKER = 'imported.json';
const AREAS = [
  { kind: 'dashboards', prefix: 'rest-api/templates/dashboards/' },
  { kind: 'tests', prefix: 'rest-api/templates/tests/' },
  { kind: 'dashboards', prefix: 'rest-api/templates/dashboards-custom/', legacy: 'dashboards-custom' },
  { kind: 'dashboards', prefix: 'rest-api/templates/sql-custom/', legacy: 'sql-custom' },
];

const backupRoot = () => path.join(fmlabDir(), BACKUP_DIR);

function listBackups() {
  try {
    return fs.readdirSync(backupRoot(), { withFileTypes: true })
      .filter(e => e.isDirectory())
      .map(e => e.name)
      .sort();
  } catch {
    return [];
  }
}

function sameFile(a, b) {
  try {
    return fs.readFileSync(a).equals(fs.readFileSync(b));
  } catch {
    return false;
  }
}

/** Unit paths of one backup (update.json `units`; none without a readable update.json). */
function unitsOf(dir) {
  try {
    const units = JSON.parse(fs.readFileSync(path.join(dir, 'update.json'), 'utf-8')).units;
    if (Array.isArray(units)) return units.filter(u => typeof u === 'string');
  } catch {
    // no (readable) update.json
  }
  return [];
}

/** True when a saved old-place unit matches the frozen index file by file (logical path below templates/). */
function sameAsFrozen(src, isDir, logical, frozen) {
  if (!frozen) return false;
  const expected = [...frozen.keys()].filter(k => k === logical || k.startsWith(`${logical}/`));
  const present = isDir ? engine.listFiles(src).map(f => [`${logical}/${f}`, path.join(src, f)]) : [[logical, src]];
  return expected.length > 0 && present.length === expected.length
    && present.every(([k, abs]) => frozen.get(k) === dashboardCleanup.blobSha(abs));
}

/** Turns one saved unit into an own version. → { kind, unit, fork, fork_id } | { unit, skipped } */
function importUnit(dir, unit) {
  const area = AREAS.find(a => unit.startsWith(a.prefix));
  const rel = area && unit.slice(area.prefix.length);
  if (!area || !rel || rel.split('/').includes('..')) return { unit, skipped: 'not a dashboard or test' };
  const src = path.join(dir, 'units', unit);
  let isDir;
  try {
    isDir = fs.statSync(src).isDirectory();
  } catch {
    return { unit, skipped: 'missing in the backup' };
  }
  const t = environment.templates;
  if (area.kind === 'tests') {
    if (!isDir) return { unit, skipped: 'not a test folder' };
    if (engine.sameTree(src, path.join(t.testsDir, rel))) return { unit, skipped: 'identical to the shipped version' };
    const forkId = testCleanup.freeForkId(path.basename(rel), t.testsCustomDir);
    testCleanup.forkTest(src, path.join(t.testsCustomDir, forkId), forkId);
    return { kind: 'tests', unit, fork: `${testCleanup.CUSTOM}/${forkId}`, fork_id: forkId };
  }
  if (area.legacy) {
    if (!isDir && !rel.endsWith('.sql')) return { unit, skipped: 'not a dashboard or test' };
    const frozen = dashboardCleanup.readFrozenIndex(path.dirname(path.resolve(t.dashboardsDir)));
    if (sameAsFrozen(src, isDir, `${area.legacy}/${rel}`, frozen)) return { unit, skipped: 'identical to the shipped version' };
  } else {
    const shipped = path.join(t.dashboardsDir, rel);
    if (isDir ? engine.sameTree(src, shipped) : sameFile(src, shipped)) return { unit, skipped: 'identical to the shipped version' };
  }
  const id = isDir ? path.basename(rel) : path.basename(rel, '.sql');
  const forkId = dashboardCleanup.freeForkId(id, t.dashboardsCustomDir);
  const target = isDir ? forkId : `${forkId}.sql`;
  dashboardCleanup.forkUnit(src, path.join(t.dashboardsCustomDir, target), { case: isDir ? 'a2' : 'f1', fork_id: forkId });
  return { kind: 'dashboards', unit, fork: `${dashboardCleanup.CUSTOM}/${target}`, fork_id: forkId };
}

/**
 * Imports every backup folder not marked yet.
 * → [{ backup, forks: [...], skipped: [...] }] (only folders handled in this call)
 */
function importUpdateBackups({ now = new Date() } = {}) {
  const results = [];
  for (const stamp of listBackups()) {
    const dir = path.join(backupRoot(), stamp);
    if (fs.existsSync(path.join(dir, MARKER))) continue;
    const forks = [];
    const skipped = [];
    for (const unit of unitsOf(dir)) {
      try {
        const r = importUnit(dir, unit);
        if (r.skipped) skipped.push(r);
        else forks.push(r);
      } catch (err) {
        skipped.push({ unit, skipped: err.message });
      }
    }
    const record = { version: 1, imported_at: now.toISOString().replace(/\.\d{3}Z$/, 'Z'), forks, skipped };
    fs.writeFileSync(path.join(dir, MARKER), JSON.stringify(record, null, 2) + '\n', 'utf-8');
    results.push({ backup: `.fmlab/${BACKUP_DIR}/${stamp}`, forks, skipped });
  }
  return results;
}

/** Newest import that produced own versions of `kind`. → { stamp, backup, forks } | null */
function lastImport(kind) {
  for (const stamp of listBackups().reverse()) {
    let record;
    try {
      record = JSON.parse(fs.readFileSync(path.join(backupRoot(), stamp, MARKER), 'utf-8'));
    } catch {
      continue;
    }
    const forks = (record.forks || []).filter(f => f.kind === kind);
    if (forks.length) return { stamp, backup: `.fmlab/${BACKUP_DIR}/${stamp}`, forks };
  }
  return null;
}

module.exports = { importUpdateBackups, lastImport };
