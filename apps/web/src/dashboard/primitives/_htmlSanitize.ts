/**
 * HTML sanitizer of the `HtmlContent` primitive — an allow-list, no dependency.
 *
 * Dashboard HTML comes from dashboard SQL (shipped, custom or community
 * bundles) and carries data from the FileMaker solution (object names, comments,
 * calculation text). None of it may run script in the app's origin, so every
 * string passes through here before it reaches the DOM:
 *
 *   1. `DOMParser` parses it into an inert document (no script runs, no image
 *      loads, no resource is fetched).
 *   2. A NEW tree is built in the target document from the allowed parts only:
 *      allowed elements are recreated, allowed attributes copied one by one,
 *      text copied as text. Nothing of the parsed tree is reused.
 *   3. The caller appends that fragment directly. There is no serialize →
 *      re-parse round trip, so mutation XSS (markup that parses differently
 *      the second time) has no second parse to exploit.
 *
 * Elements: allowed ones are kept; dangerous ones are dropped with their
 * content (DROP_*); anything else unknown is unwrapped — its children stay,
 * so text of exotic markup (e.g. `<font>`, a stray `<uint64>`) is not lost.
 * Every element of a namespace other than HTML and SVG (MathML) is dropped.
 *
 * The pure policy functions (elementPolicy, filterAttribute, filterStyle,
 * isAllowedUrl) carry the decisions and are unit-tested without a DOM
 * (tests/htmlSanitize.test.ts); the tree walk needs a browser DOM.
 */

export const HTML_NS = 'http://www.w3.org/1999/xhtml';
export const SVG_NS = 'http://www.w3.org/2000/svg';

export type ElementPolicy = 'keep' | 'unwrap' | 'drop';

const HTML_KEEP = new Set([
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'dl', 'dt', 'dd',
  'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'caption', 'colgroup', 'col',
  'details', 'summary', 'section', 'article', 'div', 'span',
  'b', 'strong', 'i', 'em', 'u', 's', 'small', 'sub', 'sup', 'code', 'pre', 'kbd',
  'samp', 'var', 'abbr', 'cite', 'q', 'del', 'ins', 'mark', 'time',
  'br', 'wbr', 'hr', 'blockquote', 'a', 'img', 'figure', 'figcaption',
]);

// Dropped with everything inside: script/style carriers, embedded documents,
// forms, media, document metadata and the raw-text elements.
const HTML_DROP = new Set([
  'script', 'style', 'template', 'noscript', 'noembed', 'noframes', 'xmp',
  'plaintext', 'listing', 'iframe', 'frame', 'frameset', 'object', 'embed',
  'applet', 'param', 'portal', 'base', 'link', 'meta', 'title', 'head',
  'form', 'input', 'button', 'textarea', 'select', 'option', 'optgroup',
  'datalist', 'output', 'video', 'audio', 'source', 'track', 'canvas',
  'picture', 'map', 'area', 'dialog', 'slot',
]);

const SVG_KEEP = new Set([
  'svg', 'g', 'defs', 'marker', 'path', 'rect', 'circle', 'ellipse', 'line',
  'polyline', 'polygon', 'text', 'tspan', 'title', 'desc',
]);

/** keep / unwrap / drop for an element of namespace `ns` (localName as parsed). */
export function elementPolicy(ns: string | null, name: string): ElementPolicy {
  if (ns === HTML_NS) {
    const tag = name.toLowerCase();
    if (HTML_KEEP.has(tag)) return 'keep';
    if (HTML_DROP.has(tag)) return 'drop';
    return 'unwrap';
  }
  if (ns === SVG_NS) {
    // SVG is case-sensitive; everything outside the list (foreignObject, use,
    // image, script, style, animate*, set, filters, a) goes with its content.
    return SVG_KEEP.has(name) ? 'keep' : 'drop';
  }
  return 'drop';
}

