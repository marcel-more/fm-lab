/**
 * Targets of the retired `/query*` routes. Queries are single-file dashboards
 * now; the old links (bookmarks, docs, own dashboards) land on `/dashboard*`
 * for one release cycle.
 *
 * Import-free on purpose: the unit test loads this file directly with Node's
 * type stripping.
 */

/** Old category label → folder path: `Metadata Integrity` → `metadata-integrity`. */
export function categoryToFolderSlug(label: string): string {
  return label.trim().toLowerCase().replace(/\s+/g, '-');
}

/**
 * `/query[?category=<Label>]` → `/dashboard[?folder=<slug>]`. Other params are
 * dropped. `knownFolders` = folder paths of the dashboard overview; a slug
 * outside it lands on the overview root. `null` (folders unknown) keeps the
 * slug — the overview shows its own hint for an unknown folder.
 */
export function queryOverviewTarget(search: URLSearchParams, knownFolders: ReadonlySet<string> | null): string {
  const category = search.get('category');
  if (!category) return '/dashboard';
  const slug = categoryToFolderSlug(category);
  if (!slug || (knownFolders && !knownFolders.has(slug))) return '/dashboard';
  return `/dashboard?folder=${encodeURIComponent(slug)}`;
}

/** `/query/<name>?…` → `/dashboard/<name>?…` with every param except `query`. */
export function queryDetailTarget(name: string, search: URLSearchParams): string {
  const next = new URLSearchParams();
  for (const [k, v] of search.entries()) {
    if (k !== 'query') next.append(k, v);
  }
  const qs = next.toString();
  return `/dashboard/${encodeURIComponent(name)}${qs ? `?${qs}` : ''}`;
}
