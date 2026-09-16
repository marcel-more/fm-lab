import React, { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useObjectDetails } from '../hooks/useObjectDetails';
import { useApiLang } from '../hooks/useApiLang';
import { useCurrentFile } from '../lib/currentFileContext';
import { buildDocsEntryPath } from '../api/docsApi';
import { fetchPluginFunctionSpec, type PluginFunctionSpec } from '../api/pluginSpecApi';
import { buildObjectPath } from '../lib/navigation';
import { FunctionUsageSection } from './FunctionUsageSection';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import './PseudoFunctionDetail.css';

/**
 * Zeilen der PluginFunction-Detail-Projektion (object_details_pluginfunction.sql).
 * `section` diskriminiert: 'meta' | 'usage'. Alle Spalten sind in jeder Zeile
 * vorhanden (NULL, wo nicht zutreffend).
 */
export interface PluginFunctionRow {
  section: 'meta' | 'usage';
  // meta
  object_name: string | null;
  plugin_name: string | null;
  sub_name: string | null;
  component_name: string | null;
  component_uuid: string | null;
  total_objects: number | null;
  total_files: number | null;
  total_occurrences: number | null;
  // usage
  link_role: string | null;
  used_by_type: string | null;
  object_count: number | null;
  file_count: number | null;
  occurrence_count: number | null;
}

interface PluginFunctionDetailProps {
  uuid: string;
}

/**
 * Detailseite einer Plugin-Funktion — datei-unabhängiges Pseudo-Objekt, das
 * beim Import aus den Plugin-Aufrufen der Formeln entsteht.
 *
 * Zwei Abschnitte, strukturgleich zur Built-in-Funktion:
 *  - **Details** — Katalog-Identität (Funktionsname, Katalogname, Komponenten-
 *    Objekt als Link) plus die Referenz-Schicht aus `plugin_spec` (Plugin,
 *    Version, Deprecation-Status) und die Doku-Querlinks: Seite im installierten
 *    Hersteller-Docset, sonst die Herstellerseite online.
 *  - **Verwendung** — verdichtete Where-used-Zahlen je Rolle und Objekttyp; die
 *    Aufrufer-LISTE lebt im Referenzen-Tab.
 *
 * Die Plattform-Matrix des Plugins zeigt bereits das Badge über der Tab-Leiste
 * (PluginPlatformBadge) — sie wird hier bewusst nicht wiederholt.
 */
