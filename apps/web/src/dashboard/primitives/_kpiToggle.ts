/**
 * Toggle tiles of a KPIStrip (`items[].toggle: true`).
 *
 * A clickable tile sets filter params through its `onClick` action. A second
 * click on an ACTIVE toggle tile sends the same action with every one of its
 * params emptied instead: an empty value is not preserved by the sticky-param
 * merge, so exactly this tile's filter goes away, while the other sticky
 * filters (set by other tiles) stay. Non-param args (target id, …) are kept.
 */

interface ParamAction {
  args?: Record<string, unknown>;
}

export function withClearedParams<T extends ParamAction>(spec: T): T {
  const params = spec.args?.params;
  if (!params || typeof params !== 'object') return spec;
  const cleared: Record<string, string> = {};
  for (const key of Object.keys(params)) cleared[key] = '';
  return { ...spec, args: { ...spec.args, params: cleared } };
}
