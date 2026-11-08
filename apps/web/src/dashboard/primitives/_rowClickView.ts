/**
 * Table option `keepViewOnRowClick`: a row click that navigates to the SAME
 * dashboard (master-detail selection) keeps the list as the user arranged it —
 * search term, sort and page of THIS table.
 *
 * `openDashboard` rebuilds the query string from the click args plus the
 * sticky params, so without this the list falls back to page 1, default order
 * and no search, and the selected row is often no longer on screen. Values the
 * click args set themselves win; empty view values are left out.
 */

interface ClickSpec {
  action: string;
  args?: Record<string, unknown>;
}

/** Dashboard id of a `/dashboard/<id>` path, '' for any other path. */
export function dashboardIdFromPath(pathname: string): string {
  const parts = pathname.split('/').filter(Boolean);
  if (parts.length < 2 || parts[0] !== 'dashboard') return '';
  try {
    return decodeURIComponent(parts[parts.length - 1]);
  } catch {
    return parts[parts.length - 1];
  }
}

export function withListView<T extends ClickSpec>(
  spec: T,
  view: Record<string, string | null | undefined>,
  currentDashboardId: string,
): T {
  if (spec.action !== 'openDashboard' || !spec.args) return spec;
  if (!currentDashboardId || String(spec.args.id ?? '') !== currentDashboardId) return spec;
  const extra = Object.entries(view).filter(([, v]) => v != null && v !== '') as [string, string][];
  if (extra.length === 0) return spec;
  const nested = spec.args.params;
  if (nested && typeof nested === 'object') {
    const params = { ...(nested as Record<string, unknown>) };
    for (const [k, v] of extra) if (!(k in params)) params[k] = v;
    return { ...spec, args: { ...spec.args, params } };
  }
  // Flat form: every arg except `id` is a query param.
  const args = { ...spec.args };
  for (const [k, v] of extra) if (k !== 'id' && !(k in args)) args[k] = v;
  return { ...spec, args };
}
