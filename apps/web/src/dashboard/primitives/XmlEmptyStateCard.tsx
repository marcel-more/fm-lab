import { useCallback, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { useNavigate, useSearchParams } from 'react-router-dom';
import { API_BASE } from '../../config/apiBase';
import type { PrimitiveProps } from '../types';

/**
 * XmlEmptyStateCard — Hinweis-Karte für das Home-Dashboard, sichtbar nur wenn
 * die DuckDB-Datenbank leer ist (keine importierten Dateien). Zwei Zustände:
 *
 *  1. **Noch keine Dateien im `xml/`-Ordner** — geführte Anleitung in zwei
 *     nummerierten Schritten (1. Export aus FileMaker · 2. Dateien in den Ordner
 *     legen), getrennt durch einen Divider. Schritt 2 trägt die Ordner-Affordance
 *     (nativ „Ordner öffnen", sonst kopierbarer Host-Pfad). Kein Convert-Button —
 *     es gibt noch nichts zu konvertieren.
 *  2. **Dateien erkannt** — die Karte kollabiert auf eine einzige Zeile:
 *     „N XML file(s) found • <Größe>" mit dem Convert-Button direkt dahinter.
 *     Der Klick wechselt zum Import-Dashboard UND startet sofort (`?autostart=1`).
 *     Ist keine Datei importierbar (nur FileMaker-18-Exporte, `importable_count`
 *     = 0 aus `xml_directory_meta`), wechselt er nur zur Import-Seite — dort
 *     stehen Grund und Abhilfe — und die Zeile nennt den Formatbefund.
 *     Läuft bereits eine Konvertierung, ersetzt ein Hinweis den Button (Lauf aus
 *     dem Terminal, z. B. tools/init.sh) bzw. der Button zeigt den Fortschritt
 *     (Lauf aus dem Web-Client).
 *
 * Datasets:
 *   - project_summary       (für den `db_empty`-Marker)
 *   - xml_directory_meta    (count, total_bytes, Pfade, runtime, can_reveal)
 *   - xml_directory_listing (Fallback für die Anzahl, falls Meta fehlt)
 *
 * Die Live-Aktualisierung übernimmt der 6-s-Soft-Refresh des Home-Dashboards
 * (kein eigenes Polling hier) — sobald Dateien auftauchen, schaltet die Karte
 * automatisch von Zustand 1 auf Zustand 2.
 */

const COPY_FEEDBACK_MS = 1500;

function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
  const value = bytes / Math.pow(1024, i);
  return `${value >= 10 || i === 0 ? Math.round(value) : value.toFixed(1)} ${units[i]}`;
}

