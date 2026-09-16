const pluginDocsConfig = require('../../config/plugin-docs.config');

/**
 * Plugin-Docs-Service-Registry
 *
 * Vermittelt zwischen Controller und Quellen-Adapter. Lädt Adapter lazy aus
 * der Config und liefert eine einheitliche Sicht auf alle registrierten
 * Quellen — auch wenn einzelne Quellen nicht installiert sind.
 */

function getSourceConfig(sourceId) {
  return pluginDocsConfig.sources[sourceId] || null;
}

function getSourceAdapter(sourceId) {
  const cfg = getSourceConfig(sourceId);
  if (!cfg) return null;
  return cfg.adapter;
}

/**
 * Liste aller registrierten Quellen mit Verfügbarkeits-Status.
 */
function listSources() {
  return Object.values(pluginDocsConfig.sources).map((cfg) => {
    const adapter = cfg.adapter;
    try {
      return adapter.getStatus();
    } catch (e) {
      return {
        id: cfg.id,
        label: cfg.label,
        available: false,
        error: e.message,
      };
    }
  });
}

/**
 * Status einer einzelnen Quelle. Liefert NULL für unbekannte Quelle.
 */
function getSourceStatus(sourceId) {
  const adapter = getSourceAdapter(sourceId);
  if (!adapter) return null;
  return adapter.getStatus();
}

/**
 * Eine Funktion in einer bestimmten Quelle nachschlagen. Wirft einen Error
 * mit deklarativem `code`, wenn die Quelle unbekannt ist.
 */
function getFunctionDoc(sourceId, fnName) {
  const adapter = getSourceAdapter(sourceId);
  if (!adapter) {
    const err = new Error(`Unbekannte Plugin-Doku-Quelle: ${sourceId}`);
    err.code = 'PLUGIN_DOC_SOURCE_UNKNOWN';
    throw err;
  }
  return adapter.getFunctionDoc(fnName);
}

/**
 * Adresse der Doku-Seite einer Funktion im Doku-Browser (`{ category, entry }`)
 * oder NULL — unbekannte Quelle, Adapter ohne Eintragsebene, Doku nicht
 * installiert oder Funktion nicht im Index. Bewusst fehlertolerant: der
 * Aufrufer entscheidet damit nur, ob er einen Link rendert.
 */
function resolveEntryRef(sourceId, fnName) {
  const adapter = getSourceAdapter(sourceId);
  if (!adapter || typeof adapter.resolveEntryRef !== 'function') return null;
  try {
    return adapter.resolveEntryRef(fnName);
  } catch {
    return null;
  }
}

/** Externe Doku-URL einer Funktion beim Hersteller; NULL für unbekannte Quellen. */
function externalUrl(sourceId, fnName) {
  const cfg = getSourceConfig(sourceId);
  if (!cfg || typeof cfg.externalUrl !== 'function' || !fnName) return null;
  return cfg.externalUrl(fnName);
}

/**
 * Adresse der Rubrikseite einer Komponente im Doku-Browser (`{ category }`)
 * oder NULL — gleiche Fehlertoleranz wie `resolveEntryRef`.
 */
function resolveCategoryRef(sourceId, categoryName) {
  const adapter = getSourceAdapter(sourceId);
  if (!adapter || typeof adapter.resolveCategoryRef !== 'function') return null;
  try {
    return adapter.resolveCategoryRef(categoryName);
  } catch {
    return null;
  }
}

/** Externe Rubrik-URL beim Hersteller; NULL für unbekannte Quellen. */
function externalCategoryUrl(sourceId, categoryName) {
  const cfg = getSourceConfig(sourceId);
  if (!cfg || typeof cfg.externalCategoryUrl !== 'function' || !categoryName) return null;
  return cfg.externalCategoryUrl(categoryName);
}

/**
 * Kategorien-Liste einer Quelle. Wirft einen Error mit `code` für unbekannte
 * Quellen oder wenn der Adapter `listCategories` nicht unterstützt.
 */
function listCategories(sourceId, options = {}) {
  const adapter = getSourceAdapter(sourceId);
  if (!adapter) {
    const err = new Error(`Unbekannte Plugin-Doku-Quelle: ${sourceId}`);
    err.code = 'PLUGIN_DOC_SOURCE_UNKNOWN';
    throw err;
  }
  if (typeof adapter.listCategories !== 'function') {
    const err = new Error(`Adapter '${sourceId}' unterstützt keine Kategorien-Auflistung.`);
    err.code = 'NOT_IMPLEMENTED';
    throw err;
  }
  return adapter.listCategories(options);
}

/**
 * Funktionen einer Kategorie auflisten. Wirft `PLUGIN_FUNCTION_NOT_FOUND` mit
 * `target='category'`, wenn die Kategorie im Index nicht existiert.
 */
function listFunctionsInCategory(sourceId, categoryName, options = {}) {
  const adapter = getSourceAdapter(sourceId);
  if (!adapter) {
    const err = new Error(`Unbekannte Plugin-Doku-Quelle: ${sourceId}`);
    err.code = 'PLUGIN_DOC_SOURCE_UNKNOWN';
    throw err;
  }
  if (typeof adapter.listFunctionsInCategory !== 'function') {
    const err = new Error(`Adapter '${sourceId}' unterstützt keine Kategorien-Funktionsliste.`);
    err.code = 'NOT_IMPLEMENTED';
    throw err;
  }
  const result = adapter.listFunctionsInCategory(categoryName, options);
  if (!result.exists) {
    const err = new Error(`Kategorie '${categoryName}' nicht in Quelle '${sourceId}' gefunden.`);
    err.code = 'PLUGIN_CATEGORY_NOT_FOUND';
    err.source = sourceId;
    err.category = categoryName;
    throw err;
  }
  return result;
}

/**
 * Volltext-Suche nach Funktionsnamen in einer Quelle.
 */
function searchFunctions(sourceId, query, options = {}) {
  const adapter = getSourceAdapter(sourceId);
  if (!adapter) {
    const err = new Error(`Unbekannte Plugin-Doku-Quelle: ${sourceId}`);
    err.code = 'PLUGIN_DOC_SOURCE_UNKNOWN';
    throw err;
  }
  if (typeof adapter.searchFunctions !== 'function') {
    const err = new Error(`Adapter '${sourceId}' unterstützt keine Funktions-Suche.`);
    err.code = 'NOT_IMPLEMENTED';
    throw err;
  }
  return adapter.searchFunctions(query, options);
}

function clearCaches(sourceId) {
  if (sourceId) {
    const adapter = getSourceAdapter(sourceId);
    if (adapter && typeof adapter.clearCaches === 'function') adapter.clearCaches();
    return;
  }
  // Alle Quellen
  for (const cfg of Object.values(pluginDocsConfig.sources)) {
    const a = cfg.adapter;
    if (a && typeof a.clearCaches === 'function') a.clearCaches();
  }
}

module.exports = {
  listSources,
  getSourceStatus,
  getFunctionDoc,
  resolveEntryRef,
  externalUrl,
  resolveCategoryRef,
  externalCategoryUrl,
  listCategories,
  listFunctionsInCategory,
  searchFunctions,
  clearCaches,
};
