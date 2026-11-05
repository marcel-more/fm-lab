import type { ReactNode } from 'react';
import { useEffect, useState } from 'react';
import { useParams, useSearchParams, Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { fetchSolutions } from '../api/solutionsApi';
import { getTest } from '../api/testsApi';
import { getDashboardDataset } from '../api/dashboardApi';
import { fetchDocsCatalog } from '../api/docsApi';
import { useApiLang } from '../hooks/useApiLang';
import { getSelectedSolution } from '../lib/solutionStore';
import { DashboardHost } from './DashboardHost';
import { CleanupNotice } from './CleanupNotice';
import { FavoriteStar } from './FavoriteStar';
import { SubNav } from '../components/SubNav';
import { StatusBar } from '../components/StatusBar';
import { SolutionSettingsControls } from '../components/SolutionSettingsControls';
import { TitleBox } from '../components/TitleBox';
import { buildBreadcrumb, type BreadcrumbCtx } from '../lib/navigation';
import type { BreadcrumbItem } from '../types';

/**
 * Leitseiten: clean top-level routes that render an
 * existing dashboard bundle with a hard-wired id and a proper breadcrumb —
 * replacing the generic `/dashboard/:id` detour for the index bundles.
 */

function titleize(s: string): string {
  return s.replace(/[-_]/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

function BundlePage({
  id,
  ctx,
  params,
  pageTitle,
  pageDescription,
  titleActions,
  statusTrailing,
  notice,
}: {
  id: string;
  ctx: BreadcrumbCtx;
  params?: Record<string, unknown>;
  /**
   * Leitseiten pass title + description → rendered as a framed TitleBox; das
   * darunter liegende Bundle enthält dann nur noch die Einträge (kein eigener
   * Card-Titel/-Subtitel). Object-entry bundles (docset_home/category) lassen
   * beides weg und nutzen ihre eigene Hero-Titelbox.
   */
  pageTitle?: string;
  pageDescription?: string;
  /** Optional right-aligned quick-jump buttons on the title row. */
  titleActions?: ReactNode;
  /** Optional controls pinned far-right of the back/status row. */
  statusTrailing?: ReactNode;
  /** Optional hint rendered between the title box and the bundle. */
  notice?: ReactNode;
}) {
  const { t } = useTranslation(['nav']);
  return (
    <div className="app">
      <SubNav breadcrumbs={buildBreadcrumb(ctx, t)} />
      <StatusBar trailingActions={statusTrailing} />
      {pageTitle && <TitleBox title={pageTitle} subtitle={pageDescription} actions={titleActions} />}
      {notice}
      <DashboardHost id={id} params={params} />
    </div>
  );
}

/**
 * `/file/:filename` → `file` bundle (per-file detail view). Breadcrumb
 * `Home / {Dateiname}`. The file name is passed both as the bundle param
 * (drives the `:file`-scoped datasets) and as the page title.
 */
export function FileDetailPage() {
  const { filename } = useParams<{ filename: string }>();
  const { t } = useTranslation(['nav']);
  const file = filename ?? '';
  const enc = encodeURIComponent(file);
  const titleActions = (
    <>
      <Link className="title-box__action" to={`/?file=${enc}`}>
        {t('nav:fileActions.search', { defaultValue: 'Search' })}
      </Link>
      <Link
        className="title-box__action"
        to={`/atlas?segment_by=file&seg=${enc}&seg_label=${enc}`}
      >
        {t('nav:fileActions.drilldown', { defaultValue: 'Drill-down' })}
      </Link>
    </>
  );
  return (
    <BundlePage
      id="file"
      ctx={{ kind: 'file', fileLabel: file }}
      params={{ file }}
      pageTitle={file}
      titleActions={titleActions}
    />
  );
}

/**
 * Folder crumbs for a bundle page whose TileGrid runs in `folderNav` mode.
 *
 * The folder navigation (`?folder=`) rides on the ONE unified top breadcrumb
 * (SubNav) — no second breadcrumb inside the panel. Localized segment labels
 * come from the very `folders` dataset the grid itself reads, so labels can
 * never drift between crumb and tile; while it loads (or for unknown paths)
 * the humanized segment is the fallback.
 *
 * `basePath` is the page's own route — each crumb links back to it with the
 * partial path, so a deep rubric stays navigable segment by segment.
 */
function useFolderCrumbs(bundleId: string, basePath: string) {
  const lang = useApiLang();
  const [searchParams] = useSearchParams();
  const folder = searchParams.get('folder') ?? '';
  const [folderLabels, setFolderLabels] = useState<Map<string, string>>(new Map());

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const rows = await getDashboardDataset(bundleId, 'folders', undefined, lang);
        if (cancelled) return;
        const map = new Map<string, string>();
        for (const row of rows) {
          map.set(String(row.path), String(row.label ?? row.path));
        }
        setFolderLabels(map);
      } catch {
        /* labels degrade to humanized segments */
      }
    })();
    return () => { cancelled = true; };
  }, [bundleId, lang]);

  if (!folder) return undefined;
  return folder.split('/').map((seg, i, segs) => {
    const prefix = segs.slice(0, i + 1).join('/');
    return {
      label: folderLabels.get(prefix) ?? titleize(seg),
      path: `${basePath}?folder=${encodeURIComponent(prefix)}`,
    };
  });
}

