const express = require('express');
const router = express.Router({ caseSensitive: false });
const xmlController = require('../controllers/xml.controller');

/**
 * XML-Convert Routes.
 *
 * Diese Routen steuern den XML→DuckDB-Konvertierungs-Prozess aus dem Web-
 * Frontend heraus (Sub-Dashboard "xml_convert"). Die eigentliche Logik bleibt
 * im Bash-Skript ingestion/convert_fm_xml.sh; der Service spawnt es im
 * `--quiet`-Modus und streamt dessen NDJSON-Events als SSE durch.
 */

router.get('/xml/status',         xmlController.getStatus);
router.get('/xml/runs',           xmlController.getRuns);
router.post('/xml/reveal',        xmlController.reveal);
router.get('/xml/last-run/log',   xmlController.getLastRunLog);
router.post('/xml/convert',       xmlController.convert);
// Lauf vom Request entkoppelt — Stream-Abo + expliziter Cancel.
router.get('/xml/convert/stream',  xmlController.streamConvert);
router.post('/xml/convert/cancel', xmlController.cancelConvert);

module.exports = router;
