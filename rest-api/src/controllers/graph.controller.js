const graphService = require('../services/graph.service');
const { sendFormatted } = require('../utils/response-builder');
const { createError } = require('../middleware/error-handler');

/**
 * Graph Controller (P2 — Subgraph-Backend)
 *
 * Core-Endpoints:
 *   GET /api/graph/subgraph   — fokus-zentrierter k-Hop-Subgraph
 *   GET /api/graph/neighbors  — 1-Hop-Expansion (Lazy-Expand)
 *   GET /api/graph/search     — Fokus-Autocomplete über ObjectCatalog
 */

/**
 * Fokus-Auflösung mit Clone-Disambiguierung. Wirft 404 (unbekannt) bzw. 409
 * (mehrdeutig ohne focus_file) — sonst stiller Treffer auf den falschen Klon.
 */
async function assertFocusResolvable(ctx, focus, focusFile) {
  const status = await graphService.objectFocusStatus(ctx, focus, focusFile);
  if (!status.exists) {
    throw createError('OBJECT_NOT_FOUND', `Focus object '${focus}' not found in ObjectCatalog`, { focus });
  }
  if (status.ambiguous) {
    throw createError(
      'AMBIGUOUS_UUID',
      `Focus UUID '${focus}' exists in ${status.files.length} files (cloned/modular solution); ` +
        `add &focus_file=<File_Name> to disambiguate`,
      { focus, matched_files: status.files }
    );
  }
}

/** GET /api/graph/subgraph */
async function getSubgraph(req, res, next) {
  try {
    const { format, meta, debug } = req.query;

    await assertFocusResolvable(req.solutionContext, req.query.focus, req.query.focus_file);

    const { payload, sql } = await graphService.getSubgraph(req.solutionContext, req.query);
    const metaInfo = meta
      ? { focus: payload.focus, ...payload.stats, truncated: payload.truncated }
      : null;
    return sendFormatted(res, payload, format, metaInfo, debug ? sql : null);
  } catch (error) {
    next(error);
  }
}

/** GET /api/graph/neighbors — 1-Hop um einen bestehenden Knoten */
async function getNeighbors(req, res, next) {
  try {
    const { format, meta, debug } = req.query;

    await assertFocusResolvable(req.solutionContext, req.query.focus, req.query.focus_file);

    const { payload, sql } = await graphService.getNeighbors(req.solutionContext, req.query);
    const metaInfo = meta
      ? { focus: payload.focus, ...payload.stats, truncated: payload.truncated }
      : null;
    return sendFormatted(res, payload, format, metaInfo, debug ? sql : null);
  } catch (error) {
    next(error);
  }
}

/**
 * GET /api/graph/trace — selektiver Ablauf-Graph.
 * Fehlerpfade: 404/409 wie Subgraph (assertFocusResolvable auf start/start_file),
 * 422 TRACE_UNSUPPORTED_START (v1 kennt nur Script + Layout), 422 TRACE_EMPTY_ENTRY
 * (gewähltes Preset ohne Seeds — details tragen die Preset-Liste mit Zählern).
 */
async function getTrace(req, res, next) {
  try {
    const { format, meta, debug } = req.query;

    await assertFocusResolvable(req.solutionContext, req.query.start, req.query.start_file);

    const startType = await graphService.objectTypeOf(
      req.solutionContext, req.query.start, req.query.start_file
    );
    if (startType !== 'Script' && startType !== 'Layout') {
      throw createError(
        'TRACE_UNSUPPORTED_START',
        `Trace v1 supports Script and Layout starts; '${req.query.start}' is a ${startType}`,
        { start: req.query.start, type: startType, supported: ['Script', 'Layout'] }
      );
    }

    const { payload, sql } = await graphService.getTrace(
      req.solutionContext, req.query, startType
    );
    if (payload.trace.seeds.length === 0) {
      // Leeres Preset ehrlich ablehnen statt einen leeren Graph zu rendern;
      // die verfügbaren Presets (mit Zählern) wandern in den Fehler-Payload.
      const { payload: entriesPayload } = await graphService.getTraceEntries(
        req.solutionContext, { start: req.query.start, start_file: req.query.start_file }
      );
      throw createError(
        'TRACE_EMPTY_ENTRY',
        `Entry preset '${payload.trace.entry}' yields no seed scripts for this start object`,
        { start: req.query.start, entry: payload.trace.entry, entries: entriesPayload.entries }
      );
    }

    const metaInfo = meta
      ? { start: payload.start, entry: payload.trace.entry, ...payload.stats, truncated: payload.truncated }
      : null;
    return sendFormatted(res, payload, format, metaInfo, debug ? sql : null);
  } catch (error) {
    next(error);
  }
}

/** GET /api/graph/trace/entries — Einstiegspfad-Presets mit Seed-Zählern */
async function getTraceEntries(req, res, next) {
  try {
    const { format, meta, debug } = req.query;

    await assertFocusResolvable(req.solutionContext, req.query.start, req.query.start_file);

    const { payload, sql } = await graphService.getTraceEntries(req.solutionContext, req.query);
    if (payload.entries.length === 0) {
      const startType = await graphService.objectTypeOf(
        req.solutionContext, req.query.start, req.query.start_file
      );
      throw createError(
        'TRACE_UNSUPPORTED_START',
        `Trace v1 supports Script and Layout starts; '${req.query.start}' is a ${startType}`,
        { start: req.query.start, type: startType, supported: ['Script', 'Layout'] }
      );
    }
    const metaInfo = meta ? { start: payload.start, count: payload.entries.length } : null;
    return sendFormatted(res, payload, format, metaInfo, debug ? sql : null);
  } catch (error) {
    next(error);
  }
}

