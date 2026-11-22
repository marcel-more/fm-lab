/**
 * Autoren-Overlay der Änderungs-Metadaten — TEMP-Objekte auf der READ_ONLY-
 * Katalogverbindung einer Lösung.
 *
 * Der Katalog kennt je Stempel den automatisch normalisierten Author_Key
 * (lower(trim(userName))) und die Import-Klassifikation technischer Autoren
 * (ObjectChangeMeta.Author_Kind: 'tool' | 'runtime' | NULL = Person). Vom Nutzer
 * kuratierte Aliase — Schreibvarianten derselben Person zusammenführen, Anzeigename,
 * technischer Autor ja/nein — liegen im Annotations-Sidecar (Tabelle
 * ChangeAuthorAlias), damit sie einen Force-Rebuild überleben.
 *
 * Der Sidecar ist eine eigene DuckDB-Instanz und NICHT an den Katalog gehängt; eine
 * View über beide Dateien gibt es deshalb nicht. Dieses Modul spiegelt die Aliase als
 * TEMP-Tabelle ChangeAuthorAlias in die Katalogverbindung und legt darüber die
 * TEMP-View v_change_meta_authors (eine Zeile je Author_Key). Templates und Dashboards
 * lesen sie wie eine Katalog-View. DuckDB erlaubt TEMP-Objekte im READ_ONLY-Modus
 * (vgl. ensureCoreStubs in config/database.js).
 *
 * Läuft in der Pool-Factory — nach Start, Reload und Sync ist die Spiegelung damit
 * aktuell. Ein Katalog ohne die nötigen ObjectChangeMeta-Spalten (älteres Schema)
 * bekommt einen leeren TEMP-Stub gleichen Namens: Abfragen liefern dann leer statt
 * „does not exist". Nie fatal.
 *
 * v_change_meta_authors:
 *   Author_Key     — normalisierter Benutzername aus dem Katalog
 *   Person_Key     — Ziel des Alias (sonst Author_Key): danach gruppieren, um Varianten
 *                    derselben Person zusammenzufassen
 *   Display_Name   — je Person: Alias-Anzeigename, sonst die häufigste Schreibweise des
 *                    Schlüssels, der selbst Person_Key ist
 *   Is_Technical   — Alias-Override, sonst Author_Kind IS NOT NULL
 *   Author_Kind    — Import-Klassifikation (unverändert)
 *   Is_Curated     — ein Alias-Eintrag trifft den Schlüssel
 *   Raw_Names      — Schreibweisen von userName, häufigste zuerst
 *   Accounts       — Konten (accountName), sortiert
 *   Stamps / Single_Stamps / Files / First_At / Last_At — Kennzahlen des Schlüssels
 *                    (Single_Stamps = außerhalb von Massenereignissen)
 *
 * Kind 'account' im Sidecar ist für Konto-Aliase reserviert; die View wertet nur
 * 'user' aus.
 */

const COLUMNS = [
  ['Author_Key', 'VARCHAR'],
  ['Person_Key', 'VARCHAR'],
  ['Display_Name', 'VARCHAR'],
  ['Is_Technical', 'BOOLEAN'],
  ['Author_Kind', 'VARCHAR'],
  ['Is_Curated', 'BOOLEAN'],
  ['Raw_Names', 'VARCHAR[]'],
  ['Accounts', 'VARCHAR[]'],
  ['Stamps', 'BIGINT'],
  ['Single_Stamps', 'BIGINT'],
  ['Files', 'BIGINT'],
  ['First_At', 'TIMESTAMP'],
  ['Last_At', 'TIMESTAMP'],
];

const ALIAS_TABLE_DDL = `CREATE OR REPLACE TEMP TABLE ChangeAuthorAlias (
     Raw_Value VARCHAR, Kind VARCHAR, Author_Key VARCHAR, Display_Name VARCHAR, Is_Technical BOOLEAN
   )`;

const VIEW_DDL = `CREATE OR REPLACE TEMP VIEW v_change_meta_authors AS
WITH per_key AS (
    SELECT m.Author_Key,
           min(m.Author_Kind) AS Author_Kind,
           count(*) AS Stamps,
           count(*) FILTER (WHERE m.Bulk_Event_ID IS NULL) AS Single_Stamps,
           count(DISTINCT m.File_Name) AS Files,
           min(m.Modified_At) AS First_At,
           max(m.Modified_At) AS Last_At,
           list_sort(list_distinct(list(m.Modified_Account))) AS Accounts
    FROM ObjectChangeMeta m
    WHERE m.Author_Key IS NOT NULL
    GROUP BY m.Author_Key
),
variants AS (
    SELECT m.Author_Key, m.Modified_By, count(*) AS n
    FROM ObjectChangeMeta m
    WHERE m.Author_Key IS NOT NULL
    GROUP BY ALL
),
names AS (
    SELECT v.Author_Key,
           first(v.Modified_By ORDER BY v.n DESC, v.Modified_By) AS Top_Name,
           list(v.Modified_By ORDER BY v.n DESC, v.Modified_By) AS Raw_Names
    FROM variants v
    GROUP BY v.Author_Key
),
alias AS (
    SELECT lower(trim(a.Raw_Value)) AS Raw_Key,
           NULLIF(lower(trim(a.Author_Key)), '') AS Alias_Person,
           NULLIF(trim(a.Display_Name), '') AS Alias_Display,
           a.Is_Technical AS Alias_Technical
    FROM ChangeAuthorAlias a
    WHERE COALESCE(a.Kind, 'user') = 'user'
),
resolved AS (
    SELECT p.*, n.Top_Name, n.Raw_Names,
           COALESCE(al.Alias_Person, p.Author_Key) AS Person_Key,
           al.Alias_Display, al.Alias_Technical,
           al.Raw_Key IS NOT NULL AS Is_Curated
    FROM per_key p
    JOIN names n ON n.Author_Key = p.Author_Key
    LEFT JOIN alias al ON al.Raw_Key = p.Author_Key
),
person_display AS (
    SELECT r.Person_Key,
           COALESCE(min(r.Alias_Display),
                    first(r.Top_Name ORDER BY (r.Author_Key = r.Person_Key) DESC, r.Stamps DESC, r.Author_Key))
               AS Display_Name
    FROM resolved r
    GROUP BY r.Person_Key
)
SELECT r.Author_Key,
       r.Person_Key,
       pd.Display_Name,
       COALESCE(r.Alias_Technical, r.Author_Kind IS NOT NULL) AS Is_Technical,
       r.Author_Kind,
       r.Is_Curated,
       r.Raw_Names,
       r.Accounts,
       r.Stamps,
       r.Single_Stamps,
       r.Files,
       r.First_At,
       r.Last_At
FROM resolved r
JOIN person_display pd ON pd.Person_Key = r.Person_Key`;

