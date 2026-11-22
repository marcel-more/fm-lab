'use strict';

/**
 * Wege des Ablauf-Trace (mode=flow) aus den Vorgänger-Zeigern des Templates
 * graph_trace.sql (>= 2.1.0). Rein funktional — keine Datenbank, deterministisch.
 *
 * - abwärts („Ruft auf“): ein Weg je erreichtem Script und je Aufrufschritt ohne
 *   statisches Ziel (DynamicCall). Pfad = Vorgängerkette vom Start bis zum Ziel,
 *   Aufruf- und Navigationsschritte sind Knoten. Die Wege bilden einen
 *   Aufrufbaum: parentWayId = Weg zum vorigen Script auf dem Pfad. Art (kind)
 *   = letzte Kante: call, cascade (Ereignis eines betretenen Layouts), trigger
 *   (Ereignis des Start-Layouts bei Layout-Starts) oder dynamic.
 * - aufwärts („Erreicht über“): ein Weg je Script des Aufwärts-Walks, das einen
 *   Einstieg hat — Button, Trigger, Menü, Datei-Trigger (Einstiegsgruppen mit
 *   Zählern), Wurzel (keine Aufrufer), Budget (Walk am up_depth gekappt) oder
 *   Ausschluss. Pfad = vom Einstiegs-Script über die Aufrufer bis zum Start.
 *
 * „Quelle verfolgen“ aufwärts: Für aufgeklappte Aufwärts-Wege
 * (expand_way) liefert das Template neue Knoten außerhalb des Aufwärts-Walks —
 * Scripts, die ein Owner-Layout des Einstiegs per Go to Layout betreten, bzw.
 * die Aufrufer eines am Budget gekappten Einstiegs, je mit Aufrufern bis
 * up_depth. Jeder neue Knoten mit Einstieg wird ein Weg unter dem
 * aufgeklappten (parentWayId); sein Abschnitt endet vor dem Einstiegs-Script
 * des Eltern-Wegs, der Eltern-Pfad folgt (pathSuffix). Die Kante Layout →
 * Einstiegs-Script trägt das Ereignis des neuen Wegs (`event`).
 *
 * Pfad-Abschnitte: pathNodes eines Wegs trägt nur den Pfad hinter `pathPrefix`
 * (Weg-ID, deren voller Pfad davor liegt; fehlt = voller Pfad). Abwärts ist
 * pathPrefix der Eltern-Weg — die Vorgängerkette ist ein Baum, der Pfad eines
 * Kinds ist der des Eltern-Wegs plus ein Abschnitt. So wächst die Nutzlast
 * linear mit der Wegezahl statt mit Wegezahl × Pfadlänge. Aufwärts gilt das
 * Gegenstück `pathSuffix`: der volle Pfad des genannten Wegs folgt hinter
 * pathNodes. Kanten stehen nicht
 * in der Antwort: im linearen Pfad folgen sie aus der Knotenfolge und den
 * Typen (Script → Schritt `step`, Schritt → Script `call`, Schritt → Layout
 * `navigate`, Layout → Script `event`, Script → Script `call` ohne Schritt-
 * Anker); das Ereignis einer Kaskade steht am Weg (`event`, `eventOwner`) —
 * es ist immer die letzte Kante des Wegs. expandWayPath() setzt den vollen
 * Pfad samt Kanten zusammen.
 *
 * Einstiegsgruppen (entryGroups) haben nur Aufwärts-Wege.
 *
 * Kennzeichen je Weg (flags, über den vollen Pfad): conditions = Zahl der
 * Kanten, deren Aufrufstellen alle bedingt sind (immer gesetzt, 0 = läuft
 * immer); loop / server / param = eine Aufrufstelle einer Kante in einer
 * Schleife / per PSoS / mit Parameter; crossFile = ein Schritt des Pfads
 * wechselt die Datei; unreachable = eine Kante hat nur Aufrufstellen hinter
 * Exit Script / Halt Script; cascade = der Pfad läuft über eine Trigger-
 * Kaskade (Ereignis eines betretenen Layouts). Boolesche Kennzeichen erscheinen nur, wenn
 * sie zutreffen. precision = schlechteste Kante (dynamic = DynamicCall, approx
 * = Aufruf ohne Schritt-Anker, sonst exact).
 */

