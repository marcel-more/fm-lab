import { useCallback, useLayoutEffect, useRef } from 'react';
import type { PrimitiveProps } from '../types';
import { API_BASE } from '../../config/apiBase';
import { sanitizeToFragment } from './_htmlSanitize';
import '../../docs/DocsEntryView.css';

/**
 * HtmlContent — renders HTML from a field of the bound row (a docs page from
 * the docs-content pipeline, or HTML built by dashboard SQL) with the
 * `.docs-content` typography of the DocsEntryView.
 *
 * Props:
 *   - field: row field holding the HTML string (default: "content_html")
 *
 * Security: EVERY string is sanitized on the client before it reaches the DOM
 * (allow-list of HTML and SVG elements, attributes, URL schemes and a few CSS
 * properties — see ./_htmlSanitize.ts). The sanitized tree is appended
 * directly, never serialized and re-parsed. Dashboard SQL carries data from the
 * FileMaker solution, so a server-side sanitizer cannot be assumed.
 *
 * Link handling as in the DocsEntryView: app-internal paths (`/docs/...`)
 * navigate through the SPA router; external protocols, `/api/` assets and
 * in-document anchors keep the browser default.
 */
export function HtmlContent({ node, row, navigate }: PrimitiveProps) {
  const props = node.props ?? {};
  const field = (props.field as string) ?? 'content_html';
  const raw = row ? String(row[field] ?? '') : '';
  const boxRef = useRef<HTMLDivElement>(null);

  // The backend renders content_html with absolute /api/... paths. In the Vite
  // dev setup /api lives on another port → prefix with API_BASE (production:
  // API_BASE is empty, the rewrite is a no-op).
  useLayoutEffect(() => {
    const box = boxRef.current;
    if (!box) return;
    const rewriteUrl = API_BASE
      ? (url: string) => (url.startsWith('/api/') ? `${API_BASE}${url}` : url)
      : undefined;
    box.replaceChildren(sanitizeToFragment(raw, document, { rewriteUrl }));
  }, [raw]);

  const handleClick = useCallback(
    (e: React.MouseEvent<HTMLDivElement>) => {
      const anchor = (e.target as HTMLElement).closest('a') as HTMLAnchorElement | null;
      if (!anchor) return;
      const href = anchor.getAttribute('href') || '';
      if (/^(?:https?:|mailto:|tel:|fmp:|fmps:)/i.test(href)) return;
      if (href.startsWith('/api/') || href.startsWith('#')) return;
      if (href.startsWith('/')) {
        e.preventDefault();
        navigate(href);
      }
    },
    [navigate],
  );

  if (!raw) return null;

  return <div ref={boxRef} className="docs-content" onClick={handleClick} />;
}
