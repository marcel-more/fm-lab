const express = require('express');
const router = express.Router({ caseSensitive: false });

const objectRoutes = require('./object.routes');
const systemRoutes = require('./system.routes');
const versionRoutes = require('./version.routes');
const queryRoutes = require('./query.routes');
const adminRoutes = require('./admin.routes');
const pluginsRoutes = require('./plugins.routes');
const pluginDocsRoutes = require('./plugin-docs.routes');
const docsRoutes = require('./docs.routes');
const xmlRoutes = require('./xml.routes');
const relationshipGraphRoutes = require('./relationshipGraph.routes');
const graphRoutes = require('./graph.routes');
const annotationsRoutes = require('./annotations.routes');
const codegenRoutes = require('./codegen.routes');
const referenceRoutes = require('./reference.routes');
const pluginSpecRoutes = require('./plugin-spec.routes');
const dashboardRoutes = require('./dashboard.routes');
const testsRoutes = require('./tests.routes');
const resultsRoutes = require('./results.routes');
const favoritesRoutes = require('./favorites.routes');
const maintenanceRoutes = require('./maintenance.routes');
const debugRoutes = require('./debug.routes');
const { loadPlugins } = require('../plugins/loader');

/**
 * Route Aggregator
 * Combines all route modules
 */

// Object-related routes (/api/get, /api/list, etc.)
router.use('/', objectRoutes);

// System routes (/api/version, /api/info)
router.use('/', systemRoutes);

// Version manifest (/api/version-manifest) — modul-granulares version.json
router.use('/', versionRoutes);

// Query & Report routes (/api/query, /api/report)
router.use('/', queryRoutes);

// Admin routes (/api/admin/reload)
router.use('/', adminRoutes);

// Plugins metadata API (/api/plugins) — must be mounted before loadPlugins()
router.use('/', pluginsRoutes);

// Plugin function documentation (/api/plugin-docs)
router.use('/', pluginDocsRoutes);

// Docs (catalog + installed + categories + entries) — neue v2-API
router.use('/', docsRoutes);

// XML-Konvertierung (/api/xml/status, /api/xml/convert)
router.use('/', xmlRoutes);

// Relationship Graph (/api/relationship-graph/:fileName)
router.use('/', relationshipGraphRoutes);

// Graph Explorer (/api/graph/subgraph, /neighbors, /search) — P2
router.use('/', graphRoutes);

// User-Annotationen (/api/annotations/*) — Noise-Filter & semantische Anreicherung
router.use('/', annotationsRoutes);

// Codegen (/api/codegen/lint, /api/codegen/compile) — fmgen-Pipeline, stateless
router.use('/', codegenRoutes);

// Reference-DB (Script Steps + Functions + Claris-Hilfe-Mirror)
router.use('/', referenceRoutes);

// Plugin-Spec-DB (Plattform-Map für Plugin-Funktionen, plugref)
router.use('/', pluginSpecRoutes);

// Dashboards (deklarative Bundles aus templates/dashboards/)
router.use('/', dashboardRoutes);

// Analysis Tests (deklarierte Sammlungen aus templates/tests{,-custom}/)
router.use('/', testsRoutes);

// Results-Layer (/api/results/*) — Envelope-Summary, Aggregat, Trigger
router.use('/', resultsRoutes);

// Favorites (/api/favorites/:kind[/:id], kind = dashboard | test) — workspace-wide, solution-independent
router.use('/', favoritesRoutes);

// Maintenance (/api/maintenance/dashboards/cleanup) — solution-independent
router.use('/', maintenanceRoutes);

// Debug-Session (Frontend-Interaktions-Ingestion + Logging-Status)
router.use('/', debugRoutes);

// Plugin routes (dynamically discovered)
loadPlugins(router);

module.exports = router;