const crypto = require('crypto');

const MAX_CHAIN = 64; // Gurt gegen fehlerhafte Vorgängerketten
const ENTRY_ORDER = ['button', 'trigger', 'menu', 'file', 'root', 'budget', 'excluded'];

/** `uuid::file` → file (null ohne Datei-Teil). */
function fileOf(id) {
  const i = id.indexOf('::');
  return i === -1 ? null : id.slice(i + 2);
}

/** Stabile Weg-ID (12 Hex wie im Datenfluss-Trace). */
function wayIdOf(dir, target) {
  return crypto.createHash('md5').update(`flow|${dir}|${target}`).digest('hex').slice(0, 12);
}

function stepNodeId(stepUuid, file) {
  return `${stepUuid}${file === null || file === undefined ? '' : `::${file}`}`;
}

/** Objekt ohne leere Felder (null, undefined, false); `keep` bleibt immer. */
function compact(obj, keep = []) {
  const out = {};
  for (const [k, v] of Object.entries(obj)) {
    if (keep.includes(k) || (v !== null && v !== undefined && v !== false)) out[k] = v;
  }
  return out;
}

/** Kontext einer Kante für die Schritt-Referenz — nur gesetzte Felder. */
function siteOf(hop) {
  return compact({
    guard: hop.guard ? compact(hop.guard) : null,
    conditions: hop.conditions || null,
    inLoop: hop.inLoop === true,
    passesParam: hop.passesParam ?? null,
    unreachable: hop.unreachable === true,
    sites: hop.n ?? 1,
    allConditional: hop.allConditional === true,
    anyLoop: hop.anyLoop === true,
    anyServer: hop.anyServer === true,
    anyParam: hop.anyParam === true,
    allUnreachable: hop.allUnreachable === true,
  });
}

function newFlags() {
  return {
    conditions: 0, loop: false, server: false, crossFile: false, param: false, unreachable: false, cascade: false,
  };
}

/** Kennzeichen einer Kante (hop) in die Weg-Kennzeichen falten. */
function foldHop(flags, hop) {
  if (hop.allConditional) flags.conditions += 1;
  if (hop.anyLoop) flags.loop = true;
  if (hop.anyServer) flags.server = true;
  if (hop.anyParam) flags.param = true;
  if (hop.allUnreachable) flags.unreachable = true;
}

const cmpStr = (a, b) => (a < b ? -1 : a > b ? 1 : 0);

/**
 * @param {Object} input
 * @param {string} input.startId    Knoten-ID des Starts
 * @param {Array}  input.preds      pred-Zeilen ({ id, label, type, file, dir, pred, kind, event, owner, crossFile, hop })
 * @param {Array}  input.blind      blinde Stellen ({ id, script, file, kind, stepUuid, stepIndex, stepId, stepName, … })
 * @param {Array}  input.entries    Einstiegsgruppen ({ script, kind, event, n, nLayouts, layouts, sample })
 * @param {Array}  input.upinfo     Aufwärts-Knoten ({ id, label, type, file, depth, nCallers, excluded })
 * @param {Map}    input.labels     id → { label, type, file } bekannter Knoten
 * @param {number} input.upDepth    Budget aufwärts
 * @param {number} input.waysLimit  Wege je Richtung
 * @param {Array}  [input.xpreds]   „Quelle verfolgen“: Vorgänger je Weg-ID ({ id, label, type, file, way, pred, kind, depth, layout, layoutLabel, event, crossFile, hop })
 * @param {Array}  [input.xupinfo]  „Quelle verfolgen“: neue Knoten ({ id, label, type, file, way, depth, nCallers, excluded })
 * @returns {{ ways: Array, overview: {up: Object, down: Object}, refs: Object,
 *             stats: { down: number, up: number, downTotal: number, upTotal: number } }}
 */
