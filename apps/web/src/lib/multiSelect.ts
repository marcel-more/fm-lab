/**
 * Selection logic of the multi-select popover (components/MultiSelectPopover):
 * reading a delimited URL value, keeping a canonical order, toggling one value
 * and the caption of the trigger. Pure functions, no React — tested with
 * `npm test` in apps/web.
 */

/** Values of a delimited param (`a|b`), empty parts dropped. */
export function parseSelection(raw: string | null | undefined, separator: string): string[] {
  if (!raw) return [];
  return raw.split(separator).filter(v => v !== '');
}

/**
 * Canonical order of a selection: the order of the options first, then values
 * the options do not list, in their own order (a deep link must not lose them
 * silently). Duplicates are dropped.
 */
export function orderSelection(optionValues: readonly string[], values: readonly string[]): string[] {
  const chosen = new Set(values);
  const known = optionValues.filter(v => chosen.has(v));
  const listed = new Set(optionValues);
  const unknown = [...new Set(values)].filter(v => !listed.has(v));
  return [...new Set([...known, ...unknown])];
}

/** The selection with `value` added or removed. */
export function toggleSelection(selected: readonly string[], value: string): string[] {
  return selected.includes(value) ? selected.filter(v => v !== value) : [...selected, value];
}

export interface SelectionSummary {
  /** Caption of the trigger. */
  text: string;
  /** Tooltip of the trigger: every chosen label when the caption only counts them. */
  title?: string;
}

/**
 * Caption of the trigger: the empty label when nothing is chosen, one or two
 * labels, or a count from three on (then the labels go into the tooltip).
 */
export function selectionSummary(
  selected: readonly string[],
  labelOf: (value: string) => string,
  emptyLabel: string,
  countLabel: (count: number) => string,
): SelectionSummary {
  if (selected.length === 0) return { text: emptyLabel };
  const labels = selected.map(labelOf);
  if (selected.length <= 2) return { text: labels.join(', ') };
  return { text: countLabel(selected.length), title: labels.join(', ') };
}
