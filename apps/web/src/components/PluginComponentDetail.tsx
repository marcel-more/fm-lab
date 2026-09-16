import React, { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useObjectDetails } from '../hooks/useObjectDetails';
import { useApiLang } from '../hooks/useApiLang';
import { useCurrentFile } from '../lib/currentFileContext';
import { buildDocsCategoryPath } from '../api/docsApi';
import { fetchPluginComponentSpec, type PluginComponentSpec } from '../api/pluginSpecApi';
import { buildObjectPath } from '../lib/navigation';
import { FunctionUsageSection } from './FunctionUsageSection';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import './PseudoFunctionDetail.css';

/**
 * Zeilen der PluginComponent-Detail-Projektion (object_details_plugincomponent.sql).
 * `section` diskriminiert: 'meta' | 'function' | 'usage'. Alle Spalten sind in
 * jeder Zeile vorhanden (NULL, wo nicht zutreffend).
 */
export interface PluginComponentRow {
  section: 'meta' | 'function' | 'usage';
  // meta
  object_name: string | null;
  plugin_name: string | null;
  component_name: string | null;
  function_count: number | null;
  used_function_count: number | null;
  total_objects: number | null;
  total_files: number | null;
  total_occurrences: number | null;
  // function
  function_uuid: string | null;
  function_name: string | null;
  // usage
  link_role: string | null;
  used_by_type: string | null;
  object_count: number | null;
  file_count: number | null;
  occurrence_count: number | null;
}

interface PluginComponentDetailProps {
  uuid: string;
}

/**
 * Detailseite einer Plugin-Komponente — das Container-Pseudo-Objekt über den
 * Plugin-Funktionen (`MBS::XL`, `MBS::JSON`, …).
 *
 * Drei Abschnitte, nach demselben Muster wie die Funktions-Detailseiten:
 *  - **Details** — Katalog-Identität plus die Referenz-Schicht aus `plugin_spec`
 *    (Plugin, Größe der Komponente beim Hersteller) und die Doku-Querlinks:
 *    Rubrikseite im installierten Docset, sonst die Rubrikseite des Herstellers.
 *  - **Funktionen** — die Mitglieds-Funktionen mit ihren eigenen
 *    Verwendungs-Zahlen; jede verlinkt auf ihre Detailseite, wo die konkreten
 *    Aufrufer im Referenzen-Tab stehen.
 *  - **Verwendung** — über alle Mitglieds-Funktionen verdichtet. Die Zahlen sind
 *    dedupliziert: ein Script, das drei Funktionen dieser Komponente aufruft,
 *    ist EIN verwendendes Objekt.
 */
