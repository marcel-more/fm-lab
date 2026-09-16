import { API_BASE } from '../config/apiBase';

/**
 * Docs manifest API (GET /api/docs) — catalog + installed doc-sets.
 * Plain fetch; the catalog is solution-independent and changes only when the
 * maintainer edits `.fmlab/docs.json`, so one in-memory cache per SPA session
 * is enough (used by the DocsSetPage bundle switch).
 */

/**
 * Adresse eines Eintrags im Doku-Browser — das Gegenstück eines Steps,
 * einer Funktion oder einer Plugin-Funktion in einem installierten Docset.
 * Der Server liefert `null`, wenn das Docset fehlt oder die Seite im Spiegel
 * nicht existiert: der Link wird nur gerendert, wenn das Ziel wirklich da ist.
 */
export interface DocsEntryRef {
  set: string;
  category: string;
  entry: string;
}

/** SPA-Route der Doku-Seite; `lang` reist als Deep-Link-State mit (`?lang=`). */
export function buildDocsEntryPath(ref: DocsEntryRef | null | undefined, lang: string): string | null {
  if (!ref) return null;
  return `/docs/${encodeURIComponent(ref.set)}/${encodeURIComponent(ref.category)}/${encodeURIComponent(ref.entry)}?lang=${encodeURIComponent(lang)}`;
}

/**
 * Adresse einer Docset-RUBRIK (eine Ebene über dem Eintrag) — z. B. die
 * Komponentenseite eines Plugins. Wie `DocsEntryRef` server-seitig null,
 * wenn das Docset fehlt oder die Rubrik dort nicht existiert.
 */
export interface DocsCategoryRef {
  set: string;
  category: string;
}

/** SPA-Route der Rubrikseite; `lang` reist als Deep-Link-State mit (`?lang=`). */
export function buildDocsCategoryPath(ref: DocsCategoryRef | null | undefined, lang: string): string | null {
  if (!ref) return null;
  return `/docs/${encodeURIComponent(ref.set)}/${encodeURIComponent(ref.category)}?lang=${encodeURIComponent(lang)}`;
}

export interface DocsCatalogEntry {
  id: string;
  name: string;
  description: string | null;
  source_url: string | null;
  skill: string | null;
  languages: string[];
  visible: boolean;
  references: boolean;
  output_format: string;
  download_format: string | null;
  index_page: string | null;
  /** Content-root-relative page slug rendered as the doc-set's start page (null → default listing). */
  start_page: string | null;
}

interface DocsManifestResponse {
  catalog: DocsCatalogEntry[];
}

let catalogPromise: Promise<DocsCatalogEntry[]> | null = null;

export function fetchDocsCatalog(): Promise<DocsCatalogEntry[]> {
  if (!catalogPromise) {
    catalogPromise = (async () => {
      const res = await fetch(`${API_BASE}/api/docs`);
      const json = await res.json();
      if (!json.success) {
        throw new Error(json.error?.message || `Request failed (HTTP ${res.status})`);
      }
      return (json.data as DocsManifestResponse).catalog ?? [];
    })().catch(err => {
      // Fehlversuche nicht dauerhaft cachen — nächster Aufruf versucht es erneut.
      catalogPromise = null;
      throw err;
    });
  }
  return catalogPromise;
}
