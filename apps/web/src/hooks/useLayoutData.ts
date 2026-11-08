import { useEffect, useRef, useState } from 'react';
import { fetchTemplateQuery } from '../api/templateApi';

export type LayoutObject = {
  object_uuid: string;
  object_id: number;
  object_type: string;
  object_name: string | null;
  text_content: string | null;
  abs_top: number;
  abs_left: number;
  abs_bottom: number;
  abs_right: number;
  nesting_level: number;
  z_order: number | null;
  parent_object_id: number | null;
  part_type: string | null;
  /** Assigned layout part (catalog schema 1.39.0); null on older catalogs → lib/layoutParts fallback. */
  part_seq?: number | null;
  part_kind?: number | null;
  hide_text: string | null;
  tooltip_text: string | null;
  label_calc_text: string | null;
  /** Regel-genaue CF-Anzahl aus LayoutObjectConditions (selbstverankert). */
  cf_count: number;
  /** Anzahl Script-Trigger + vollständige Event-Liste (','-getrennt, Slot-Reihenfolge). */
  trigger_count: number;
  trigger_events: string | null;
  /** Anzahl Layout-Calculation-Instanzen (<<ƒ:…>>, Rolle display_calculation). */
  display_calc_count: number;
  /** Belegte typspezifische Slot-Rollen (','-getrennt, z.B. 'placeholder,portal_filter'). */
  other_calc_roles: string | null;
  /** Anzahl triggers_script-Links (für „+n weitere" in der Tooltip-Ziel-Zeile). */
  script_count: number;
  field_uuid: string | null;
  field_name: string | null;
  script_uuid: string | null;
  script_name: string | null;
  /** Go-to-Layout-Ziel (Buttons ohne Script) — abgeleitetes Modifier-Ziel. */
  nav_layout_uuid: string | null;
  nav_layout_name: string | null;
  /** Portal-TableOccurrence (portal_context) — abgeleitetes Modifier-Ziel. */
  portal_to_uuid: string | null;
  portal_to_name: string | null;
};

export type LayoutPart = {
  /** Identity of the part within its layout (several sub-summaries of one kind stay distinct). */
  part_seq: number | null;
  /** Catalog UUID `part_<Layout_ID>_<Part_Kind>_<Part_Seq>_<File_Name>` (detail view). */
  part_uuid: string | null;
  part_type: string;
  part_kind: number;
  part_size: number;
  part_absolute: number;
  object_count: number;
  part_name?: string | null;
  /** Break field of a sub-summary (kind 3/5); uuid/file from the breaks_on_field edge. */
  break_field_name?: string | null;
  break_field_uuid?: string | null;
  break_field_file?: string | null;
  break_to_name?: string | null;
  layout_name: string;
  layout_uuid: string;
  layout_to_name: string | null;
  file_name: string;
};

/**
 * Single-row layout metadata from `display_layout_meta` (Schema 1.8.0 view columns
 * + context TO / theme / menu set / width). Used by the layout detail properties
 * panel next to the canvas. `null` when the template yields no row.
 */
export type LayoutMeta = {
  layout_name: string;
  layout_uuid: string;
  file_name: string;
  to_name: string | null;
  to_uuid: string | null;
  width: number | null;
  theme_id: number | null;
  theme_name: string | null;
  theme_display: string | null;
  theme_uuid: string | null;
  theme_base: string | null;
  menuset_name: string | null;
  options_raw: number | null;
  view_form_available: boolean | null;
  view_list_available: boolean | null;
  view_table_available: boolean | null;
  default_view: 'Form' | 'List' | 'Table' | null;
  // „Allgemein"-Optionen (aus dem <Options>-Bitfeld); null bei Ordnern/Trennern.
  auto_save_changes: boolean | null;
  show_field_frames: boolean | null;
  frame_current_record_only: boolean | null;
  show_current_record_list: boolean | null;
  quick_find_enabled: boolean | null;
  is_hidden: boolean | null;
};

