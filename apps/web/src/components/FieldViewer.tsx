import React, { useEffect, useMemo, useRef } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { FieldTokens } from '../script/calcTokens';
import { HighlightRefContext } from '../script/highlightContext';
import { useVarSelection, useVarDeepLinkScroll, countCalcVarMatches } from '../script/varSelectionContext';
import { buildObjectPath } from '../lib/navigation';
import { fieldOptionLabel } from '../lib/fieldOptionLabels';
import { CalcTokenList, normalizeCalcWhitespace } from './CalcTokenSpan';
import { useCalcTokens } from '../hooks/useCalcTokens';
import { useApiLang } from '../hooks/useApiLang';
import './CustomFunctionViewer.css';
import './FieldViewer.css';

/**
 * Nebenslot-Formel (Validierung / Fehlermeldungs-Formel): DDR-verankerte
 * Instanzen rendern tokenisiert via get-calc?uuid (Tooltips + Cross-Nav wie im
 * Script-Detail); DDR-lose Instanzen fallen deklariert auf den Klartext zurück
 * — entschieden am Katalog-Datensatz (uuid == null), nie am Fehlerpfad.
 */
const FieldSlotCalc: React.FC<{ uuid: string | null; fallbackText: string | null }> = ({ uuid, fallbackText }) => {
  const { t } = useTranslation(['detail']);
  const lang = useApiLang();
  const { data } = useCalcTokens(uuid, lang, 'uuid');

  if (uuid && data && data.tokens.length > 0) {
    return (
      <pre className="fm-customfunction-body fm-field-slot-calc">
        <code>
          <CalcTokenList tokens={data.tokens} />
        </code>
      </pre>
    );
  }
  if (!fallbackText) return null;
  return (
    <>
      <pre className="fm-customfunction-body fm-field-slot-calc">
        <code>{normalizeCalcWhitespace(fallbackText)}</code>
      </pre>
      {!uuid && (
        <div className="fm-calc-fallback-hint">
          {t('detail:calculationDetail.ddrlessHint', {
            defaultValue: 'Plain text only — this instance has no DDR chunk data, so tokens, tooltips and cross-navigation are unavailable.',
          })}
        </div>
      )}
    </>
  );
};

interface FieldViewerProps {
  data: FieldTokens;
  /** Cross-Reference Highlight: Token-Match auf Tokens mit `uuid ∈ Set`. */
  highlightRefUuids?: Set<string> | null;
  /** Reicht die gezählten Highlight-Treffer hoch zur RefOriginPill. */
  onLiveMatchCount?: (count: number) => void;
}

/**
 * Renderer für die Feld-Details. Zeigt die Feld-Metadaten (Tabelle, Typ,
 * Datentyp, Kommentar etc.) als Property-Liste und — falls vorhanden — die
 * Calculation-Formel als Token-Sequenz (analog CustomFunctionViewer).
 *
 * Tokens werden über `CalcTokenSpan` gerendert, identisch zu CustomFunctions:
 * Engine-Funktionen erhalten einen Reference-DB-Tooltip, Field- und CF-Refs
 * werden zu klickbaren Links. Variablen, Plugin-Funktionen und Kommentare
 * bekommen ihre jeweilige Highlight-Klasse.
 */
