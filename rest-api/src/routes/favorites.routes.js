const express = require('express');
const router = express.Router({ caseSensitive: false });
const controller = require('../controllers/favorites.controller');

/**
 * Favorites Routes — workspace-wide favorites in `.fmlab/favorites.json`,
 * independent of the selected solution. A path of their own: under
 * /dashboards/… the segment `favorites` would read as a dashboard id.
 * `:kind` ∈ dashboard | test (anything else → 400).
 * Mounted under /api by routes/index.js.
 */

// GET /api/favorites/:kind — { items: [{ id, added_at }], missing: [id] }
router.get('/favorites/:kind', controller.list);

// PUT /api/favorites/:kind/:id — idempotent add (404 unknown, 422 not favoritable)
router.put('/favorites/:kind/:id', controller.add);

// DELETE /api/favorites/:kind/:id — idempotent remove
router.delete('/favorites/:kind/:id', controller.remove);

module.exports = router;
