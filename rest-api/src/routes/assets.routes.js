const express = require('express');

const router = express.Router({ caseSensitive: false });

/**
 * Static browser assets of the API's own HTML pages (no CDN).
 *
 * GET /api/assets/pele.js — pele's browser bundle (global `pele`), loaded by the
 * `format=mermaid` page (formatters/mermaid/html.js). The page adds `?v=<pele
 * version>`, so the file can be cached for a long time. Only files named here
 * are served; the path is resolved through the package's export map.
 */
const ASSETS = {
  'pele.js': 'pele/global',
};

router.get('/assets/:name', (req, res, next) => {
  const specifier = Object.prototype.hasOwnProperty.call(ASSETS, req.params.name)
    ? ASSETS[req.params.name]
    : null;
  if (!specifier) return next();

  let file;
  try {
    file = require.resolve(specifier);
  } catch {
    return res.status(404).json({
      success: false,
      error: { code: 'FILE_NOT_FOUND', message: `Asset not installed: ${req.params.name}` },
    });
  }
  res.type('application/javascript; charset=utf-8');
  return res.sendFile(file, {
    maxAge: req.query.v ? '30d' : '1h',
    immutable: Boolean(req.query.v),
  });
});

module.exports = router;
