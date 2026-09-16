/**
 * Navigation-Helper für Cross-Reference Highlight.
 *
 * Klick-Quellen, die zwischen Objekten springen (Referenzen-Tab, RefSpan,
 * LayoutCanvas Cross-Nav, DependencyGraph, CF-Token-Links, RG-Doppelklick),
 * hängen `?ref=<currentObjectUuid>` an. Der Ziel-View liest den Param und
 * blendet einen Origin-Indikator ein, der die Back-References hervorhebt.
 *
 * `currentUuid` darf weggelassen werden — z.B. bei der initialen Suche oder
 * wenn kein Origin sinnvoll ist; dann wird kein `ref` angehängt.
 *
 * Klon-Disambiguierung (`file`): Geklonte/modulare FileMaker-Dateien teilen sich
 * dieselbe Object_UUID, d.h. die bare UUID ist nicht mehr global eindeutig
 * (REST liefert sonst `AMBIGUOUS_UUID` 409). Die Objekt-Identität ist deshalb das
 * Paar (UUID, File_Name); `file` reitet als zweiter Identitäts-Begleiter auf
 * derselben Query-Param-Maschinerie wie `ref`. Fehlt `file`, gilt Graceful
 * Downgrade (bare UUID, unverändertes Verhalten auf klonfreien Lösungen).
 */

export type ObjectPathExtras = Record<string, string | null | undefined>;

// ──────────────────────────────────────────────────────────────────────────
// Zentraler Breadcrumb-Builder
//
// Eine Stelle für die gesamte Breadcrumb-Logik. Jede Seitenklasse liefert ihren
// `BreadcrumbCtx`; der Builder erzeugt die
// `BreadcrumbItem[]`-Kette nach den verbindlichen Crumb-Ziel-Regeln. Der **letzte**
// Crumb ist immer aktiv (path = null, nicht klickbar), alle übrigen verlinken auf
// ihr Leit-/Listenziel.
// ──────────────────────────────────────────────────────────────────────────

import type { BreadcrumbItem } from '../types';
import { formatObjectDisplayName } from './objectName';

/** Minimaler i18next-`t`-Vertrag (vermeidet harte TFunction-Kopplung). */
export type TranslateFn = (key: string, opts?: Record<string, unknown>) => string;

export type BreadcrumbCtx =
  | { kind: 'search' }
  | { kind: 'hierarchy' }
  | { kind: 'object'; objectType: string; objectName: string; objectPath?: string | null; tab?: string | null }
  | { kind: 'graph' }
  | { kind: 'graphNode'; nodeName: string }
  | { kind: 'graphSegment'; segment: string }
  | { kind: 'relationships'; file: string }
  | { kind: 'file'; fileLabel: string }
  | { kind: 'dashboards'; folderCrumbs?: BreadcrumbItem[] }
  | { kind: 'dashboard'; title: string; folderCrumbs?: BreadcrumbItem[] }
  | { kind: 'customQueries'; category?: string | null }
  | { kind: 'query'; name: string; category?: string | null }
  | { kind: 'tests'; folderCrumbs?: BreadcrumbItem[] }
  | { kind: 'testDetail'; testLabel: string; folderCrumbs?: BreadcrumbItem[] }
  | { kind: 'docs' }
  | { kind: 'docsSet'; setLabel: string }
  | { kind: 'docsCategory'; setId: string; setLabel: string; categoryLabel: string }
  | { kind: 'xmlImport' }
  | { kind: 'cluster' }
  | { kind: 'fmSpec' }
  | { kind: 'fmSpecStep'; stepName: string }
  | { kind: 'fmSpecFunction'; name: string }
  | { kind: 'fmSpecTrigger'; name: string }
  | { kind: 'settings' };

/**
 * Kategorie-Krume der Custom Queries. Anders als Dashboards/Tests haben Queries
 * keinen Ordnerbaum — ihre Gruppierung ist der `@category:`-Header des
 * SQL-Templates, also genau EINE Ebene. Der Wert ist unlokalisiert (er steht
 * einsprachig im Template-Header); das Label ist deshalb der Rohwert.
 */
function queryCategoryCrumb(category?: string | null): BreadcrumbItem[] {
  if (!category) return [];
  return [{ label: category, path: `/query?category=${encodeURIComponent(category)}` }];
}

/** Letzten Crumb auf aktiv (kein Link) setzen — Regel 4. */
function finalize(items: BreadcrumbItem[]): BreadcrumbItem[] {
  if (items.length > 0) {
    items[items.length - 1] = { ...items[items.length - 1], path: null };
  }
  return items;
}

