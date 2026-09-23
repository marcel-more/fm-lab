import { API_BASE } from '../config/apiBase';
import type { NavigateFunction } from 'react-router-dom';
import { substituteDeep } from './tokens';

/**
 * Dashboard Click-Action-Whitelist.
 * Token-Substitution erfolgt VOR der Action.
 */

export type ActionName =
  | 'openObject'
  | 'openFile'
  | 'openDashboard'
  | 'openDocsEntry'
  | 'navigate'
  | 'applyFilter'
  | 'runQuery'
  | 'openUrl'
  | 'copyToClipboard';

export interface ActionSpec {
  action: string;
  /** Args als Objekt — Token-Substitution wird rekursiv angewendet. */
  args?: Record<string, unknown>;
  /** Alternative: Args als "k=v&k2=v2"-String (z.B. aus DB-Spalten). */
  argsString?: string;
}

export interface ActionContext {
  navigate: NavigateFunction;
}

function parseArgsString(str: string): Record<string, string> {
  const out: Record<string, string> = {};
  if (!str) return out;
  // Wir unterstützen "k=v&k2=v2" und "k=v, k2=v2"
  const pairs = str.split(/[&,]/).map(s => s.trim()).filter(Boolean);
  for (const p of pairs) {
    const eq = p.indexOf('=');
    if (eq < 0) continue;
    const key = p.slice(0, eq).trim();
    const rawValue = p.slice(eq + 1).trim();
    // URL-decode the value so that backends that emit %XX sequences in
    // action_args (e.g. encodeURIComponent("fn:1") → "fn%3A1") deliver clean
    // values to action handlers. Without this, URLSearchParams would re-encode
    // the %XX as %25XX, producing a double-encoded query string.
    let value = rawValue;
    try {
      value = decodeURIComponent(rawValue);
    } catch {
      // Malformed percent-encoding — keep the raw value.
    }
    out[key] = value;
  }
  return out;
}

/**
 * Resolviert Tokens in einem ActionSpec gegen die Datenzeile,
 * gibt {action, args} mit fertig substituierten Args zurück oder null,
 * wenn die Action nach Substitution kein gültiger Name mehr ist.
 */
export function resolveAction(
  spec: ActionSpec | undefined,
  row: Record<string, unknown> | undefined
): { action: string; args: Record<string, unknown> } | null {
  if (!spec || !spec.action) return null;

  const resolvedAction = (substituteDeep(spec.action, row) as string) || '';
  if (!resolvedAction) return null;

  let args: Record<string, unknown> = {};
  if (spec.args) {
    args = (substituteDeep(spec.args, row) as Record<string, unknown>) || {};
  }
  if (spec.argsString) {
    const stringResolved = (substituteDeep(spec.argsString, row) as string) || '';
    args = { ...parseArgsString(stringResolved), ...args };
  }
  return { action: resolvedAction, args };
}

/**
 * "Mode"-Params, die bei openDashboard-Selbstnavigation (Klick innerhalb
 * desselben Dashboards) erhalten bleiben — im Gegensatz zu Filter-Params
 * (api_family, host, ref_type, …), die klick-skopiert zurückgesetzt werden.
 *
 * Zwei Quellen, vereinigt:
 * - Legacy-Basis-Set für Bestands-Bundles ohne Deklaration:
 *   `api_set` = Klassifikations-Set, `file` = App-Dateifilter, `comment` = Kommentar-Linse.
 * - Manifest-deklarierte Params mit `sticky: true`, die der DashboardHost beim
 *   Laden über `registerStickyDashboardParams` meldet.
 */
const STICKY_DASHBOARD_PARAMS = ['api_set', 'file', 'comment'];

let manifestSticky: { dashboardId: string; params: string[] } | null = null;

/**
 * Meldet die sticky-deklarierten Manifest-Params des aktuell gemounteten
 * Dashboards. Wird bei jedem Manifest-Load überschrieben; ein Eintrag wirkt
 * nur, wenn die Selbstnavigation dieselbe Dashboard-ID trifft.
 */
export function registerStickyDashboardParams(dashboardId: string, params: string[]): void {
  manifestSticky = { dashboardId, params };
}

function stickyParamsFor(dashboardId: string): string[] {
  const declared = manifestSticky?.dashboardId === dashboardId ? manifestSticky.params : [];
  return [...STICKY_DASHBOARD_PARAMS, ...declared];
}

/**
 * Führt eine Action aus. Unbekannte Actions werden geloggt, aber ignoriert.
 */
