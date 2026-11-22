/**
 * Mermaid renderer adapter shared by the dashboard `Mermaid` primitive and the
 * Graph Explorer's data-trace way view. Both talk only to this module, so the
 * renderer can be swapped (e.g. for mermaid.js) without touching them.
 *
 * Implementation: pele (Mermaid syntax → SVG, no runtime dependencies) through
 * `pele/lazy`, which loads the code of a diagram type on first use. Callers
 * load this module lazily, so views without diagrams do not pay for it.
 *
 * Security: diagram text is data (object names from the FileMaker solution).
 * pele escapes text; links and images are switched off, no icon resolver is
 * passed, and `config` never comes from the dataset. Errors are written as
 * text, never as markup.
 */
import { detectType, load, mountAsync, renderAsync, PeleError } from 'pele/lazy';
import type { Mounted } from 'pele/lazy';

/** Upper bound of the diagram source in characters. */
export const MERMAID_SOURCE_LIMIT = 200_000;

export interface MermaidError {
  /** 'syntax' | 'semantic' | 'unsupported-diagram' | 'limit' | 'unknown' */
  code: string;
  message: string;
  line: number;
  column: number;
  snippet: string;
}

export interface MermaidOptions {
  /** `auto` (default): zoom controls when the diagram is larger than its box. */
  zoom?: boolean | 'auto';
  onError?: (error: MermaidError | null) => void;
  onRender?: (element: HTMLElement) => void;
}

export interface MermaidHandle {
  /** Re-renders with new text; loads the code of a new diagram type first. */
  update(text: string): Promise<void>;
  destroy(): void;
}

export function toMermaidError(err: unknown): MermaidError {
  if (err instanceof PeleError) {
    return {
      code: err.code,
      message: err.message,
      line: err.line,
      column: err.column,
      snippet: err.snippet,
    };
  }
  return { code: 'unknown', message: String((err as Error)?.message ?? err), line: 0, column: 0, snippet: '' };
}

export async function mountMermaid(
  element: HTMLElement,
  text: string,
  options: MermaidOptions = {},
): Promise<MermaidHandle> {
  const notify = () => {
    options.onError?.(null);
    options.onRender?.(element);
  };
  const mounted: Mounted = await mountAsync(element, text, {
    links: false,
    images: false,
    limit: MERMAID_SOURCE_LIMIT,
    zoom: options.zoom ?? 'auto',
    onRender: notify,
    onError: (err) => options.onError?.(toMermaidError(err)),
  });
  // A diagram that fails on first render reports through `error`, not onError.
  if (mounted.error !== undefined) options.onError?.(toMermaidError(mounted.error));
  return {
    async update(next: string) {
      await load(detectType(next));
      mounted.update(next);
      if (mounted.error !== undefined) options.onError?.(toMermaidError(mounted.error));
    },
    destroy() {
      mounted.destroy();
    },
  };
}

/**
 * Renders Mermaid text to an SVG string without a DOM element (exports). Same
 * settings as the mounted diagram; errors are thrown as MermaidError. The SVG
 * keeps pele's colour variables with their light fallbacks, so a file without
 * the app's stylesheet shows the light theme.
 */
export async function renderMermaidSvg(text: string): Promise<string> {
  try {
    const { svg } = await renderAsync(text, { links: false, images: false, limit: MERMAID_SOURCE_LIMIT });
    return svg;
  } catch (err) {
    throw toMermaidError(err);
  }
}
