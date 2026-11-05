import { API_BASE } from '../config/apiBase';
import { isConnectionError } from '../lib/netErrors';
/**
 * Dashboard-API-Client.
 * Verwendet plain fetch wie der Rest des Frontends — kein react-query.
 */

const baseUrl = API_BASE;
const API = `${baseUrl}/api`;

export interface DashboardListItem {
  id: string;
  title: string;
  description: string | null;
  icon: string | null;
  tags: string[];
  category: string | null;
  /** Relative folder path (without the bundle id), null = root. Drives the grouped navigation. */
  folder: string | null;
  /** Localized display path of `folder` (folder.json locales layer), null = root. */
  folder_label: string | null;
  author: string | null;
  version: string | null;
}

export interface DashboardDatasetSpec {
  id: string;
  source: string;
  params?: Record<string, unknown>;
  description?: string;
}

export interface DashboardManifest {
  id: string;
  version?: string;
  title: string;
  description?: string;
  author?: string;
  icon?: string;
  category?: string;
  tags: string[];
  entry: string;
  datasets: DashboardDatasetSpec[];
  params: Array<{
    name: string;
    type: 'string' | 'number' | 'boolean';
    required: boolean;
    default?: unknown;
    description?: string;
    /** Survives openDashboard self-navigation (mode/lens params). */
    sticky?: boolean;
  }>;
  permissions: { read_only: boolean; allow_navigation: boolean };
  /**
   * Message-token catalog for findings context deep links (`ref_msgid` →
   * template with `{name}` placeholders). Localized server-side via the
   * `messages.<key>` manifest overrides in the bundle's locale files.
   */
  messages?: Record<string, string>;
}

/**
 * Declarative visibility guard on a layout node. Reads the first row of a dataset
 * and shows the node only when the condition holds (absent = always visible).
 * Used e.g. to hide the data cards on the home dashboard while the catalog is empty
 * (`db_empty` truthy) so only the "convert your XML" card remains.
 */
export interface VisibleWhen {
  /** Dataset id whose first row is tested. */
  dataset: string;
  /** Field on that row to read. */
  field: string;
  /** Show only when the field strictly equals this value. */
  equals?: unknown;
  /** Show only when the field does NOT strictly equal this value. */
  notEquals?: unknown;
  /** Show only when the field is truthy (`true`) / falsy (`false`). */
  truthy?: boolean;
}

export interface LayoutNode {
  type: string;
  /** Stable anchor for server-side i18n overrides (see dashboard-i18n.service). */
  id?: string;
  props?: Record<string, unknown>;
  data?: { dataset?: string } & Record<string, unknown>;
  children?: LayoutNode[];
  /** Optional declarative visibility guard (absent = always visible). */
  visibleWhen?: VisibleWhen;
}

export interface DashboardLayout {
  schemaVersion: number;
  root: LayoutNode;
}

/** Storage area of a dashboard bundle (server-derived from its directory). */
export type DashboardArea = 'system' | 'module' | 'builtin' | 'custom' | 'community';

/** One folder crumb of a bundle's rubric path — partial path + localized label. */
export interface DashboardNavCrumb {
  path: string;
  label: string;
}

export interface DashboardEnvelope {
  manifest: DashboardManifest;
  layout: DashboardLayout;
  /**
   * Rubric of the bundle (additive since the folder breadcrumb). The route
   * carries only the flat bundle id, so without this the detail view cannot
   * know which folder it sits in. `crumbs` are localized server-side through
   * the same cascade as the overview's folder labels. `area` is the bundle's
   * storage area; custom/community crumbs start with the fixed area level
   * ("Custom"/"Community"), system/module bundles carry no folder at all.
   */
  nav?: {
    area?: DashboardArea;
    /** Content areas only (builtin, custom, community). */
    favoritable?: boolean;
    folder: string | null;
    crumbs: DashboardNavCrumb[];
  };
}

