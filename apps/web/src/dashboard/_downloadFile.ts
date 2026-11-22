/**
 * Action `downloadFile` — the pure part: builds the file text from rows that are
 * already loaded in the dashboard. No server call, no write API; the browser
 * download itself happens in actions.ts. Unit-tested in tests/downloadFile.test.ts.
 *
 * Args:
 *   dataset    source of the rows (must be loaded on the page)
 *   rows       `all` (default) | `selected` — the row whose `key` equals the value
 *              of selection channel `channel`
 *   template   text per row with {{token}}s of that row
 *   separator  between rows (default: one blank line)
 *   header / footer  text before / after, {{token}}s of the context row
 *   context    dataset whose first row provides tokens for header, footer and
 *              filename (exported row tokens win in the filename)
 *   filename   template; characters outside letters, digits, `.`, `_`, `-` → `_`
 *   mime       text/markdown (default) | text/plain | text/csv | image/svg+xml | text/html
 *   document   text/html only: wrap the content in a complete, self-contained page
 *              (doctype, charset, `title`, embedded styles for screen and print)
 *   title      text/html with `document`: page title, {{token}}s of the context row
 *   appLinks   text/html: links into the app (`/object/…`) inside `*_html` columns —
 *              `text` (default: link removed, text kept) | `absolute` (current origin)
 *
 * Tokens: `{{ col | svg }}` inserts the Mermaid text of `col` as an SVG drawing.
 * Rendering is asynchronous and needs the browser, so it happens before this
 * module runs (exportPrepare.ts) and arrives as `hooks.svg` (source → SVG).
 * In text/html every token is HTML-escaped except `| svg` and plain `*_html`
 * columns (sanitized by the server); image/svg+xml exports exactly one row and
 * gets an XML header and a white background (pele draws none).
 */
import { substituteValue } from './tokens.ts';

type Row = Record<string, unknown>;

export const DOWNLOAD_MIME_TYPES = Object.freeze([
  'text/markdown', 'text/plain', 'text/csv', 'image/svg+xml', 'text/html',
]);
export const DOWNLOAD_MAX_BYTES = 20 * 1024 * 1024;

const EXTENSIONS: Record<string, string> = {
  'text/markdown': '.md',
  'text/plain': '.txt',
  'text/csv': '.csv',
  'image/svg+xml': '.svg',
  'text/html': '.html',
};

export interface DownloadArgs {
  dataset?: string;
  rows?: 'all' | 'selected';
  channel?: string;
  key?: string;
  template?: string;
  separator?: string;
  header?: string;
  footer?: string;
  context?: string;
  filename?: string;
  mime?: string;
  document?: boolean;
  title?: string;
  appLinks?: 'text' | 'absolute';
}

/** Browser-side inputs of buildDownload (exportPrepare.ts); tests pass fakes. */
export interface DownloadHooks {
  /** Mermaid source → rendered SVG (or a short HTML note when it failed). */
  svg?: ReadonlyMap<string, string>;
  /** Rewrites the app links of `*_html` columns (text/html exports). */
  rewriteHtml?: (html: string) => string;
  /** `lang` of an HTML document. */
  lang?: string;
}

export type DownloadResult =
  | { ok: true; content: string; filename: string; mime: string; rowCount: number }
  | { ok: false; reason: 'noDataset' | 'empty' | 'noSelection' | 'tooLarge' | 'svgOneRow' | 'renderFailed'; detail?: string };

const TOKEN_RE = /\{\{\s*([^}]+?)\s*\}\}/g;

