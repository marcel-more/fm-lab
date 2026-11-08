import { useCallback, useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useApiLang } from '../hooks/useApiLang';
import { isAbortError } from '../lib/netErrors';
import { getDashboard, getDashboardData } from '../api/dashboardApi';
import type {
  DashboardEnvelope,
  DashboardDataResponse,
} from '../api/dashboardApi';
import { DashboardRenderer } from './DashboardRenderer';
import { registerStickyDashboardParams } from './actions';
import { TitleBox } from '../components/TitleBox';
import { FavoriteStar } from './FavoriteStar';
import { NoDataYet } from '../components/NoDataYet';
import { ScopeNoticeBar } from './primitives/ScopeNotice';
import { layoutBindsParam, layoutHasScopeNotice, scopeSupport } from './primitives/_scopeNotice';
import './dashboard.css';

interface Props {
  id: string;
  params?: Record<string, unknown>;
  /**
   * Render a framed TitleBox from the manifest (title + description) above the
   * grid — for object-entry dashboards (/dashboard/:id), where the manifest
   * carries the authoritative title + rich description. Leitseiten/Docset
   * bundles render their own title and leave this off.
   */
  showManifestTitle?: boolean;
  /**
   * Called after the envelope (manifest + layout + nav) has loaded. The host
   * fetches it anyway, so the route view can build its breadcrumb from the real
   * localized title and rubric path without a second request.
   */
  onEnvelopeLoaded?: (envelope: DashboardEnvelope) => void;
}

/**
 * Dashboards, die ihre Datasets proaktiv (Fokus / Tab-Sichtbarkeit / Idle-Poll /
 * „Neu scannen"-Button) NICHT-destruktiv nachladen — ohne die View zu leeren.
 * Aktuell nur die XML-Konvertierung: neu im xml/-Verzeichnis abgelegte Dateien
 * sollen auftauchen, ohne dass erst ein Convert-Lauf nötig ist (der Server-Scan
 * `getStatus()` liefert sie längst, das Frontend fragte bisher nur nicht nach).
 */
const AUTO_REFRESH_DASHBOARDS = new Set(['xml_convert']);
/**
 * Dashboards, die NUR im Leerzustand (noch kein Katalog importiert) auto-refreshen.
 * Das Home zeigt dann die „erst XML konvertieren"-Karte; per Poll/Focus erscheint eine
 * neu in xml/ abgelegte Datei live (Button aktiviert sich), ohne Seiten-Reload — derselbe
 * Server-Scan (`getStatus()` → `xml_directory_listing`) wie auf der XML-Import-Seite.
 * Sobald der Katalog gefüllt ist, entfällt der Poll wieder (die Home-Daten sind dann statisch).
 */
const AUTO_REFRESH_WHEN_EMPTY_DASHBOARDS = new Set(['home']);
/** Idle-Polling-Intervall für Auto-Refresh-Dashboards. */
const IDLE_POLL_MS = 6000;

/**
 * Lädt Manifest + Daten eines Dashboards und mountet den Renderer.
 */
