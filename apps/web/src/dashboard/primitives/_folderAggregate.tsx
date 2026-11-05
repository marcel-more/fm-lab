import { displayState, type ResultDisplayState, type ResultEnvelope } from '../../api/resultsApi';
import { addToAggregate, emptyAggregate, mergeAggregate, type FolderAggregate, type ResultFacts } from './_folderTree';

/**
 * Result aggregation shared by the overview's folder views (tiles and the
 * hierarchical list): envelope → facts, folding over a rubric subtree, and
 * the compact state tokens. The fold itself lives in the import-free
 * `_folderTree` so its unit tests run without a bundler.
 */

export { STATE_RANK, emptyAggregate, type FolderAggregate } from './_folderTree';

export const STATE_TOKEN: Record<ResultDisplayState, string> = {
  error: '●', warning: '▲', neutral: '◦', ok: '✓', failed: '⚡', pending: '…',
};
export const FILTERABLE_STATES: ResultDisplayState[] = ['error', 'warning', 'ok', 'neutral', 'pending', 'failed'];

/** Auto-run cap (O7): rubric levels auto-trigger, larger sets stay explicit. */
export const AUTO_RUN_MAX_PENDING = 32;

/**
 * Entry-count meta — two states:
 *   - flat hierarchy (no subfolders):     "(total)"
 *   - nested hierarchy (with subfolders): "direct (total)"
 */
export function formatEntryCount(direct: number, total: number, nested: boolean): string {
  return nested ? `${direct} (${total})` : `(${total})`;
}

/** Reduces an envelope to the facts the folder aggregates and sorts read. */
export function resultFacts(envelope: ResultEnvelope): ResultFacts {
  const ran = envelope.runStatus === 'ran';
  return {
    state: displayState(envelope),
    covered: envelope.runStatus !== 'pending',
    findings: ran && envelope.unit === 'findings' && typeof envelope.value === 'number' ? envelope.value : null,
    value: ran && typeof envelope.value === 'number' ? envelope.value : null,
  };
}

/** Folds a concrete envelope set (e.g. the matches of a collapsed section). */
export function aggregateEnvelopes(envelopes: Iterable<ResultEnvelope>): FolderAggregate {
  const agg = emptyAggregate();
  for (const envelope of envelopes) addToAggregate(agg, resultFacts(envelope));
  return agg;
}

/**
 * Client-side fold of the flat envelope map over one folder subtree
 * (dashboard kind only — queries/tests anchor in their own hierarchies).
 */
export function aggregateFolder(
  results: Record<string, ResultEnvelope> | null,
  path: string,
): FolderAggregate | null {
  if (!results) return null;
  const prefix = `${path}/`;
  const agg = aggregateEnvelopes(Object.values(results).filter(envelope => {
    if (envelope.ref.kind !== 'dashboard') return false;
    const rubric = envelope.rubric || '';
    return rubric === path || rubric.startsWith(prefix);
  }));
  return agg.total > 0 ? agg : null;
}

/**
 * Aggregate of a featured bundle over the subtrees it declares (`badgeRoots`,
 * comma-separated as in the dataset column `_badge_roots`) — the sum the
 * featured row of the list shows. Null while nothing is loaded or no root
 * holds a result unit.
 */
export function aggregateBadgeRoots(
  results: Record<string, ResultEnvelope> | null,
  badgeRoots: unknown,
): FolderAggregate | null {
  const roots = String(badgeRoots ?? '').split(',').map(s => s.trim()).filter(Boolean);
  if (!results || roots.length === 0) return null;
  const agg = emptyAggregate();
  for (const root of roots) {
    const part = aggregateFolder(results, root);
    if (part) mergeAggregate(agg, part);
  }
  return agg.total > 0 ? agg : null;
}

/** Compact state counters for a folder: `3● 7▲ 41✓` (zero states omitted). */
export const AggregateTokens = ({ agg }: { agg: FolderAggregate }) => (
  <span className="dash-tile__chips" aria-hidden="true">
    {FILTERABLE_STATES.filter(s => agg.counts[s] > 0).map(s => (
      <span key={s} className={`dash-chip dash-state-${s}`}>
        {agg.counts[s]}{STATE_TOKEN[s]}
      </span>
    ))}
  </span>
);