const STUB_DDL = `CREATE OR REPLACE TEMP TABLE v_change_meta_authors (
     ${COLUMNS.map(([n, t]) => `${n} ${t}`).join(', ')}
   )`;

const esc = (s) => String(s).replace(/'/g, "''");
const lit = (v) => (v === null || v === undefined ? 'NULL' : `'${esc(v)}'`);
const boolLit = (v) => (v === null || v === undefined ? 'NULL' : (v ? 'TRUE' : 'FALSE'));

async function exec(connection, sql) {
  const stmt = await connection.prepare(sql);
  try {
    await stmt.run();
  } finally {
    try { stmt.destroySync(); } catch { /* freigegeben */ }
  }
}

/**
 * Aliase der Lösung aus dem Sidecar — je (Kind, Raw_Value ohne Groß-/Kleinschreibung
 * und Randleerzeichen) gewinnt der zuletzt geänderte Eintrag. Leer, wenn der Sidecar
 * nicht verfügbar ist.
 */
async function loadAliasRows(solutionId) {
  try {
    return await require('./annotations-db').query(
      { solution: solutionId },
      `SELECT Raw_Value, Kind, Author_Key, Display_Name, Is_Technical
         FROM ChangeAuthorAlias
        WHERE Raw_Value IS NOT NULL AND trim(Raw_Value) <> ''
      QUALIFY row_number() OVER (
                PARTITION BY COALESCE(Kind, 'user'), lower(trim(Raw_Value))
                ORDER BY Updated_At DESC NULLS LAST, Author_Key NULLS LAST) = 1`
    );
  } catch (err) {
    console.warn(`  - change author aliases unavailable (solution: ${solutionId}): ${err.message}`);
    return [];
  }
}

/**
 * TEMP-Tabelle + TEMP-View auf einer Katalogverbindung (neu) anlegen. `aliasRows`:
 * Zeilen { Raw_Value, Kind, Author_Key, Display_Name, Is_Technical }. Liefert
 * 'view' | 'stub' | 'skipped'.
 */
async function installOverlay(connection, aliasRows = []) {
  try {
    await exec(connection, ALIAS_TABLE_DDL);
    if (aliasRows.length > 0) {
      const values = aliasRows
        .map((r) => `(${lit(r.Raw_Value)}, ${lit(r.Kind)}, ${lit(r.Author_Key)}, ${lit(r.Display_Name)}, ${boolLit(r.Is_Technical)})`)
        .join(', ');
      await exec(connection, `INSERT INTO ChangeAuthorAlias VALUES ${values}`);
    }
  } catch (err) {
    console.warn(`  - change author overlay skipped: ${err.message}`);
    return 'skipped';
  }
  try {
    await exec(connection, VIEW_DDL);
    return 'view';
  } catch {
    // Katalog ohne ObjectChangeMeta bzw. ohne Author_Kind/Bulk_Event_ID (älteres Schema).
    try {
      await exec(connection, STUB_DDL);
      return 'stub';
    } catch (err) {
      console.warn(`  - change author overlay stub skipped: ${err.message}`);
      return 'skipped';
    }
  }
}

/** Pool-Factory-Hook: Aliase der Lösung laden und das Overlay installieren. */
async function install(entry) {
  const rows = await loadAliasRows(entry.solutionId);
  const mode = await installOverlay(entry.connection, rows);
  // Connections for file SQL (config/database.js) install the same overlay from
  // these rows; a new version retires the ones prepared before.
  entry.aliasRows = rows;
  entry.overlayVersion = (entry.overlayVersion || 0) + 1;
  if (mode === 'view') {
    console.log(`  - change author overlay: v_change_meta_authors (${rows.length} alias row(s))`);
  } else if (mode === 'stub') {
    console.log('  - change author overlay: TEMP stub (catalog without change metadata)');
  }
  return mode;
}

module.exports = { install, installOverlay, loadAliasRows, COLUMNS };