/**
 * Ein Layout-Ebene Script-Trigger (Tab „Script-Trigger" der Layouteinstellung).
 * `trigger_action` ist der kanonische (englische) Enum-Name; das Frontend lokalisiert.
 */
export type LayoutTrigger = {
  trigger_id: number;
  trigger_action: string;
  browse_mode: boolean;
  find_mode: boolean;
  preview_mode: boolean;
  script_id: number | null;
  script_name: string | null;
  script_uuid: string | null;
  /** Synthetische Katalog-UUID des ScriptTrigger-Objekts (`trig_<id>_…`);
   *  optional, damit ältere API-Stände den Client nicht brechen. */
  trigger_uuid?: string | null;
  file_name: string;
};

export type LayoutData = {
  objects: LayoutObject[];
  parts: LayoutPart[];
  layoutName: string;
  layoutToName: string | null;
  fileName: string;
  meta: LayoutMeta | null;
  triggers: LayoutTrigger[];
};

type Result = {
  data: LayoutData | null;
  loading: boolean;
  error: string | null;
};

// Key = `${uuid}::${file ?? ''}` — Klon-Disambiguierung (siehe useObjectDetail).
const cache = new Map<string, LayoutData>();

/**
 * Lädt Layout-Objekte und Layout-Parts parallel über die beiden Custom-SQL-Templates
 * `display_layout_objects_data` und `display_layout_parts_data`. Cached pro (UUID, File).
 *
 * `file` (Klon-Disambiguierung): wird in den Cache-Key aufgenommen und an die
 * Templates durchgereicht. Die Layout-Templates skopieren heute noch bare-UUID
 * (gated Follow-up); der Param ist vorwärtskompatibel und schadet nicht
 * (ungenutzte Template-Variable). Der Cache-Key verhindert sofort, dass zwei
 * Klon-Layouts denselben Eintrag teilen.
 */
export function useLayoutData(uuid: string | undefined, file?: string | null): Result {
  const [data, setData] = useState<LayoutData | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const lastUuidRef = useRef<string | undefined>(undefined);

  useEffect(() => {
    if (!uuid) {
      setData(null);
      setError(null);
      setLoading(false);
      return;
    }

    const cacheKey = `${uuid}::${file ?? ''}`;
    const cached = cache.get(cacheKey);
    if (cached) {
      setData(cached);
      setError(null);
      setLoading(false);
      lastUuidRef.current = uuid;
      return;
    }

    let cancelled = false;
    lastUuidRef.current = uuid;
    setLoading(true);
    setError(null);

    const params: Record<string, string> = { uuid };
    if (file) params.file = file;
    Promise.all([
      fetchTemplateQuery('display_layout_objects_data', params),
      fetchTemplateQuery('display_layout_parts_data', params),
      fetchTemplateQuery('display_layout_meta', params),
      fetchTemplateQuery('display_layout_triggers', params),
    ])
      .then(([objectsRes, partsRes, metaRes, triggersRes]) => {
        if (cancelled) return;
        const objects = (objectsRes.data as unknown as LayoutObject[]) ?? [];
        const parts = (partsRes.data as unknown as LayoutPart[]) ?? [];
        const meta = ((metaRes.data as unknown as LayoutMeta[]) ?? [])[0] ?? null;
        const triggers = (triggersRes.data as unknown as LayoutTrigger[]) ?? [];
        const first = parts[0];
        const layoutData: LayoutData = {
          objects,
          parts,
          layoutName: first?.layout_name ?? meta?.layout_name ?? '',
          layoutToName: first?.layout_to_name ?? meta?.to_name ?? null,
          fileName: first?.file_name ?? meta?.file_name ?? '',
          meta,
          triggers,
        };
        cache.set(cacheKey, layoutData);
        setData(layoutData);
      })
      .catch(err => {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : 'Failed to load layout');
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [uuid, file]);

  return { data, loading, error };
}