export const PluginComponentDetail: React.FC<PluginComponentDetailProps> = ({ uuid }) => {
  const { t } = useTranslation(['detail', 'common', 'types']);
  const uiLang = useApiLang();
  const currentFile = useCurrentFile();
  const { data, loading, error, retry } = useObjectDetails(uuid, currentFile);

  const meta = useMemo(
    () => data?.find((r) => r.section === 'meta') as unknown as PluginComponentRow | undefined,
    [data],
  );
  const functions = useMemo(
    () => (data?.filter((r) => r.section === 'function') ?? []) as unknown as PluginComponentRow[],
    [data],
  );
  const usage = useMemo(
    () => (data?.filter((r) => r.section === 'usage') ?? []) as unknown as PluginComponentRow[],
    [data],
  );

  // Referenz-Schicht: Größe der Komponente beim Hersteller + Doku-Querlinks.
  // Fehlt die Map, bleibt `null` — die Katalog-Fakten stehen trotzdem da.
  const plugin = meta?.plugin_name ?? null;
  const component = meta?.component_name ?? null;
  // Erste Mitglieds-Funktion als Auflösungs-Hinweis: der Katalog benennt die
  // Komponente nach dem Funktionspräfix ('GMImage'), der Hersteller anders
  // ('GraphicsMagick') — ohne den Hinweis fände der Server die Rubrik nicht.
  const viaFunction = functions[0]?.function_name ?? null;
  const [spec, setSpec] = useState<PluginComponentSpec | null>(null);
  useEffect(() => {
    let cancelled = false;
    setSpec(null);
    if (!plugin || !component) return;
    fetchPluginComponentSpec(plugin, component, viaFunction).then((result) => {
      if (!cancelled) setSpec(result);
    });
    return () => { cancelled = true; };
  }, [plugin, component, viaFunction]);

  if (loading) return <LoadingSpinner message={t('common:loading') as string} />;
  if (error) return <ErrorMessage message={error} onRetry={retry} />;
  if (!meta) return <div className="no-references">{t('common:noData')}</div>;

  const heading = t('detail:headings.PluginComponent', { defaultValue: 'Plug-in component details' });
  const docsPath = buildDocsCategoryPath(spec?.docsCategory, uiLang);
  const onlineUrl = spec?.online_url ?? null;
  const pillLabelArgs = { plugin: plugin ?? '' };

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

      {/* Referenz-Schicht (plugin_spec): Plugin · Hersteller-Komponente · Größe.
          Der abweichende Hersteller-Name wird ausgewiesen, sonst wirkte die
          Referenz-Größe neben einer anders benannten Komponente willkürlich.
          Ohne aufgelöste Hersteller-Komponente bleibt es beim Plugin-Namen. */}
      {spec && (
        <p className="fm-fn-subtitle">
          {t('detail:pluginFunction.metaPlugin', { defaultValue: 'Plug-in' })}: {spec.plugin_name}
          {spec.vendor_component && spec.vendor_component !== meta.component_name && (
            <>
              {' · '}
              {t('detail:pluginComponent.vendorComponent', { defaultValue: 'Vendor component' })}
              : {spec.vendor_component}
            </>
          )}
          {spec.vendor_component && (
            <>
              {' · '}
              {t('detail:pluginComponent.documentedFunctions', { defaultValue: 'Functions in the reference' })}
              : {spec.documented_functions}
            </>
          )}
        </p>
      )}

      <dl className="fm-fn-meta">
        <dt>{t('detail:pluginFunction.metaComponent', { defaultValue: 'Component' })}</dt>
        <dd>{meta.object_name}</dd>
        <dt>{t('detail:pseudoFunction.metaType', { defaultValue: 'Type' })}</dt>
        <dd>{t('detail:pluginComponent.typeValue', { defaultValue: 'Plug-in component' })}</dd>
        <dt>{t('detail:pluginComponent.functionsInSolution', { defaultValue: 'Functions in this solution' })}</dt>
        <dd>
          {meta.function_count ?? 0}
          <span className="fm-fn-count">
            {' '}({t('detail:pluginComponent.usedSuffix', {
              defaultValue: '{{used}} used', used: meta.used_function_count ?? 0,
            })})
          </span>
        </dd>
        <dt>{t('detail:pseudoFunction.metaScope', { defaultValue: 'Scope' })}</dt>
        <dd>{t('detail:pseudoFunction.scopeValue', { defaultValue: 'Solution-independent' })}</dd>
      </dl>

      <section className="fm-fn-section">
        <h3 className="fm-fn-section-head">
          {t('detail:pluginComponent.functionsHeading', { defaultValue: 'Functions' })}
          <span className="fm-fn-count"> ({functions.length})</span>
        </h3>
        {functions.length === 0 ? (
          <div className="fm-fn-empty">{t('common:noData')}</div>
        ) : (
          <table className="fm-fn-table">
            <thead>
              <tr>
                <th>{t('detail:pluginComponent.colFunction', { defaultValue: 'Function' })}</th>
                <th className="fm-fn-col-num">{t('detail:pseudoFunction.colObjects', { defaultValue: 'Objects' })}</th>
                <th className="fm-fn-col-num">{t('detail:pseudoFunction.colOccurrences', { defaultValue: 'Occurrences' })}</th>
              </tr>
            </thead>
            <tbody>
              {functions.map((fn) => (
                <tr key={fn.function_uuid ?? fn.function_name ?? ''}>
                  <td>
                    {fn.function_uuid ? (
                      <Link className="fm-field-link" to={buildObjectPath(fn.function_uuid, uuid, null)}>
                        {fn.function_name}
                      </Link>
                    ) : fn.function_name}
                  </td>
                  <td className="fm-fn-col-num">{fn.object_count}</td>
                  <td className="fm-fn-col-num">{fn.occurrence_count}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <FunctionUsageSection
        rows={usage}
        totalObjects={meta.total_objects ?? 0}
        totalFiles={meta.total_files ?? 0}
        totalOccurrences={meta.total_occurrences ?? 0}
      />
    </div>
  );
};
