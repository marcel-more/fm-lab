-- @title: Logical Links View (Graph Explorer)
-- @description: Read-only-Vorschau der operationalen Referenz-Kanten (LogicalLinks-View)
-- @version: 2.0.0
-- @author: Marcel / Claude
-- @tags: graph, subgraph, logical-view
-- @note: KONSUMENTEN-STUB — die kanonische LogicalLinks-Definition lebt in der
--        Import-Engine: ingestion/sql/convert_xml_05_homes.sql (P5 legt die View
--        bei jedem Import im Katalog an; der convert-xml-Sync spiegelt sie in
--        die READ_ONLY-API-Kopie). Dieses Template definiert NICHTS mehr —
--        vormals trug es eine synchron zu haltende Kopie der Definition
--        (Sync-Pflicht seit dem Kanonizitäts-Dreh entfallen). Design-Rationale,
--        Datenbefund und Versions-Historie (v1.1.0–v1.5.0: Promotion, Stufe C,
--        Graph-Policy, Feld-Verankerung, Spezialtypen) stehen am Kanon.
--
-- ZWECK dieses Stubs: ad-hoc-Einblick in den Kantensatz der "logischen Sicht"
-- (mode=logical) über den generischen /api/query-Template-Pool — läuft read-only
-- auf der API-Kopie. Die Graph-Endpoints (graph_subgraph.sql,
-- graph_overview_*.sql, graph_depth_profile.sql) konsumieren die View direkt.
--
-- LIMIT bewusst: LogicalLinks ist eine Hoisting-View-Kette; ein Voll-Scan über
-- Großkorpora (100k+ Kanten) gehört nicht in eine Pool-Vorschau.

SELECT
  Source_UUID,
  Source_File,
  Target_UUID,
  Target_File,
  Link_Role,
  Link_Subrole,
  Link_Type,
  Is_Cross_File
FROM LogicalLinks
LIMIT 500;