function buildFlowWays(input) {
  const { startId, preds, blind, entries, upinfo, labels, upDepth, waysLimit } = input;
  const xpreds = input.xpreds || [];
  const xupinfo = input.xupinfo || [];
  const stepRefs = new Map(); // Schritt-ID → Referenz (Beschriftung + Kontext)
  const known = new Map(labels);
  for (const x of [...preds, ...upinfo, ...xpreds, ...xupinfo]) {
    if (!known.has(x.id)) known.set(x.id, { label: x.label, type: x.type, file: x.file });
  }
  for (const x of xpreds) {
    if (x.layout && !known.has(x.layout)) {
      known.set(x.layout, { label: x.layoutLabel ?? null, type: 'Layout', file: fileOf(x.layout) });
    }
  }
  const labelOf = (id) => known.get(id)?.label ?? stepRefs.get(id)?.label ?? id;

  const down = new Map();
  const up = new Map();
  for (const p of preds) (p.dir === 'up' ? up : down).set(p.id, p);

  const addStep = (hop, scriptId) => {
    const id = stepNodeId(hop.stepUuid, fileOf(scriptId));
    if (!stepRefs.has(id)) {
      stepRefs.set(id, {
        label: `#${hop.stepIndex + 1} ${hop.stepName ?? ''}`.trim(),
        type: 'ScriptStep',
        stepIndex: hop.stepIndex,
        stepId: hop.stepId,
        scriptId,
        site: siteOf(hop),
      });
    }
    return id;
  };

  // ── abwärts ───────────────────────────────────────────────────────────────
  // Vorgängerkette bis zur Wurzel (Start bzw. Seed), von der Wurzel zum Knoten.
  const chainCache = new Map();
  const chainDown = (id) => {
    if (chainCache.has(id)) return chainCache.get(id);
    const links = [];
    const seen = new Set([id]);
    let cur = id;
    while (down.has(cur) && links.length < MAX_CHAIN) {
      const p = down.get(cur);
      links.push(p);
      if (seen.has(p.pred)) break; // Gurt: Zyklus
      seen.add(p.pred);
      cur = p.pred;
    }
    links.reverse();
    chainCache.set(id, links);
    return links;
  };

  /** Knoten einer Kettenstrecke; faltet Kennzeichen, Präzision und Ereignis. */
  const segmentOf = (links, acc) => {
    const nodes = [];
    for (const l of links) {
      if (l.crossFile) acc.flags.crossFile = true;
      if (l.kind === 'event') {
        nodes.push(l.id);
        acc.level += 1;
        // Ereignis des Start-Layouts (Layout-Start) ist der Einstieg, keine Kaskade
        if (l.pred !== startId) acc.flags.cascade = true;
        acc.event = { event: l.event, owner: l.owner || null };
      } else if (!l.hop) {
        // Aufruf ohne Schritt-Anker (MBS FM.RunScript): direkte Kante, approx
        nodes.push(l.id);
        acc.precision = 'approx';
        if (l.kind === 'call') acc.level += 1;
      } else {
        nodes.push(addStep(l.hop, l.pred), l.id);
        foldHop(acc.flags, l.hop);
        if (l.kind === 'call') acc.level += 1;
      }
    }
    return { nodes };
  };

  /** Script vor dem Ziel: Aufrufer bzw. — bei einer Kaskade — das navigierende Script. */
  const parentScriptOf = (links) => {
    if (links.length === 0) return null;
    const last = links[links.length - 1];
    if (last.kind !== 'event') return last.pred;
    const nav = links.length >= 2 ? links[links.length - 2] : null;
    return nav && nav.kind === 'navigate' ? nav.pred : null;
  };

  const downCand = [];
  for (const p of down.values()) {
    if (p.type !== 'Script' || p.id === startId) continue;
    const links = chainDown(p.id);
    if (links.length === 0) continue;
    const acc = { flags: newFlags(), precision: 'exact', level: 0 };
    segmentOf(links, acc); // Kennzeichen über den vollen Pfad
    const last = links[links.length - 1];
    const trigger = last.kind === 'event' && links.length >= 2 ? links[links.length - 2] : last;
    downCand.push({
      target: p.id,
      // Art = letzte Kante: Aufruf, Kaskade (Ereignis eines betretenen Layouts)
      // oder Trigger des Start-Layouts (Layout-Start)
      kind: last.kind !== 'event' ? 'call' : (last.pred === startId ? 'trigger' : 'cascade'),
      level: acc.level,
      flags: acc.flags,
      precision: acc.precision,
      links,
      parentScript: parentScriptOf(links),
      // Sortierschritt im Eltern-Script: Aufrufschritt bzw. der auslösende
      // Go to Layout-Schritt einer Kaskade (Layout-Start: Ereignis zuerst)
      sortStep: trigger.hop ? trigger.hop.stepIndex : (trigger.kind === 'event' ? -1 : Number.MAX_SAFE_INTEGER),
    });
  }
  // DynamicCall — am aufrufenden Script, das abwärts erreicht ist (oder der Start)
  for (const b of blind) {
    if (b.script !== startId && !down.has(b.script)) continue;
    const links = b.script === startId ? [] : chainDown(b.script);
    const acc = { flags: newFlags(), precision: 'dynamic', level: 0 };
    segmentOf(links, acc);
    acc.precision = 'dynamic';
    if (b.ifDepth > 0) acc.flags.conditions += 1;
    if (b.inLoop) acc.flags.loop = true;
    if (b.stepId === 164 || b.stepId === 210) acc.flags.server = true;
    if (b.passesParam != null) acc.flags.param = true;
    if (b.unreachable) acc.flags.unreachable = true;
    if (!stepRefs.has(b.id)) {
      stepRefs.set(b.id, {
        label: `#${b.stepIndex + 1} ${b.stepName ?? ''}`.trim(),
        type: 'DynamicCall',
        stepIndex: b.stepIndex,
        stepId: b.stepId,
        scriptId: b.script,
        stepUuid: b.stepUuid,
        blindKind: b.kind,
        name: b.name ?? null,
        site: siteOf({
          ...b, n: 1, allConditional: b.ifDepth > 0, anyLoop: b.inLoop,
          anyServer: b.stepId === 164 || b.stepId === 210, anyParam: b.passesParam != null,
          allUnreachable: b.unreachable,
        }),
      });
    }
    downCand.push({
      target: b.id,
      kind: 'dynamic',
      level: acc.level + 1,
      flags: acc.flags,
      precision: 'dynamic',
      links,
      blind: b,
      parentScript: b.script === startId ? null : b.script,
      sortStep: b.stepIndex,
    });
  }

  // Aufrufbaum in Breitensuche-Reihenfolge — Ebene, Platz des Eltern-Wegs,
  // Schritt im Eltern-Script, Beschriftung, ID (Tiebreak deterministisch).
  const byTarget = new Map(downCand.map((w) => [w.target, w]));
  const ordered = [];
  const rankOf = new Map();
  const levels = [...new Set(downCand.map((w) => w.level))].sort((a, b) => a - b);
  for (const lv of levels) {
    const row = downCand.filter((w) => w.level === lv);
    const pr = (w) => (w.parentScript && byTarget.has(w.parentScript)
      ? (rankOf.get(w.parentScript) ?? Number.MAX_SAFE_INTEGER) : -1);
    row.sort((a, b) => pr(a) - pr(b) || a.sortStep - b.sortStep
      || String(labelOf(a.target)).localeCompare(String(labelOf(b.target)))
      || cmpStr(a.target, b.target));
    for (const w of row) {
      rankOf.set(w.target, ordered.length);
      ordered.push(w);
    }
  }
  // Unterbaum-Zähler über alle Kandidaten (auch jenseits von ways_limit)
  const nDesc = new Map();
  for (let i = ordered.length - 1; i >= 0; i -= 1) {
    const w = ordered[i];
    if (w.parentScript && byTarget.has(w.parentScript)) {
      nDesc.set(w.parentScript, (nDesc.get(w.parentScript) ?? 0) + (nDesc.get(w.target) ?? 0) + 1);
    }
  }

  const ways = [];
  const downOut = ordered.slice(0, waysLimit);
  downOut.forEach((w, i) => {
    // Gurt: der Eltern-Weg muss ein echtes Präfix sein (kein Selbstbezug)
    const hasParent = w.parentScript !== null && w.parentScript !== w.target && byTarget.has(w.parentScript)
      && chainDown(w.parentScript).length < w.links.length;
    // Abschnitt hinter dem Eltern-Weg (dessen Pfad ist ein Präfix dieses Pfads)
    const prefixLen = hasParent ? chainDown(w.parentScript).length : 0;
    const acc = { flags: newFlags(), precision: 'exact', level: 0 };
    const seg = segmentOf(w.links.slice(prefixLen), acc);
    if (!hasParent) seg.nodes.unshift(w.links.length > 0 ? w.links[0].pred : w.blind.script);
    if (w.blind) seg.nodes.push(w.blind.id);
    const parentWayId = hasParent ? wayIdOf('down', w.parentScript) : null;
    const endsInEvent = w.links.length > 0 && w.links[w.links.length - 1].kind === 'event';
    const tail = endsInEvent && acc.event ? { event: acc.event.event, eventOwner: acc.event.owner } : {};
    ways.push({
      wayNo: i + 1,
      wayId: wayIdOf('down', w.target),
      dir: 'down',
      kind: w.kind,
      level: w.level,
      target: w.target,
      parentWayId,
      nDesc: nDesc.get(w.target) ?? 0,
      precision: w.precision,
      flags: compact(w.flags, ['conditions']),
      ...tail,
      ...(parentWayId ? { pathPrefix: parentWayId } : {}),
      pathNodes: seg.nodes,
    });
  });

  // ── aufwärts ──────────────────────────────────────────────────────────────
  const entriesOf = new Map();
  for (const e of entries) {
    if (!entriesOf.has(e.script)) entriesOf.set(e.script, []);
    entriesOf.get(e.script).push(e);
    for (const s of e.sample || []) {
      if (!known.has(s.id)) known.set(s.id, { label: s.label ?? null, type: s.type, file: fileOf(s.id) });
    }
  }
  /** Einstiegsgruppen eines Aufwärts-Knotens (Owner-Einstiege plus Endpunkt des Walks). */
  const groupsOf = (u) => {
    const groups = (entriesOf.get(u.id) || []).map((e) => ({
      kind: e.kind, event: e.event ?? null, n: e.n, nLayouts: e.nLayouts ?? 0,
      layouts: e.layouts || [], sample: (e.sample || []).map((s) => s.id),
    }));
    if (u.nCallers === 0) {
      groups.push({ kind: 'root', event: null, n: 1, nLayouts: 0, layouts: [], sample: [] });
    } else if (u.excluded && u.id !== startId) {
      groups.push({ kind: 'excluded', event: null, n: u.nCallers, nLayouts: 0, layouts: [], sample: [] });
    } else if (u.depth >= upDepth) {
      groups.push({ kind: 'budget', event: null, n: u.nCallers, nLayouts: 0, layouts: [], sample: [] });
    }
    groups.sort((a, b) => ENTRY_ORDER.indexOf(a.kind) - ENTRY_ORDER.indexOf(b.kind)
      || cmpStr(String(a.event ?? ''), String(b.event ?? '')));
    return groups;
  };

  const upCand = [];
  for (const u of upinfo) {
    const groups = groupsOf(u);
    if (groups.length === 0) continue;

    // Pfad: Einstiegs-Script → Schritt → … → Start (wenige Wege, voller Pfad)
    const nodes = [u.id];
    const flags = newFlags();
    let precision = 'exact';
    const seen = new Set([u.id]);
    let cur = u.id;
    let hops = 0;
    while (up.has(cur) && hops < MAX_CHAIN) {
      hops += 1;
      const l = up.get(cur);
      if (l.crossFile) flags.crossFile = true;
      if (l.hop) {
        nodes.push(addStep(l.hop, cur), l.pred);
        foldHop(flags, l.hop);
      } else {
        nodes.push(l.pred);
        precision = 'approx';
      }
      if (seen.has(l.pred)) break;
      seen.add(l.pred);
      cur = l.pred;
    }
    upCand.push({
      target: u.id,
      level: u.depth,
      nEntries: groups.reduce((n, g) => n + (g.n || 0), 0),
      groups, nodes, flags, precision,
    });
  }
  upCand.sort((a, b) => a.level - b.level
    || String(labelOf(a.target)).localeCompare(String(labelOf(b.target)))
    || cmpStr(a.target, b.target));
  const upOut = upCand.slice(0, waysLimit);
  upOut.forEach((w, i) => {
    ways.push({
      wayNo: i + 1,
      wayId: wayIdOf('up', w.target),
      dir: 'up',
      kind: 'entry',
      level: w.level,
      target: w.target,
      parentWayId: null,
      nDesc: 0,
      precision: w.precision,
      flags: compact(w.flags, ['conditions']),
      nEntries: w.nEntries,
      entryGroups: w.groups,
      pathNodes: w.nodes,
    });
  });

  // ── „Quelle verfolgen“ aufwärts ───────────────────────────────────────────
  const xByWay = new Map(); // Weg-ID → (Knoten-ID → Vorgänger)
  for (const x of xpreds) {
    if (!xByWay.has(x.way)) xByWay.set(x.way, new Map());
    xByWay.get(x.way).set(x.id, x);
  }
  const upById = new Map(ways.filter((w) => w.dir === 'up').map((w) => [w.wayId, w]));
  const xCand = [];
  for (const u of xupinfo) {
    const parent = upById.get(u.way);
    if (!parent) continue; // aufgeklappter Weg nicht in der Liste (ways_limit)
    const groups = groupsOf(u);
    if (groups.length === 0) continue;
    const xp = xByWay.get(u.way) || new Map();
    // Abschnitt: neuer Einstieg → … bis vor das Einstiegs-Script des Eltern-Wegs
    const nodes = [u.id];
    const flags = newFlags();
    let precision = 'exact';
    let event = null;
    const seen = new Set([u.id]);
    let cur = u.id;
    let hops = 0;
    while (xp.has(cur) && hops < MAX_CHAIN) {
      hops += 1;
      const l = xp.get(cur);
      if (l.crossFile) flags.crossFile = true;
      if (l.hop) {
        nodes.push(addStep(l.hop, cur));
        foldHop(flags, l.hop);
      } else {
        precision = 'approx';
      }
      if (l.kind === 'enter') {
        // Go to Layout auf ein Owner-Layout — das Ereignis führt zum Eltern-Einstieg
        nodes.push(l.layout);
        event = l.event ?? null;
        break;
      }
      if (l.pred === parent.target || seen.has(l.pred)) break;
      seen.add(l.pred);
      nodes.push(l.pred);
      cur = l.pred;
    }
    // Kennzeichen über den vollen Pfad: Abschnitt plus Eltern-Weg
    const pf = parent.flags || {};
    flags.conditions += pf.conditions ?? 0;
    for (const k of ['loop', 'server', 'crossFile', 'param', 'unreachable', 'cascade']) if (pf[k]) flags[k] = true;
    const rank = { exact: 0, approx: 1, dynamic: 2 };
    if ((rank[parent.precision] ?? 0) > (rank[precision] ?? 0)) precision = parent.precision;
    xCand.push({
      target: u.id,
      parent,
      level: parent.level + u.depth,
      nEntries: groups.reduce((n, g) => n + (g.n || 0), 0),
      groups, nodes, flags, precision, event,
    });
  }
  xCand.sort((a, b) => a.parent.wayNo - b.parent.wayNo || a.level - b.level
    || String(labelOf(a.target)).localeCompare(String(labelOf(b.target)))
    || cmpStr(a.target, b.target));
  const xOut = xCand.slice(0, waysLimit);
  xOut.forEach((w, i) => {
    w.parent.nDesc += 1;
    ways.push({
      wayNo: upOut.length + i + 1,
      wayId: wayIdOf('up', w.target),
      dir: 'up',
      kind: 'entry',
      level: w.level,
      target: w.target,
      parentWayId: w.parent.wayId,
      nDesc: 0,
      precision: w.precision,
      flags: compact(w.flags, ['conditions']),
      ...(w.event ? { event: w.event } : {}),
      nEntries: w.nEntries,
      entryGroups: w.groups,
      pathSuffix: w.parent.wayId,
      pathNodes: w.nodes,
    });
  });

  // ── Weg 0 (Kopfzahlen; der Baum selbst steht in parentWayId) ───────────────
  const count = (list, key) => list.reduce((o, x) => {
    const k = key(x);
    o[k] = (o[k] ?? 0) + 1;
    return o;
  }, {});
  const downWays = ways.filter((w) => w.dir === 'down');
  const upWays = ways.filter((w) => w.dir === 'up');
  const overview = {
    down: {
      start: startId,
      byLevel: count(downWays, (w) => w.level),
      byKind: count(downWays, (w) => w.kind),
    },
    up: {
      start: startId,
      byLevel: count(upWays, (w) => w.level),
      byEntry: upWays.reduce((o, w) => {
        for (const g of w.entryGroups || []) o[g.kind] = (o[g.kind] ?? 0) + g.n;
        return o;
      }, {}),
    },
  };

  // ── Referenzen: jeder Knoten, den die Wege nennen ──────────────────────────
  const want = new Map(); // id → flowRole (null = aus dem Typ)
  for (const w of ways) {
    for (const id of w.pathNodes) if (!want.has(id)) want.set(id, null);
    if (w.eventOwner && !want.has(w.eventOwner)) want.set(w.eventOwner, 'entry');
    for (const g of w.entryGroups || []) for (const s of g.sample) want.set(s, 'entry');
  }
  const roleOf = (id, type) => {
    if (id === startId) return 'start';
    if (type === 'Script') return 'script';
    if (type === 'Layout') return 'layout';
    return 'entry';
  };
  const refs = {};
  for (const [id, role] of want) {
    if (stepRefs.has(id)) refs[id] = stepRefs.get(id);
    else if (known.has(id)) {
      const k = known.get(id);
      refs[id] = { label: k.label ?? null, type: k.type ?? null, file: k.file ?? null,
        flowRole: role ?? roleOf(id, k.type) };
    }
  }

  return {
    ways,
    overview,
    refs,
    stats: {
      down: downOut.length,
      up: upOut.length + xOut.length,
      downTotal: ordered.length,
      upTotal: upCand.length + xCand.length,
    },
  };
}

