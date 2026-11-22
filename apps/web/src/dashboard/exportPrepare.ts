/**
 * Browser stage of the action `downloadFile`: draws the `{{ col | svg }}` tokens
 * with the Mermaid renderer (loaded only when an export needs it) and rewrites
 * app links of HTML columns, then hands over to the pure buildDownload
 * (_downloadFile.ts). pele's SVG goes into the file as rendered — the HtmlContent
 * allow-list would strip its colour variables and `xmlns`; pele escapes text and
 * runs with links and images switched off, as in the mounted diagram.
 */
import i18n from 'i18next';
import { buildDownload, escapeHtml, svgSources } from './_downloadFile';
import type { DownloadArgs, DownloadResult } from './_downloadFile';

type Row = Record<string, unknown>;

/**
 * Links into the app (`/object/…`, `/file/…`) point nowhere in a file:
 * `text` replaces each by its content, `absolute` prefixes the current origin.
 */
export function rewriteAppLinks(html: string, mode: 'text' | 'absolute', origin: string): string {
  if (!html.includes('href="/')) return html;
  const doc = new DOMParser().parseFromString(`<body>${html}</body>`, 'text/html');
  for (const a of Array.from(doc.body.querySelectorAll('a[href^="/"]'))) {
    const href = a.getAttribute('href') ?? '';
    if (href.startsWith('//')) continue;
    if (mode === 'absolute') {
      a.setAttribute('href', origin + href);
    } else {
      a.replaceWith(...Array.from(a.childNodes));
    }
  }
  return doc.body.innerHTML;
}

export async function prepareDownload(
  args: DownloadArgs,
  datasets: Record<string, { data?: Row[] } | undefined>,
  selection: Record<string, string | null>,
): Promise<DownloadResult> {
  // Refusals that need no drawing come first (no rows, no selection, an SVG of
  // several rows) — before any diagram is rendered.
  const check = buildDownload(args, datasets, selection, { svg: new Map() });
  if (!check.ok && check.reason !== 'tooLarge') return check;
  const sources = svgSources(args, datasets, selection);
  const svg = new Map<string, string>();
  if (sources.length > 0) {
    const { renderMermaidSvg } = await import('../lib/mermaid/renderMermaid');
    for (const source of sources) {
      try {
        svg.set(source, await renderMermaidSvg(source));
      } catch (err) {
        const detail = (err as { message?: string })?.message ?? String(err);
        // A single drawing that fails leaves nothing to save; in a document
        // the failing diagram becomes a short note and the rest is exported.
        if (args.mime === 'image/svg+xml') return { ok: false, reason: 'renderFailed', detail };
        svg.set(source, `<p class="export-error">${escapeHtml(i18n.t('dashboard:download.diagramError', { detail }))}</p>`);
      }
    }
  }
  const html = args.mime === 'text/html';
  return buildDownload(args, datasets, selection, {
    svg,
    rewriteHtml: html ? (h) => rewriteAppLinks(h, args.appLinks === 'absolute' ? 'absolute' : 'text', window.location.origin) : undefined,
    lang: i18n.language || 'en',
  });
}
