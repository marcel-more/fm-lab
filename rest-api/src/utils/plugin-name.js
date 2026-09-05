/**
 * Plugin-Function Namens-Utility (Server-Seite).
 *
 * PluginFunctions tragen im ObjectCatalog einen bewusst redundanten
 * Object_Name, aus dem sich die synthetische UUID ableitet
 * (vgl. ingestion/sql/convert_xml_04_catalog.sql):
 *
 *   Container-Plugin (MBS):  `<Plugin>:<Sub>::<Sub>`   z.B. `MBS:FM.InsertRecord::FM.InsertRecord`
 *   Non-Container-Plugin:    `<Name>`                  (kein `::`)
 *
 * Historie: bis AP-5a war der Container-Name `MBS::<Sub>` (Plugin-Namespace mit
 * doppeltem Doppelpunkt direkt vor dem SubName). Seit der Qualifizierung ist er
 * `MBS:<Sub>::<Sub>` (einfacher Doppelpunkt nach dem Namespace). Alle Resolver,
 * die den fachlichen SubName brauchen (Docset-Referenzen, Pseudo-Object-Lookup,
 * Component-Aggregation), MÜSSEN format-tolerant arbeiten.
 *
 * Kanonische Regel — deckungsgleich mit apps/web/src/lib/objectName.ts:
 *   • SubName    = Teil hinter dem LETZTEN `::`  (funktioniert für beide Formate)
 *   • Namespace  = Teil vor dem ERSTEN `:`       (`MBS`; null bei Non-Container)
 *
 * Diese Datei ist die EINZIGE Quelle der Extraktions-Logik auf der Server-Seite;
 * SQL-Templates spiegeln `SQL_PLUGIN_SUBNAME`/`sqlPluginSubName()` inline
 * (DuckDB kann kein JS importieren) und verweisen im Kommentar hierher.
 */

const SUB_SEP = '::';

/**
 * Fachlicher SubName einer PluginFunction (Teil hinter dem letzten `::`).
 * Für Non-Container-Plugins (kein `::`) bleibt der Name unverändert.
 * @param {string} objectName
 * @returns {string}
 */
function pluginSubName(objectName) {
  if (!objectName) return objectName;
  const i = objectName.lastIndexOf(SUB_SEP);
  return i === -1 ? objectName : objectName.slice(i + SUB_SEP.length);
}

/**
 * Plugin-Namespace einer PluginFunction (Teil vor dem ersten `:`), z.B. `MBS`.
 * null bei Non-Container-Plugins (kein `::`).
 * @param {string} objectName
 * @returns {string|null}
 */
function pluginComponentNamespace(objectName) {
  if (!objectName || objectName.indexOf(SUB_SEP) === -1) return null;
  const head = objectName.slice(0, objectName.indexOf(SUB_SEP));
  const colon = head.indexOf(':');
  return colon === -1 ? null : head.slice(0, colon);
}

/**
 * DuckDB-Ausdruck, der aus einer Object_Name-Spalte den SubName zieht
 * (greedy `.*::` matcht bis zum LETZTEN `::`). Format-tolerant für altes
 * `MBS::<Sub>` und neues `MBS:<Sub>::<Sub>`. Non-Container-Namen ohne `::`
 * bleiben unverändert.
 * @param {string} col - Spalten-Ausdruck, default 'Object_Name'
 * @returns {string}
 */
function sqlPluginSubName(col = 'Object_Name') {
  return `regexp_replace(${col}, '^.*::', '')`;
}

/** Vorgefertigter Ausdruck für die Standard-Spalte `Object_Name`. */
const SQL_PLUGIN_SUBNAME = sqlPluginSubName();

module.exports = {
  pluginSubName,
  pluginComponentNamespace,
  sqlPluginSubName,
  SQL_PLUGIN_SUBNAME,
};
