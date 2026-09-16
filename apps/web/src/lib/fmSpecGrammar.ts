/**
 * Presentation helpers for the grammar blocks of the fm-spec step view.
 *
 * The reference API returns the grammar tables row by row (one row per
 * binding value, one row per skeleton hull). The rows are the data of
 * record; these helpers only derive a reader-friendly shape from them:
 *
 *   - option labels and enum display texts instead of raw keys / XML values
 *   - `requires`/`excludes` bindings grouped per (element, option) into the
 *     allowed-value set they form together (the reference's own semantics:
 *     several rows for one element and option = the set of values at which
 *     the element exists / is dropped)
 *   - skeleton hulls as the tree they describe (parent/child tags), ordered
 *     like the snippet template
 */
import type {
  StepElementBinding,
  StepOption,
  StepSkeletonElement,
} from '../api/fmSpecApi';

export interface OptionLookup {
  /** "Label (key)" when the option has a display label, the key otherwise. */
  option: (key: string | null | undefined) => string;
  /** Enum display text for an XML value, the XML value when none is curated. */
  value: (key: string | null | undefined, xmlValue: string | null | undefined) => string;
  /** "Label (key) = v1, v2" */
  condition: (key: string | null | undefined, values: Array<string | null | undefined>) => string;
}

export function buildOptionLookup(options: StepOption[] | undefined): OptionLookup {
  const byKey = new Map<string, StepOption>();
  for (const o of options ?? []) {
    if (!byKey.has(o.optionKey)) byKey.set(o.optionKey, o);
  }
  const option = (key: string | null | undefined): string => {
    if (!key) return '';
    const label = byKey.get(key)?.displayLabelEn;
    return label && label !== key ? `${label} (${key})` : key;
  };
  const value = (key: string | null | undefined, xmlValue: string | null | undefined): string => {
    if (xmlValue == null) return '';
    const row = key ? byKey.get(key) : undefined;
    const hit = row?.values.find((v) => v.xmlValue === xmlValue);
    // a display text that is a placeholder of another option ("{calculation}")
    // says nothing on its own — the XML value is the honest spelling then
    if (!hit?.displayTextEn || hit.displayTextEn.includes('{')) return xmlValue;
    // one display text for several states (Account: 'Microsoft Entra ID' =
    // Azure and AzureGroup) — the XML value is what tells them apart
    const shared = row!.values.filter((v) => v.displayTextEn === hit.displayTextEn).length > 1;
    return shared ? `${hit.displayTextEn} (${xmlValue})` : hit.displayTextEn;
  };
  const condition = (key: string | null | undefined, values: Array<string | null | undefined>): string =>
    `${option(key)} = ${values.map((v) => value(key, v)).join(', ')}`;
  return { option, value, condition };
}

export interface BindingGroup {
  coverage?: string | null;
  elementPath: string;
  binding: string;
  optionKey: string | null;
  /** all values of the group, in row order (empty for the option-level kinds) */
  optionValues: string[];
  evidence: string | null;
  verifiedVersion: string | null;
}

/**
 * Group value-bound rows (`requires`, `excludes`) per element, option and
 * coverage; the option-level kinds stay one group per row. Order = first
 * appearance in the row list.
 */
export function groupBindings(rows: StepElementBinding[] | undefined): BindingGroup[] {
  const groups: BindingGroup[] = [];
  const index = new Map<string, BindingGroup>();
  for (const b of rows ?? []) {
    const valueBound = b.binding === 'requires' || b.binding === 'excludes';
    const key = valueBound
      ? [b.elementPath, b.binding, b.optionKey ?? '', b.coverage ?? '*'].join(' ')
      : null;
    const existing = key ? index.get(key) : undefined;
    if (existing) {
      if (b.optionValue != null && !existing.optionValues.includes(b.optionValue)) {
        existing.optionValues.push(b.optionValue);
      }
      continue;
    }
    const g: BindingGroup = {
      coverage: b.coverage,
      elementPath: b.elementPath,
      binding: b.binding,
      optionKey: b.optionKey ?? null,
      optionValues: b.optionValue != null ? [b.optionValue] : [],
      evidence: b.evidence,
      verifiedVersion: b.verifiedVersion,
    };
    groups.push(g);
    if (key) index.set(key, g);
  }
  return groups;
}

export interface HullNode {
  row: StepSkeletonElement;
  /** true when the parent is neither `Step` nor another hull row (rendered with an "in <parent>" prefix) */
  orphan: boolean;
  children: HullNode[];
}

/** First position of a tag's opening in the template; unknown tags sort last. */
function templateIndex(template: string | null | undefined, tag: string): number {
  if (!template) return Number.MAX_SAFE_INTEGER;
  const i = template.search(new RegExp(`<${tag}[\\s>/]`));
  return i < 0 ? Number.MAX_SAFE_INTEGER : i;
}

/**
 * The hull rows as a tree: children of `Step` are roots, a row whose parent
 * tag is another row's child tag hangs below it, everything else is an
 * orphan root (its parent lives in the template only). Siblings follow the
 * template order.
 */
export function buildHullTree(
  rows: StepSkeletonElement[] | undefined,
  template: string | null | undefined,
): HullNode[] {
  const list = rows ?? [];
  const hullTags = new Set(list.map((r) => r.childTag));
  const byParent = new Map<string, StepSkeletonElement[]>();
  for (const r of list) {
    const parent = r.parentTag === 'Step' || hullTags.has(r.parentTag) ? r.parentTag : 'Step';
    const bucket = byParent.get(parent) ?? [];
    bucket.push(r);
    byParent.set(parent, bucket);
  }
  const sortRows = (a: StepSkeletonElement, b: StepSkeletonElement): number =>
    templateIndex(template, a.childTag) - templateIndex(template, b.childTag)
    || a.childTag.localeCompare(b.childTag);
  const build = (parent: string, depth: number): HullNode[] => {
    if (depth > 8) return []; // defensive: a cyclic parent/child pair must not loop
    return (byParent.get(parent) ?? []).slice().sort(sortRows).map((row) => ({
      row,
      orphan: row.parentTag !== 'Step' && !hullTags.has(row.parentTag),
      children: build(row.childTag, depth + 1),
    }));
  };
  return build('Step', 0);
}