/**
 * `/dashboard` → `dashboards` bundle. Breadcrumb `Home / Dashboards / <Rubrik>…`.
 */
export function DashboardsPage() {
  const { t } = useTranslation(['nav']);
  const folderCrumbs = useFolderCrumbs('dashboards', '/dashboard');

  return (
    <BundlePage
      id="dashboards"
      ctx={{ kind: 'dashboards', folderCrumbs }}
      pageTitle={t('nav:crumbs.dashboards') as string}
      pageDescription={t('nav:leitDescription.dashboards') as string}
      notice={<CleanupNotice kind="dashboards" />}
    />
  );
}

/**
 * `/tests` → `tests_overview` bundle. Breadcrumb `Home / Tests / <Rubrik>…`.
 *
 * Same folder navigation as the dashboard overview — the grid reads the test
 * category folders (`builtin:list_test_folders`), the crumbs read the same
 * dataset.
 */
export function TestsOverviewPage() {
  const { t } = useTranslation(['nav']);
  const folderCrumbs = useFolderCrumbs('tests_overview', '/tests');

  return (
    <BundlePage
      id="tests_overview"
      ctx={{ kind: 'tests', folderCrumbs }}
      pageTitle={t('nav:crumbs.tests') as string}
      pageDescription={t('nav:leitDescription.tests') as string}
      notice={<CleanupNotice kind="tests" />}
    />
  );
}

/**
 * `/tests/:id` → `test_detail` bundle (per-test detail view). Breadcrumb
 * `Home / Tests / {Titel}`. The bundle datasets take the id as their param;
 * title and description come from the test definition itself — one light
 * fetch, so breadcrumb and title box read the test's own words instead of
 * its id. An unknown id keeps the id as the label; the bundle then renders
 * its "not found" guard card.
 */
export function TestDetailPage() {
  const { id } = useParams<{ id: string }>();
  const testId = id ?? '';
  const [title, setTitle] = useState<string | null>(null);
  const [description, setDescription] = useState<string | null>(null);
  // Tier rubric of the test — same light fetch as title/description, so the
  // crumb chain matches the dashboard detail: Home / Tests / <Rubrik> / <Test>.
  const [folderCrumbs, setFolderCrumbs] = useState<BreadcrumbItem[] | undefined>(undefined);
  // The star only appears for a test that exists — an unknown id cannot be favorited.
  const [found, setFound] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setFound(false);
    setTitle(null);
    setDescription(null);
    setFolderCrumbs(undefined);
    (async () => {
      try {
        const test = await getTest(testId);
        if (cancelled) return;
        setFound(true);
        setTitle(test.title);
        setDescription(test.description);
        setFolderCrumbs((test.folder_crumbs ?? []).map(c => ({
          label: c.label,
          path: `/tests?folder=${encodeURIComponent(c.path)}`,
        })));
      } catch {
        /* unknown/invalid id — the bundle's guard card explains it */
      }
    })();
    return () => { cancelled = true; };
  }, [testId]);

  return (
    <BundlePage
      id="test_detail"
      ctx={{ kind: 'testDetail', testLabel: title ?? testId, folderCrumbs }}
      params={{ id: testId }}
      pageTitle={title ?? testId}
      pageDescription={description ?? undefined}
      titleActions={found ? <FavoriteStar id={testId} kind="test" /> : undefined}
    />
  );
}

/** `/docs` → `docs_overview` bundle. Breadcrumb `Home / Docs`. */
export function DocsOverviewPage() {
  const { t } = useTranslation(['nav']);
  return (
    <BundlePage
      id="docs_overview"
      ctx={{ kind: 'docs' }}
      pageTitle={t('nav:crumbs.docs') as string}
      pageDescription={t('nav:leitDescription.docs') as string}
    />
  );
}

/**
 * `/xml-import` → `xml_convert` bundle. Breadcrumb `Home / XML Import`.
 *
 * Kontext-bewusst: `?solution_id=<id>` importiert eine beliebige Lösung,
 * OHNE sie zu aktivieren (Einstieg: Settings-Lösungsliste). Ohne Parameter
 * gilt die aktive Lösung. Die Titelzeile nennt immer die Kontext-Lösung
 * („XML-Import: <Anzeigename>"); bei Kontext ≠ aktiv erklärt eine Notiz,
 * dass die angezeigten Analysedaten sich erst nach dem Aktivieren ändern.
 */
