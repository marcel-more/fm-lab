-- @template_type: report
-- @title: Graph Trace Profile Candidates (H1–H4)
-- @description: Kandidaten für das Lösungsprofil des Datenfluss-Trace — technische Layouts (H1), Infrastruktur-Scripts (H2), UI-Zustandsvariablen (H3), Variablen mit sehr vielen Lesern (H4); nur Vorschläge, das Profil wirkt erst nach Bestätigung
-- @params: (keine)
-- @version: 1.0.0
-- @author: Marcel / Claude
-- @tags: graph, trace, dataflow, profile
-- @note: 1.0.0 — Kandidaten des Lösungsprofils. Schwellen (gemessen an realen Lösungen):
--        H1 ≥ 5 Layouts gleichen Namens mit je ≥ 60 % editierbaren Feldern der
--        Basistabelle (Name als Muster); H2 Aufrufe aus ≥ 5 Dateien, Ergebnis an
--        keiner Aufrufstelle gelesen (auch nicht über Custom Functions);
--        H3 ≥ 80 % der Lesestellen in Layout-Objekten; H4 ≥ 100 Lesekontexte,
--        Layout-Anteil ≥ 0,5 (darunter `uncertain`), ohne die H3-Treffer.
--        Liest v_dataflow_edges (entry_input, result_to_step) — der Service prüft
--        vorher, ob die Datenfluss-Tabellen existieren.
--
-- AUSGABE — eine Zeile je Kandidat:
--   heuristic   H1 · H2 · H3 · H4
--   kind        technical_layout · boundary_script · ui_state_variable · hub_variable
--   uuid, file  Objekt (H2–H4); H1 trägt stattdessen pattern = Layoutname
--   name        Anzeige
--   metric_a/b  Kennzahlen (H1 Layouts über der Schwelle / Layouts gesamt,
--               H2 Dateien / Aufrufe, H3/H4 Leser / Layout-Anteil in Prozent)
--   uncertain   TRUE = nur als unsicher vorschlagen (H4 mit Layout-Anteil < 0,5)
--   sample      bis zu 5 Belege (H1: Layouts „Name [Datei]“)
-- ============================================================================

WITH
-- editierbare Feldobjekte (Einstieg Eingabe von Hand) je Layout
lo_entry AS (
  SELECT DISTINCT lo.File_Name, lo.Layout_ID, d.To_UUID AS fld, d.To_File AS fld_file
  FROM v_dataflow_edges d
  JOIN LayoutObjects lo ON lo.Object_UUID = d.From_UUID AND lo.File_Name = d.From_File
  WHERE d.Flow_Kind = 'entry_input'
),
lay AS (
  SELECT l.File_Name, l.L_ID, l.L_UUID, l.L_Name, t.BT_UUID
  FROM Layouts l
  LEFT JOIN TableOccurrenceCatalog t ON t.TO_UUID = l.L_TO_UUID AND t.File_Name = l.File_Name
  WHERE NOT COALESCE(l.Is_Separator, FALSE) AND l.L_Name IS NOT NULL AND l.L_Name <> ''
),
bt AS (
  SELECT Table_UUID, File_Name, count(*) AS nfields
  FROM FieldsForTables WHERE Field_Type = 'Normal' GROUP BY ALL
),
ed AS (
  SELECT File_Name, Layout_ID, count(DISTINCT fld) AS ned FROM lo_entry GROUP BY ALL
),
-- Layouts über der Editier-Schwelle
lay_hit AS (
  SELECT lay.*
  FROM lay
  JOIN ed ON ed.File_Name = lay.File_Name AND ed.Layout_ID = lay.L_ID
  JOIN bt ON bt.Table_UUID = lay.BT_UUID AND bt.File_Name = lay.File_Name
  WHERE ed.ned >= 0.6 * bt.nfields
),
h1 AS (
  SELECT 'H1' AS heuristic, 'technical_layout' AS kind,
         CAST(NULL AS VARCHAR) AS uuid, CAST(NULL AS VARCHAR) AS file, h.L_Name AS pattern, h.L_Name AS name,
         count(*) AS metric_a,
         (SELECT count(*) FROM lay a WHERE a.L_Name = h.L_Name) AS metric_b,
         FALSE AS uncertain,
         list_slice(list(h.L_Name || ' [' || h.File_Name || ']' ORDER BY h.File_Name, h.L_ID), 1, 5) AS sample
  FROM lay_hit h
  GROUP BY h.L_Name
  HAVING count(*) >= 5
),
-- Aufrufe je Script (Aufrufschritte aus allen Dateien)
calls AS (
  SELECT Target_UUID, Target_File, count(DISTINCT File_Name) AS nfiles, count(*) AS ncalls
  FROM v_script_step_links
  WHERE Link_Role = 'calls_script' AND Target_Type = 'Script' AND Target_UUID IS NOT NULL
  GROUP BY ALL
),
result_read AS (
  SELECT DISTINCT From_UUID, From_File FROM v_dataflow_edges WHERE Flow_Kind = 'result_to_step'
),
h2 AS (
  SELECT 'H2', 'boundary_script', c.Target_UUID, c.Target_File, CAST(NULL AS VARCHAR), sc.Script_Name,
         c.nfiles, c.ncalls, FALSE, CAST([] AS VARCHAR[])
  FROM calls c
  JOIN ScriptCatalog sc ON sc.Script_UUID = c.Target_UUID AND sc.File_Name = c.Target_File
  WHERE c.nfiles >= 5
    AND NOT EXISTS (SELECT 1 FROM result_read r
                    WHERE r.From_UUID = c.Target_UUID || '#result' AND r.From_File = c.Target_File)
),
gvar AS (
  SELECT md5(Variable_Scope || '::' || Scope_Anchor || '::' || Variable_Name) AS var_uuid,
         Scope_Anchor AS file, Variable_Name,
         count(DISTINCT COALESCE(Context_UUID, '') || '#' || COALESCE(CAST(Step_Index AS VARCHAR), ''))
           FILTER (WHERE Usage_Type = 'read') AS readers,
         count(*) FILTER (WHERE Usage_Type = 'read' AND Context_Type = 'layout_object') AS lo_reads,
         count(*) FILTER (WHERE Usage_Type = 'read') AS reads
  FROM VariableUsages
  WHERE Variable_Scope IN ('global', 'superglobal')
  GROUP BY ALL
),
h3 AS (
  SELECT 'H3', 'ui_state_variable', g.var_uuid, g.file, CAST(NULL AS VARCHAR), g.Variable_Name,
         g.reads, CAST(round(100.0 * g.lo_reads / g.reads) AS BIGINT), FALSE, CAST([] AS VARCHAR[])
  FROM gvar g
  WHERE g.reads > 0 AND g.lo_reads >= 0.8 * g.reads
),
h4 AS (
  SELECT 'H4', 'hub_variable', g.var_uuid, g.file, CAST(NULL AS VARCHAR), g.Variable_Name,
         g.readers, CAST(round(100.0 * g.lo_reads / g.reads) AS BIGINT),
         g.lo_reads < 0.5 * g.reads, CAST([] AS VARCHAR[])
  FROM gvar g
  WHERE g.readers >= 100 AND NOT (g.lo_reads >= 0.8 * g.reads)
)
SELECT * FROM h1
UNION ALL SELECT * FROM h2
UNION ALL SELECT * FROM h3
UNION ALL SELECT * FROM h4
ORDER BY heuristic, uncertain, metric_a DESC, name, file, uuid;
