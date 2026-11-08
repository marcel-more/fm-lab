// Scope of a dashboard page as the URL carries it — pure helpers of the
// ScopeNotice primitive (no React, no DOM; unit-tested in tests/scopeNotice.test.ts).
//
// An Analysis Test opens its member dashboards with the scope it ran in:
// `file` (file scope, or the file of an object) and `scope_uuids` (object,
// object list or cluster, as a CSV of Object_UUIDs). The dataset SQL filters on
// both, so the KPIs and lists show only that scope — the notice makes it visible.

/** URL params that narrow a dashboard to a scope. */
export const SCOPE_PARAMS = ['file', 'scope_uuids'] as const;

/** Params that only make sense inside the narrowed view and go with the scope. */
const RESET_WITH_SCOPE = ['page'] as const;

export interface DashboardScope {
  /** File filter, when it is not already visible in a control of the layout. */
  file: string | null;
  /** The scoped objects (deduplicated, order kept). */
  uuids: string[];
}

type ParamSource = Pick<URLSearchParams, 'get'>;

/** Which scope params a dashboard applies, and whether its layout shows the file itself. */
export interface ScopeOptions {
  /** The dataset SQL filters on `file` (default true). */
  fileApplies?: boolean;
  /** The dataset SQL filters on `scope_uuids` (default true). */
  uuidsApply?: boolean;
  /** A Select/FilterChips of the layout drives `file` — the control shows it already. */
  fileShownByControl?: boolean;
}

/**
 * The scope the page is narrowed to, or null when it shows the whole solution.
 * A param the dashboard does not apply is left out: the notice never claims a
 * filter the counts do not follow.
 */
export function deriveScope(params: ParamSource, opts: ScopeOptions = {}): DashboardScope | null {
  const { fileApplies = true, uuidsApply = true, fileShownByControl = false } = opts;
  const rawFile = (params.get('file') ?? '').trim();
  const uuids = uuidsApply
    ? [...new Set((params.get('scope_uuids') ?? '').split(',').map((s) => s.trim()).filter(Boolean))]
    : [];
  const file = rawFile && fileApplies && !fileShownByControl ? rawFile : null;
  if (!file && uuids.length === 0) return null;
  return { file, uuids };
}

interface ManifestLike {
  analysis?: { scope?: { supported?: string[] } } | null;
  params?: Array<{ name?: string }> | null;
}

/**
 * Scope support of a dashboard from its manifest: `scope_uuids` needs an
 * object-like scope (object / object-list / cluster) in `analysis.scope.supported`;
 * `file` counts when the file scope is supported or `file` is a declared param.
 */
export function scopeSupport(manifest: ManifestLike | null | undefined): { fileApplies: boolean; uuidsApply: boolean } {
  const supported = manifest?.analysis?.scope?.supported ?? [];
  const params = (manifest?.params ?? []).map((p) => p?.name);
  return {
    fileApplies: supported.includes('file') || params.includes('file'),
    uuidsApply: supported.some((s) => s === 'object' || s === 'object-list' || s === 'cluster'),
  };
}

/** The search string without the scope (and the page that belongs to it). */
export function withoutScope(search: string): string {
  const next = new URLSearchParams(search);
  for (const k of [...SCOPE_PARAMS, ...RESET_WITH_SCOPE]) next.delete(k);
  return next.toString();
}

interface LayoutLike {
  type?: unknown;
  props?: Record<string, unknown> | null;
  children?: unknown;
  /** The layout document wraps its tree: `{ schemaVersion, root }`. */
  root?: unknown;
}

/** Walks a layout (document or node) depth-first; stops as soon as `test` returns true. */
function someNode(node: unknown, test: (n: LayoutLike) => boolean): boolean {
  if (!node || typeof node !== 'object') return false;
  if (Array.isArray(node)) return node.some((child) => someNode(child, test));
  const n = node as LayoutLike;
  if (test(n)) return true;
  return someNode(n.root, test) || someNode(n.children, test);
}

/** True when a control of the layout drives the URL param `name` (`props.param`). */
export function layoutBindsParam(layout: unknown, name: string): boolean {
  return someNode(layout, (n) => n.props?.param === name);
}

/** True when the layout places the ScopeNotice itself (the host then adds none). */
export function layoutHasScopeNotice(layout: unknown): boolean {
  return someNode(layout, (n) => n.type === 'ScopeNotice');
}
