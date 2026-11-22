// `marked` is ESM-only since v15+ (package.json "type":"module", no CommonJS build).
// It is loaded lazily via dynamic import() — independent of require(ESM) support —
// and initialized once at server startup (initMarked, awaited in src/index.js
// before the HTTP server binds). The render helpers below stay synchronous; they
// run at request time, long after init.
let marked = null;

/**
 * Docs Content Renderer
 *
 * Konvertiert Markdown-Quellen (DuckDB, fmIDE, fm-lab) zu HTML und betreibt
 * eine minimale Sanitization plus Link-Rewriting. HTML-Quellen (Claris,
 * MBS) durchlaufen denselben Sanitizer, aber ohne Marked-Pass.
 *
 * Verhalten:
 *   - Markdown wird im Backend zu HTML konvertiert, BEVOR es ausgeliefert wird.
 *   - Relative Links werden auf API-Pfade umgeschrieben.
 *   - Anchors (#...) bleiben unangetastet.
 *   - Sanitization entfernt <script>/<style>/<iframe>/javascript: etc.
 *
 * Bewusste Verzicht-Entscheidungen:
 *   - Keine `sanitize-html` / `jsdom`-Dependency — das Inhalts-Universum ist
 *     trusted-ish (eigene Installer-Skills, kuratierte Quellen). Eine
 *     handgeschriebene Regex-Sanitization deckt die realen XSS-Vektoren
 *     (script, on*=, javascript:) ab, ohne ein 5-MB-Paket nachzuziehen.
 *   - Kein Syntax-Highlighting im Backend — verlagert auf den Frontend-Renderer
 *     (Prism/Shiki), damit Theme-Switching live funktioniert.
 */

/**
 * GitHub-Wiki-kompatible Slug-Bildung für Überschriften.
 *
 * Bildung (analog GitHub):
 *   - lower-case
 *   - alles außer [a-z0-9_-] entfernen, Leerzeichen → "-"
 *   - umlaute + sonstige diakritische Zeichen werden via NFKD entfernt
 *   - mehrfache "-" zusammengezogen, leading/trailing gestrippt
 *
 * Stellt sicher, dass aus `## How it maps to the technical components`
 * der Anker `how-it-maps-to-the-technical-components` wird, identisch zu
 * dem, was Markdown-Editoren / GitHub-Wikis verlinken.
 *
 * Bei Duplikaten innerhalb eines Dokuments hängt der Renderer einen Zähler
 * an (foo, foo-1, foo-2, …) — analog GitHub.
 */
function slugifyHeading(text) {
  return String(text)
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')   // strip combining diacritics
    .toLowerCase()
    .replace(/[^\w\s-]/g, '')          // drop punctuation
    .trim()
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '');
}

/**
 * Wendet einen heading-Renderer an, der GitHub-Wiki-kompatible IDs auf alle
 * `<h1>..<h6>` setzt. marked v15+ hat das eingebaute `headerIds`-Flag
 * entfernt; wir restaurieren das Verhalten als Custom-Renderer.
 */
const headingRenderer = {
  heading({ tokens, depth }) {
    const text = this.parser.parseInline(tokens);
    const raw = tokens.map(t => ('raw' in t ? t.raw : t.text || '')).join('');
    const baseSlug = slugifyHeading(raw);
    // Duplikate innerhalb eines Renderlaufs nummerieren. `usedSlugs` wird vor
    // jedem `marked.parse()`-Aufruf zurückgesetzt (siehe `renderMarkdown`).
    let slug = baseSlug;
    if (baseSlug) {
      const count = usedSlugs.get(baseSlug) || 0;
      usedSlugs.set(baseSlug, count + 1);
      if (count > 0) slug = `${baseSlug}-${count}`;
    }
    return slug
      ? `<h${depth} id="${slug}">${text}</h${depth}>\n`
      : `<h${depth}>${text}</h${depth}>\n`;
  },
};

const usedSlugs = new Map();

/**
 * Loads `marked` (ESM-only) via dynamic import and applies our options + custom
 * heading renderer. Idempotent — safe to call more than once. Awaited once at server
 * startup so the synchronous render helpers can rely on `marked` being present.
 */
async function initMarked() {
  if (marked) return marked;
  ({ marked } = await import('marked'));
  marked.setOptions({ gfm: true, breaks: false });
  marked.use({ renderer: headingRenderer });
  return marked;
}

