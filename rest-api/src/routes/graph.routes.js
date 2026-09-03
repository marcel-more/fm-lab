const express = require('express');
const router = express.Router({ caseSensitive: false });
const controller = require('../controllers/graph.controller');
const { validate } = require('../middleware/validator');

/**
 * Graph Explorer Routes (P2 — Subgraph-Backend).
 * Gemountet unter /api durch routes/index.js.
 */

// GET /api/graph/subgraph?focus=…&depth=…&direction=…&mode=…&types=…&roles=…&include_builtins=…&node_limit=…&hub_degree=…
router.get('/graph/subgraph', validate('graphSubgraph'), controller.getSubgraph);

// GET /api/graph/neighbors?focus=…&direction=…&mode=…  — 1-Hop-Expansion
router.get('/graph/neighbors', validate('graphNeighbors'), controller.getNeighbors);

// GET /api/graph/trace?start=…&up_depth=…&down_depth=…&trigger_depth=…  — selektiver
// Ablauf-Graph (Chain + Touch + Kontext-Trigger), Antwort im Subgraph-Format + Trace-Felder
router.get('/graph/trace', validate('graphTrace'), controller.getTrace);

// GET /api/graph/trace/entries?start=…  — Einstiegspfad-Presets mit Seed-Zählern
router.get('/graph/trace/entries', validate('graphTraceEntries'), controller.getTraceEntries);

// GET /api/graph/overview?view=…&level=…&segment_by=…&weight=…  — Graph-Atlas Top-Down-Einstieg
router.get('/graph/overview', validate('graphOverview'), controller.getOverview);

// GET /api/graph/community-stats  — Community-Namen-Status + Cluster-Verfügbarkeit (Atlas-Statusleiste / Failover)
router.get('/graph/community-stats', validate('graphCommunityStats'), controller.getCommunityStats);

// GET /api/graph/communities  — vollständige Community-Liste der aktiven Engine (Cluster-Übersicht)
router.get('/graph/communities', validate('graphCommunityStats'), controller.getCommunities);

// GET /api/graph/depth-profile?focus=…&direction=…&mode=…  — max. Tiefe + per-Tiefe-Count
router.get('/graph/depth-profile', validate('graphDepthProfile'), controller.getDepthProfile);

// GET /api/graph/search?q=…&type=…&file=…&limit=…  — Fokus-Autocomplete
router.get('/graph/search', validate('graphSearch'), controller.search);

// POST /api/graph/recluster  — Rebuild-Button: cluster.sh (Roh-Repartition + Sync
// + Reload → Namens-Restore), SSE-Stream (start · log · done). Concurrency: 409.
router.post('/graph/recluster', controller.recluster);

module.exports = router;
