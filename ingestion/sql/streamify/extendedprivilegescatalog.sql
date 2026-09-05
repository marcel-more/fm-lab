-- streamify-Override für ExtendedPrivilegesCatalog.
-- Hat einen ObjectList-Wrapper → Single-VARCHAR-Capture (PrivilegeSets-Muster): priv_xml
-- bleibt das ganze <ExtendedPrivilege>-Element → alle Downstream-/ExtendedPrivilege/…-
-- xpaths (inkl. nested //ObjectList/PrivilegeSetReference) UNVERÄNDERT. Keine Roh-Spalte
-- → voll bit-identisch erwartet.
WITH filename_normalized AS (
    SELECT getvariable('fm_file') as File_Name
),
raw_privileges AS (
    SELECT unnest(xml_extract_elements('<ObjectList>' || ObjectList || '</ObjectList>', '/ObjectList/ExtendedPrivilege')) as priv_xml
    FROM read_xml(
        getvariable('fm_xml'),
        record_element='ExtendedPrivilegesCatalog',
        maximum_file_size=getvariable('dom_threshold'),
        streaming=getvariable('use_streaming'),
        columns={'ObjectList':'VARCHAR'}
    )
    WHERE ObjectList IS NOT NULL
)
INSERT INTO ExtendedPrivilegesCatalog
SELECT
    xml_extract_text(priv_xml, '/ExtendedPrivilege/@id')[1]::BIGINT as EP_ID,
    -- xml_unescape/ws_restore — identisch zur DOM-Basis (Begründung dort).
    xml_unescape(xml_extract_text(priv_xml, '/ExtendedPrivilege/@name')[1]) as EP_Name,
    ws_restore(xml_extract_text(priv_xml, '/ExtendedPrivilege/Description/text()')[1]) as EP_Description,
    xml_extract_text(priv_xml, '/ExtendedPrivilege/UUID/text()')[1] as EP_UUID,

    -- Array of PrivilegeSet IDs und Namen
    list(xml_extract_text(ps_xml, '/PrivilegeSetReference/@id')[1]::BIGINT) as PrivilegeSet_IDs,
    list(xml_extract_text(ps_xml, '/PrivilegeSetReference/@name')[1]) as PrivilegeSet_Names,

    fn.File_Name as File_Name

FROM raw_privileges
CROSS JOIN filename_normalized fn
LEFT JOIN LATERAL (
    SELECT unnest(xml_extract_elements(priv_xml, '//ObjectList/PrivilegeSetReference')) as ps_xml
) ps ON true
GROUP BY EP_ID, EP_Name, EP_Description, EP_UUID, fn.File_Name
ON CONFLICT (EP_UUID, File_Name) DO UPDATE SET
    EP_ID = EXCLUDED.EP_ID,
    EP_Name = EXCLUDED.EP_Name,
    EP_Description = EXCLUDED.EP_Description,
    PrivilegeSet_IDs = EXCLUDED.PrivilegeSet_IDs,
    PrivilegeSet_Names = EXCLUDED.PrivilegeSet_Names;