// Attributes allowed on every kept HTML element (URL attributes are separate).
const HTML_ATTRS = new Set([
  'class', 'id', 'title', 'lang', 'dir', 'role', 'aria-label', 'aria-hidden',
  'align', 'valign', 'width', 'height', 'colspan', 'rowspan', 'scope', 'span',
  'start', 'reversed', 'value', 'open', 'border', 'cellpadding', 'cellspacing',
  'alt', 'datetime', 'style',
]);

// Attributes allowed on every kept SVG element. Case matters: the HTML parser
// already restores SVG's camelCase (viewbox → viewBox).
const SVG_ATTRS = new Set([
  'class', 'id', 'role', 'aria-label', 'aria-hidden', 'style',
  'x', 'y', 'x1', 'y1', 'x2', 'y2', 'cx', 'cy', 'r', 'rx', 'ry', 'dx', 'dy',
  'width', 'height', 'viewBox', 'preserveAspectRatio', 'd', 'points', 'transform',
  'fill', 'fill-opacity', 'stroke', 'stroke-width', 'stroke-opacity',
  'stroke-dasharray', 'stroke-linejoin', 'stroke-linecap', 'opacity',
  'font-size', 'font-weight', 'font-family', 'font-style', 'text-anchor',
  'dominant-baseline', 'marker-end', 'marker-start', 'refX', 'refY',
  'markerWidth', 'markerHeight', 'orient',
]);