export const FieldViewer: React.FC<FieldViewerProps> = ({ data, highlightRefUuids, onLiveMatchCount }) => {
  const { t } = useTranslation(['detail']);
  const navigate = useNavigate();
  const rootRef = useRef<HTMLDivElement>(null);
  const highlightSig = highlightRefUuids ? Array.from(highlightRefUuids).sort().join(',') : '';
  useEffect(() => {
    if (!highlightSig || !rootRef.current) return;
    const id = requestAnimationFrame(() => {
      const first = rootRef.current?.querySelector('.fm-ref--highlighted');
      if (first) first.scrollIntoView({ behavior: 'smooth', block: 'center' });
    });
    return () => cancelAnimationFrame(id);
  }, [highlightSig]);

  // Live-Match-Count: zählt Calc-Tokens mit UUID im Highlight-Set. Für die
  // RefOriginPill — der server-seitige back_references-Count liefert für
  // Token-Container keinen (Field) bzw. nur einen Self-Link-Repräsentanten,
  // nicht die tatsächliche Anzahl Vorkommen in der Formel (analog ScriptViewer).
  const liveMatchCount = useMemo(() => {
    if (!highlightRefUuids || highlightRefUuids.size === 0) return 0;
    let n = 0;
    for (const tok of data.tokens) {
      if (tok.uuid && highlightRefUuids.has(tok.uuid)) n++;
    }
    return n;
  }, [data.tokens, highlightRefUuids]);
  useEffect(() => {
    onLiveMatchCount?.(liveMatchCount);
  }, [liveMatchCount, onLiveMatchCount]);

  // Variablen-Auswahl: Zählung über die Haupt-Formel (Nebenslot-Formeln der
  // FieldSlotCalc-Komponenten laden eigenständig und markieren via Kontext,
  // zählen aber nicht mit — bewusste v1-Vereinfachung analog liveMatchCount).
  const varSel = useVarSelection();
  const varMatches = useMemo(
    () => countCalcVarMatches(data.tokens, varSel?.selectedKey ?? null),
    [data.tokens, varSel?.selectedKey],
  );
  useEffect(() => {
    varSel?.reportMatches(varMatches.count, varMatches.displayName);
  }, [varMatches, varSel]);
  useVarDeepLinkScroll(rootRef);

  const field = data.field;
  const hasFormula = data.tokens && data.tokens.length > 0;
  // Sind überhaupt Options-Sektionen zu zeigen? Steuert den Trenner zwischen
  // Identität und Optionen (leere Felder bekommen keinen Doppelstrich).
  const hasOptions = !!field && !!(
    field.autoEnterType || field.prohibitModification ||
    field.validation || field.storage || field.summary ||
    field.annotation || field.displayNames
  );
  // "Deaktiviert"-Marke für dormante Slots (FileMaker 26 exportiert sie mit enable="False").
  const disabledBadge = (
    <span className="fm-field-disabled">
      {t('detail:fieldViewer.disabled', { defaultValue: 'disabled' })}
    </span>
  );
  const formulaLabel = field?.autoEnterType === 'Calculated'
    ? t('detail:fieldViewer.autoEnterCalculation')
    : t('detail:fieldViewer.calculationFormula');

  // Enum-Lokalisierung über den gemeinsamen Helfer (identisch zur Base-Table-Feldliste).
  const enumLabel = (group: string, value: string | null | undefined): string =>
    fieldOptionLabel(t, group, value);
  const yes = t('detail:fieldViewer.yes', { defaultValue: 'Yes' }) as string;

  const currentUuid = data.object.uuid;
  const currentFile = data.object.file;
  // Klickbarer Objekt-Link (Lookup-Quellfeld, Summary-Zielfeld); ohne UUID reiner Text.
  // `file` ist die aufgelöste Zieldatei (Lookup ggf. datei-übergreifend), currentUuid = ref-Origin.
  const objectLink = (uuid: string | null, file: string | null, label: string): React.ReactNode =>
    uuid ? (
      <button type="button" className="fm-field-link" onClick={() => navigate(buildObjectPath(uuid, currentUuid, file))}>
        {label}
      </button>
    ) : (
      label
    );

  return (
    <HighlightRefContext.Provider value={highlightRefUuids ?? null}>
      <div ref={rootRef} className="fm-customfunction fm-field" aria-label={t('detail:fieldViewer.ariaLabel') as string}>
        <div className="fm-customfunction-header">
          <h2 className="type-detail-heading">
            {field?.table && (
              <span className="fm-field-table">{field.table}::</span>
            )}
            {data.object.name}
          </h2>
          <span className="fm-customfunction-meta">{data.object.file}</span>
        </div>

        {field && (
          <div className="fm-field-options">
            {/* Identität */}
            <dl className="fm-field-props">
              <dt>{t('detail:fieldViewer.fieldType')}</dt>
              <dd>{enumLabel('fieldType', field.fieldType)}</dd>
              <dt>{t('detail:fieldViewer.dataType')}</dt>
              <dd>{enumLabel('dataType', field.dataType)}</dd>
              {field.isGlobal && (
                <>
                  <dt>{t('detail:fieldViewer.global')}</dt>
                  <dd>{yes}</dd>
                </>
              )}
              {field.maxRepetitions > 1 && (
                <>
                  <dt>{t('detail:fieldViewer.repetitions')}</dt>
                  <dd>{field.maxRepetitions}</dd>
                </>
              )}
              {field.comment && (
                <>
                  <dt>{t('detail:fieldViewer.comment')}</dt>
                  <dd className="fm-field-comment">{field.comment}</dd>
                </>
              )}
            </dl>

            {hasOptions && (
            <div className="fm-field-sections">
            {/* Automatische Eingabe */}
            {(field.autoEnterType || field.prohibitModification) && (
              <section className="fm-field-section">
                <h3 className="fm-field-section-title">{t('detail:fieldViewer.sectionAutoEnter', { defaultValue: 'Auto-enter' })}</h3>
                <dl className="fm-field-props">
                  {field.autoEnterType && (
                    <>
                      <dt>{t('detail:fieldViewer.type', { defaultValue: 'Type' })}</dt>
                      <dd>
                        {enumLabel('autoEnter', field.autoEnterType)}
                        {field.autoEnterType === 'ConstantData' && field.constantData != null && (
                          <span className="fm-field-constant"> = <code>{field.constantData}</code></span>
                        )}
                      </dd>
                    </>
                  )}
                  {field.serial && (
                    <>
                      <dt>{t('detail:fieldViewer.serialNext', { defaultValue: 'Next value' })}</dt>
                      <dd>{field.serial.nextValue ?? '–'}</dd>
                      <dt>{t('detail:fieldViewer.serialIncrement', { defaultValue: 'Increment' })}</dt>
                      <dd>{field.serial.increment ?? '–'}</dd>
                      <dt>{t('detail:fieldViewer.serialGenerate', { defaultValue: 'Generate' })}</dt>
                      <dd>{enumLabel('serialGenerate', field.serial.generate)}</dd>
                    </>
                  )}
                  {field.lookup && (
                    <>
                      <dt>{t('detail:fieldViewer.lookupSource', { defaultValue: 'Source field' })}</dt>
                      <dd>
                        {objectLink(field.lookup.fieldUuid, field.lookup.fieldFile, field.lookup.field ?? '–')}
                        {field.lookup.fieldTable && (
                          <span className="fm-field-origin"> ({field.lookup.fieldTable})</span>
                        )}
                        {!field.lookup.enabled && disabledBadge}
                      </dd>
                      {field.lookup.to && (
                        <>
                          <dt>{t('detail:fieldViewer.lookupVia', { defaultValue: 'Via relationship' })}</dt>
                          <dd>{field.lookup.to}</dd>
                        </>
                      )}
                      {field.lookup.dontCopyIfEmpty && (
                        <>
                          <dt>{t('detail:fieldViewer.lookupDontCopy', { defaultValue: "Don't copy empty" })}</dt>
                          <dd>{yes}</dd>
                        </>
                      )}
                      {field.lookup.noMatch && (
                        <>
                          <dt>{t('detail:fieldViewer.lookupNoMatch', { defaultValue: 'If no match' })}</dt>
                          <dd>{enumLabel('noMatch', field.lookup.noMatch)}</dd>
                        </>
                      )}
                    </>
                  )}
                  {field.autoEnterCalc && !field.autoEnterCalc.enabled && (
                    <>
                      <dt>{t('detail:fieldViewer.autoEnterCalculation')}</dt>
                      <dd>{disabledBadge}</dd>
                    </>
                  )}
                  {field.autoEnterCalc?.overwriteExisting && (
                    <>
                      <dt>{t('detail:fieldViewer.calcOverwrite', { defaultValue: 'Overwrite existing' })}</dt>
                      <dd>{yes}</dd>
                    </>
                  )}
                  {field.autoEnterCalc?.alwaysEvaluate && (
                    <>
                      <dt>{t('detail:fieldViewer.calcAlwaysEvaluate', { defaultValue: 'Always re-evaluate' })}</dt>
                      <dd>{yes}</dd>
                    </>
                  )}
                  {field.prohibitModification && (
                    <>
                      <dt>{t('detail:fieldViewer.prohibitModification', { defaultValue: 'Modification prohibited' })}</dt>
                      <dd>{yes}</dd>
                    </>
                  )}
                </dl>
              </section>
            )}

            {/* Überprüfung */}
            {field.validation && (
              <section className="fm-field-section">
                <h3 className="fm-field-section-title">{t('detail:fieldViewer.sectionValidation', { defaultValue: 'Validation' })}</h3>
                <dl className="fm-field-props">
                  {field.validation.mode && (
                    <>
                      <dt>{t('detail:fieldViewer.validationMode', { defaultValue: 'When' })}</dt>
                      <dd>{enumLabel('validationType', field.validation.mode)}</dd>
                    </>
                  )}
                  {(field.validation.notEmpty || field.validation.unique || field.validation.existing) && (
                    <>
                      <dt>{t('detail:fieldViewer.constraints', { defaultValue: 'Requires' })}</dt>
                      <dd className="fm-field-chips">
                        {field.validation.notEmpty && <span className="fm-field-chip">{t('detail:fieldViewer.constraintNotEmpty', { defaultValue: 'Not empty' })}</span>}
                        {field.validation.unique && <span className="fm-field-chip">{t('detail:fieldViewer.constraintUnique', { defaultValue: 'Unique' })}</span>}
                        {field.validation.existing && <span className="fm-field-chip">{t('detail:fieldViewer.constraintExisting', { defaultValue: 'Existing' })}</span>}
                      </dd>
                    </>
                  )}
                  {field.validation.valueList && (
                    <>
                      <dt>{t('detail:fieldViewer.validationValueList', { defaultValue: 'From value list' })}</dt>
                      <dd>{field.validation.valueList.name}</dd>
                    </>
                  )}
                  {field.validation.strictType && (
                    <>
                      <dt>{t('detail:fieldViewer.validationStrict', { defaultValue: 'Strict data type' })}</dt>
                      <dd>{enumLabel('strictType', field.validation.strictType)}</dd>
                    </>
                  )}
                  {field.validation.maxChars != null && (
                    <>
                      <dt>{t('detail:fieldViewer.validationMaxChars', { defaultValue: 'Max. characters' })}</dt>
                      <dd>{field.validation.maxChars}</dd>
                    </>
                  )}
                  {(field.validation.rangeFrom || field.validation.rangeTo) && (
                    <>
                      <dt>{t('detail:fieldViewer.validationRange', { defaultValue: 'In range' })}</dt>
                      <dd>{field.validation.rangeFrom ?? '…'} – {field.validation.rangeTo ?? '…'}</dd>
                    </>
                  )}
                  {(field.validation.calcText || field.validation.calcUuid) && (
                    <>
                      <dt>{t('detail:fieldViewer.validationByCalc', { defaultValue: 'Validated by calculation' })}</dt>
                      <dd>
                        {!field.validation.calcEnabled && <div>{disabledBadge}</div>}
                        <FieldSlotCalc
                          uuid={field.validation.calcUuid}
                          fallbackText={field.validation.calcText}
                        />
                      </dd>
                    </>
                  )}
                  {field.validation.message && (
                    <>
                      <dt>{t('detail:fieldViewer.validationMessage', { defaultValue: 'Custom message' })}</dt>
                      <dd className="fm-field-comment">{field.validation.message}</dd>
                    </>
                  )}
                  {field.validation.messageCalc && (
                    <>
                      <dt>{t('detail:fieldViewer.validationMessageCalc', { defaultValue: 'Message calculation' })}</dt>
                      <dd>
                        {!field.validation.messageCalc.enabled && <div>{disabledBadge}</div>}
                        <FieldSlotCalc
                          uuid={field.validation.messageCalc.uuid}
                          fallbackText={field.validation.messageCalc.text}
                        />
                      </dd>
                    </>
                  )}
                  {field.validation.allowOverride && (
                    <>
                      <dt>{t('detail:fieldViewer.validationAllowOverride', { defaultValue: 'User may override' })}</dt>
                      <dd>{yes}</dd>
                    </>
                  )}
                </dl>
              </section>
            )}

            {/* Speicher / Indizierung */}
            {field.storage && (
              <section className="fm-field-section">
                <h3 className="fm-field-section-title">{t('detail:fieldViewer.sectionStorage', { defaultValue: 'Storage' })}</h3>
                <dl className="fm-field-props">
                  {field.storage.index && (
                    <>
                      <dt>{t('detail:fieldViewer.storageIndex', { defaultValue: 'Indexing' })}</dt>
                      <dd>{enumLabel('index', field.storage.index)}</dd>
                    </>
                  )}
                  {field.storage.autoIndex && (
                    <>
                      <dt>{t('detail:fieldViewer.storageAutoIndex', { defaultValue: 'Auto-create indexes' })}</dt>
                      <dd>{yes}</dd>
                    </>
                  )}
                  {field.storage.indexLanguage && (
                    <>
                      <dt>{t('detail:fieldViewer.storageIndexLanguage', { defaultValue: 'Index language' })}</dt>
                      <dd>{field.storage.indexLanguage}</dd>
                    </>
                  )}
                  {!field.storage.storeCalcResults && (
                    <>
                      <dt>{t('detail:fieldViewer.storageStoreCalc', { defaultValue: 'Calculation result stored' })}</dt>
                      <dd>{t('detail:fieldViewer.no', { defaultValue: 'No' })}</dd>
                    </>
                  )}
                  {field.storage.evaluatesWhenEmpty && (
                    <>
                      <dt>{t('detail:fieldViewer.calcEvaluatesWhenEmpty', { defaultValue: 'Evaluates even if fields empty' })}</dt>
                      <dd>{yes}</dd>
                    </>
                  )}
                </dl>
              </section>
            )}

            {/* Erweiterte Feldoptionen (FileMaker 26): Anmerkung + Anzeigenamen */}
            {(field.annotation || field.displayNames) && (
              <section className="fm-field-section">
                <h3 className="fm-field-section-title">{t('detail:fieldViewer.sectionExtended', { defaultValue: 'Extended options (FileMaker 26)' })}</h3>
                <dl className="fm-field-props">
                  {field.annotation && (
                    <>
                      <dt>{t('detail:fieldViewer.annotation', { defaultValue: 'Annotation (DDL)' })}</dt>
                      <dd className="fm-field-comment">{field.annotation}</dd>
                    </>
                  )}
                  {field.displayNames && (
                    <>
                      <dt>{t('detail:fieldViewer.displayNames', { defaultValue: 'Display names' })}</dt>
                      <dd>
                        {field.displayNames.enabled
                          ? t('detail:fieldViewer.displayNamesEnabled', { defaultValue: 'Custom display names enabled' })
                          : t('detail:fieldViewer.displayNamesDisabled', { defaultValue: 'Not customized' })}
                      </dd>
                      {field.displayNames.elements.length > 0 && (
                        <>
                          <dt>{t('detail:fieldViewer.displayNameElements', { defaultValue: 'Elements' })}</dt>
                          <dd>
                            <table className="fm-field-dn-table">
                              <thead>
                                <tr>
                                  <th>{t('detail:fieldViewer.displayNameKey', { defaultValue: 'Element' })}</th>
                                  <th>{t('detail:fieldViewer.displayNameValue', { defaultValue: 'Label / formula' })}</th>
                                </tr>
                              </thead>
                              <tbody>
                                {field.displayNames.elements.map(el => (
                                  <tr key={el.seq}>
                                    <td><code>{el.key}</code></td>
                                    <td>
                                      {el.kind === 'formula'
                                        ? <code className="fm-field-dn-formula">{el.value ?? ''}</code>
                                        : <span>{el.value ?? ''}</span>}
                                      {el.jsonType && el.jsonType !== 'JSONString' && (
                                        <span className="fm-field-origin"> ({el.jsonType})</span>
                                      )}
                                    </td>
                                  </tr>
                                ))}
                              </tbody>
                            </table>
                          </dd>
                        </>
                      )}
                      {(field.displayNames.calcText || field.displayNames.calcUuid) && (
                        <>
                          <dt>{t('detail:fieldViewer.displayNamesFormula', { defaultValue: 'Display-names formula' })}</dt>
                          <dd>
                            <FieldSlotCalc
                              uuid={field.displayNames.calcUuid}
                              fallbackText={field.displayNames.calcText}
                            />
                          </dd>
                        </>
                      )}
                    </>
                  )}
                </dl>
              </section>
            )}

            {/* Statistik */}
            {field.summary && (
              <section className="fm-field-section">
                <h3 className="fm-field-section-title">{t('detail:fieldViewer.sectionSummary', { defaultValue: 'Summary' })}</h3>
                <dl className="fm-field-props">
                  <dt>{t('detail:fieldViewer.summaryOperation', { defaultValue: 'Operation' })}</dt>
                  <dd>{enumLabel('summaryOp', field.summary.operation)}</dd>
                  {field.summary.field && (
                    <>
                      <dt>{t('detail:fieldViewer.summaryField', { defaultValue: 'Summarized field' })}</dt>
                      <dd>{objectLink(field.summary.field.uuid, currentFile, field.summary.field.name)}</dd>
                    </>
                  )}
                  {field.summary.restartEachGroup && (
                    <>
                      <dt>{t('detail:fieldViewer.summaryRestartGroup', { defaultValue: 'Restart for each group' })}</dt>
                      <dd>{yes}</dd>
                    </>
                  )}
                  {field.summary.repetitionMode && (
                    <>
                      <dt>{t('detail:fieldViewer.summaryRepMode', { defaultValue: 'Summarize repetitions' })}</dt>
                      <dd>{enumLabel('repMode', field.summary.repetitionMode)}</dd>
                    </>
                  )}
                </dl>
              </section>
            )}
            </div>
            )}
          </div>
        )}

        {hasFormula && (
          <div className="fm-field-formula">
            <div className="fm-field-formula-label">{formulaLabel}</div>
            <pre className="fm-customfunction-body">
              <code>
                <CalcTokenList tokens={data.tokens} />
              </code>
            </pre>
          </div>
        )}
      </div>
    </HighlightRefContext.Provider>
  );
};
