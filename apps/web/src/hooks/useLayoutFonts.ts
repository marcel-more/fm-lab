import { useEffect, useState } from 'react';
import { fetchTemplateQuery } from '../api/templateApi';
import { isSchemaDriftError } from '../lib/errors';
import { buildFontIndex, type LayoutFontIndex, type LayoutFontRow } from '../lib/layoutFonts';

/**
 * idle         not asked for yet (lazy)
 * loading      request running
 * ready        index built
 * unavailable  catalog older than schema 1.45.0 (SCHEMA_DRIFT) — re-import needed
 * error        any other failure
 */
export type LayoutFontsStatus = 'idle' | 'loading' | 'ready' | 'unavailable' | 'error';

export type LayoutFontsState = {
  status: LayoutFontsStatus;
  index: LayoutFontIndex | null;
};

type Entry = { status: 'ready'; index: LayoutFontIndex } | { status: 'unavailable' };

// Per (layout UUID, file), like useLayoutData; failures other than schema drift
// are not cached, so the next request tries again.
const cache = new Map<string, Entry>();

const IDLE: LayoutFontsState = { status: 'idle', index: null };

/**
 * Font uses and applied styles of one layout (template `display_layout_fonts`)
 * for the font and style filter and the tooltip of the canvas. Lazy: loads only
 * once `enabled` turned true (details stage open, a font/style URL param set,
 * first hover) and keeps the data afterwards. The canvas itself never waits for
 * it — on an older catalog only the filter row shows the re-import notice.
 */
export function useLayoutFonts(
  layoutUuid: string | null | undefined,
  file: string | null | undefined,
  enabled: boolean,
): LayoutFontsState {
  const key = layoutUuid ? `${layoutUuid}::${file ?? ''}` : null;
  const [wanted, setWanted] = useState<string | null>(null);
  const [state, setState] = useState<{ key: string | null; value: LayoutFontsState }>({ key: null, value: IDLE });

  // Sticky: once asked for on this layout, stay loaded when `enabled` drops again.
  if (enabled && key && wanted !== key) setWanted(key);
  const active = key != null && wanted === key;

  useEffect(() => {
    if (!active || !key || !layoutUuid) return;
    const hit = cache.get(key);
    if (hit) {
      setState({ key, value: hit.status === 'ready' ? { status: 'ready', index: hit.index } : { status: 'unavailable', index: null } });
      return;
    }
    let cancelled = false;
    setState({ key, value: { status: 'loading', index: null } });
    const params: Record<string, string> = { uuid: layoutUuid };
    if (file) params.file = file;
    fetchTemplateQuery('display_layout_fonts', params)
      .then(res => {
        if (cancelled) return;
        const index = buildFontIndex((res.data as unknown as LayoutFontRow[]) ?? []);
        cache.set(key, { status: 'ready', index });
        setState({ key, value: { status: 'ready', index } });
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        const message = err instanceof Error ? err.message : String(err);
        if (isSchemaDriftError(message)) {
          cache.set(key, { status: 'unavailable' });
          setState({ key, value: { status: 'unavailable', index: null } });
        } else {
          setState({ key, value: { status: 'error', index: null } });
        }
      });
    return () => {
      cancelled = true;
    };
  }, [active, key, layoutUuid, file]);

  return state.key === key ? state.value : IDLE;
}