export function XmlImportPage() {
  const { t } = useTranslation(['nav']);
  const [searchParams] = useSearchParams();
  const solutionId = searchParams.get('solution_id') || undefined;
  const [solutionName, setSolutionName] = useState<string | null>(null);
  const [isForeign, setIsForeign] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const solutions = await fetchSolutions();
        if (cancelled) return;
        // Ohne `?solution_id=`-Deep-Link folgt der Titel der Tab-Auswahl
        // (SolutionPicker → X-Solution-Header), nicht dem Server-Default —
        // sonst bliebe die Überschrift stehen, während die Seite darunter
        // schon die gewählte Lösung zeigt. Fallback: Server-Default.
        const selectedId = getSelectedSolution();
        const target = solutionId
          ? solutions.find((s) => s.id === solutionId)
          : (selectedId ? solutions.find((s) => s.id === selectedId) : undefined)
              ?? solutions.find((s) => s.is_active);
        setSolutionName(target ? (target.display_name || target.id) : (solutionId ?? null));
        // „Fremd-Import"-Notiz (Analyse ändert sich erst nach Aktivieren) gilt
        // nur im Deep-Link-Pfad; die Tab-Auswahl spiegelt die Seite ohnehin.
        setIsForeign(!!solutionId && !!target && !target.is_active);
      } catch {
        /* Titel degradiert auf den generischen Namen */
      }
    })();
    return () => { cancelled = true; };
  }, [solutionId]);

  const baseTitle = t('nav:crumbs.xmlImport') as string;
  return (
    <BundlePage
      id="xml_convert"
      ctx={{ kind: 'xmlImport' }}
      params={solutionId ? { solution_id: solutionId } : undefined}
      statusTrailing={<SolutionSettingsControls />}
      pageTitle={solutionName ? `${baseTitle}: ${solutionName}` : baseTitle}
      pageDescription={
        isForeign
          ? (t('nav:leitDescription.xmlImportContextNote', {
            defaultValue: 'Import einer nicht-aktiven Lösung — die angezeigten Analysedaten ändern sich erst nach dem Aktivieren.',
          }) as string)
          : (t('nav:leitDescription.xmlImport') as string)
      }
    />
  );
}

/**
 * `/docs/:setId` → Bundle-Weiche. Breadcrumb `Home / Docs / {Set}`.
 *
 * Doc-Sets mit deklarierter `start_page` (Manifest `.fmlab/docs.json`) rendern
 * das `docset_start`-Bundle (gerenderte Startseite + gruppierte Seitenliste);
 * alle anderen das bisherige `docset_home` (Hero + Category-Liste). Bis die
 * Catalog-Info da ist, rendern wir nichts unterhalb der Navigation — der
 * Fetch ist lokal und gecacht, ein Bundle-Flackern wäre störender.
 */
export function DocsSetPage() {
  const { t } = useTranslation(['nav']);
  const { set } = useParams<{ set: string }>();
  const [hasStartPage, setHasStartPage] = useState<boolean | null>(null);

  useEffect(() => {
    let cancelled = false;
    setHasStartPage(null);
    (async () => {
      try {
        const catalog = await fetchDocsCatalog();
        if (cancelled) return;
        const entry = catalog.find((c) => c.id === set);
        setHasStartPage(!!entry?.start_page);
      } catch {
        // Catalog nicht erreichbar → Default-Verhalten (docset_home).
        if (!cancelled) setHasStartPage(false);
      }
    })();
    return () => { cancelled = true; };
  }, [set]);

  const ctx: BreadcrumbCtx = { kind: 'docsSet', setLabel: titleize(set ?? '') };
  if (hasStartPage === null) {
    return (
      <div className="app">
        <SubNav breadcrumbs={buildBreadcrumb(ctx, t)} />
        <StatusBar />
      </div>
    );
  }
  return (
    <BundlePage
      id={hasStartPage ? 'docset_start' : 'docset_home'}
      ctx={ctx}
      params={{ id: set }}
    />
  );
}

/** `/docs/:set/:category` → `docset_category`. Breadcrumb `Home / Docs / {Set} / {Category}`. */
export function DocsCategoryPage() {
  const { set, category } = useParams<{ set: string; category: string }>();
  return (
    <BundlePage
      id="docset_category"
      ctx={{
        kind: 'docsCategory',
        setId: set ?? '',
        setLabel: titleize(set ?? ''),
        categoryLabel: titleize(category ?? ''),
      }}
      params={{ docset: set, category }}
    />
  );
}
