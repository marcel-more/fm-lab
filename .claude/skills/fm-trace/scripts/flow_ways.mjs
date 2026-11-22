#!/usr/bin/env node
/**
 * flow_ways.mjs — terminal view of the ways of a flow trace (mode=flow) for fm-trace.
 *
 * Reads `GET /api/graph/trace` once and prints the ways of both directions as
 * Markdown tables: "reached from" (up — one way per entry script with its entry
 * groups; first, like the Explorer's default tab) and "calls" (down — one way per
 * reached script, call tree in breadth-first order). With --way the script prints the Mermaid source of ONE way
 * instead (`format=mermaid-raw&way=n&way_dir=…`, 0 = overview).
 *
 * The REST API is required: the ways are built by the service, not by SQL.
 *
 * Usage:
 *   node flow_ways.mjs --start=<uuid> [--file=<File_Name>] [--solution=<id>]
 *        [--api=<base url>] [--ways=down|up|both] [--limit=15]
 *        [--way=<n> [--way-dir=up|down]] [--include-disabled] [--expand=<wayId>[,…]]
 *        [--entry=<preset>] [--up-depth=<n>] [--down-depth=<n>] [--trigger-depth=<n>]
 *        [--vars] [--buttons] [--interaction-triggers] [--expand-up] [--exclude=<id>[,…]]
 *
 *   --limit   rows per direction (default 15, 0 = all ways of the response)
 *   --expand  "follow source" on up-ways (wayId from the up table, max. 20)
 *
 * Exit codes: 0 ok · 2 usage · 3 API unreachable · 4 catalog too old / data-flow
 * block missing (SCHEMA_DRIFT, DATAFLOW_NOT_BUILT) · 5 other API error (e.g. unknown way).
 */

const args = parseArgs(process.argv.slice(2));
if (!args.start) usage('missing --start=<uuid>');

const dirs = args.ways === 'up' ? ['up'] : args.ways === 'down' ? ['down'] : ['up', 'down'];
if (args.ways && !['up', 'down', 'both'].includes(args.ways)) usage('--ways must be down, up or both');
const limit = args.limit === undefined ? 15 : Number(args.limit);
if (!Number.isInteger(limit) || limit < 0) usage('--limit must be an integer >= 0');

const base = await resolveApi(args.api);
const query = buildQuery(args);

if (args.way !== undefined) {
  const wayNo = Number(args.way);
  if (!Number.isInteger(wayNo) || wayNo < 0) usage('--way must be an integer >= 0');
  const wayDir = args['way-dir'] === 'up' ? 'up' : 'down';
  query.set('format', 'mermaid-raw');
  query.set('way', String(wayNo));
  query.set('way_dir', wayDir);
  const text = await call(base, query, 'text');
  process.stdout.write('```mermaid\n' + text.replace(/\s+$/, '') + '\n```\n');
  process.exit(0);
}

const data = await call(base, query, 'json');
process.stdout.write(render(data, dirs, limit));

// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const out = {};
  for (const a of argv) {
    const m = /^--([a-z-]+)(?:=(.*))?$/.exec(a);
    if (!m) usage(`unknown argument ${a}`);
    out[m[1]] = m[2] === undefined ? true : m[2];
  }
  return out;
}

function usage(msg) {
  process.stderr.write(`flow_ways: ${msg}\nsee the header of flow_ways.mjs for the usage\n`);
  process.exit(2);
}

async function resolveApi(given) {
  const candidates = given ? [given] : [process.env.FMLAB_API_URL, 'http://localhost:3003', 'http://api:3003'].filter(Boolean);
  for (const c of candidates) {
    const b = c.replace(/\/+$/, '');
    try {
      const r = await fetch(`${b}/api/version`, { signal: AbortSignal.timeout(2000) });
      if (r.ok) return b;
    } catch { /* next candidate */ }
  }
  process.stderr.write(`flow_ways: REST API not reachable (tried ${candidates.join(', ')})\n`);
  process.exit(3);
}