export function buildBreadcrumb(ctx: BreadcrumbCtx, t: TranslateFn): BreadcrumbItem[] {
  const home: BreadcrumbItem = { label: t('nav:crumbs.home'), path: '/' };
  const search: BreadcrumbItem = { label: t('nav:crumbs.search'), path: '/' };
  const graph: BreadcrumbItem = { label: t('nav:crumbs.graph'), path: '/atlas' };
  const docs: BreadcrumbItem = { label: t('nav:crumbs.docs'), path: '/docs' };
  const dashboards: BreadcrumbItem = { label: t('nav:crumbs.dashboards'), path: '/dashboard' };
  const customQueries: BreadcrumbItem = { label: t('nav:crumbs.customQueries'), path: '/query' };

  switch (ctx.kind) {
    case 'search':
      return finalize([home, search]);
    case 'hierarchy':
      return finalize([home, { label: t('nav:crumbs.hierarchy'), path: '/?mode=tree' }]);
    case 'object': {
      const typeLabel = t(`types:objectTypes.${ctx.objectType}`, { defaultValue: ctx.objectType });
      const items: BreadcrumbItem[] = [
        home,
        search,
        { label: typeLabel, path: `/?type=${encodeURIComponent(ctx.objectType)}` },
        { label: formatObjectDisplayName(ctx.objectType, ctx.objectName), path: ctx.objectPath ?? null },
      ];
      // Tab-Crumb nur, wenn ein nicht-Default-Tab aktiv ist (V6).
      if (ctx.tab && ctx.tab !== 'detail') {
        items.push({ label: t(`nav:detailView.tabs.${ctx.tab}`, { defaultValue: ctx.tab }), path: null });
      }
      return finalize(items);
    }
    case 'graph':
      return finalize([home, graph]);
    case 'graphNode':
      return finalize([home, graph, { label: ctx.nodeName, path: null }]);
    case 'graphSegment':
      return finalize([home, graph, { label: ctx.segment, path: null }]);
    case 'relationships':
      return finalize([home, graph, { label: t('nav:crumbs.relationships'), path: '/atlas' }, { label: ctx.file, path: null }]);
    case 'file':
      return finalize([home, { label: ctx.fileLabel, path: null }]);
    case 'dashboards':
      // Folder navigation of the dashboard overview rides on the ONE unified
      // breadcrumb: Home / Dashboards / <Rubrik> / <Unterrubrik>. Each folder
      // crumb links to `/dashboard?folder=<teilpfad>`; finalize() makes the
      // last one the active page.
      return finalize([home, dashboards, ...(ctx.folderCrumbs ?? [])]);
    case 'dashboard':
      // Same shape as the overview above: the rubric path sits between
      // `Dashboards` and the dashboard itself, each segment linking back into
      // `/dashboard?folder=<teilpfad>`. `folderCrumbs` arrives with the
      // envelope, so before it loads the chain is just Home / Dashboards / <title>.
      return finalize([home, dashboards, ...(ctx.folderCrumbs ?? []), { label: ctx.title, path: null }]);
    case 'customQueries':
      return finalize([home, customQueries, ...queryCategoryCrumb(ctx.category)]);
    case 'query':
      // Queries have no folder tree — their grouping is the `@category:` header
      // of the SQL template. It behaves like one rubric level: the crumb links
      // to `/query?category=<kategorie>`, which filters the overview.
      return finalize([home, customQueries, ...queryCategoryCrumb(ctx.category), { label: ctx.name, path: null }]);
    case 'tests':
      // Folder navigation of the tests overview rides on the same unified
      // breadcrumb as the dashboard one: Home / Tests / <Rubrik> / …
      return finalize([
        home,
        { label: t('nav:crumbs.tests'), path: '/tests' },
        ...(ctx.folderCrumbs ?? []),
      ]);
    case 'testDetail':
      // Same shape as the dashboard detail: the tier rubric sits between
      // `Tests` and the test itself, each segment linking into
      // `/tests?folder=<teilpfad>`. `folderCrumbs` arrives with the test
      // definition, so before it loads the chain is Home / Tests / <label>.
      return finalize([
        home,
        { label: t('nav:crumbs.tests'), path: '/tests' },
        ...(ctx.folderCrumbs ?? []),
        { label: ctx.testLabel, path: null },
      ]);
    case 'docs':
      return finalize([home, docs]);
    case 'docsSet':
      return finalize([home, docs, { label: ctx.setLabel, path: null }]);
    case 'docsCategory':
      return finalize([home, docs, { label: ctx.setLabel, path: `/docs/${encodeURIComponent(ctx.setId)}` }, { label: ctx.categoryLabel, path: null }]);
    case 'xmlImport':
      return finalize([home, { label: t('nav:crumbs.xmlImport'), path: '/xml-import' }]);
    case 'cluster':
      return finalize([home, { label: t('nav:crumbs.cluster'), path: '/cluster' }]);
    case 'fmSpec':
      return finalize([home, { label: t('nav:crumbs.fmSpec'), path: '/fm-spec' }]);
    case 'fmSpecStep':
      return finalize([home, { label: t('nav:crumbs.fmSpec'), path: '/fm-spec' }, { label: ctx.stepName, path: null }]);
    case 'fmSpecFunction':
      return finalize([home, { label: t('nav:crumbs.fmSpec'), path: '/fm-spec' }, { label: ctx.name, path: null }]);
    case 'fmSpecTrigger':
      return finalize([home, { label: t('nav:crumbs.fmSpec'), path: '/fm-spec?tab=triggers' }, { label: ctx.name, path: null }]);
    case 'settings':
      return finalize([home, { label: t('nav:crumbs.settings'), path: '/settings' }]);
  }
}