export const PluginFunctionDetail: React.FC<PluginFunctionDetailProps> = ({ uuid }) => {
  const { t } = useTranslation(['detail', 'common', 'types']);
  const uiLang = useApiLang();
  const currentFile = useCurrentFile();
  const { data, loading, error, retry } = useObjectDetails(uuid, currentFile);

  const meta = useMemo(
    () => data?.find((r) => r.section === 'meta') as unknown as PluginFunctionRow | undefined,
    [data],
  );
  const usage = useMemo(
    () => (data?.filter((r) => r.section === 'usage') ?? []) as unknown as PluginFunctionRow[],
    [data],
  );

  // Referenz-Schicht: Plattform-Map des Herstellers (plugin_spec) samt Doku-
  // Querlinks. Fehlt sie (Map nicht installiert, Funktion unbekannt), liefert
  // der Client `null` — die Katalog-Fakten bleiben vollständig lesbar.
  const plugin = meta?.plugin_name ?? null;
  const fnName = meta?.sub_name ?? meta?.object_name ?? null;
  const [spec, setSpec] = useState<PluginFunctionSpec | null>(null);
  useEffect(() => {
    let cancelled = false;
    setSpec(null);
    if (!plugin || !fnName) return;
    fetchPluginFunctionSpec(plugin, fnName).then((result) => {
      if (!cancelled) setSpec(result);
    });
    return () => { cancelled = true; };
  }, [plugin, fnName]);

  if (loading) return <LoadingSpinner message={t('common:loading') as string} />;
  if (error) return <ErrorMessage message={error} onRetry={retry} />;
  if (!meta) return <div className="no-references">{t('common:noData')}</div>;

  const heading = t('detail:headings.PluginFunction', { defaultValue: 'Plug-in function details' });

  // Doku-Seite des installierten Hersteller-Docsets ist der Normalfall (interner
  // Link, bleibt in der App). `docsEntry` ist server-seitig null, wenn das Docset
  // fehlt oder die Funktion nicht mehr im Doku-Index steht (entfernte Funktionen)
  // — dann führt der Fallback auf die Herstellerseite.
  const docsPath = buildDocsEntryPath(spec?.docsEntry, uiLang);
  const onlineUrl = spec?.online_url ?? null;
  const pillLabelArgs = { plugin: plugin ?? '' };

  // Deprecation-Hinweis aus der Referenz — dieselben Formulierungen wie im
  // Plattform-Badge über der Tab-Leiste.
  const statusText = spec && spec.status !== 'active'
    ? [
      t(spec.status === 'removed' ? 'detail:pluginSpec.removed' : 'detail:pluginSpec.deprecated'),
      spec.status === 'removed' && spec.removed_in ? `(${spec.removed_in})` : null,
      spec.replacement ? `— ${t('detail:pluginSpec.replacementHint', { replacement: spec.replacement })}` : null,
    ].filter(Boolean).join(' ')
    : null;

  return (
    <div className="object-detail fm-fn" aria-label={heading as string}>
      <div className="fm-fn-head">
        <h2 className="type-detail-heading fm-fn-title">
          {heading}
          {plugin && <span className="fm-fn-id">{plugin}</span>}
        </h2>
        <div className="fm-fn-links">
          {docsPath ? (
            <Link className="fm-fn-pill" to={docsPath}>
              {t('detail:pluginFunction.docsetLink', { defaultValue: '{{plugin}} docs →', ...pillLabelArgs })}
            </Link>
          ) : onlineUrl ? (
            <a className="fm-fn-pill" href={onlineUrl} target="_blank" rel="noopener noreferrer">
              {t('detail:pluginFunction.docsOnline', { defaultValue: '{{plugin}} docs ↗', ...pillLabelArgs })}
            </a>
          ) : null}
        </div>
      </div>

      {/* Referenz-Schicht (plugin_spec): Plugin · seit Version · Status. */}
      {spec && (
        <p className="fm-fn-subtitle">
          {t('detail:pluginFunction.metaPlugin', { defaultValue: 'Plug-in' })}: {spec.plugin_name}
          {spec.since_version && <>{' · '}{t('detail:pluginSpec.since', { version: spec.since_version })}</>}
          {statusText && <>{' · '}{statusText}</>}
        </p>
      )}

      <dl className="fm-fn-meta">
        <dt>{t('detail:pseudoFunction.metaFunction', { defaultValue: 'Function' })}</dt>
        <dd>{fnName}</dd>
        {/* Der Katalogname ist bewusst redundant (`MBS:<Sub>::<Sub>`) — er ist die
            Identität des Knotens und wird nur gezeigt, wenn er abweicht. */}
        {meta.object_name && meta.object_name !== fnName && (
          <>
            <dt>{t('detail:pluginFunction.metaCatalogName', { defaultValue: 'Catalog name' })}</dt>
            <dd>{meta.object_name}</dd>
          </>
        )}
        <dt>{t('detail:pseudoFunction.metaType', { defaultValue: 'Type' })}</dt>
        <dd>{t('detail:pluginFunction.typeValue', { defaultValue: 'Plug-in function' })}</dd>
        {meta.component_name && (
          <>
            <dt>{t('detail:pluginFunction.metaComponent', { defaultValue: 'Component' })}</dt>
            <dd>
              {meta.component_uuid ? (
                <Link className="fm-field-link" to={buildObjectPath(meta.component_uuid, uuid, null)}>
                  {meta.component_name}
                </Link>
              ) : meta.component_name}
            </dd>
          </>
        )}
        <dt>{t('detail:pseudoFunction.metaScope', { defaultValue: 'Scope' })}</dt>
        <dd>{t('detail:pseudoFunction.scopeValue', { defaultValue: 'Solution-independent' })}</dd>
      </dl>

      <FunctionUsageSection
        rows={usage}
        totalObjects={meta.total_objects ?? 0}
        totalFiles={meta.total_files ?? 0}
        totalOccurrences={meta.total_occurrences ?? 0}
      />
    </div>
  );
};