export function DashboardHost({ id, params, showManifestTitle, onEnvelopeLoaded }: Props) {
  const { t } = useTranslation();
  const lang = useApiLang();
  const [envelope, setEnvelope] = useState<DashboardEnvelope | null>(null);
  const [datasets, setDatasets] = useState<DashboardDataResponse | null>(null);
  // Getrennte Fehlerquellen der beiden Lade-Effekte (Envelope vs. Daten), damit
  // keiner den Fehler des anderen wegräumen oder überschreiben kann — die
  // Anzeige faltet beide zusammen (Envelope-Fehler gewinnt).
  const [envError, setEnvError] = useState<string | null>(null);
  const [dataError, setDataError] = useState<string | null>(null);
  // External re-fetch trigger (e.g. after a successful docset install via
  // the DocsetInstallControl inline-control). Bumped from a window event.
  const [reloadTick, setReloadTick] = useState(0);
  // Tracks whether an XML convert run is active. Während eines Laufs pausiert der
  // Soft-Refresh — dann besitzt das Live-SSE-Overlay (useXmlConvertFileStates)
  // die Datei-Tabelle, und ein Re-Fetch der statischen Zeilen wäre unnötig/störend.
  const convertRunningRef = useRef(false);
  // Via ref, not via the effect's dep array: an inline callback would change
  // identity on every parent render and re-run the envelope effect — which
  // tears the view down (setEnvelope(null)) and would loop.
  const onEnvelopeLoadedRef = useRef(onEnvelopeLoaded);
  onEnvelopeLoadedRef.current = onEnvelopeLoaded;

  useEffect(() => {
    const handler = () => setReloadTick(n => n + 1);
    window.addEventListener('fmlab:reload-dashboard', handler);
    const onConvertStatus = (e: Event) => {
      const detail = (e as CustomEvent<{ status?: string }>).detail;
      convertRunningRef.current = detail?.status === 'running';
    };
    window.addEventListener('fmlab:xml-convert-status', onConvertStatus);
    return () => {
      window.removeEventListener('fmlab:reload-dashboard', handler);
      window.removeEventListener('fmlab:xml-convert-status', onConvertStatus);
    };
  }, []);

  const paramsKey = JSON.stringify(params || {});

  // Effekt 1 (Envelope): Manifest + Layout. Läuft NUR bei Dashboard-/Sprach-
  // Wechsel und externem reloadTick — nicht bei Param-Änderungen. Nur er reißt
  // die View ab (voller Loading-Zustand); ein Param-Wechsel (Slider, Chips,
  // Select) bleibt damit flackerfrei und unmountet keine Controls im Drag.
  // Abbruch per AbortController: Bei schnellen Folge-Läufen (Slider-Ticks,
  // StrictMode-Doppellauf) stirbt der alte Request, statt sich mit dem neuen
  // um Verbindungen und State-Schreibrechte zu überlappen.
  useEffect(() => {
    const ac = new AbortController();
    setEnvError(null);
    setEnvelope(null);
    setDatasets(null);

    (async () => {
      try {
        const env = await getDashboard(id, lang, ac.signal);
        if (ac.signal.aborted) return;
        registerStickyDashboardParams(
          env.manifest.id,
          (env.manifest.params ?? []).filter(p => p.sticky).map(p => p.name),
        );
        setEnvelope(env);
        onEnvelopeLoadedRef.current?.(env);
      } catch (err) {
        if (ac.signal.aborted || isAbortError(err)) return;
        setEnvError(err instanceof Error ? err.message : String(err));
      }
    })();

    return () => ac.abort();
  }, [id, lang, reloadTick]);

  // Effekt 2 (Daten): lädt NUR die Dataset-Payload und tauscht sie in place —
  // ohne Loading-Zustand, ohne die View zu leeren (Muster softRefresh). Beim
  // Erst-Load bzw. nach Effekt 1 ist datasets null, dann greift der abgeleitete
  // Loading-Zustand unten; bei reinen Param-Wechseln bleibt die alte View
  // stehen, bis die neuen Daten da sind.
  useEffect(() => {
    const ac = new AbortController();

    (async () => {
      try {
        const data = await getDashboardData(id, params, lang, ac.signal);
        if (ac.signal.aborted) return;
        setDataError(null);
        setDatasets(data);
      } catch (err) {
        if (ac.signal.aborted || isAbortError(err)) return;
        setDataError(err instanceof Error ? err.message : String(err));
      }
    })();

    return () => ac.abort();
  }, [id, paramsKey, lang, reloadTick]);

  const error = envError ?? dataError;
  const loading = !error && (!envelope || !datasets);

  // Nicht-destruktiver In-place-Refresh: lädt NUR die Dataset-Payload neu und
  // tauscht sie aus, OHNE `loading`/`datasets=null` zu setzen (das würde die View
  // leeren + den Renderer remounten = Flackern, und die lokalen Tabellen-States
  // wie Suche/Sortierung verwerfen). Bei laufendem Convert oder verstecktem Tab
  // wird übersprungen; bei identischer Payload (Idle-Poll ohne Änderung) entfällt
  // das setState, sodass kein Re-Render anfällt.
  const softRefresh = useCallback(async () => {
    if (convertRunningRef.current) return;
    if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return;
    try {
      const data = await getDashboardData(id, params, lang);
      setDatasets(prev => {
        if (prev && JSON.stringify(prev) === JSON.stringify(data)) return prev;
        return data;
      });
    } catch {
      // Soft-Refresh bleibt still — bei transienten Fehlern die aktuelle View halten.
    }
  }, [id, paramsKey, lang]);

  // Leerzustand des Katalogs (spiegelt XmlEmptyStateCard): steuert, ob das Home
  // im Ausgangszustand mit-pollt. project_summary.db_empty kommt aus dem (gestubten)
  // leeren Katalog; file_count==null ist der gleiche „nichts importiert"-Marker.
  const summaryRow = datasets?.project_summary?.data?.[0] as Record<string, unknown> | undefined;
  const catalogEmpty = !!summaryRow && (
    summaryRow.db_empty === true || summaryRow.db_empty === 1
    || summaryRow.file_count == null || summaryRow.file_count === 0
  );
  const autoRefresh = AUTO_REFRESH_DASHBOARDS.has(id)
    || (AUTO_REFRESH_WHEN_EMPTY_DASHBOARDS.has(id) && catalogEmpty);

  // Auto-Refresh-Trigger (Fokus / Tab-Sichtbarkeit / Idle-Poll / „Neu scannen") —
  // für opt-in-Dashboards (AUTO_REFRESH_DASHBOARDS) bzw. das Home im Leerzustand
  // (AUTO_REFRESH_WHEN_EMPTY_DASHBOARDS), erst nach dem Erst-Load (envelope vorhanden).
  // Hält das xml/-Verzeichnis-Listing synchron, ohne einen Convert-Lauf zu erzwingen.
  useEffect(() => {
    if (!autoRefresh || !envelope) return;

    const trigger = () => { void softRefresh(); };
    const onVisible = () => { if (document.visibilityState === 'visible') void softRefresh(); };

    window.addEventListener('focus', trigger);
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('fmlab:refresh-datasets', trigger);

    const poll = window.setInterval(() => {
      if (document.visibilityState !== 'hidden') void softRefresh();
    }, IDLE_POLL_MS);

    return () => {
      window.removeEventListener('focus', trigger);
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('fmlab:refresh-datasets', trigger);
      window.clearInterval(poll);
    };
  }, [autoRefresh, envelope, softRefresh]);

  if (loading) {
    return <div className="dash-host dash-host--loading">{t('dashboard.loading')}</div>;
  }
  if (error) {
    return (
      <div className="dash-host dash-host--error">
        <strong>{t('dashboard.loadError', { message: '' }).replace(/:\s*$/, ':')}</strong>
        <pre>{error}</pre>
      </div>
    );
  }
  if (!envelope || !datasets) {
    return <div className="dash-host">{t('dashboard.noData')}</div>;
  }

  // Leerzustand-Gate (kein Import): Sobald ein Dataset dieses Bundles nur wegen
  // fehlenden Imports leer ist (`emptyReason: 'no_import'`, vom Backend NUR bei
  // leerem Katalog gesetzt), zeigen wir statt des Grids EINE neutrale Karte mit
  // „Zurück zur Startseite" — konsistent zu Hierarchie/Atlas. Bundles, die auf
  // leerem Katalog sinnvoll bleiben (Home mit Import-Karte, Doku, die Index-
  // Listen), setzen den Marker nie und rendern normal weiter.
  const noImport = Object.values(datasets).some(d => d?.emptyReason === 'no_import');
  if (noImport) {
    return (
      <div className="dash-host">
        <NoDataYet />
      </div>
    );
  }

  return (
    <div className={`dash-host dash-host--${envelope.manifest.id}`}>
      {showManifestTitle && envelope.manifest.title && (
        <TitleBox
          title={envelope.manifest.title}
          subtitle={envelope.manifest.description}
          // Favorite star, right-aligned — content-area bundles only, system/module pages carry none.
          actions={envelope.nav?.favoritable ? <FavoriteStar id={envelope.manifest.id} /> : undefined}
        />
      )}
      {/* Scope hint of content dashboards (Analysis Test deep links carry file /
          scope_uuids): automatic unless the layout places the ScopeNotice itself.
          Only the params the dashboard applies; a file the layout shows in its own
          control is left out. */}
      {showManifestTitle && !layoutHasScopeNotice(envelope.layout) && (
        <ScopeNoticeBar options={{
          ...scopeSupport(envelope.manifest),
          fileShownByControl: layoutBindsParam(envelope.layout, 'file'),
        }} />
      )}
      <DashboardRenderer layout={envelope.layout} datasets={datasets} />
    </div>
  );
}
