import { API_BASE } from '../config/apiBase';

/**
 * Analysis-Tests API client (GET /api/tests…).
 * Mirrors the response shapes of tests.controller / tests.service.
 */

const API = `${API_BASE}/api`;

export interface TestValidationIssue {
  rule: string;
  message: string;
}

export interface TestValidation {
  status: 'ok' | 'warnings' | 'errors';
  errors: TestValidationIssue[];
  warnings: TestValidationIssue[];
}

export interface TestProfileSummary {
  id: string;
  title: string;
  description: string | null;
  memberCount: number;
  /** Member refs the profile covers; null = no `members` field = all members. */
  members?: string[] | null;
}

export interface TestListItem {
  id: string;
  title: string;
  description: string | null;
  testType: string;
  keywords: string[];
  objectTypes: string[];
  scopes: string[];
  outputs: string[];
  memberCount: number;
  profiles: TestProfileSummary[];
  folder: string | null;
  folder_label?: string | null;
  /**
   * Tier rubric split into crumbs — partial path + localized label per segment.
   * Same cascade as `folder_label`, but navigable: only the detail endpoint
   * fills it (the list rows carry the joined label).
   */
  folder_crumbs?: Array<{ path: string; label: string }>;
  folder_order?: number;
  tier: 'system' | 'custom';
  overridesSystem: boolean;
  version: string | null;
  validation: TestValidation;
}

export interface TestMemberSummary {
  kind: 'dashboard' | 'query';
  ref: string;
  title?: string;
  icon?: string | null;
  severity?: string | null;
  resolved: boolean;
  analysis?: unknown;
}

export interface TestDetail extends TestListItem {
  members: TestMemberSummary[];
}

export interface TestRunDefaultResult {
  type: 'number' | 'boolean' | 'text';
  name: string;
  meaning: string | null;
  value: unknown;
}

export interface TestRunFinding {
  severity?: string;
  file_name?: string;
  nav_uuid?: string;
  script_name?: string;
  step_no?: number;
  step_uuid?: string;
  message?: string;
  [key: string]: unknown;
}

/** Two-axis state model, derived server-side. */
export type TestRunStatus = 'ran' | 'failed' | 'skipped';
export type TestResultState = 'error' | 'warning' | 'neutral' | 'ok' | 'skipped';

export interface TestRunSummary {
  error: number;
  warning: number;
  neutral: number;
  ok: number;
  skipped: number;
  failed: number;
}

/**
 * Declarative row-click action of the member's findings table, verbatim from
 * the bundle's layout.json (`{{column}}` tokens unresolved) — structurally an
 * ActionSpec for the dashboard action dispatcher.
 */
export interface TestRowAction {
  action: string;
  args?: Record<string, unknown>;
  argsString?: string;
}

export interface TestRunMemberResult {
  kind: 'dashboard' | 'query';
  ref: string;
  title?: string;
  /** Deprecated alias of runStatus (ok=ran, error=failed) — kept for compat. */
  status: 'ok' | 'error' | 'skipped';
  runStatus: TestRunStatus;
  resultState?: TestResultState;
  skipReason?: string;
  /** Human-readable reason for a skip (server-side, English). */
  skipMessage?: string;
  severity?: string | null;
  defaultResult?: TestRunDefaultResult;
  findings?: { truncated: boolean; rows: TestRunFinding[] };
  rowAction?: TestRowAction;
  openTarget: string;
  error?: string;
}

export interface TestRunResult {
  test: { id: string; title: string; testType: string };
  context: Record<string, unknown> & { scope: string };
  results: TestRunMemberResult[];
  summary: TestRunSummary;
  meta: {
    durationMs: number;
    lang?: string;
    solution?: string | null;
    catalogFingerprint?: string | null;
    catalogMtimeMs?: number | null;
  };
}

/** Cache-key context of the effective solution. */
export interface TestsContext {
  solution: string | null;
  catalogFingerprint: string | null;
  catalogMtimeMs: number | null;
}

export interface TestRunScopeParams {
  uuid?: string;
  uuids?: string;
  file?: string;
  cluster?: string;
  object_type?: string;
  include?: 'findings';
  findingsLimit?: number;
  profile?: string;
}

function buildQuery(params?: Record<string, unknown>): string {
  if (!params) return '';
  const usp = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v == null || v === '') continue;
    usp.set(k, String(v));
  }
  const s = usp.toString();
  return s ? `?${s}` : '';
}

async function getJson<T>(path: string): Promise<T> {
  const res = await fetch(`${API}${path}`);
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

export async function listTests(
  filters?: { objectType?: string; testType?: string; scope?: string; q?: string; folder?: string },
  lang?: string,
): Promise<TestListItem[]> {
  return getJson<TestListItem[]>(`/tests${buildQuery({ ...(filters || {}), lang })}`);
}

export async function getTestsContext(): Promise<TestsContext> {
  return getJson<TestsContext>('/tests/context');
}

export async function getTest(id: string, lang?: string): Promise<TestDetail> {
  return getJson<TestDetail>(`/tests/${encodeURIComponent(id)}${buildQuery(lang ? { lang } : undefined)}`);
}

export async function runTest(id: string, params: TestRunScopeParams, lang?: string): Promise<TestRunResult> {
  return getJson<TestRunResult>(
    `/tests/${encodeURIComponent(id)}/run${buildQuery({ ...params, lang })}`,
  );
}

export async function runTestMember(
  id: string,
  memberIndex: number,
  params: TestRunScopeParams,
  lang?: string,
): Promise<TestRunResult> {
  return getJson<TestRunResult>(
    `/tests/${encodeURIComponent(id)}/run/${memberIndex}${buildQuery({ ...params, lang })}`,
  );
}
