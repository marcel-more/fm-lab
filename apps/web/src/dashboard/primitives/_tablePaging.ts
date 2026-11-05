/**
 * Client-side paging and keyboard navigation of the `Table` primitive — the
 * page-size options, the auto default above a row threshold, page clamping and
 * the focus moves across page boundaries.
 *
 * Runtime-import-free on purpose (see `_folderTree.ts`): the unit tests run it
 * on Node without the React/Vite stack.
 */

/** A page size: a row count, or every row on one page. */
export type PageSize = number | 'all';

/** The page-size options of a layout, invalid entries dropped, duplicates removed. */
export function normalizePageSizeOptions(raw: unknown): PageSize[] {
  if (!Array.isArray(raw)) return [];
  const out: PageSize[] = [];
  for (const v of raw) {
    const size: PageSize | null = v === 'all'
      ? 'all'
      : typeof v === 'number' && Number.isInteger(v) && v > 0 ? v : null;
    if (size != null && !out.includes(size)) out.push(size);
  }
  return out;
}

/** The smallest row-count option — below it a page-size choice changes nothing. */
export function smallestPageSize(options: readonly PageSize[]): number | null {
  const counts = options.filter((o): o is number => o !== 'all');
  return counts.length > 0 ? Math.min(...counts) : null;
}

/**
 * The effective page size. An explicit choice of the user wins when it is
 * still an option; otherwise the layout default applies. `'auto'` means every
 * row while the rows stay within `threshold`, else the largest row-count
 * option not above the threshold (the threshold itself when it is one).
 */
export function resolvePageSize(input: {
  total: number;
  options: readonly PageSize[];
  defaultSize?: PageSize | 'auto';
  threshold?: number;
  explicit?: PageSize | null;
}): PageSize {
  const { total, options, explicit } = input;
  if (options.length === 0) return 'all';
  if (explicit != null && options.includes(explicit)) return explicit;
  const fallback = options.includes('all') ? 'all' : options[0];
  const def = input.defaultSize ?? 'all';
  if (def !== 'auto') return options.includes(def) ? def : fallback;
  const threshold = input.threshold ?? 100;
  if (total <= threshold) return fallback;
  const fitting = options.filter((o): o is number => o !== 'all' && o <= threshold);
  if (fitting.length > 0) return Math.max(...fitting);
  return smallestPageSize(options) ?? fallback;
}

/** Rows per page as a number — `'all'` covers the whole set (at least 1). */
export function rowsPerPage(size: PageSize, total: number): number {
  return size === 'all' ? Math.max(1, total) : size;
}

export function pageCountOf(total: number, size: PageSize): number {
  return Math.max(1, Math.ceil(total / rowsPerPage(size, total)));
}

/** The page within 1…pageCount; a shrunk set lands on its last page. */
export function clampPage(page: number, total: number, size: PageSize): number {
  if (!Number.isFinite(page)) return 1;
  return Math.min(Math.max(1, Math.floor(page)), pageCountOf(total, size));
}

/** 1-based page that holds the row at `index` (0-based, in the whole set). */
export function pageOfIndex(index: number, total: number, size: PageSize): number {
  return Math.floor(Math.max(0, index) / rowsPerPage(size, total)) + 1;
}

/** Index range [start, end) of a page in the whole set. */
export function pageWindow(page: number, total: number, size: PageSize): { start: number; end: number } {
  const per = rowsPerPage(size, total);
  const start = (clampPage(page, total, size) - 1) * per;
  return { start, end: Math.min(total, start + per) };
}

/** Keys the row navigation handles; Enter is the caller's (it opens the row). */
export type NavKey = 'ArrowDown' | 'ArrowUp' | 'Home' | 'End' | 'PageDown' | 'PageUp';

export function isNavKey(key: string): key is NavKey {
  return key === 'ArrowDown' || key === 'ArrowUp' || key === 'Home'
    || key === 'End' || key === 'PageDown' || key === 'PageUp';
}

/**
 * The row index (0-based, in the whole set) a key moves the focus to — the
 * current index where the key has nothing to do (an arrow at either end of the
 * set, PageDown on the last page), `null` only for an empty set. Arrows cross
 * page boundaries (the caller turns the page); Home/End stay on the current
 * page; PageDown/PageUp turn the page and keep the position, clamped on a
 * shorter last page.
 */
export function nextFocus(index: number, key: NavKey, total: number, size: PageSize): number | null {
  if (total <= 0) return null;
  const current = Math.min(Math.max(0, index), total - 1);
  const per = rowsPerPage(size, total);
  const pageStart = Math.floor(current / per) * per;
  const pageEnd = Math.min(total, pageStart + per) - 1;
  let next: number;
  switch (key) {
    case 'ArrowDown': next = current + 1; break;
    case 'ArrowUp': next = current - 1; break;
    case 'Home': next = pageStart; break;
    case 'End': next = pageEnd; break;
    case 'PageDown':
      next = pageStart + per >= total ? current : Math.min(current + per, total - 1);
      break;
    case 'PageUp':
      next = pageStart === 0 ? current : current - per;
      break;
  }
  return Math.min(Math.max(0, next), total - 1);
}
