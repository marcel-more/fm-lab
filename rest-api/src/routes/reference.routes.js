const express = require('express');
const path = require('path');
const fs = require('fs');
const router = express.Router({ caseSensitive: false });
const controller = require('../controllers/reference.controller');
const environment = require('../config/environment');
const helpService = require('../services/help.service');

/**
 * Reference-Routes
 *
 * WICHTIG bei Routen-Reihenfolge:
 *   - /help/status muss VOR /help/:lang/:slug stehen (sonst wird 'status' als lang interpretiert)
 *   - /embed muss VOR /:idOrSlug-Detail stehen (für /api/reference/steps/:idOrSlug/embed)
 *   - /_static/:lang/... per express.static gemountet (vor den anderen, sonst fängt _static
 *     keine GETs ab)
 *
 * Statische Mirror-Assets:
 *   /api/reference/_static/<lang>/content/...
 *   /api/reference/_static/<lang>/Resources/...
 *   /api/reference/_static/<lang>/Skins/...
 *   /api/reference/_static/<lang>/assets/...
 */

// === Help & Static Mounts =====================================================
router.get('/reference/help/status', controller.helpStatus);

// Statische Assets aus dem Claris-Mirror. Wir mounten pro Sprache dynamisch —
// `:lang/...`-Routing greift, sobald die Sprache als Verzeichnis existiert.
router.use('/reference/_static/:lang', (req, res, next) => {
  const lang = String(req.params.lang || '');
  // Path-Traversal-Schutz: nur a-z, A-Z, 0-9, -, _
  if (!/^[a-zA-Z0-9_-]+$/.test(lang)) {
    return res.status(400).json({
      success: false,
      error: { code: 'VALIDATION_ERROR', message: `Invalid lang param: '${lang}'` },
    });
  }
  const root = path.resolve(__dirname, '../../', environment.reference.htmlCacheRoot, lang);
  if (!fs.existsSync(root)) {
    return res.status(404).json({
      success: false,
      error: { code: 'REF_HELP_NOT_FOUND', message: `Mirror dir '${lang}' not present.` },
    });
  }
  return express.static(root, {
    fallthrough: false,
    setHeaders(res) {
      res.setHeader('Cache-Control', 'public, max-age=604800'); // 7d
    },
  })(req, res, next);
});

// Help-HTML (rohes Dokument) — der Slug-Parameter kann '.html'-Suffix tragen
router.get('/reference/help/:lang/:slug', controller.helpHtml);

// === Categories / Lookup / Meta ===============================================
router.get('/reference/categories', controller.getCategories);
router.get('/reference/lookup', controller.lookup);
router.get('/reference/meta', controller.getMeta);

// Lokalisierte Script-Trigger-Event-Beschriftungen (fm_spec ≥ 1.18.0)
router.get('/reference/trigger-events', controller.getTriggerEvents);

// === Runtime & diagnostics (fm_spec ≥ 2.8.0) ==================================
// Listen VOR den :param-Details; /error-codes/:code nimmt negative Zahlen an
// (der Parameter ist ein freier Pfadabschnitt, geprüft im Controller).
router.get('/reference/triggers', controller.listTriggers);
router.get('/reference/triggers/:idOrName', controller.getTrigger);
router.get('/reference/error-codes', controller.listErrorCodes);
router.get('/reference/error-codes/:code', controller.getErrorCode);
router.get('/reference/feature-versions', controller.listFeatureVersions);
router.get('/reference/constants', controller.listConstants);

// === Steps ====================================================================
// Reihenfolge: literale/spezifische Sub-Pfade VOR dem :idOrSlug-Detail.
router.get('/reference/steps', controller.listSteps);
router.get('/reference/steps/:idOrSlug/langs', controller.getStepLangs);
router.get('/reference/steps/:idOrSlug/grammar', controller.getStepGrammar);
router.get('/reference/steps/:idOrSlug/embed', controller.getStepEmbed);
router.get('/reference/steps/:idOrSlug', controller.getStep);

// === Functions ================================================================
router.get('/reference/functions', controller.listFunctions);
router.get('/reference/functions/:nameOrId/embed', controller.getFunctionEmbed);
router.get('/reference/functions/:nameOrId', controller.getFunction);

// Beim ersten Routen-Load Manifest einlesen (lazy, aber an dieser Stelle direkt
// triggern, damit der Server-Start-Log den Status zeigt).
helpService.getManifest();

module.exports = router;
