const express = require('express');
const router = express.Router({ caseSensitive: false });
const pluginSpecService = require('../services/plugin-spec.service');
const { buildSuccess } = require('../utils/response-builder');

/**
 * Plugin-Spec Routes
 *
 *   GET /api/plugin-spec/meta                       — plugins + derivation meta
 *   GET /api/plugin-spec/functions/:prefix/:name    — platform spec of one function
 *   GET /api/plugin-spec/components/:prefix/:name   — size + doc links of one component (`?fn=` resolves the vendor component name)
 *
 * 503 when reference/plugin_spec.duckdb is not attached (mirror not installed),
 * 404 for unknown functions — consumers degrade to "no platform statement".
 */

const ERROR_STATUS = {
  PLUGSPEC_NOT_ATTACHED: 503,
  PLUGSPEC_FN_NOT_FOUND: 404,
};

function asyncWrap(fn) {
  return (req, res, next) => Promise.resolve(fn(req, res, next)).catch((err) => {
    if (err && err.code && ERROR_STATUS[err.code]) {
      return res.status(ERROR_STATUS[err.code]).json({
        success: false,
        error: { code: err.code, message: err.message },
      });
    }
    next(err);
  });
}

router.get('/plugin-spec/meta', asyncWrap(async (req, res) => {
  const data = await pluginSpecService.getMeta(req.solutionContext);
  res.json(buildSuccess(data));
}));

router.get('/plugin-spec/functions/:prefix/:name', asyncWrap(async (req, res) => {
  const data = await pluginSpecService.getFunctionSpec(
    req.solutionContext, req.params.prefix, req.params.name
  );
  res.json(buildSuccess(data));
}));

// `?fn=` — Name einer Mitglieds-Funktion. Hilfsangabe, mit der der
// Katalog-Komponentenname auf die Hersteller-Komponente aufgelöst wird
// (Katalog 'GMImage' → Hersteller 'GraphicsMagick').
router.get('/plugin-spec/components/:prefix/:name', asyncWrap(async (req, res) => {
  const data = await pluginSpecService.getComponentSpec(
    req.solutionContext, req.params.prefix, req.params.name,
    { viaFunction: req.query.fn || null }
  );
  res.json(buildSuccess(data));
}));

module.exports = router;
