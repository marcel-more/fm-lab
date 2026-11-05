import { useEffect, useState } from 'react';
import { Navigate, useParams, useSearchParams } from 'react-router-dom';
import { getDashboardDataset } from '../api/dashboardApi';
import { queryDetailTarget, queryOverviewTarget } from '../lib/queryRedirect';

/**
 * `/query[?category=<Label>]` → `/dashboard[?folder=<slug>]`. With a category
 * the overview's folder list decides whether the slug names a real folder;
 * an unknown one lands on the overview root.
 */
export function QueryOverviewRedirect() {
  const [searchParams] = useSearchParams();
  const hasCategory = searchParams.has('category');
  const [folders, setFolders] = useState<ReadonlySet<string> | null | undefined>(hasCategory ? undefined : null);

  useEffect(() => {
    if (!hasCategory) return;
    let cancelled = false;
    (async () => {
      try {
        const rows = await getDashboardDataset('dashboards', 'folders');
        if (!cancelled) setFolders(new Set(rows.map(row => String(row.path))));
      } catch {
        if (!cancelled) setFolders(null);
      }
    })();
    return () => { cancelled = true; };
  }, [hasCategory]);

  if (folders === undefined) return null;
  return <Navigate replace to={queryOverviewTarget(searchParams, folders)} />;
}

/** `/query/<name>?…` → `/dashboard/<name>?…` (every param except `query`). */
export function QueryDetailRedirect() {
  const { queryName } = useParams<{ queryName: string }>();
  const [searchParams] = useSearchParams();
  if (!queryName) return <Navigate replace to="/dashboard" />;
  return <Navigate replace to={queryDetailTarget(queryName, searchParams)} />;
}