export function dispatchAction(
  spec: ActionSpec | undefined,
  row: Record<string, unknown> | undefined,
  ctx: ActionContext
): void {
  const resolved = resolveAction(spec, row);
  if (!resolved) return;
  const { action, args } = resolved;

  switch (action as ActionName | string) {
    case 'openObject': {
      const uuid = String(args.uuid || '');
      if (!uuid) {
        console.warn('[dashboard] openObject called without uuid', args);
        return;
      }
      // Zwei Aufruf-Formen (analog openDashboard):
      //   args = { uuid, params: { tab, ref, ... } }   — explizit verschachtelt
      //   args = { uuid, tab, ref, ... }               — flat, kommt aus
      //                                                 argsString="uuid=...&tab=..."
      // Im Flat-Fall heben wir alles außer uuid in den Query-String.
      const nested = args.params as Record<string, unknown> | undefined;
      const flat: Record<string, unknown> = {};
      if (!nested) {
        for (const [k, v] of Object.entries(args)) {
          if (k === 'uuid') continue;
          if (v != null) flat[k] = v;
        }
      }
      const merged = nested ?? flat;
      // A FileMaker file has its own detail page (`/file/:name`, the `file`
      // bundle). The generic object view knows no File renderer, so a File row
      // would land on a bare header. Rule bundles reach this branch two ways:
      // with a literal `type: "File"` (export_ddr_missing) and with a `{{type}}`
      // taken from ObjectCatalog, which yields 'File' on cloned files
      // (uuid_clone_collisions) — hence the redirect lives here and not in the
      // single bundle. Without a file name we keep the generic route: the File
      // object's UUID alone cannot address `/file/:name`.
      if (String(merged.type ?? '') === 'File' && String(merged.file ?? '')) {
        ctx.navigate(`/file/${encodeURIComponent(String(merged.file))}`);
        return;
      }
      const qs = Object.keys(merged).length > 0
        ? new URLSearchParams(
            Object.fromEntries(
              Object.entries(merged)
                .filter(([, v]) => v != null && String(v) !== '')
                .map(([k, v]) => [k, String(v)])
            )
          ).toString()
        : '';
      ctx.navigate(`/object/${encodeURIComponent(uuid)}${qs ? '?' + qs : ''}`);
      return;
    }
    case 'openFile': {
      // Navigates to the file-detail view /file/:filename. Dedicated action
      // (not `navigate`) because file names carry spaces/special chars — the
      // generic path substitution does not URL-encode, so we encode here
      // (symmetric with openObject) and the route param is auto-decoded.
      const file = String(args.file || '');
      if (!file) {
        console.warn('[dashboard] openFile called without file', args);
        return;
      }
      ctx.navigate(`/file/${encodeURIComponent(file)}`);
      return;
    }
    case 'openDashboard': {
      const id = String(args.id || '');
      if (!id) {
        console.warn('[dashboard] openDashboard called without id', args);
        return;
      }
      // Two supported shapes:
      //   args = { id, params: { ... } }         — nested form, used by hand-written JSON
      //   args = { id, ...flatParams }           — flat form, produced by argsString="id=...&docset=..."
      // The flat form lifts everything except `id` itself into query-string params.
      const nested = args.params as Record<string, unknown> | undefined;
      const flat: Record<string, unknown> = {};
      if (!nested) {
        for (const [k, v] of Object.entries(args)) {
          if (k === 'id') continue;
          if (v != null) flat[k] = v;
        }
      }
      const merged = nested ?? flat;
      // Mode-Params bei Selbstnavigation bewahren (siehe STICKY_DASHBOARD_PARAMS):
      // openDashboard ersetzt sonst den ganzen Querystring → ein aktives api_set
      // ginge verloren, eine Familie aus diesem Set verschwände und die Detailliste
      // bliebe leer. Neue Args gewinnen über den bewahrten Wert.
      try {
        const curId = decodeURIComponent(
          window.location.pathname.split('/').filter(Boolean).pop() || '',
        );
        if (curId === id) {
          const cur = new URLSearchParams(window.location.search);
          for (const key of stickyParamsFor(id)) {
            const value = cur.get(key);
            if (value != null && value !== '' && !(key in merged)) merged[key] = value;
          }
        }
      } catch {
        // Kein window (SSR/Tests) — Bewahrung überspringen.
      }
      const qs = Object.keys(merged).length > 0
        ? '?' +
          new URLSearchParams(
            Object.fromEntries(
              Object.entries(merged)
                .filter(([, v]) => v != null)
                .map(([k, v]) => [k, String(v)])
            )
          ).toString()
        : '';
      ctx.navigate(`/dashboard/${encodeURIComponent(id)}${qs}`);
      return;
    }
    case 'openDocsEntry': {
      // Navigates to /docs/:set/:category/:fn. Used by docset_category Functions-Liste
      // to open the Function-Volltext-View.
      const setId = String(args.set || args.docset || '');
      const category = String(args.category || '');
      const fn = String(args.fn || args.function || '');
      if (!setId || !category || !fn) {
        console.warn('[dashboard] openDocsEntry needs set/category/fn', args);
        return;
      }
      const lang = args.lang ? String(args.lang) : '';
      const qs = lang ? `?lang=${encodeURIComponent(lang)}` : '';
      ctx.navigate(`/docs/${encodeURIComponent(setId)}/${encodeURIComponent(category)}/${encodeURIComponent(fn)}${qs}`);
      return;
    }
    case 'navigate': {
      // Generic SPA-Navigation to an app-internal path. Replaces the
      // id-Spezialfälle in openDashboard for the Leitseiten (`/dashboard`,
      // `/query`, `/docs`, `/xml-import`).
      const path = String(args.path || '');
      if (!path.startsWith('/')) {
        console.warn('[dashboard] navigate requires an app-internal path (leading "/")', args);
        return;
      }
      // Optionaler Suchzustand: `q` reist als Query-Param mit, damit die
      // Zielseite ihr Suchfeld daraus vorbelegen kann (Doc-Set-Rubrikliste →
      // Eintragsliste). Ohne das Argument bleibt der Pfad unverändert.
      const q = args.q != null ? String(args.q) : '';
      if (!q) {
        ctx.navigate(path);
        return;
      }
      ctx.navigate(`${path}${path.includes('?') ? '&' : '?'}q=${encodeURIComponent(q)}`);
      return;
    }
    case 'applyFilter': {
      const usp = new URLSearchParams();
      // Tree/Hierarchie-Deep-Link: mode=tree schaltet die Startseite in den
      // Hierarchie-Modus, subtype wählt den Baum (script/layout/customfunction).
      // SearchView liest beide beim Mount aus der URL.
      if (args.mode) usp.set('mode', String(args.mode));
      if (args.subtype) usp.set('subtype', String(args.subtype));
      if (args.q) usp.set('q', String(args.q));
      if (args.type) usp.set('type', String(args.type));
      if (args.file) usp.set('file', String(args.file));
      if (args.label) usp.set('label', String(args.label));
      // Pseudo-Token-Filter (BuiltinFunction/ScriptStepType/PluginFunction):
      // initialCategory wird vom PseudoTokenView aus ?category= gelesen.
      if (args.category) usp.set('category', String(args.category));
      if (args.sort) usp.set('sort', String(args.sort));
      const qs = usp.toString();
      ctx.navigate(qs ? `/?${qs}` : '/');
      return;
    }
    case 'runQuery': {
      const q = String(args.query || '');
      if (!q) {
        console.warn('[dashboard] runQuery called without query', args);
        return;
      }
      // Phase 2: _generic-Dashboard. Vorerst: navigiere auf /query/:name (Stub).
      ctx.navigate(`/query/${encodeURIComponent(q)}`);
      return;
    }
    case 'openUrl': {
      const url = String(args.url || '');
      if (!url) return;
      // Local API paths: prefix with VITE_API_URL and navigate in the SAME tab
      // (no confirmation) — they hit our own backend (e.g.
      // /api/plugin-docs/mbs/Clipboard.GetText/page returns the locally
      // mirrored MBS help HTML). Same-tab navigation keeps the browser back
      // button as the obvious way back to the dashboard.
      if (url.startsWith('/api/')) {
        const apiBase = (API_BASE).replace(/\/+$/, '');
        window.location.href = `${apiBase}${url}`;
        return;
      }
      // External URLs: require https:// and ask for confirmation. These stay
      // in a new tab so the user doesn't lose dashboard context to a third
      // party site.
      if (!url.startsWith('https://')) {
        console.warn('[dashboard] openUrl requires https:// or /api/', args);
        return;
      }
      const ok = window.confirm(`Externe URL öffnen?\n${url}`);
      if (ok) window.open(url, '_blank', 'noopener,noreferrer');
      return;
    }
    case 'copyToClipboard': {
      const value = String(args.value ?? '');
      navigator.clipboard?.writeText(value).catch(err => {
        console.warn('[dashboard] copyToClipboard failed', err);
      });
      return;
    }
    default:
      console.warn(`[dashboard] unknown action: ${action}`);
  }
}