const DANGEROUS_TAGS_RE = /<\/?(?:script|style|iframe|object|embed|noscript|template|form|input|button|textarea|select)\b[^>]*>/gi;
const SCRIPT_BLOCK_RE   = /<script\b[\s\S]*?<\/script>/gi;
const STYLE_BLOCK_RE    = /<style\b[\s\S]*?<\/style>/gi;
const ON_ATTR_RE        = /\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi;
const JS_URL_ATTR_RE    = /\s+(href|src|action|formaction|xlink:href)\s*=\s*(?:"\s*javascript:[^"]*"|'\s*javascript:[^']*'|\s*javascript:[^\s>]*)/gi;

/**
 * Strips the obvious XSS vectors. Not bullet-proof but covers script,
 * inline-event handlers and javascript:-URLs.
 */
function sanitizeHtml(html) {
  if (!html) return '';
  return String(html)
    .replace(SCRIPT_BLOCK_RE, '')
    .replace(STYLE_BLOCK_RE, '')
    .replace(DANGEROUS_TAGS_RE, '')
    .replace(ON_ATTR_RE, '')
    .replace(JS_URL_ATTR_RE, ' $1="#"');
}

/**
 * Resolves a relative content path (image src, page href) against the
 * directory of the page being rendered. Handles `../` traversal and `./`,
 * yielding a content-root-relative path with no segments outside the root.
 *
 *   pageDir = "Wiki",  relPath = "../Assets/foo.jpg"
 *     → "Assets/foo.jpg"
 *
 * If the page-dir is empty (top-level page), the relative path is returned
 * as-is (after stripping `./`).
 *
 * Segments that would escape the content root (more `..` than depth) are
 * dropped — the asset endpoint will still enforce path-traversal safety, so
 * the worst case is a 404.
 */
function resolveRelativeToPage(pageDir, relPath) {
  const segments = String(`${pageDir || ''}/${relPath}`).split('/').filter(Boolean);
  const out = [];
  for (const seg of segments) {
    if (seg === '..') { if (out.length) out.pop(); continue; }
    if (seg === '.') continue;
    out.push(seg);
  }
  return out.join('/');
}

/**
 * Rewrites href/src URLs to point at the API where appropriate.
 *
 * Rules (in order):
 *   1. Absolute URLs (http://, https://, mailto:, tel:, data:) — passed through.
 *   2. Anchors (`#...`) — passed through.
 *   3. Relative `*.md` (or extension-less) references → `/docs/{set}/{slug}`
 *      (frontend route, so React-Router picks them up as in-app navigation).
 *      Resolved against the rendered page's own directory (`pagePath`), so
 *      `../sibling.md` works on nested docs.
 *   4. Other relative paths (assets, images) → resolved against pagePath +
 *      passed through the doc-set asset endpoint
 *      `/api/docs/{set}/_asset/{path}`.
 *
 * Anchors inside otherwise-relative links are preserved (`./Other.md#section`).
 *
 * `pagePath` is the content-root-relative path of the current page WITHOUT
 * the .md suffix (e.g. "Wiki/Architecture"). Optional — top-level pages set
 * it to the file basename, then pageDir resolves to empty.
 */
