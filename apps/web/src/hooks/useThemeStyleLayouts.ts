import { useCallback, useEffect, useState } from 'react';
import { fetchTemplateQuery } from '../api/templateApi';
import { toStyleLayouts, type ThemeStyleLayoutRow } from '../lib/themeDetail';

export type StyleLayoutsStatus = 'loading' | 'ready' | 'error';

export interface StyleLayoutsState {
  status: StyleLayoutsStatus;
  layouts: ThemeStyleLayoutRow[];
  retry: () => void;
}

// Per (theme UUID, file, style class) for the session; failures are not cached,
// so the next expand tries again.
const cache = new Map<string, ThemeStyleLayoutRow[]>();

/**
 * Layouts carrying one style of a theme (template `display_theme_style_layouts`),
 * loaded when the style row is expanded — the theme detail response itself holds
 * one row per style only, so a heavily styled file never ships all its
 * (style, layout) pairs up front. Mount this hook only for an expanded row.
 */
export function useThemeStyleLayouts(
  themeUuid: string,
  file: string | null | undefined,
  styleClass: string,
): StyleLayoutsState {
  const key = `${themeUuid}::${file ?? ''}::${styleClass}`;
  const [attempt, setAttempt] = useState(0);
  const [state, setState] = useState<{ key: string; status: StyleLayoutsStatus; layouts: ThemeStyleLayoutRow[] }>(() => {
    const hit = cache.get(key);
    return { key, status: hit ? 'ready' : 'loading', layouts: hit ?? [] };
  });

  useEffect(() => {
    const hit = cache.get(key);
    if (hit) {
      setState({ key, status: 'ready', layouts: hit });
      return;
    }
    let cancelled = false;
    setState({ key, status: 'loading', layouts: [] });
    const params: Record<string, string> = { uuid: themeUuid, style: styleClass };
    if (file) params.file = file;
    fetchTemplateQuery('display_theme_style_layouts', params)
      .then(res => {
        if (cancelled) return;
        const layouts = toStyleLayouts(res.data as unknown as Array<Record<string, unknown>>);
        cache.set(key, layouts);
        setState({ key, status: 'ready', layouts });
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        console.warn('Theme style layouts fetch failed:', err);
        setState({ key, status: 'error', layouts: [] });
      });
    return () => {
      cancelled = true;
    };
  }, [key, themeUuid, file, styleClass, attempt]);

  const retry = useCallback(() => setAttempt(a => a + 1), []);
  if (state.key !== key) return { status: 'loading', layouts: [], retry };
  return { status: state.status, layouts: state.layouts, retry };
}