function buildQuery(a) {
  const q = new URLSearchParams({ start: a.start, mode: 'flow' });
  const map = {
    file: 'start_file', entry: 'entry', 'up-depth': 'up_depth', 'down-depth': 'down_depth',
    'trigger-depth': 'trigger_depth', exclude: 'exclude', expand: 'expand_way',
  };
  for (const [k, p] of Object.entries(map)) if (typeof a[k] === 'string' && a[k] !== '') q.set(p, a[k]);
  const toggles = {
    'include-disabled': 'include_disabled', vars: 'include_local_vars', buttons: 'include_buttons',
    'interaction-triggers': 'include_interaction_triggers', 'expand-up': 'expand_up',
  };
  for (const [k, p] of Object.entries(toggles)) if (a[k]) q.set(p, 'true');
  if (q.has('expand_way')) q.set('expand_way', q.get('expand_way').toLowerCase());
  return q;
}

async function call(b, q, kind) {
  const headers = args.solution ? { 'X-Solution': String(args.solution) } : {};
  let r;
  try {
    r = await fetch(`${b}/api/graph/trace?${q}`, { headers, signal: AbortSignal.timeout(60000) });
  } catch (e) {
    process.stderr.write(`flow_ways: request failed: ${e.message}\n`);
    process.exit(3);
  }
  if (r.ok) return kind === 'text' ? r.text() : (await r.json()).data;
  let err = {};
  try { err = (await r.json()).error ?? {}; } catch { /* non-JSON error body */ }
  process.stderr.write(`flow_ways: HTTP ${r.status} ${err.code ?? ''} ${err.message ?? ''}\n`);
  process.exit(['SCHEMA_DRIFT', 'DATAFLOW_NOT_BUILT'].includes(err.code) ? 4 : 5);
}

// --- rendering -------------------------------------------------------------

function render(d, wantDirs, max) {
  const tr = d.trace ?? {};
  const refs = tr.refs ?? {};
  const nodes = new Map((d.nodes ?? []).map((n) => [n.id, n]));
  const label = (id) => nodes.get(id)?.label ?? refs[id]?.label ?? String(id).slice(0, 8);
  const startFile = tr.start?.file;
  // scripts of the same name live in several files (clones, interface files)
  const named = (id) => {
    const file = String(id).split('::')[1];
    return file && startFile && file !== startFile ? `${label(id)} [${file}]` : label(id);
  };
  const isStep = (id) => ['ScriptStep', 'DynamicCall'].includes(refs[id]?.type);
  const ways = tr.ways ?? [];
  const byId = new Map(ways.map((w) => [w.wayId, w]));
  const st = tr.stats ?? {};
  const out = [];

  const start = tr.start ? `${tr.start.uuid}::${tr.start.file}` : d.start;
  out.push(`Flow trace of ${tr.start?.type ?? 'object'} "${label(start)}" · calls ${st.ways?.down ?? 0}` +
    `${st.waysTotal?.down > st.ways?.down ? ` of ${st.waysTotal.down}` : ''} ways · reached from ${st.ways?.up ?? 0}` +
    `${st.waysTotal?.up > st.ways?.up ? ` of ${st.waysTotal.up}` : ''} ways · conditional calls ${st.conditionalCalls ?? 0}` +
    ` · disabled steps ${d.params?.includeDisabled ? 'followed' : 'skipped'} ${st.disabledSteps ?? 0}` +
    ` · dynamic calls ${st.dynamicCalls ?? 0}` +
    (st.truncatedBy?.length ? ` · truncated by ${st.truncatedBy.join(', ')}` : ''));

  if (wantDirs.includes('up')) {
    const up = ways.filter((w) => w.dir === 'up');
    // child ways ("follow source") directly below their parent
    const roots = up.filter((w) => !w.parentWayId || !byId.has(w.parentWayId));
    const kids = (id) => up.filter((w) => w.parentWayId === id);
    const ordered = [];
    const visit = (w, depth) => { ordered.push([w, depth]); for (const k of kids(w.wayId)) visit(k, depth + 1); };
    for (const r of roots) visit(r, 0);
    out.push('', `### Reached from (up) — ${up.length} ways`, '');
    out.push('| # | Lvl | Entry script | Entries | Flags | Path to start | Way-ID |', '|---:|---:|---|---|---|---|---|');
    for (const [w, depth] of cut(ordered, max)) {
      const path = w.pathNodes.filter((id) => !isStep(id)).map(label);
      if (w.parentWayId) path.push(`${eventText(w.event)} → way ${byId.get(w.parentWayId)?.wayNo ?? '?'}`);
      out.push(row([`${'↳'.repeat(depth)}${w.wayNo}`, w.level, named(w.target), entryText(w.entryGroups),
        flagText(w), trimLeft(path.join(' → '), 70), `\`${w.wayId}\``]));
    }
    if (ordered.length > shown(ordered, max)) out.push(`| … | | ${ordered.length - shown(ordered, max)} more ways | | | | |`);
  }

  if (wantDirs.includes('down')) {
    const down = ways.filter((w) => w.dir === 'down');
    out.push('', `### Calls (down) — ${down.length} ways`, '');
    out.push('| # | Lvl | Target | Kind | Called at | Flags | Chain |', '|---:|---:|---|---|---|---|---|');
    for (const w of cut(down, max)) {
      const via = [...w.pathNodes].reverse().find(isStep);
      out.push(row([w.wayNo, w.level, named(w.target), kindText(w, label), siteText(via, refs, label),
        flagText(w), chainDown(w, byId, label)]));
    }
    if (down.length > shown(down, max)) out.push(`| … | | ${down.length - shown(down, max)} more ways | | | | |`);
  }
  out.push('');
  return out.join('\n');
}

