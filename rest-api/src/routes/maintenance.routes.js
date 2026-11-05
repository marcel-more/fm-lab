const express = require('express');
const router = express.Router({ caseSensitive: false });
const controller = require('../controllers/maintenance.controller');

/**
 * Maintenance Routes — workspace housekeeping, independent of the selected
 * solution. Mounted under /api by routes/index.js. A path of their own: under
 * /dashboards/… the segment `cleanup` would read as a dashboard id.
 */

// GET /api/maintenance/dashboards/cleanup — read-only check for leftovers of
// older dashboard and query layouts: { inventory, stamp, items, summary, running }
router.get('/maintenance/dashboards/cleanup', controller.previewDashboardCleanup);

// POST /api/maintenance/dashboards/cleanup — body { exclude?: [from] }; moves the
// leftovers (409 while a run is active, X-Admin-Token like /api/admin/*)
router.post('/maintenance/dashboards/cleanup', controller.runDashboardCleanup);

// GET /api/maintenance/tests/cleanup — read-only check for tests and folders in
// the shipped tests/ tree this release does not ship (same response form)
router.get('/maintenance/tests/cleanup', controller.previewTestCleanup);

// POST /api/maintenance/tests/cleanup — body { exclude?: [from] }; moves them
// (409 while a test cleanup is active, X-Admin-Token like /api/admin/*)
router.post('/maintenance/tests/cleanup', controller.runTestCleanup);

module.exports = router;