/**
 * Voller Pfad eines Wegs: Abschnitte entlang pathPrefix zusammengesetzt, die
 * Kanten aus Knotenfolge und Typen abgeleitet (siehe Modulkopf).
 * @param {Array} ways  trace.ways (beide Richtungen)
 * @param {Object} way  der Weg
 * @param {(id: string) => ?string} typeOf  Objekttyp je Knoten-ID (Canvas-Knoten und trace.refs)
 * @returns {{ pathNodes: string[], pathEdges: Object[] }}
 */
function expandWayPath(ways, way, typeOf) {
  const byId = new Map(ways.filter((w) => w.dir === way.dir).map((w) => [w.wayId, w]));
  const seen = new Set([way.wayId]);
  // abwärts: Eltern-Wege davor (pathPrefix) · aufwärts: Eltern-Wege dahinter (pathSuffix)
  const before = [];
  let p = way.pathPrefix ? byId.get(way.pathPrefix) : null;
  while (p && !seen.has(p.wayId)) {
    seen.add(p.wayId);
    before.unshift(p);
    p = p.pathPrefix ? byId.get(p.pathPrefix) : null;
  }
  const after = [];
  let q = way.pathSuffix ? byId.get(way.pathSuffix) : null;
  while (q && !seen.has(q.wayId)) {
    seen.add(q.wayId);
    after.push(q);
    q = q.pathSuffix ? byId.get(q.pathSuffix) : null;
  }
  const chain = [...before, way, ...after];
  const pathNodes = [];
  const ownerAt = []; // Weg, dessen Abschnitt den Knoten trägt
  for (const w of chain) {
    for (const id of w.pathNodes) {
      pathNodes.push(id);
      ownerAt.push(w);
    }
  }
  const isStep = (t) => t === 'ScriptStep' || t === 'DynamicCall';
  const pathEdges = [];
  for (let i = 1; i < pathNodes.length; i += 1) {
    const source = pathNodes[i - 1];
    const target = pathNodes[i];
    const ts = typeOf(source);
    const tt = typeOf(target);
    let edge;
    if (isStep(tt)) edge = { source, target, kind: 'step' };
    else if (isStep(ts)) edge = { source, target, kind: tt === 'Layout' ? 'navigate' : 'call' };
    else if (ts === 'Layout') {
      // Ereignis: am Weg, dessen Abschnitt das Layout trägt (aufwärts der neue
      // Weg vor seinem Eltern-Einstieg), sonst am Weg, dessen Ziel die Kante
      // abschließt (abwärts die Kaskade)
      const own = ownerAt[i - 1];
      const owner = own && own.event ? own : chain.find((w) => w.target === target && w.event);
      edge = compact({ source, target, kind: 'event', event: owner?.event ?? null, owner: owner?.eventOwner ?? null });
    } else edge = { source, target, kind: 'call', precision: 'approx' };
    pathEdges.push(edge);
  }
  return { pathNodes, pathEdges };
}

module.exports = { buildFlowWays, expandWayPath, wayIdOf };