// SVG paint/marker attributes that may reference a fragment: only `url(#id)`.
const SVG_URL_ATTRS = new Set(['fill', 'stroke', 'marker-end', 'marker-start']);
const LOCAL_URL_REF = /^url\(\s*(['"]?)#[A-Za-z_][\w.:-]*\1\s*\)$/;

const ID_RE = /^[A-Za-z][\w:.-]*$/;

const HREF_SCHEMES = new Set(['http', 'https', 'mailto', 'tel', 'fmp', 'fmps']);
const SRC_SCHEMES = new Set(['https']);

/**
 * Whether `value` is an allowed URL for `kind`: `href` (links) allows http(s),
 * mailto, tel, fmp(s), fragments and relative paths; `src` (images) allows
 * https and relative/root paths (e.g. `/api/…`) — no http (mixed content),
 * no data:/blob:. Browsers ignore whitespace and control characters inside
 * a scheme (`java\tscript:`), so they are removed before the scheme is read.
 * Entities are already decoded by the parser.
 */
export function isAllowedUrl(kind: 'href' | 'src', value: string): boolean {
  // eslint-disable-next-line no-control-regex
  const compact = value.replace(/[\u0000- \u007f-\u009f]/g, '');
  const m = /^([a-z][a-z0-9+.-]*):/i.exec(compact);
  if (!m) return true; // relative path, root path, `#fragment`, `?query`
  const scheme = m[1].toLowerCase();
  return (kind === 'href' ? HREF_SCHEMES : SRC_SCHEMES).has(scheme);
}

// CSS properties allowed in `style` (layout of tables and scroll boxes only).
const STYLE_PROPS = new Set([
  'overflow', 'overflow-x', 'overflow-y', 'overflow-wrap', 'word-break',
  'width', 'min-width', 'max-width', 'table-layout', 'text-align',
  'white-space', 'vertical-align',
]);
const STYLE_VALUE_BAD = /url\s*\(|expression|image-set|javascript|\\|\/\*|[<>@{}"']/i;

/**
 * Keeps only allowed declarations of a `style` value and rebuilds it
 * (`prop: value; …`); returns null when nothing is left.
 */
export function filterStyle(value: string): string | null {
  const kept: string[] = [];
  for (const decl of value.split(';')) {
    const colon = decl.indexOf(':');
    if (colon < 0) continue;
    const prop = decl.slice(0, colon).trim().toLowerCase();
    const val = decl.slice(colon + 1).trim();
    if (!STYLE_PROPS.has(prop) || !val || STYLE_VALUE_BAD.test(val)) continue;
    kept.push(`${prop}: ${val}`);
  }
  return kept.length ? kept.join('; ') : null;
}

/**
 * Value to copy for attribute `name` of element `tag` (namespace `ns`), or
 * null to leave it out. Event handlers (`on*`), `xlink:*`, `xmlns*`, `srcset`,
 * `formaction`, `data-*` etc. are never in the lists and so never copied.
 */
export function filterAttribute(ns: string, tag: string, name: string, value: string): string | null {
  if (ns === HTML_NS) {
    const t = tag.toLowerCase();
    const n = name.toLowerCase();
    if (n === 'href') return t === 'a' && isAllowedUrl('href', value) ? value : null;
    if (n === 'src') return t === 'img' && isAllowedUrl('src', value) ? value : null;
    if (n === 'target') return t === 'a' && value === '_blank' ? value : null;
    if (!HTML_ATTRS.has(n)) return null;
    if (n === 'style') return filterStyle(value);
    if (n === 'id') return ID_RE.test(value) ? value : null;
    return value;
  }
  if (ns === SVG_NS) {
    if (!SVG_ATTRS.has(name)) return null;
    if (name === 'style') return filterStyle(value);
    if (name === 'id') return ID_RE.test(value) ? value : null;
    if (/url\s*\(/i.test(value)) {
      return SVG_URL_ATTRS.has(name) && LOCAL_URL_REF.test(value.trim()) ? value : null;
    }
    return value;
  }
  return null;
}

export interface SanitizeOptions {
  /** Rewrites an allowed href/src (e.g. prefixing `/api/` with API_BASE). */
  rewriteUrl?: (url: string) => string;
}

const MAX_DEPTH = 256;

/**
 * Parses `html` and returns a fragment of `target` that holds only the allowed
 * parts. Append it directly (`el.replaceChildren(fragment)`); do not serialize
 * and re-parse it.
 */
export function sanitizeToFragment(
  html: string,
  target: Document = document,
  options: SanitizeOptions = {},
): DocumentFragment {
  const out = target.createDocumentFragment();
  if (!html) return out;
  const parsed = new DOMParser().parseFromString(html, 'text/html');
  copyChildren(parsed.body, out, target, options, 0);
  return out;
}

/** Serialized form of sanitizeToFragment — for tests and diagnostics. */
export function sanitizeToString(html: string, options: SanitizeOptions = {}): string {
  const doc = document.implementation.createHTMLDocument('');
  const box = doc.createElement('div');
  box.appendChild(sanitizeToFragment(html, doc, options));
  return box.innerHTML;
}

function copyChildren(from: Node, to: Node, target: Document, options: SanitizeOptions, depth: number): void {
  if (depth > MAX_DEPTH) return;
  for (let child = from.firstChild; child; child = child.nextSibling) {
    if (child.nodeType === Node.TEXT_NODE) {
      to.appendChild(target.createTextNode((child as Text).data));
      continue;
    }
    if (child.nodeType !== Node.ELEMENT_NODE) continue; // comments, PIs, CDATA
    const el = child as Element;
    const ns = el.namespaceURI;
    const policy = elementPolicy(ns, el.localName);
    if (policy === 'drop') continue;
    if (policy === 'unwrap') {
      copyChildren(el, to, target, options, depth + 1);
      continue;
    }
    const copy = ns === SVG_NS
      ? target.createElementNS(SVG_NS, el.localName)
      : target.createElement(el.localName);
    for (const attr of Array.from(el.attributes)) {
      if (attr.namespaceURI) continue; // xlink:href, xml:*, xmlns:*
      let value = filterAttribute(ns as string, el.localName, attr.name, attr.value);
      if (value === null) continue;
      if ((attr.name === 'href' || attr.name === 'src') && options.rewriteUrl) {
        value = options.rewriteUrl(value);
      }
      copy.setAttribute(attr.name, value);
    }
    if (copy.getAttribute('target') === '_blank') copy.setAttribute('rel', 'noopener noreferrer');
    copyChildren(el, copy, target, options, depth + 1);
    to.appendChild(copy);
  }
}
