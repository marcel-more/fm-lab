/**
 * Pure helpers for layout parts (sections) — no React, no i18n instance.
 *
 * - Part names follow the FileMaker "Part Definition" dialog and are keyed by
 *   `part_kind` (the export's `@type` is localized and FileMaker ≤ 22 mislabels
 *   kind 5). Sub-summaries (kind 3 leading / 5 trailing) share one dialog term;
 *   the list adds the break field and the position (leading/trailing) so several
 *   sub-summaries of one layout stay distinguishable.
 * - Object → part: the catalog carries `part_seq` (schema 1.39.0). For older
 *   catalogs (`part_seq` NULL) the same rule runs here: a root object belongs to
 *   the part whose band [part_absolute, part_absolute + part_size) contains its
 *   top edge; nested objects inherit the part of their parent.
 * - Part options: dialog options O1–O5 are bits of `Definition/@Options`
 *   (bit 0, 1, 2, 6, 8); bits 7/10 are no dialog options and are not decoded.
 */

/** Minimal shape of a part row (display_layout_parts_data). */
export interface PartLike {
  part_seq?: number | null;
  part_kind: number;
  part_absolute: number;
  part_size: number;
  break_field_name?: string | null;
}

/** Minimal shape of an object row (display_layout_objects_data). */
export interface ObjectLike {
  object_uuid: string;
  object_id: number;
  abs_top: number;
  parent_object_id: number | null;
  nesting_level?: number;
  part_seq?: number | null;
}

/** Kinds FileMaker exports (9–11 are unassigned). */
export const PART_KINDS = [12, 0, 1, 2, 3, 4, 5, 6, 7, 8, 13] as const;

export const SUB_SUMMARY_KINDS = new Set([3, 5]);
export const BODY_KIND = 4;

/** i18n key of a part kind's dialog term (`detail:layoutParts.kind.<n>`). */
export function partKindKey(kind: number): string {
  // Leading and trailing sub-summary share the dialog term.
  const k = kind === 5 ? 3 : kind;
  return `detail:layoutParts.kind.${k}`;
}

/** Position qualifier of a sub-summary; null for every other kind. */
export function subSummaryPosition(kind: number): 'leading' | 'trailing' | null {
  if (kind === 3) return 'leading';
  if (kind === 5) return 'trailing';
  return null;
}

/** Minimal i18next `t` contract (keeps this module free of i18next types). */
export type PartTranslate = (key: string, opts?: Record<string, unknown>) => string;
type Translate = PartTranslate;

/**
 * Display label of a part: dialog term; for sub-summaries additionally the break
 * field and the position, e.g. "Sub-summary when sorted by ‹Ship via› (trailing)".
 * Unknown kinds fall back to the canonical `part_type`.
 */
export function partLabel(
  t: Translate,
  part: { part_kind: number; part_type?: string | null; break_field_name?: string | null },
): string {
  const fallback = part.part_type ?? `#${part.part_kind}`;
  const base = t(partKindKey(part.part_kind), { defaultValue: fallback });
  const pos = subSummaryPosition(part.part_kind);
  if (!pos) return base;
  const position = t(`detail:layoutParts.position.${pos}`);
  if (part.break_field_name) {
    return t('detail:layoutParts.subSummaryLabel', { kind: base, field: part.break_field_name, position });
  }
  return t('detail:layoutParts.subSummaryLabelNoField', { kind: base, position });
}

/**
 * Compact label for the canvas band: sub-summaries as "‹field› (position)" (the
 * full dialog phrase would cover the objects of a narrow band), otherwise the
 * dialog term of the kind.
 */
export function partBandLabel(
  t: Translate,
  part: { part_kind: number; part_type?: string | null; break_field_name?: string | null },
): string {
  const pos = subSummaryPosition(part.part_kind);
  if (pos && part.break_field_name) {
    return `‹${part.break_field_name}› (${t(`detail:layoutParts.position.${pos}`)})`;
  }
  return partLabel(t, part);
}

/** Part whose band contains `top` (half-open: a top edge on a boundary → lower part). */
export function partAt<P extends PartLike>(parts: P[], top: number): P | null {
  for (const p of parts) {
    if (p.part_absolute <= top && top < p.part_absolute + p.part_size) return p;
  }
  return null;
}

/**
 * Map object_uuid → part_seq. Uses the catalog value where present; otherwise
 * root objects by geometry and nested objects via the parent chain (their
 * bounds are relative to the parent in the catalog — `abs_top` from the API is
 * already absolute, but the parent rule is what FileMaker does and stays exact
 * for objects that overhang their part).
 */
export function assignObjectParts<O extends ObjectLike, P extends PartLike>(
  objects: O[],
  parts: P[],
): Map<string, number | null> {
  const result = new Map<string, number | null>();
  const byId = new Map<number, O>();
  for (const o of objects) byId.set(o.object_id, o);
  const memo = new Map<number, number | null>();

  const resolve = (o: O, depth: number): number | null => {
    if (o.part_seq != null) return o.part_seq;
    const cached = memo.get(o.object_id);
    if (cached !== undefined) return cached;
    let seq: number | null = null;
    const parent = o.parent_object_id != null ? byId.get(o.parent_object_id) : undefined;
    if (parent && depth < 32) {
      seq = resolve(parent, depth + 1);
    } else if (o.parent_object_id == null) {
      seq = partAt(parts, o.abs_top)?.part_seq ?? null;
    }
    memo.set(o.object_id, seq);
    return seq;
  };

  for (const o of objects) result.set(o.object_uuid, resolve(o, 0));
  return result;
}

/** Decoded dialog options O1–O5 (`Definition/@Options`). */
export interface PartOptionFlags {
  pageBreakBefore: boolean;        // O1, bit 0
  pageBreakAfterEvery: boolean;    // O2, bit 1 (n in Part_Break_Every)
  restartPageNumbers: boolean;     // O3, bit 2
  allowBreakAcrossPages: boolean;  // O4, bit 6
  discardRemainder: boolean;       // O5, bit 8 (only together with O4)
}

export function decodePartOptions(options: number | null | undefined): PartOptionFlags {
  const v = options ?? 0;
  return {
    pageBreakBefore: (v & 1) !== 0,
    pageBreakAfterEvery: (v & 2) !== 0,
    restartPageNumbers: (v & 4) !== 0,
    allowBreakAcrossPages: (v & 64) !== 0,
    discardRemainder: (v & 256) !== 0,
  };
}

/** Bits outside the decoded dialog options (shown raw only). */
export function undecodedOptionBits(options: number | null | undefined): number {
  return (options ?? 0) & ~(1 | 2 | 4 | 64 | 256);
}

/** Section key of a `part_…` catalog UUID in a highlight set, else null. */
export function isPartUuid(uuid: string): boolean {
  return uuid.startsWith('part_');
}

/**
 * Kind and sequence of a layout-part catalog key
 * `part_<Layout_ID>_<Part_Kind>_<Part_Seq>_<File_Name>`. The three leading
 * segments are numeric, so the file name (which may contain underscores) never
 * shifts them. null for any other UUID.
 */
export function parsePartKey(uuid: string | null | undefined): { layoutId: number; kind: number; seq: number } | null {
  if (!uuid) return null;
  const m = /^part_(\d+)_(\d+)_(\d+)_/.exec(uuid);
  if (!m) return null;
  return { layoutId: Number(m[1]), kind: Number(m[2]), seq: Number(m[3]) };
}