export function escapeHtml(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** Field expression of a `| svg` token (`mermaid | svg` → `mermaid`), else null. */
function svgExpression(expr: string): string | null {
  const parts = expr.split('|').map((p) => p.trim());
  return parts.length > 1 && parts[parts.length - 1] === 'svg' ? parts.slice(0, -1).join(' | ') : null;
}

function tokenValue(expr: string, row: Row): string {
  const value = substituteValue(`{{${expr}}}`, row);
  return value == null ? '' : String(value);
}

/** Fills one template: plain text, or HTML with escaping (see module comment). */
function fill(template: string, row: Row, html: boolean, hooks: DownloadHooks): string {
  return template.replace(TOKEN_RE, (_match, expr: string) => {
    const svgOf = svgExpression(expr);
    if (svgOf !== null) {
      const source = tokenValue(svgOf, row);
      return source ? (hooks.svg?.get(source) ?? '') : '';
    }
    const text = tokenValue(expr, row);
    if (!html) return text;
    if (/^[A-Za-z0-9_]+_html$/.test(expr.trim())) return hooks.rewriteHtml ? hooks.rewriteHtml(text) : text;
    return escapeHtml(text);
  });
}

/** Rows an export covers (all rows, or the selected one of a channel). */
function exportRows(
  args: DownloadArgs,
  datasets: Record<string, { data?: Row[] } | undefined>,
  selection: Record<string, string | null>,
): Row[] | DownloadResult {
  const source = args.dataset ? datasets[args.dataset]?.data : undefined;
  if (!source) return { ok: false, reason: 'noDataset', detail: args.dataset };
  if (args.rows !== 'selected') return source;
  const value = args.channel ? selection[args.channel] : null;
  if (value == null || !args.key) return { ok: false, reason: 'noSelection', detail: args.channel };
  return source.filter((r) => String(r[args.key as string] ?? '') === value);
}

/**
 * Mermaid sources of all `| svg` tokens the export will fill — rendered by the
 * browser stage before buildDownload runs. Empty when there is nothing to draw.
 */
export function svgSources(
  args: DownloadArgs,
  datasets: Record<string, { data?: Row[] } | undefined>,
  selection: Record<string, string | null> = {},
): string[] {
  const rows = exportRows(args, datasets, selection);
  if (!Array.isArray(rows)) return [];
  const contextRow = (args.context ? datasets[args.context]?.data?.[0] : undefined) ?? {};
  const out = new Set<string>();
  const collect = (template: string | undefined, rowsOf: Row[]) => {
    if (!template) return;
    for (const match of template.matchAll(TOKEN_RE)) {
      const svgOf = svgExpression(match[1]);
      if (svgOf === null) continue;
      for (const r of rowsOf) {
        const source = tokenValue(svgOf, r);
        if (source) out.add(source);
      }
    }
  };
  collect(args.template, rows);
  collect(args.header, [contextRow]);
  collect(args.footer, [contextRow]);
  return [...out];
}

/** Standalone SVG file: XML header and a white background behind the drawing. */
function svgFile(content: string): string {
  const body = content.trim();
  const open = /^<svg\b[^>]*>/.exec(body);
  if (!open) return body;
  const box = /viewBox="\s*([-\d.]+)[\s,]+([-\d.]+)[\s,]+([-\d.]+)[\s,]+([-\d.]+)\s*"/.exec(open[0]);
  const rect = box
    ? `<rect x="${box[1]}" y="${box[2]}" width="${box[3]}" height="${box[4]}" fill="#fff"/>`
    : '<rect width="100%" height="100%" fill="#fff"/>';
  return `<?xml version="1.0" encoding="UTF-8"?>\n${open[0]}${rect}${body.slice(open[0].length)}`;
}

/** Styles of an HTML export: light, readable, printable, no external resources. */
export const EXPORT_CSS = [
  'body{font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;color:#1f2937;background:#fff;max-width:1100px;margin:24px auto;padding:0 16px}',
  'h1{font-size:1.5rem;margin:0 0 .4em}h2{font-size:1.15rem;margin:2em 0 .6em;padding-bottom:.3em;border-bottom:1px solid #e5e7eb}h3,h4{font-size:1rem;margin:1.4em 0 .4em}',
  'p,li{margin:.4em 0}a{color:#2563eb}code{background:#f3f4f6;padding:0 4px;border-radius:3px;font-size:.9em}',
  'table{border-collapse:collapse;width:100%;font-size:.85rem;margin:.8em 0}th,td{border:1px solid #e5e7eb;padding:4px 8px;text-align:left;vertical-align:top}th{background:#f9fafb}',
  'blockquote{margin:.8em 0;padding:.2em 1em;border-left:3px solid #d1d5db;color:#4b5563}',
  // Screen: diagrams in their natural size, wide ones scroll; print: fit the page.
  'figure{margin:1em 0;overflow-x:auto}figure svg{max-width:none!important;height:auto}',
  '.export-error{color:#b91c1c}',
  '@media print{body{max-width:none;margin:0}h2{break-after:avoid}figure{overflow:visible}figure svg{max-width:100%!important}figure,tr{break-inside:avoid}}',
].join('\n');

function htmlDocument(body: string, title: string, lang: string): string {
  return '<!doctype html>\n'
    + `<html lang="${escapeHtml(lang)}">\n<head>\n<meta charset="utf-8">\n`
    + '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    + `<title>${escapeHtml(title)}</title>\n<style>\n${EXPORT_CSS}\n</style>\n</head>\n<body>\n${body}\n</body>\n</html>`;
}

/** File name: tokens filled, unsafe characters → `_`, extension of the type added. */
export function safeFilename(name: string, mime: string): string {
  const ext = EXTENSIONS[mime] ?? '';
  // A run of unsafe characters becomes one `_`; underscores of the name stay (Abgesagt__n).
  let base = name.trim().replace(/[^\p{L}\p{N}._-]+/gu, '_').replace(/^[._]+/, '');
  if (!base) base = 'export';
  if (ext && !base.toLowerCase().endsWith(ext)) base += ext;
  return base.slice(0, 180);
}

export function buildDownload(
  args: DownloadArgs,
  datasets: Record<string, { data?: Row[] } | undefined>,
  selection: Record<string, string | null> = {},
  hooks: DownloadHooks = {},
): DownloadResult {
  const mime = DOWNLOAD_MIME_TYPES.includes(args.mime ?? '') ? (args.mime as string) : 'text/markdown';
  const selected = exportRows(args, datasets, selection);
  if (!Array.isArray(selected)) return selected;
  const rows = selected;
  if (rows.length === 0) return { ok: false, reason: 'empty' };
  const svg = mime === 'image/svg+xml';
  if (svg && rows.length > 1) return { ok: false, reason: 'svgOneRow', detail: String(rows.length) };

  const html = mime === 'text/html';
  const contextRow = (args.context ? datasets[args.context]?.data?.[0] : undefined) ?? {};
  const template = args.template ?? '';
  const separator = args.separator ?? '\n\n';
  const body = rows.map((r) => (template ? fill(template, r, html, hooks) : '')).join(separator);
  let content: string;
  if (svg) {
    // One drawing per file: header and footer would break the SVG.
    content = svgFile(body) + '\n';
  } else {
    const parts = [
      args.header ? fill(args.header, contextRow, html, hooks) : '',
      body,
      args.footer ? fill(args.footer, contextRow, html, hooks) : '',
    ].filter((p) => p !== '');
    content = parts.join(separator).replace(/\r?\n/g, '\n');
    if (html && args.document) {
      content = htmlDocument(content, fill(args.title ?? '', contextRow, false, {}), hooks.lang ?? 'en');
    }
    content += '\n';
  }

  const bytes = new TextEncoder().encode(content).length;
  if (bytes > DOWNLOAD_MAX_BYTES) return { ok: false, reason: 'tooLarge', detail: String(bytes) };

  const nameTemplate = args.filename ?? 'export';
  const filename = safeFilename(fill(nameTemplate, { ...contextRow, ...rows[0] }, false, {}), mime);
  return { ok: true, content, filename, mime, rowCount: rows.length };
}