function rewriteLinks(html, { setId, pagePath } = {}) {
  if (!html || !setId) return html;
  const setSeg = encodeURIComponent(setId);

  // Directory der gerenderten Page (für Relativ-Auflösung). Aus
  // "Wiki/Architecture" wird "Wiki", aus "Documentation" wird "".
  const pageDir = pagePath && pagePath.includes('/')
    ? pagePath.slice(0, pagePath.lastIndexOf('/'))
    : '';

  return String(html).replace(/\s(href|src)\s*=\s*(?:"([^"]*)"|'([^']*)')/gi, (match, attr, dq, sq) => {
    const raw = (dq ?? sq ?? '').trim();
    if (!raw) return match;
    // Absolute or scheme-prefixed → leave alone
    if (/^(?:https?:|mailto:|tel:|data:|fmp:|fmps:)/i.test(raw)) return match;
    // In-document anchor
    if (raw.startsWith('#')) return match;
    // Already routed by an earlier pre-pass (API mirror, SPA-Route oder
    // Dashboard-Deeplink) — keine erneute Umformung.
    if (raw.startsWith('/api/') || raw.startsWith('/docs/') || raw.startsWith('/dashboard/')) {
      return match;
    }

    // Split anchor
    let pathPart = raw;
    let anchor = '';
    const hashIdx = raw.indexOf('#');
    if (hashIdx >= 0) {
      pathPart = raw.slice(0, hashIdx);
      anchor = raw.slice(hashIdx);
    }

    // Decide page vs. asset by file extension:
    //   - .md or no extension at all → Markdown cross-link (wiki convention)
    //   - has another extension (.png, .pdf, .css, …) → asset
    const lastSegment = pathPart.split('/').pop() || '';
    const extMatch = lastSegment.match(/\.([a-z0-9]{1,8})$/i);
    const ext = extMatch ? extMatch[1].toLowerCase() : null;
    const isPage = !ext || ext === 'md';

    // Marked / Wiki-Pre-Processor liefern Pfade ggf. schon prozent-kodiert
    // (z.B. Unicode-Emojis im fmIDE-Wiki). encodeURIComponent würde die
    // Prozentzeichen erneut kodieren ("%F0" → "%25F0"). Wir dekodieren daher
    // jedes Segment defensiv, bevor wir es neu kodieren — bricht nichts kaputt,
    // weil decodeURIComponent auf bereits unkodierten Strings idempotent ist.
    const safeEncodeSegment = (seg) => {
      let decoded = seg;
      try { decoded = decodeURIComponent(seg); } catch { /* malformed → keep raw */ }
      return encodeURIComponent(decoded);
    };

    // Relativen Pfad gegen Page-Verzeichnis auflösen. Das eliminiert "../" und
    // "./" serverseitig, damit der Browser die `..` nicht aus der URL streicht
    // und auf einem Pfad landet, den der Asset-Endpoint nicht kennt.
    const resolved = resolveRelativeToPage(pageDir, pathPart);

    // Slug decoded → re-encoded als URL-Component. Verhindert Double-Encoding,
    // wenn der Quell-Pfad bereits prozent-kodierte Zeichen enthält (z.B. `%20`
    // für Leerzeichen in fm-lab Wiki-Linknamen "How%20it%20works.md").
    const encodeAsRouteSegment = (s) => {
      let decoded = s;
      try { decoded = decodeURIComponent(s); } catch { /* malformed → keep raw */ }
      return encodeURIComponent(decoded);
    };

    let rewritten;
    if (isPage) {
      const slug = resolved.replace(/\.md$/i, '');
      const routeSeg = encodeAsRouteSegment(slug);
      // markdown-fs hat keine echte Funktion-Ebene — Slug ist gleich category-id;
      // category==function in der URL ist die Konvention für nicht-indizierte
      // Sets (siehe rewriter-Konvention für /docs/:set/:cat/:fn).
      rewritten = `/docs/${setSeg}/${routeSeg}/${routeSeg}`;
    } else {
      const segments = resolved.split('/').map(safeEncodeSegment).join('/');
      rewritten = `/api/docs/${setSeg}/_asset/${segments}`;
    }

    return ` ${attr}="${rewritten}${anchor}"`;
  });
}

/**
 * Convert Markdown to sanitized HTML with rewritten links.
 *
 * Returns plain HTML string. Callers should wrap this in
 * `<article class="docs-content">…</article>` on the frontend.
 */
/**
 * Pre-processes GitHub-Wiki-Style markup that marked doesn't understand:
 *   [[image-path|alt-text]]  →  ![alt-text](image-path)
 *   [[image-path]]           →  ![image-path](image-path)
 * Used by the fmIDE wiki.
 */
function preprocessWikiSyntax(md) {
  return String(md).replace(/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_, target, alt) => {
    const cleanTarget = target.replace(/^\//, '');
    const altText = (alt || cleanTarget).trim();
    return `![${altText}](${cleanTarget})`;
  });
}

/**
 * MBS-spezifischer Pre-Rewriter: das Dash-DocSet-HTML verwendet generische
 * `href="#"`-Anker zusammen mit `data-plugin-fn="<name>"` bzw.
 * `data-plugin-component="<category>"`-Attributen für interne Cross-Refs.
 * Wir setzen die Daten-Attribute in echte App-interne Routen um:
 *
 *   <a href="#" data-plugin-fn="Clipboard.AddText">
 *     → href="/docs/mbs/Clipboard/Clipboard.AddText"
 *   <a href="#" data-plugin-component="Clipboard">
 *     → href="/docs/mbs/Clipboard"
 *
 * Wird vor `rewriteLinks` aufgerufen — die neuen Hrefs beginnen mit `/docs/`
 * und werden vom Frontend als App-Routes erkannt.
 */