/**
 * Baut einen `/object/<uuid>`-Pfad mit optionalem Origin-, File- und Zusatz-Parametern.
 *
 * - `originUuid` wird als `ref`-Query-Param angehängt (Cross-Reference Highlight).
 * - `file` wird als `file`-Query-Param angehängt (Klon-Disambiguierung). Leeres /
 *   `null` / `undefined` → kein Param ⇒ Graceful Downgrade auf bare-UUID.
 * - `extras` erlauben zusätzliche Query-Params (z.B. `tab=graph`); `null`/`undefined`
 *   Werte werden ignoriert, damit Aufrufer nicht selbst filtern müssen.
 *
 * Self-Reference (`originUuid === targetUuid`) wird BEWUSST mitgesetzt: rekursive
 * CustomFunctions/Scripts referenzieren sich selbst, und der Klick auf den
 * Self-Eintrag (Referenzen-Tab oder Token-Link in der eigenen Formel) soll die
 * rekursive Stelle hervorheben. Für nicht-rekursive Objekte erzeugt ein Self-`ref`
 * 0 Token-Treffer → die RefOriginPill blendet sich aus (count===0) und es wird
 * nichts markiert — also kein Störsignal.
 */
export function buildObjectPath(
  targetUuid: string,
  originUuid?: string | null,
  file?: string | null,
  extras?: ObjectPathExtras,
): string {
  const params = new URLSearchParams();
  if (originUuid) {
    params.set('ref', originUuid);
  }
  if (file) {
    params.set('file', file);
  }
  if (extras) {
    for (const [k, v] of Object.entries(extras)) {
      if (v == null || v === '') continue;
      params.set(k, v);
    }
  }
  const qs = params.toString();
  return qs ? `/object/${targetUuid}?${qs}` : `/object/${targetUuid}`;
}

/**
 * Container-aware Navigation für Sub-Knoten.
 *
 * Sub-Knoten wie LayoutObject oder ScriptStep haben keinen sinnvollen Standalone-
 * Detail-View — ihr Wert liegt im Container-Kontext. Wenn ein Reference-Item
 * (oder Graph-Node) einen `containerUuid` mitführt, wird transparent der
 * Container geöffnet und der Sub-Knoten als ref-Highlight gesetzt.
 *
 * Fallback (kein containerUuid): identisch zu `buildObjectPath(targetUuid, originUuid, file)`.
 *
 * Beispiel — Klick auf LayoutObject im Script-Referenzen-Tab:
 *   buildNavigablePath('<layoutobject>', '<script>', '<layout>', '<file>')
 *   → '/object/<layout>?ref=<layoutobject>&file=<file>'   (Layout öffnet sich, LayoutObject highlighted)
 *
 * Beispiel — Klick auf Field im Script-Referenzen-Tab:
 *   buildNavigablePath('<field>', '<script>', null, '<file>')
 *   → '/object/<field>?ref=<script>&file=<file>'          (normales Verhalten)
 */
export function buildNavigablePath(
  targetUuid: string,
  originUuid?: string | null,
  containerUuid?: string | null,
  file?: string | null,
  extras?: ObjectPathExtras,
): string {
  if (containerUuid && containerUuid !== targetUuid) {
    // Sub-Knoten → Container öffnen, Sub-Knoten als ref. Der ursprüngliche
    // Origin (originUuid) geht in dem Fall verloren — der spezifische Treffer
    // (Sub-Knoten) ist die nützlichere Hervorhebung. Browser-Back führt zurück.
    // `file` gilt für den geöffneten Container; Container und Sub-Knoten liegen
    // per Definition in derselben Datei, also ist es dieselbe File_Name.
    return buildObjectPath(containerUuid, targetUuid, file, extras);
  }
  return buildObjectPath(targetUuid, originUuid, file, extras);
}

/**
 * Vereinfachte Variante für Layout-Vollbild (`/layout/:uuid`) — gleiches Schema
 * inkl. `file`-Klon-Disambiguierung (siehe buildObjectPath).
 */
export function buildLayoutPath(
  layoutUuid: string,
  originUuid?: string | null,
  file?: string | null,
  extras?: ObjectPathExtras,
): string {
  const params = new URLSearchParams();
  // Self-Reference bewusst mitgesetzt (siehe buildObjectPath) — degradiert für
  // nicht-rekursive Fälle still auf 0 Treffer.
  if (originUuid) {
    params.set('ref', originUuid);
  }
  if (file) {
    params.set('file', file);
  }
  if (extras) {
    for (const [k, v] of Object.entries(extras)) {
      if (v == null || v === '') continue;
      params.set(k, v);
    }
  }
  const qs = params.toString();
  return qs ? `/layout/${layoutUuid}?${qs}` : `/layout/${layoutUuid}`;
}
