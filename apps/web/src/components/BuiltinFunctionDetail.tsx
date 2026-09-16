import React, { useMemo } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useObjectDetails } from '../hooks/useObjectDetails';
import { useFunctionReference } from '../hooks/useFunctionReference';
import { useApiLang } from '../hooks/useApiLang';
import { useCurrentFile } from '../lib/currentFileContext';
import { buildDocsEntryPath } from '../api/docsApi';
import { FunctionUsageSection } from './FunctionUsageSection';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import './PseudoFunctionDetail.css';

/**
 * Zeilen der BuiltinFunction-Detail-Projektion (object_details_builtinfunction.sql).
 * `section` diskriminiert: 'meta' | 'usage'. Alle Spalten sind in jeder Zeile
 * vorhanden (NULL, wo nicht zutreffend).
 */
export interface BuiltinFunctionRow {
  section: 'meta' | 'usage';
  // meta
  object_name: string | null;
  localized_name: string | null;
  function_id: number | null;
  namespace: string | null;
  canonical_name: string | null;
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

interface BuiltinFunctionDetailProps {
  uuid: string;
}

/**
 * Detailseite einer Built-in-Funktion — eines der datei-unabhängigen
 * Pseudo-Objekte (der Knoten entsteht beim Import aus den Formel-Chunks, nicht
 * aus einem FileMaker-Katalog).
 *
 * Zwei Abschnitte:
 *  - **Details** — Katalog-Identität (kanonischer Name, lokalisierte
 *    Schreibweise, Geltungsbereich) plus die Referenz-Schicht aus `fm_spec`
 *    (Kategorie · Rückgabetyp · Ursprungs-Version) und die beiden Querlinks:
 *    Claris-Hilfe (Doku-Seite des installierten Docsets, sonst Online-Hilfe der
 *    passenden Sprachfassung) und der fm-spec-Eintrag.
 *  - **Verwendung** — verdichtete Where-used-Zahlen je Rolle und Objekttyp.
 *    Die Aufrufer-LISTE lebt bewusst im Referenzen-Tab (dort ist jede Kante
 *    navigierbar), nicht hier.
 *
 * Ohne Identitätszeile (JSON-Typkonstanten wie `JSONString`, Operatoren) bleibt
 * der Referenz-Block leer — die Katalog-Fakten stehen trotzdem vollständig da.
 */
export const BuiltinFunctionDetail: React.FC<BuiltinFunctionDetailProps> = ({ uuid }) => {
  const { t } = useTranslation(['detail', 'common', 'types', 'fmSpec', 'nav']);
  const uiLang = useApiLang();
  const currentFile = useCurrentFile();
  const { data, loading, error, retry } = useObjectDetails(uuid, currentFile);

  const meta = useMemo(
    () => data?.find((r) => r.section === 'meta') as unknown as BuiltinFunctionRow | undefined,
    [data],
  );
  const usage = useMemo(
    () => (data?.filter((r) => r.section === 'usage') ?? []) as unknown as BuiltinFunctionRow[],
    [data],
  );

  const reference = useFunctionReference(meta?.function_id ?? null, uiLang);

  if (loading) return <LoadingSpinner message={t('common:loading') as string} />;
  if (error) return <ErrorMessage message={error} onRetry={retry} />;
  if (!meta) return <div className="no-references">{t('common:noData')}</div>;

  const ref = reference.data;
  const heading = t('detail:headings.BuiltinFunction', { defaultValue: 'Built-in function details' });
  const dash = '—';

  // Claris-Hilfe: die Doku-Seite des installierten Docsets ist der Normalfall
  // (interner Link, bleibt in der App). `docsEntry` ist server-seitig null,
  // wenn das Docset fehlt oder die Seite im Spiegel nicht existiert — dann
  // führt der Fallback in die Online-Hilfe der passenden Sprachfassung.
  const docsPath = buildDocsEntryPath(ref?.docsEntry, uiLang);
  const onlineHelpUrl = ref?.helpUrl ?? null;

  return (
    <div
      className="object-detail fm-fn"
      aria-label={heading as string}
    >
      <div className="fm-fn-head">
        <h2 className="type-detail-heading fm-fn-title">
          {heading}
          {meta.function_id != null && <span className="fm-fn-id">#{meta.function_id}</span>}
        </h2>
        <div className="fm-fn-links">
          {docsPath ? (
            <Link className="fm-fn-pill" to={docsPath}>
              {t('fmSpec:clarisHelp')}
            </Link>
          ) : onlineHelpUrl ? (
            <a className="fm-fn-pill" href={onlineHelpUrl} target="_blank" rel="noopener noreferrer">
              {t('detail:builtinFunction.clarisHelpOnline', { defaultValue: 'Claris Help ↗' })}
            </a>
          ) : null}
          {ref && (
            <Link className="fm-fn-pill" to={`/fm-spec/function/${ref.functionId}`}>
              {t('nav:docs.openInFmSpec', { defaultValue: 'fm-spec →' })}
            </Link>
          )}
        </div>
      </div>

      {/* Referenz-Schicht (fm_spec): Kategorie · Rückgabetyp · Ursprungs-Version —
          gleiche Zeile und gleiche Labels wie im fm-spec-Browser. */}
      {ref && (
        <p className="fm-fn-subtitle">
          {t('fmSpec:functions.col.category')}: {ref.category?.name ?? String(ref.categoryId)}
          {' · '}{t('fmSpec:functions.detail.returnType')}: {ref.returnTypeDisplay || ref.returnType || dash}
          {' · '}{t('fmSpec:functions.col.originVersion')}: {ref.originVersion ?? dash}
        </p>
      )}

      <dl className="fm-fn-meta">
        <dt>{t('detail:pseudoFunction.metaFunction', { defaultValue: 'Function' })}</dt>
        <dd>{meta.object_name}</dd>
        {meta.localized_name && (
          <>
            <dt>{t('detail:objectListItem.spellingMatch', { defaultValue: 'Spelling' })}</dt>
            <dd>{meta.localized_name}</dd>
          </>
        )}
        <dt>{t('detail:pseudoFunction.metaType', { defaultValue: 'Type' })}</dt>
        <dd>{t('detail:builtinFunction.typeValue', { defaultValue: 'FileMaker built-in function' })}</dd>
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