function cut(list, max) { return max === 0 ? list : list.slice(0, max); }
function shown(list, max) { return max === 0 ? list.length : Math.min(list.length, max); }

function row(cells) {
  return '| ' + cells.map((c) => String(c ?? '').replace(/\|/g, '\\|').replace(/\s+/g, ' ')).join(' | ') + ' |';
}

function trimLeft(s, n) { return s.length <= n ? s : '…' + s.slice(s.length - n + 1); }
function trimRight(s, n) { return s.length <= n ? s : s.slice(0, n - 1) + '…'; }

function eventText(e) {
  if (e === 'button_action') return 'Button';
  if (e === 'menu_action') return 'Menu';
  return e ?? 'enter';
}

function kindText(w, label) {
  if (w.kind === 'cascade') return `cascade ${w.event ?? ''} @ ${label(w.eventOwner)}`;
  if (w.kind === 'trigger') return `trigger ${eventText(w.event)}${w.eventOwner ? ` · ${label(w.eventOwner)}` : ''}`;
  return w.kind;
}

function guardText(g) {
  if (!g) return '';
  if (g.kind === 'else') return 'Else';
  const head = g.kind === 'elseif' ? 'Else If' : 'If';
  return g.text ? `${head} ${trimRight(g.text, 40)}` : head;
}

function siteText(id, refs, label) {
  if (!id) return '';
  const r = refs[id] ?? {};
  const s = r.site ?? {};
  const parts = [label(id)];
  if (s.guard) parts.push(guardText(s.guard));
  if (r.type === 'DynamicCall') parts.push(r.name ? `by name ${trimRight(r.name, 30)}` : 'target unresolved');
  if (s.sites > 1) parts.push(`×${s.sites}`);
  return parts.join(' · ');
}

function flagText(w) {
  const f = w.flags ?? {};
  const out = [f.conditions ? `${f.conditions} cond` : f.unreachable ? '' : 'always'];
  if (f.loop) out.push('↻');
  if (f.server) out.push('server');
  if (f.crossFile) out.push('file↗');
  if (f.param) out.push('param');
  if (f.cascade && w.kind !== 'cascade') out.push('via cascade');
  if (f.unreachable) out.push('unreachable');
  if (w.precision && w.precision !== 'exact') out.push(w.precision);
  return out.filter(Boolean).join(' ');
}

function chainDown(w, byId, label) {
  const names = [];
  for (let p = byId.get(w.parentWayId); p; p = byId.get(p.parentWayId)) names.unshift(label(p.target));
  return names.length ? trimLeft(names.join(' → '), 60) : '';
}

function entryText(groups = []) {
  return groups.map((g) => {
    switch (g.kind) {
      case 'button': return `button ×${g.n}${layoutsText(g)}`;
      case 'trigger': return `trigger ${g.event ?? ''} ×${g.n}${layoutsText(g)}`;
      case 'menu': return `menu ×${g.n}`;
      case 'file': return `file ${g.event ?? ''}`;
      case 'root': return 'no caller';
      case 'budget': return `${g.n} caller${g.n === 1 ? '' : 's'} beyond up_depth`;
      case 'excluded': return 'excluded';
      default: return `${g.kind} ×${g.n}`;
    }
  }).join('; ');
}

function layoutsText(g) {
  if (!g.nLayouts) return '';
  const names = (g.layouts ?? []).slice(0, 2).map((l) => l.name);
  return ` (${names.join(', ')}${g.nLayouts > names.length ? ` +${g.nLayouts - names.length}` : ''})`;
}
