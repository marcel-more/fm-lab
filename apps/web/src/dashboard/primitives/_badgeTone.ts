/**
 * Badge value class for the dashboard primitives (Table / KPIStrip /
 * DefinitionList).
 *
 * By default the class is derived from the value itself
 * (`true` → `dash-badge--true`, `partial` → `dash-badge--partial`), which is
 * enough as long as a value carries the same meaning everywhere it appears.
 * It does not for booleans: the file view renders "Encryption: none",
 * "Save credentials: no" and "Hide WebDirect: no" as neutral facts right next
 * to the DDR-info verdict, where the very same "no" is a warning. Colouring
 * `--no` or `--false` globally would therefore light up unrelated rows.
 *
 * A layout can instead declare the tone per value:
 *
 *   { "field": "Has_DDR_INFO", "format": "badge",
 *     "badgeTone": { "true": "ok", "false": "warning" } }
 *
 * The mapped name replaces the value in the class (`dash-badge--warning`), so
 * the tone vocabulary is the one dashboard.css already defines: ok/success,
 * warn/warning, error/bad, partial, none. Unmapped values keep the
 * value-derived class, so declaring a single entry is enough.
 */

export type BadgeTone = Record<string, string>;

export function slugify(s: string): string {
  return s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

export function badgeToneClass(rawValue: unknown, tone?: BadgeTone): string {
  const raw = String(rawValue ?? '');
  // Booleans arrive as `true`/`false`, SQL tokens in their own casing — match
  // the declared key case-insensitively so a layout need not guess.
  const mapped = tone ? (tone[raw] ?? tone[raw.toLowerCase()]) : undefined;
  return `dash-badge--${slugify(mapped ?? raw)}`;
}