export interface DatasetResult {
  data: Array<Record<string, unknown>>;
  meta: { source: string; [k: string]: unknown };
  error?: string;
  /**
   * Set by the backend when a dataset could not run because nothing has been
   * imported yet (the referenced analysis table/view only exists after import)
   * AND the catalog is empty. Such a "failure" is the empty state, not an
   * error — the DashboardHost gates the whole page on it, individual cards
   * degrade to their empty message. `'no_import'` is the only value today.
   */
  emptyReason?: 'no_import' | string;
}

export type DashboardDataResponse = Record<string, DatasetResult>;

function buildQuery(params: Record<string, unknown> | undefined): string {
  if (!params) return '';
  const usp = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v == null) continue;
    usp.set(k, String(v));
  }
  const s = usp.toString();
  return s ? `?${s}` : '';
}

async function getJsonOnce<T>(path: string, signal?: AbortSignal): Promise<T> {
  const res = await fetch(`${API}${path}`, { signal });
  if (!res.ok) {
    let detail = '';
    try {
      const body = await res.json();
      detail = body?.error?.message ?? '';
    } catch {
      /* ignore */
    }
    throw new Error(`HTTP ${res.status} ${detail || res.statusText}`);
  }
  const body = await res.json();
  if (body?.success === false) {
    throw new Error(body?.error?.message || 'Unknown API error');
  }
  return body.data as T;
}

async function getJson<T>(path: string, signal?: AbortSignal): Promise<T> {
  try {
    return await getJsonOnce<T>(path, signal);
  } catch (err) {
    // Einmal-Retry über den KOMPLETTEN Vorgang (fetch + Body-Read): Stirbt die
    // Verbindung erst während des Downloads, ist `fetch()` längst resolved und
    // erst `res.json()` wirft den Transport-TypeError — den deckt der Request-
    // Phase-Retry in lib/solutionFetch.ts nicht ab. Der retryt seinerseits die
    // Request-Phase bereits einmal → Worst Case 4 Verbindungsversuche pro GET;
    // für die Dev-Workbench akzeptabel, kein Backoff nötig. Aborts nie retryen.
    if (isConnectionError(err) && !signal?.aborted) {
      return await getJsonOnce<T>(path, signal);
    }
    throw err;
  }
}

export async function listDashboards(lang?: string): Promise<DashboardListItem[]> {
  return getJson<DashboardListItem[]>(`/dashboards${buildQuery(lang ? { lang } : undefined)}`);
}

export async function getDashboard(
  id: string,
  lang?: string,
  signal?: AbortSignal,
): Promise<DashboardEnvelope> {
  return getJson<DashboardEnvelope>(
    `/dashboards/${encodeURIComponent(id)}${buildQuery(lang ? { lang } : undefined)}`,
    signal,
  );
}

export async function getDashboardData(
  id: string,
  params?: Record<string, unknown>,
  lang?: string,
  signal?: AbortSignal,
): Promise<DashboardDataResponse> {
  const merged = lang ? { ...(params || {}), lang } : params;
  const wrapper = await getJson<{ datasets: DashboardDataResponse }>(
    `/dashboards/${encodeURIComponent(id)}/data${buildQuery(merged)}`,
    signal,
  );
  return wrapper.datasets;
}

/**
 * Rows of ONE dataset. The endpoint answers `{ success, data: rows, meta }`;
 * `getJson` unwraps `data`, so the result is the row array itself.
 */
export async function getDashboardDataset(
  id: string,
  dataset: string,
  params?: Record<string, unknown>,
  lang?: string,
): Promise<Array<Record<string, unknown>>> {
  const merged = lang ? { ...(params || {}), lang } : params;
  return getJson<Array<Record<string, unknown>>>(
    `/dashboards/${encodeURIComponent(id)}/data/${encodeURIComponent(dataset)}${buildQuery(merged)}`
  );
}