/** GET /api/graph/overview — Graph-Atlas Top-Down-Einstieg (Treemap + Meta-Graph) */
async function getOverview(req, res, next) {
  try {
    const { format, meta, debug } = req.query;
    const { payload, sql } = await graphService.getOverview(req.solutionContext, req.query, req.debug);
    const metaInfo = meta
      ? { view: payload.view, segment_by: payload.segment_by, level: payload.level ?? null,
          truncated: payload.truncated ?? null }
      : null;
    return sendFormatted(res, payload, format, metaInfo, debug ? sql : null);
  } catch (error) {
    next(error);
  }
}

/** GET /api/graph/community-stats — Community-Namen-Status + Cluster-Verfügbarkeit (Atlas-Statusleiste / Failover) */
async function getCommunityStats(req, res, next) {
  try {
    const { format } = req.query;
    const payload = await graphService.getCommunityStats(req.solutionContext);
    return sendFormatted(res, payload, format, null, null);
  } catch (error) {
    next(error);
  }
}

/** GET /api/graph/communities — vollständige Community-Liste der aktiven Engine */
async function getCommunities(req, res, next) {
  try {
    const { format } = req.query;
    const payload = await graphService.getCommunities(req.solutionContext);
    return sendFormatted(res, payload, format, null, null);
  } catch (error) {
    next(error);
  }
}

/** GET /api/graph/depth-profile — max. erreichbare Tiefe (Exzentrizität) + per-Tiefe-Count */
async function getDepthProfile(req, res, next) {
  try {
    const { format, meta, debug } = req.query;
    await assertFocusResolvable(req.solutionContext, req.query.focus, req.query.focus_file);
    const { payload, sql } = await graphService.getDepthProfile(req.solutionContext, req.query);
    const metaInfo = meta
      ? { focus: payload.focus, direction: payload.direction, maxDepth: payload.maxDepth, hitCap: payload.hitCap }
      : null;
    return sendFormatted(res, payload, format, metaInfo, debug ? sql : null);
  } catch (error) {
    next(error);
  }
}

/** GET /api/graph/search — Fokus-Autocomplete */
async function search(req, res, next) {
  try {
    const { format, meta, debug } = req.query;
    const { payload, sql } = await graphService.search(req.solutionContext, req.query);
    const metaInfo = meta ? { query: payload.query, count: payload.count } : null;
    return sendFormatted(res, payload, format, metaInfo, debug ? sql : null);
  } catch (error) {
    next(error);
  }
}

/**
 * POST /api/graph/recluster — der Rebuild-Button. Spawnt cluster.sh
 * (Roh-Repartition + Sync + Reload → Namens-Restore) und streamt SSE: start · log
 * (cluster.sh-stdout, inkl. „cache: restored …/node-reuse") · done {ok}.
 * Concurrency: 409 bei laufendem Import (Lock) oder aktivem Re-Cluster.
 */
async function recluster(req, res, next) {
  const reclusterService = require('../services/recluster.service');
  const xmlConvert = require('../services/xml-convert');

  if (reclusterService.isReclusterActive() || xmlConvert.isRunning()) {
    return res.status(409).json({
      success: false,
      error: { code: 'ALREADY_RUNNING', message: 'A conversion or re-cluster is already running.' },
    });
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  if (typeof res.flushHeaders === 'function') res.flushHeaders();

  const send = (evt) => {
    try { res.write(`data: ${JSON.stringify(evt)}\n\n`); } catch { /* client gone */ }
  };

  send({ event: 'start', ts: new Date().toISOString() });

  let aborted = false;
  res.on('close', () => {
    // cluster.sh läuft bewusst weiter (kein Kill mitten in cluster_load) — nur das
    // Forwarding zu DIESEM Socket endet.
    if (!res.writableEnded) aborted = true;
  });

  const heartbeat = setInterval(() => {
    try { res.write(': heartbeat\n\n'); } catch { /* socket gone */ }
  }, 15000);

  try {
    const { exit_code } = await reclusterService.runRecluster({
      onEvent: send,
      // Kontext-Lösung (X-Solution), nicht die aktive: sonst repartitioniert der
      // Button die Lösung eines anderen Betrachters.
      solution: req.solutionContext && req.solutionContext.solution,
    });
    if (!aborted) send({ event: 'done', ok: exit_code === 0, exit_code });
  } catch (err) {
    send({ event: 'error', message: err.message });
    send({ event: 'done', ok: false, exit_code: -1 });
  } finally {
    clearInterval(heartbeat);
    try { res.end(); } catch { /* already closed */ }
  }
}

module.exports = {
  getSubgraph,
  getNeighbors,
  getTrace,
  getTraceEntries,
  getOverview,
  getCommunityStats,
  getCommunities,
  getDepthProfile,
  search,
  recluster,
};
