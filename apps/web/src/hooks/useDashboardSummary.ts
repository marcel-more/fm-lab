import { useEffect, useSyncExternalStore } from 'react';
import type { ResultEnvelope } from '../api/resultsApi';
import {
  ensureSummaryLoaded, getCachedSummary, getResultsStoreVersion,
  isFolderRunning, isRefRunning, runDashboards, runFolder, runSingle, subscribeResultsStore,
} from '../lib/resultsStore';

/**
 * Result envelopes for the dashboard overview chips — consumed by TileGrid
 * without prop drilling (useSyncExternalStore over the resultsStore).
 *
 * Loads asynchronously AFTER the bundle load: tiles render immediately,
 * chips appear once the summary map is here (the map itself is a pure server
 * cache read, so this is always cheap; actual runs are explicit triggers).
 */
export interface DashboardSummary {
  /** kind:id → envelope, or null while nothing is loaded yet. */
  results: Record<string, ResultEnvelope> | null;
  fingerprint: string | null;
  envelopeFor: (kind: string, id: string) => ResultEnvelope | undefined;
  isFolderRunning: (path: string) => boolean;
  isRefRunning: (kind: string, id: string) => boolean;
  runFolder: typeof runFolder;
  runSingle: typeof runSingle;
  runDashboards: typeof runDashboards;
  refresh: () => Promise<void>;
}

export function useDashboardSummary(enabled = true): DashboardSummary {
  useSyncExternalStore(subscribeResultsStore, getResultsStoreVersion);
  const entry = enabled ? getCachedSummary() : null;

  useEffect(() => {
    if (!enabled) return;
    // Always re-fetch on mount (deduped, pure server-cache read): the stored
    // entry gives the instant first paint, the response's catalogFingerprint
    // implicitly drops a stale generation after a mid-session re-import.
    void ensureSummaryLoaded(true);
  }, [enabled]);

  const results = entry?.results ?? null;
  return {
    results,
    fingerprint: entry?.fingerprint ?? null,
    envelopeFor: (kind, id) => (results ? results[`${kind}:${id}`] : undefined),
    isFolderRunning,
    isRefRunning,
    runFolder,
    runSingle,
    runDashboards,
    refresh: () => ensureSummaryLoaded(true),
  };
}
