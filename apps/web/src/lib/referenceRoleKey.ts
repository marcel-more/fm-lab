/**
 * Chip/filter identity of a reference row in the references tab (URL param
 * `roles=`), shared by the tab itself and by views that deep-link into it.
 */

/**
 * Curated chip vocabulary: only these slot classes form chips of their own
 * (mirror of the i18n dictionary keys `hierarchyTree.subroles.*`).
 * `Subrole_Class` is a deliberate raw pass-through on the API side ("nothing
 * unknown is ever swallowed") — instance-bound values (trigger events, part
 * names, slot indices like `script_trigger_parameter:12`) would otherwise
 * coin one filter chip per instance (cardinality 1 = a pointless filter
 * dimension).
 */
export const CURATED_CHIP_CLASSES = new Set([
  'active_segment', 'auto_enter', 'button_action', 'conditional_format', 'hide', 'mbs_runscript',
  'menu_action', 'menu_install', 'on_server', 'placeholder', 'popover_title', 'portal_filter',
  'script_trigger_parameter', 'tooltip', 'transaction_parameter_field',
  'validation', 'web_viewer_url',
  // Usage categories of a table occurrence (role uses_table_occurrence, read
  // from v_table_occurrence_usage): one chip each, e.g. "uses_table_occurrence · Step".
  'calculation', 'calc_context', 'layout_field', 'layout_part', 'script_step',
  'security', 'table_view', 'value_list',
  // TO::Field found in the formula text of a file without DDR info.
  'calculation_text',
]);

/**
 * Role and (optionally) slot class as ONE unit (`reads_field~conditional_format`).
 * Tilde as separator — collision-free with role/class keys and URL-safe. The
 * class is normalised for the chip identity: numeric instance suffix stripped
 * (`:12`), then only curated classes form their own chip — everything else
 * falls back to the bare role chip.
 */
export function referenceRoleKey(linkRole: string, subroleClass?: string | null): string {
  const cls = subroleClass ? subroleClass.replace(/:\d+$/, '') : null;
  if (cls && linkRole === LAYOUT_PART_MEMBER_ROLE) return `${linkRole}~${cls}`;
  return cls && CURATED_CHIP_CLASSES.has(cls) ? `${linkRole}~${cls}` : linkRole;
}

/**
 * Role of the objects of a layout part (read path, from LayoutObjects.Part_Seq —
 * no edge of its own). Its class is the layout-object type ("Edit Box"), a small
 * closed vocabulary → one chip per type.
 */
export const LAYOUT_PART_MEMBER_ROLE = 'parent_part';

/** Role of the usages a table occurrence gets without an edge of its own. */
export const TABLE_OCCURRENCE_USAGE_ROLE = 'uses_table_occurrence';