export function XmlEmptyStateCard({ node, datasets }: PrimitiveProps) {
  const { t } = useTranslation('dashboard');
  const navigate = useNavigate();
  const props = node.props ?? {};
  const span = (props.span as number) ?? 12;

  const summary = datasets?.project_summary?.data?.[0] as Record<string, unknown> | undefined;
  const meta = datasets?.xml_directory_meta?.data?.[0] as Record<string, unknown> | undefined;
  const listing = (datasets?.xml_directory_listing?.data ?? []) as Array<Record<string, unknown>>;

  const dbEmpty = summary?.db_empty === true
    || summary?.db_empty === 1
    || summary?.file_count == null
    || summary?.file_count === 0;

  const count = meta?.count != null ? Number(meta.count) : listing.length;
  const totalBytes = meta?.total_bytes != null ? Number(meta.total_bytes) : null;
  const canReveal = meta?.can_reveal === true;
  const hostXmlDir = (meta?.host_xml_dir as string | null | undefined) ?? null;
  const xmlDir = (meta?.xml_dir as string | null | undefined) ?? null;
  // Im Container zeigen wir bevorzugt den HOST-Pfad (dorthin legt der Anwender die
  // Dateien); ist er nicht bekannt, fällt es auf den Container-Pfad zurück.
  const displayPath = hostXmlDir || xmlDir || 'xml/';
  const pathIsHost = hostXmlDir != null;
  const directoryEmpty = count === 0;
  const unsupportedCount = meta?.unsupported_count != null ? Number(meta.unsupported_count) : 0;
  const nothingImportable = !directoryEmpty && unsupportedCount >= count;
  // A conversion already runs: from the web client ('api', live progress on the import
  // page) or from the terminal (tools/init.sh — no live progress, the 6-s refresh swaps
  // the card for the data once it is done).
  const running = meta?.running === true;
  const runningInTerminal = running && meta?.running_source !== 'api';

  const [copied, setCopied] = useState(false);
  const [revealFailed, setRevealFailed] = useState(false);
  const copyTimer = useRef<number | null>(null);

  // Kontext-Lösung der Import-Seite (?solution_id): der Reveal öffnet den
  // xml/-Ordner DIESER Lösung; ohne Parameter den der aktiven (Home-Karte).
  const [searchParams] = useSearchParams();
  const contextSolution = searchParams.get('solution_id');

  const onReveal = useCallback(async () => {
    setRevealFailed(false);
    try {
      const apiBase = API_BASE.replace(/\/+$/, '');
      const res = await fetch(`${apiBase}/api/xml/reveal`, {
        method: 'POST',
        headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
        body: JSON.stringify(contextSolution ? { solution: contextSolution } : {}),
      });
      // 409 = Reveal in dieser Laufzeit nicht möglich → auf Pfad+Kopieren ausweichen.
      if (!res.ok) setRevealFailed(true);
    } catch {
      setRevealFailed(true);
    }
  }, [contextSolution]);

  const onCopyPath = useCallback(async () => {
    try {
      await navigator.clipboard.writeText(displayPath);
      setCopied(true);
      if (copyTimer.current != null) window.clearTimeout(copyTimer.current);
      copyTimer.current = window.setTimeout(() => {
        setCopied(false);
        copyTimer.current = null;
      }, COPY_FEEDBACK_MS);
    } catch {
      /* Clipboard verweigert (z. B. unsicherer Kontext) — kein harter Fehler. */
    }
  }, [displayPath]);

  const onConvert = useCallback(() => {
    if (directoryEmpty) return;
    // A run from the web client is already active → only show its progress.
    if (running) {
      navigate('/xml-import');
      return;
    }
    // Nichts importierbar → nur zur Import-Seite wechseln (kein Autostart).
    if (nothingImportable) {
      navigate('/xml-import');
      return;
    }
    // Wechseln UND starten: das xml_convert-Sub-Dashboard liest `autostart=1`
    // beim Mount und feuert die Konvertierung sofort.
    navigate('/xml-import?autostart=1');
  }, [directoryEmpty, nothingImportable, running, navigate]);

  if (!dbEmpty) return null;

  const style: React.CSSProperties = {
    gridColumn: `span ${Math.min(Math.max(span, 1), 12)} / span ${Math.min(Math.max(span, 1), 12)}`,
  };

  // ── Zustand 2: Dateien erkannt → nur die Anzahl-Zeile + Convert-Button ──────
  if (!directoryEmpty) {
    return (
      <section className={`dash-card xml-empty-card${runningInTerminal ? ' xml-empty-card--running' : ''}`} style={style}>
        <div className="dash-card__body">
          <div className="xml-empty-card__ready">
            <span className="xml-empty-card__count">
              {t('xmlEmpty.countFound', { count, defaultValue: '{{count}} XML file(s) found' })}
              {totalBytes != null ? ` • ${formatBytes(totalBytes)}` : ''}
              {unsupportedCount > 0 && (
                <>
                  {' • '}
                  <span className="dash-search-bar__flag dash-search-bar__flag--error">
                    {t(
                      nothingImportable ? 'detail:autoTable.formatLegacy' : 'detail:autoTable.formatLegacy_partial',
                      { count: unsupportedCount, total: count },
                    ) as string}
                  </span>
                </>
              )}
            </span>
            {runningInTerminal ? (
              <span className="xml-empty-card__running" role="status">
                {t('xmlEmpty.runningTerminal') as string}
              </span>
            ) : (
              <button type="button" className="xml-convert-btn" onClick={onConvert}>
                {running
                  ? t('xmlEmpty.showProgress')
                  : nothingImportable
                    ? t('nav:crumbs.xmlImport', { defaultValue: 'XML-Import' })
                    : t('xmlConvert.start', { defaultValue: 'XML konvertieren' })}
              </button>
            )}
          </div>
        </div>
      </section>
    );
  }

  // ── Zustand 1: noch keine Dateien → geführte Zwei-Schritte-Anleitung ────────
  const step2Text = pathIsHost
    ? (t('xmlEmpty.hostPathHint', { defaultValue: 'Put the files into this folder on the host — it is mounted into the container.' }) as string)
    : (t('xmlEmpty.putFilesHint', { defaultValue: 'Put your FileMaker XML files into the xml/ folder.' }) as string);
  const showReveal = canReveal && !revealFailed;

  return (
    <section className="dash-card xml-empty-card" style={style}>
      <div className="dash-card__body">
        <p className="xml-empty-card__hint">
          {t('xmlEmpty.hint', {
            defaultValue: 'No data yet. Drop your FileMaker XML export into the “xml/” folder and start the conversion.',
          })}
        </p>

        <p className="xml-empty-card__step">
          <span className="xml-empty-card__step-num">1.</span>
          <span>{t('xmlEmpty.hintExport', {
            defaultValue: 'Export from FileMaker Pro via “Tools ▸ Save a Copy as XML” — enable “Include details for analysis tools”.',
          })}</span>
        </p>

        <hr className="xml-empty-card__divider" />

        <div className="xml-empty-card__step">
          <span className="xml-empty-card__step-num">2.</span>
          <span>{step2Text}</span>
        </div>
        <div className="xml-empty-card__folder">
          {showReveal ? (
            <button
              type="button"
              className="xml-convert-btn xml-convert-btn--outline"
              onClick={onReveal}
            >
              {t('xmlEmpty.openFolder', { defaultValue: 'Open folder' })}
            </button>
          ) : (
            <>
              <code className="xml-empty-card__path" title={displayPath}>{displayPath}</code>
              <button
                type="button"
                className="xml-convert-btn xml-convert-btn--outline"
                onClick={onCopyPath}
              >
                {copied
                  ? (t('xmlEmpty.copied', { defaultValue: 'Copied ✓' }) as string)
                  : (t('xmlEmpty.copyPath', { defaultValue: 'Copy path' }) as string)}
              </button>
            </>
          )}
        </div>
      </div>
    </section>
  );
}