function rewriteMbsDataLinks(html) {
  return String(html).replace(/<a\b([^>]*)>/gi, (full, attrs) => {
    const fnMatch = attrs.match(/data-plugin-fn\s*=\s*"([^"]+)"/i);
    const compMatch = attrs.match(/data-plugin-component\s*=\s*"([^"]+)"/i);
    if (!fnMatch && !compMatch) return full;

    let newHref;
    if (fnMatch) {
      const fn = fnMatch[1];
      const dot = fn.indexOf('.');
      const cat = dot > 0 ? fn.slice(0, dot) : fn;
      newHref = `/docs/mbs/${encodeURIComponent(cat)}/${encodeURIComponent(fn)}`;
    } else {
      const cat = compMatch[1];
      // Bare route `/docs/:set/:category` → DocsCategoryPage rendert das
      // docset_category-Bundle (mappt :set → docset).
      newHref = `/docs/mbs/${encodeURIComponent(cat)}`;
    }

    let newAttrs;
    if (/\bhref\s*=/i.test(attrs)) {
      newAttrs = attrs.replace(/\shref\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i, ` href="${newHref}"`);
    } else {
      newAttrs = ` href="${newHref}"` + attrs;
    }
    return `<a${newAttrs}>`;
  });
}

function renderMarkdown(md, { setId, pagePath } = {}) {
  if (!md) return '';
  if (!marked) {
    // Should never happen in the server (index.js awaits initMarked() before listen).
    // A clear error beats a cryptic "Cannot read properties of null (reading 'parse')".
    throw new Error('docs-content: marked not initialized — call await initMarked() at startup');
  }
  // Heading-Slug-Tabelle pro Render-Aufruf zurücksetzen, damit Duplikat-
  // Zählung document-local bleibt (analog GitHub).
  usedSlugs.clear();
  const preprocessed = preprocessWikiSyntax(md);
  const rawHtml = marked.parse(preprocessed);
  const rewritten = rewriteLinks(rawHtml, { setId, pagePath });
  return sanitizeHtml(rewritten);
}

/**
 * Markdown from dashboard data (a dataset column, see markdown-columns.js) to
 * sanitized HTML: GFM like the docs (tables, inline HTML such as <details>,
 * heading anchors), but without the docs extras — no wiki-link syntax, no link
 * rewriting onto a doc set. The browser sanitizes again (HtmlContent).
 */
function renderMarkdownFragment(md) {
  if (!md) return '';
  if (!marked) {
    throw new Error('docs-content: marked not initialized — call await initMarked() at startup');
  }
  usedSlugs.clear();
  return sanitizeHtml(marked.parse(String(md)));
}

/**
 * Pass an HTML payload through the same pipeline (sanitize + rewrite). Used
 * for adapters whose `getEntry` already returns HTML (MBS). Für MBS werden
 * zusätzlich die `data-plugin-fn`/`data-plugin-component`-Anker in echte
 * App-Routen umgeschrieben.
 */
function renderHtml(html, { setId, pagePath } = {}) {
  if (!html) return '';
  let processed = String(html);
  if (setId === 'mbs') {
    processed = rewriteMbsDataLinks(processed);
  }
  const rewritten = rewriteLinks(processed, { setId, pagePath });
  return sanitizeHtml(rewritten);
}

/**
 * One-shot helper: takes a DocEntry payload from any adapter and returns
 * it with `content_html` always populated and post-processed. The adapter
 * surface stays unchanged — this layer is purely cosmetic.
 */
function processEntry(entry, { setId, pagePath } = {}) {
  if (!entry) return entry;
  const next = { ...entry };
  if (!next.content_html && next.content_md) {
    next.content_html = renderMarkdown(next.content_md, { setId, pagePath });
  } else if (next.content_html) {
    next.content_html = renderHtml(next.content_html, { setId, pagePath });
  }
  return next;
}

module.exports = {
  initMarked,
  renderMarkdown,
  renderMarkdownFragment,
  renderHtml,
  sanitizeHtml,
  rewriteLinks,
  rewriteMbsDataLinks,
  processEntry,
};
