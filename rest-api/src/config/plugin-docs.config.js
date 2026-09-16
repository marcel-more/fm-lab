const path = require('path');
const environment = require('./environment');

/**
 * Plugin-Funktions-Dokumentation — Quellen-Registry
 *
 * Eintrag pro unterstütztem Plugin-Doku-Quelle. Der MVP unterstützt nur MBS;
 * weitere Quellen (360Works, Troi, BaseElements, …) lassen sich durch einen
 * neuen Adapter und einen Eintrag in `sources` ergänzen — der Endpoint-Pfad
 * (`/api/plugin-docs/:source/:function`) ist quellen-agnostisch.
 */

// Pfade relativ zur rest-api/ — entsprechen anderen Konventionen im Projekt.
const REST_API_ROOT = path.resolve(__dirname, '../../');

function resolveAbsolute(p) {
  if (!p) return null;
  return path.isAbsolute(p) ? p : path.resolve(REST_API_ROOT, p);
}

function fnToSlug(fnName) {
  // List.AddPrefix → ListAddPrefix
  return String(fnName || '').replace(/\./g, '');
}

const sources = {
  mbs: {
    id: 'mbs',
    label: 'MBS FileMaker Plugin',
    publisher: 'MonkeyBread Software',
    homepage: 'https://www.mbsplugins.eu/',
    rootPath: resolveAbsolute(environment.pluginDocs.mbsPath),
    indexFile: 'docSet.dsidx',
    docsDir: 'Documents',
    versionFile: '.version',
    // Komponenten-Zuordnung: der Doku-Index (docSet.dsidx) kennt nur Namen und
    // Pfade, nicht die Komponente einer Funktion. Die maßgebliche Tabelle wird
    // beim Doku-Install aus den Seiten abgeleitet und liegt in reference/ —
    // dieselbe Quelle, die auch Import-Pipeline und Objekt-Filter benutzen.
    componentMapFile: resolveAbsolute('../reference/mbs_component_exceptions.csv'),
    externalUrl: (fnName) => `https://www.mbsplugins.eu/${fnToSlug(fnName)}.shtml`,
    // Rubrikseite einer Komponente. Gleiche Regel wie oben, nur mit dem
    // `component_`-Präfix des Doku-Index (`component_Archive.html`) — im
    // Spiegel selbst als Hersteller-URL belegt (component_*.shtml).
    externalCategoryUrl: (catName) => `https://www.mbsplugins.eu/component_${catName}.shtml`,
    // Lazy require: Adapter erst zur Laufzeit laden, sonst Zirkularimport
    // mit dem gemeinsamen html-extractor.
    get adapter() {
      // eslint-disable-next-line global-require
      return require('../services/plugin-docs/mbs-source');
    },
  },
};

module.exports = {
  sources,
  cacheTTL: environment.pluginDocs.cacheTTL,
  cacheMaxDocs: environment.pluginDocs.cacheMaxDocs,
  cacheMaxPaths: environment.pluginDocs.cacheMaxPaths,
};
