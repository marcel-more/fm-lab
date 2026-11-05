import { API_BASE } from '../config/apiBase';

/**
 * Maintenance-API-Client — workspace housekeeping, independent of the
 * selected solution: the cleanup routines that move dashboards, queries and
 * tests left over from an older template layout. Plain fetch like the rest of
 * the frontend.
 */

const API = `${API_BASE}/api`;

/** Routine = template kind; one lock per routine on the server. */
export type CleanupKind = 'dashboards' | 'tests';

/**
 * Dashboards: a1–b3 bundles, f1–f4 old query locations (sql-custom/, sql/,
 * sql-custom-details/), f5 foreign file in dashboards/. Tests: t1–t4.
 */
export type CleanupCase =
  | 'a1' | 'a2' | 'a3' | 'b1' | 'b2' | 'b3'
  | 'f1' | 'f2' | 'f3' | 'f4' | 'f5'
  | 't1' | 't2' | 't3' | 't4';

export interface CleanupItem {
  case: CleanupCase;
  /** Relative to rest-api/templates/, e.g. `dashboards-custom/static-code-analysis/…`. */
  from: string;
  to: string;
  /** `custom` = own content moving to the user area; `removed` = moved aside. */
  target: 'custom' | 'removed';
  id: string | null;
  ids: string[];
  /** Old copy that differs from the shipped one — can be left in place. */
  modified: boolean;
  /** Own content whose id or target already exists in the user area. */
  conflict: boolean;
  /** `report_template`: own file from the old `sql/`, now reachable via /api/query. */
  note?: 'report_template' | null;
  /** f1: shipped file the copy was compared with. */
  canonical?: string | null;
  /** Modified old copy: also copied here as an own version before it moves aside. */
  fork?: string;
  /** Id of that own version (`<id>-local`, …). */
  fork_id?: string;
}

export interface CleanupSummary {
  total: number;
  to_custom: number;
  to_removed: number;
  modified: number;
  conflicts: number;
  /** Edited old copies kept as own versions under Custom. */
  forked: number;
}

/** Newest automatic run at server start, read from its cleanup.json. */
export interface CleanupLastRun {
  stamp: string;
  created_at: string | null;
  trigger: 'startup' | 'manual';
  /** Run folder, relative to rest-api/templates/. */
  removed_dir: string;
  summary: CleanupSummary;
  forks: { from: string; fork: string; fork_id: string }[];
}

export interface CleanupPreview {
  /** false = no usable inventory, nothing was classified. */
  inventory: boolean;
  stamp: string;
  items: CleanupItem[];
  summary: CleanupSummary;
  running?: boolean;
  last_startup_run?: CleanupLastRun | null;
  last_update_import?: CleanupUpdateImport | null;
}

/** Newest own versions taken over at server start from a backup of tools/update.sh. */
export interface CleanupUpdateImport {
  stamp: string;
  /** Backup folder, relative to the fm-lab folder (`.fmlab/update-backup/<stamp>`). */
  backup: string;
  forks: { kind: CleanupKind; unit: string; fork: string; fork_id: string }[];
}

export interface CleanupReport {
  inventory: boolean;
  stamp: string;
  moved: CleanupItem[];
  skipped: CleanupItem[];
  errors: { from: string; message: string }[];
  summary: CleanupSummary;
  /** Run folder with cleanup.json, relative to rest-api/templates/; null when nothing moved. */
  removed_dir: string | null;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API}${path}`, init);
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

/** Read-only check for leftovers of an older layout of `kind`. */
export function getCleanup(kind: CleanupKind): Promise<CleanupPreview> {
  return request<CleanupPreview>(`/maintenance/${kind}/cleanup`);
}

/** Runs the cleanup of `kind`; `exclude` = `from` values of the preview to leave in place. */
export function runCleanup(kind: CleanupKind, exclude: string[]): Promise<CleanupReport> {
  return request<CleanupReport>(`/maintenance/${kind}/cleanup`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ exclude }),
  });
}

export const getDashboardCleanup = (): Promise<CleanupPreview> => getCleanup('dashboards');
export const runDashboardCleanup = (exclude: string[]): Promise<CleanupReport> => runCleanup('dashboards', exclude);
