import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useScriptTokens } from '../hooks/useScriptTokens';
import { useCalcTokens } from '../hooks/useCalcTokens';
import { useApiLang } from '../hooks/useApiLang';
import { useCurrentFile } from '../lib/currentFileContext';
import { buildObjectPath } from '../lib/navigation';
import { FIELD_NAV_TYPES, SCRIPT_NAV_TYPES } from '../lib/layoutObjectNav';
import { ScriptViewer } from './ScriptViewer';
import { CalcTokenList, normalizeCalcWhitespace } from './CalcTokenSpan';
import { LayoutFormulaLine } from './LayoutFormulaLine';
import { useTriggerEventFormat, useTriggerCompat } from '../lib/triggerEvents';
import {
  VarSelectionContext,
  useVarSelection,
  countCalcVarMatches,
  type VarSelection,
} from '../script/varSelectionContext';
import type { ScriptTokens } from '../script/types';
import type {
  LayoutObjectCalcSlot,
  LayoutObjectChild,
  LayoutObjectCondition,
  LayoutObjectConditionFormat,
  LayoutObjectContext,
  LayoutObjectMergeText,
  LayoutObjectTrigger,
} from '../script/calcTokens';

/** Teil-Meldung der Variablen-Treffer einer einzelnen Formel (Key-basiert). */
type ReportVarPart = (key: string, count: number, displayName: string | null) => void;

/**
 * Aggregiert die Variablen-Treffer aller Formeln der LayoutObject-Detail
 * (Slots, Trigger-Parameter, CF-Zeilen, Button-Step) und meldet die Summe an
 * den äußeren VarSelectionContext (VarSelectionPill). Der Button-Step meldet
 * über den Context selbst — der Proxy fängt diese Meldung als Teil '__step'
 * ab; alle eigenen Formel-Renderer melden key-basiert über `report`.
 */
function useVarMatchAggregator(): {
  proxySel: VarSelection | null;
  report: ReportVarPart;
} {
  const parentSel = useVarSelection();
  const partsRef = useRef(new Map<string, { count: number; displayName: string | null }>());
  const [version, setVersion] = useState(0);

  const report = useCallback<ReportVarPart>((key, count, displayName) => {
    const prev = partsRef.current.get(key);
    if (prev && prev.count === count && prev.displayName === displayName) return;
    partsRef.current.set(key, { count, displayName });
    setVersion(v => v + 1);
  }, []);

  useEffect(() => {
    if (!parentSel) return;
    let total = 0;
    let name: string | null = null;
    for (const p of partsRef.current.values()) {
      total += p.count;
      if (!name && p.displayName) name = p.displayName;
    }
    parentSel.reportMatches(total, name);
  }, [version, parentSel]);

  const proxySel = useMemo<VarSelection | null>(() => {
    if (!parentSel) return null;
    return {
      selectedKey: parentSel.selectedKey,
      toggle: parentSel.toggle,
      reportMatches: (count, displayName) => report('__step', count, displayName),
    };
  }, [parentSel, report]);

  return { proxySel, report };
}

/** Meldet die Var-Treffer einer Token-Liste key-basiert an den Aggregator. */
function useReportCalcVarMatches(
  matchKey: string,
  tokens: Parameters<typeof countCalcVarMatches>[0],
  report: ReportVarPart,
): void {
  const varSel = useVarSelection();
  const matches = useMemo(
    () => countCalcVarMatches(tokens, varSel?.selectedKey ?? null),
    [tokens, varSel?.selectedKey],
  );
  useEffect(() => {
    report(matchKey, matches.count, matches.displayName);
    return () => report(matchKey, 0, null);
  }, [matchKey, matches, report]);
}

/**
 * Inline-Formel (Trigger-Parameter, CF-Zeile): DDR-verankerte Instanzen laden
 * ihre Token-Sequenz via get-calc?uuid; DDR-lose fallen auf den Klartext
 * zurück — Entscheidung am Katalog-Datensatz (hasTokens), nie am Fehlerpfad.
 */
const InlineCalcFormula: React.FC<{
  calcUuid: string | null;
  hasTokens: boolean;
  plainText: string | null;
  matchKey: string;
  report: ReportVarPart;
}> = ({ calcUuid, hasTokens, plainText, matchKey, report }) => {
  const lang = useApiLang();
  const { data } = useCalcTokens(hasTokens && calcUuid ? calcUuid : null, lang, 'uuid');
  const tokens = useMemo(
    () => (hasTokens && data && data.tokens.length > 0 ? data.tokens : []),
    [hasTokens, data],
  );
  useReportCalcVarMatches(matchKey, tokens, report);

  if (tokens.length > 0) {
    return (
      <code className="fm-lo-inline-calc">
        <CalcTokenList tokens={tokens} />
      </code>
    );
  }
  if (plainText) {
    return <code className="fm-lo-inline-calc">{normalizeCalcWhitespace(plainText)}</code>;
  }
  return null;
};

/**
 * Ziel-Leiste (oberste Sektion): Rücksprung ins Eltern-Layout (`?ref=` markiert
 * das Objekt im Canvas) + Ziel-Chips. Der Chip des gehoisteten Ziels steht
 * vorn (identisch zum Modifier-Klick-Ziel im Canvas). Trigger-Ziele erscheinen
 * bewusst NICHT als Chips — sie leben in der Trigger-Tabelle.
 */
const LayoutObjectTargetBar: React.FC<{
  uuid: string;
  data: ScriptTokens;
  file: string | null;
}> = ({ uuid, data, file }) => {
  const { t } = useTranslation(['detail', 'types']);
  const loCtx = data.layoutObject ?? null;
  const loType = loCtx?.type ?? '';
  const targets = data.targets ?? [];

  // Button-Action-Ziel aus den Refs des eingebetteten Steps. Die
  // triggers_script-Subrole ('button_action' vs. Event) attribuiert nur als
  // Multiset je (Objekt, Script)-Gruppe, nicht kanten-genau — die Step-Refs
  // bleiben die einzige saubere Herkunft des Button-Action-Scripts.
  const buttonActionRef = useMemo(() => {
    for (const line of data.lines ?? []) {
      for (const ref of line.refs ?? []) {
        if (ref.type === 'script' && ref.uuid) return ref;
      }
    }
    return null;
  }, [data.lines]);

  type Chip = { key: string; roleLabel: string; name: string; uuid: string; file: string | null; hoisted: boolean };
  const chips = useMemo<Chip[]>(() => {
    const out: Chip[] = [];
    if (buttonActionRef) {
      out.push({
        key: 'button-action',
        roleLabel: t('detail:buttonStep.heading', { defaultValue: 'Button action' }) as string,
        name: buttonActionRef.name,
        uuid: buttonActionRef.uuid as string,
        file: buttonActionRef.file ?? null,
        hoisted: SCRIPT_NAV_TYPES.has(loType),
      });
    }
    for (const tg of targets) {
      const hoisted =
        (tg.linkRole === 'displays_field' && FIELD_NAV_TYPES.has(loType)) ||
        (tg.linkRole === 'portal_context' && loType === 'Portal') ||
        (tg.linkRole === 'navigates_to_layout' && SCRIPT_NAV_TYPES.has(loType) && !buttonActionRef);
      out.push({
        key: `${tg.linkRole}-${tg.uuid}`,
        roleLabel: t(`types:objectTypes.${tg.type}`, { defaultValue: tg.type ?? tg.linkRole }) as string,
        name: tg.name ?? tg.uuid,
        uuid: tg.uuid,
        file: tg.file,
        hoisted,
      });
    }
    // Gehoistetes Ziel nach vorn, Rest in stabiler Rollen-Reihenfolge.
    out.sort((a, b) => Number(b.hoisted) - Number(a.hoisted));
    return out;
  }, [targets, buttonActionRef, loType, t]);

  const hasBack = !!loCtx?.layoutUuid;
  if (!hasBack && chips.length === 0) return null;

  return (
    <div className="object-detail layoutobject-targetbar" aria-label={t('detail:layoutObjectDetail.targetBarAria', { defaultValue: 'Targets' }) as string}>
      <div className="fm-lo-targetbar">
        {hasBack && (
          <Link
            className="fm-lo-chip fm-lo-chip--back"
            to={buildObjectPath(loCtx!.layoutUuid as string, uuid, file)}
            title={t('detail:layoutObjectDetail.showInLayoutTitle', { defaultValue: 'Open the layout and highlight this object' }) as string}
          >
            <span aria-hidden="true">←</span>{' '}
            {t('detail:layoutObjectDetail.showInLayout', { name: loCtx!.layoutName ?? '', defaultValue: 'Show in layout: {{name}}' })}
          </Link>
        )}
        {chips.map(c => (
          <Link
            key={c.key}
            className={'fm-lo-chip' + (c.hoisted ? ' fm-lo-chip--primary' : '')}
            to={buildObjectPath(c.uuid, uuid, c.file ?? file)}
          >
            <span className="fm-lo-chip-role">{c.roleLabel}</span>
            {c.name}
          </Link>
        ))}
      </div>
    </div>
  );
};

/**
 * Script-Trigger-Tabelle (erste Logik-Sektion): eine Zeile pro Trigger in
 * Slot-Reihenfolge (Trigger_ID), Modi-Spalten B/S (V nur wenn belegt),
 * humanisierter Event-Name, Script-Link + inline tokenisierter Parameter.
 */
const LayoutObjectTriggerTable: React.FC<{
  uuid: string;
  triggers: LayoutObjectTrigger[];
  file: string | null;
  report: ReportVarPart;
}> = ({ uuid, triggers, file, report }) => {
  const { t } = useTranslation(['detail']);
  const fmtEvent = useTriggerEventFormat();
  const compatOf = useTriggerCompat();
  if (triggers.length === 0) return null;

  const showPreview = triggers.some(tr => tr.previewMode);
  // Compact runtime hint (fm_spec trigger_compat ≥ 2.8.0): only the two UI
  // client runtimes matter on a layout, and only their No/Partial cells —
  // tri-state kept (Partial ≠ unsupported), nothing shown on older references.
  const compatBadges = (triggerId: number) => {
    const c = compatOf(triggerId);
    if (!c) return null;
    const items = ([['webdirect', 'WebDirect'], ['go', 'Go']] as const)
      .filter(([k]) => c[k] === false || c[k] === null)
      .map(([k, label]) => (
        <span
          key={k}
          className={`fm-lo-compat-badge${c[k] === null ? ' fm-lo-compat-badge--partial' : ''}`}
          title={c[k] === null
            ? (t('detail:scriptTriggerDetail.compatPartialHint', { defaultValue: 'Partial — conditionally supported; see the Claris help page of the event' }) as string)
            : (t('detail:scriptTriggerDetail.compatNoHint', { defaultValue: 'This event does not fire on that runtime' }) as string)}
        >
          {label} · {c[k] === null
            ? t('detail:scriptTriggerDetail.compatPartial', { defaultValue: 'partial' })
            : t('detail:scriptTriggerDetail.compatNo', { defaultValue: 'no' })}
        </span>
      ));
    return items.length > 0 ? <> {items}</> : null;
  };
  const check = (on: boolean, title: string) =>
    on ? <span className="fm-lo-mode-check" title={title}>✓</span> : null;

  return (
    <div className="object-detail layoutobject-triggers" aria-label={t('detail:layoutViewer.triggersHeading') as string}>
      <h2 className="type-detail-heading">
        {t('detail:layoutViewer.triggersHeading')} ({triggers.length})
      </h2>
      <table className="fm-lo-table">
        <thead>
          <tr>
            <th className="fm-lo-col-mode" title={t('detail:layoutObjectDetail.modeBrowse', { defaultValue: 'Browse mode' }) as string}>
              {t('detail:layoutObjectDetail.colBrowse', { defaultValue: 'B' })}
            </th>
            <th className="fm-lo-col-mode" title={t('detail:layoutObjectDetail.modeFind', { defaultValue: 'Find mode' }) as string}>
              {t('detail:layoutObjectDetail.colFind', { defaultValue: 'F' })}
            </th>
            {showPreview && (
              <th className="fm-lo-col-mode" title={t('detail:layoutObjectDetail.modePreview', { defaultValue: 'Preview mode' }) as string}>
                {t('detail:layoutObjectDetail.colPreview', { defaultValue: 'P' })}
              </th>
            )}
            <th>{t('detail:layoutObjectDetail.colEvent', { defaultValue: 'Trigger' })}</th>
            <th>{t('detail:layoutObjectDetail.colScript', { defaultValue: 'Script (parameter)' })}</th>
          </tr>
        </thead>
        <tbody>
          {triggers.map(tr => (
            <tr key={tr.triggerId}>
              <td className="fm-lo-col-mode">{check(tr.browseMode, t('detail:layoutObjectDetail.modeBrowse', { defaultValue: 'Browse mode' }) as string)}</td>
              <td className="fm-lo-col-mode">{check(tr.findMode, t('detail:layoutObjectDetail.modeFind', { defaultValue: 'Find mode' }) as string)}</td>
              {showPreview && (
                <td className="fm-lo-col-mode">{check(tr.previewMode, t('detail:layoutObjectDetail.modePreview', { defaultValue: 'Preview mode' }) as string)}</td>
              )}
              <td className="fm-lo-trigger-event">
                {/* Event-Name als Link auf die ScriptTrigger-Detailseite;
                    reiner Text auf älteren API-Ständen ohne triggerUuid. */}
                {tr.triggerUuid ? (
                  <Link
                    className="fm-field-link"
                    to={buildObjectPath(tr.triggerUuid, uuid, file)}
                    title={t('detail:scriptTriggerDetail.openTrigger', { defaultValue: 'Script-Trigger öffnen' }) as string}
                  >
                    {fmtEvent(tr.action)}
                  </Link>
                ) : (
                  fmtEvent(tr.action)
                )}
                {compatBadges(tr.triggerId)}
              </td>
              <td>
                <div className="fm-lo-trigger-script">
                  <span className="fm-layout-trigger-arrow" aria-hidden="true">→</span>{' '}
                  {tr.scriptUuid ? (
                    <Link className="fm-field-link" to={buildObjectPath(tr.scriptUuid, uuid, file)}>
                      {tr.scriptName ?? tr.scriptUuid}
                    </Link>
                  ) : (
                    <span className="fm-layout-muted">{tr.scriptName ?? '—'}</span>
                  )}
                </div>
                {tr.paramCalcUuid && (
                  <div className="fm-lo-trigger-param">
                    <span className="fm-lo-param-label">{t('detail:layoutObjectDetail.paramLabel', { defaultValue: 'Param:' })}</span>{' '}
                    <InlineCalcFormula
                      calcUuid={tr.paramCalcUuid}
                      hasTokens={tr.paramHasTokens}
                      plainText={tr.paramText}
                      matchKey={`trg-${tr.triggerId}`}
                      report={report}
                    />
                  </div>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
};

/**
 * Operator-Vokabular der wertbasierten CF-Regeln (`Condition/@type` 1–13,
 * fixture-verifizierte C1-Matrix). 0 = Formel-Bedingung; unbekannte künftige
 * Typen fallen auf `value (type N)` zurück.
 */
const CF_OPERATOR_KEYS: Record<number, string> = {
  1: 'between',
  2: 'notBetween',
  3: 'equal',
  4: 'notEqual',
  5: 'greater',
  6: 'less',
  7: 'greaterEqual',
  8: 'lessEqual',
  9: 'contains',
  10: 'notContains',
  11: 'beginsWith',
  12: 'endsWith',
  13: 'empty',
};

/**
 * Label-Liste der gewählten Format-Dimensionen einer CF-Regel, in der
 * Reihenfolge des FileMaker-Dialogs (Stil-Toggles, Farben, Textformat-Dialog).
 * Quelle sind die semantischen Parser-Felder — Farben/Schrift/Größe sind dort
 * bereits bit-gegated, Stil-Toggles präsenz-basiert; die Labels kommen aus
 * i18n (analog der engl. `format`-Spalte der Inventar-Query, aber lokalisiert).
 */
const ConditionFormatLabels: React.FC<{ format?: LayoutObjectConditionFormat }> = ({ format }) => {
  const { t } = useTranslation(['detail']);
  if (!format) return null;

  const L = (key: string, dv: string) =>
    t(`detail:layoutObjectDetail.cfFormat.${key}`, { defaultValue: dv }) as string;

  const labels: string[] = [];
  if (format.bold) labels.push(L('bold', 'bold'));
  if (format.italic) labels.push(L('italic', 'italic'));
  if (format.underline === 'word-underline') labels.push(L('wordUnderline', 'word underline'));
  else if (format.underline === 'double-underline') labels.push(L('doubleUnderline', 'double underline'));
  else if (format.underline) labels.push(L('underline', 'underline'));
  if (format.strikethrough) labels.push(L('strikethrough', 'strikethrough'));
  if (format.textColor) labels.push(L('textColor', 'text color'));
  if (format.fillColor) labels.push(L('fillColor', 'fill color'));
  if (format.iconColor) labels.push(L('iconColor', 'icon color'));
  if (format.fontFamily) labels.push(L('font', 'font'));
  if (format.fontSize) labels.push(L('fontSize', 'font size'));
  if (format.highlightColor) labels.push(L('highlight', 'highlight'));
  if (format.glyphVariant === 'superscript') labels.push(L('superscript', 'superscript'));
  else if (format.glyphVariant === 'subscript') labels.push(L('subscript', 'subscript'));
  if (format.smallCaps) labels.push(L('smallCaps', 'small caps'));
  if (format.stretch === 'condensed') labels.push(L('condensed', 'condensed'));
  else if (format.stretch === 'expanded') labels.push(L('expanded', 'expanded'));
  if (format.textTransform === 'uppercase') labels.push(L('uppercase', 'UPPERCASE'));
  else if (format.textTransform === 'lowercase') labels.push(L('lowercase', 'lowercase'));
  else if (format.textTransform === 'capitalize') labels.push(L('capitalize', 'title case'));

  if (labels.length === 0) return <span className="fm-lo-cf-format-none">—</span>;
  return <span className="fm-lo-cf-labels">{labels.join(', ')}</span>;
};

/**
 * Kompakte Format-Vorschau einer CF-Regel aus den C3-Parser-Daten: ein
 * "AaBb"-Sample mit den fertigen Preview-Deklarationen (`format.css`) auf
 * neutralem hellem Grund (FM-Farben lesen sich wie im Layoutmodus, auch im
 * Dark Theme). Hervorheben rendert als Text-Hintergrund auf dem inneren Span
 * (abgegrenzt von der Füllfarbe = äußerer Hintergrund), die Symbolfarbe als
 * eigener Swatch. Roh-CSS als Tooltip; Regeln ohne gewählte Formatierung
 * zeigen einen Strich.
 *
 * Hoch-/Tiefgestellt simuliert der innere Span: FileMaker rendert die Glyphen
 * verkleinert (~60%) und versetzt — ein `vertical-align` allein verschiebt nur
 * die Baseline und wäre ohne Referenztext unsichtbar. Der äußere Span behält
 * die Originalgröße als Strut (Box bleibt normal hoch, Text sitzt klein
 * oben/unten); sein `verticalAlign` aus `format.css` wird dafür verworfen.
 */
const ConditionFormatPreview: React.FC<{ format?: LayoutObjectConditionFormat }> = ({ format }) => {
  const { t } = useTranslation(['detail']);
  if (!format) return null;

  const css = { ...(format.css ?? {}) } as React.CSSProperties;
  delete css.verticalAlign;
  const hasSample = Object.keys(format.css ?? {}).length > 0 || !!format.highlightColor;
  if (!hasSample && !format.iconColor) {
    return <span className="fm-lo-cf-format-none">—</span>;
  }

  const innerStyle: React.CSSProperties = {};
  if (format.highlightColor) innerStyle.backgroundColor = format.highlightColor;
  if (format.glyphVariant === 'superscript') {
    innerStyle.fontSize = '0.6em';
    innerStyle.verticalAlign = 'super';
  } else if (format.glyphVariant === 'subscript') {
    innerStyle.fontSize = '0.6em';
    innerStyle.verticalAlign = 'sub';
  }

  return (
    <span className="fm-lo-cf-format" title={format.raw ?? undefined}>
      {hasSample && (
        <span className="fm-lo-cf-sample" style={css}>
          {Object.keys(innerStyle).length > 0
            ? <span style={innerStyle}>AaBb</span>
            : 'AaBb'}
        </span>
      )}
      {format.iconColor && (
        <span
          className="fm-lo-cf-swatch"
          style={{ backgroundColor: format.iconColor }}
          title={t('detail:layoutObjectDetail.cfIconColorTitle', { defaultValue: 'Icon color' }) as string}
        />
      )}
    </span>
  );
};

/** Eine CF-Tabellenzeile — eigene Komponente, damit jede Zeile ihre Formel laden kann. */
const LayoutObjectConditionRow: React.FC<{
  cond: LayoutObjectCondition;
  report: ReportVarPart;
}> = ({ cond, report }) => {
  const { t } = useTranslation(['detail']);

  // Operator-Label wertbasierter Regeln; Operanden aus Range_Start/End.
  let operator: string | null = null;
  if (cond.conditionType !== 0) {
    const key = CF_OPERATOR_KEYS[cond.conditionType];
    const label = key
      ? (t(`detail:layoutObjectDetail.cfOperator.${key}`, { defaultValue: key }) as string)
      : (t('detail:layoutObjectDetail.cfOperatorFallback', { type: cond.conditionType, defaultValue: 'value (type {{type}})' }) as string);
    const operands = [cond.rangeStart, cond.rangeEnd].filter(v => v != null && v !== '');
    operator = operands.length > 0 ? `${label} ${operands.join(' … ')}` : label;
  }

  return (
    <tr className={cond.enabled ? undefined : 'fm-lo-cf-disabled'}>
      <td className="fm-lo-col-mode">
        {cond.enabled && (
          <span className="fm-lo-mode-check" title={t('detail:layoutObjectDetail.cfActiveTitle', { defaultValue: 'Rule enabled' }) as string}>✓</span>
        )}
      </td>
      <td>
        {operator && <span className="fm-lo-cf-op">{operator}</span>}
        <InlineCalcFormula
          calcUuid={cond.calcUuid}
          hasTokens={cond.hasTokens}
          plainText={cond.calcText}
          matchKey={`cf-${cond.ruleIndex}`}
          report={report}
        />
      </td>
      <td className="fm-lo-cf-labels-cell">
        <ConditionFormatLabels format={cond.format} />
      </td>
      <td className="fm-lo-cf-format-cell">
        <ConditionFormatPreview format={cond.format} />
      </td>
    </tr>
  );
};

/**
 * Conditional-Formatting-Tabelle: regel-genau aus LayoutObjectConditions
 * (Rule_Index-sortiert, inkl. rein wertbasierter Bedingungen). Die Format-
 * Spalte rendert die C3-Parser-Daten (conditions[].format) als Vorschau.
 */
const LayoutObjectConditionTable: React.FC<{
  conditions: LayoutObjectCondition[];
  report: ReportVarPart;
}> = ({ conditions, report }) => {
  const { t } = useTranslation(['detail']);
  if (conditions.length === 0) return null;

  return (
    <div className="object-detail layoutobject-conditions" aria-label={t('detail:calculationDetail.roles.conditional_format') as string}>
      <h2 className="type-detail-heading">
        {t('detail:calculationDetail.roles.conditional_format')} ({conditions.length})
      </h2>
      <table className="fm-lo-table">
        <thead>
          <tr>
            <th className="fm-lo-col-mode" title={t('detail:layoutObjectDetail.cfActiveTitle', { defaultValue: 'Rule enabled' }) as string}>
              {t('detail:layoutObjectDetail.cfColActive', { defaultValue: 'On' })}
            </th>
            <th>{t('detail:layoutObjectDetail.cfColCalc', { defaultValue: 'Calculation' })}</th>
            <th className="fm-lo-cf-labels-col">{t('detail:layoutObjectDetail.cfColFormat', { defaultValue: 'Format' })}</th>
            <th className="fm-lo-cf-format-col">{t('detail:layoutObjectDetail.cfColPreview', { defaultValue: 'Preview' })}</th>
          </tr>
        </thead>
        <tbody>
          {conditions.map(cond => (
            <LayoutObjectConditionRow key={cond.ruleIndex} cond={cond} report={report} />
          ))}
        </tbody>
      </table>
    </div>
  );
};

/**
 * Formel eines einzelnen Calc-Slots: DDR-verankerte Instanzen laden ihre
 * Token-Sequenz via get-calc?uuid (instanz-exakter Cache im useCalcTokens);
 * DDR-lose Instanzen fallen deklariert auf den Klartext zurück — die
 * Entscheidung fällt am Katalog-Datensatz (hasTokens), nie am Fehlerpfad.
 */
const LayoutObjectCalcSlotFormula: React.FC<{
  slot: LayoutObjectCalcSlot;
  report: ReportVarPart;
}> = ({ slot, report }) => {
  const { t } = useTranslation(['detail']);
  const lang = useApiLang();
  // Fetch auch für DDR-lose Display-Calculations: der Server synthetisiert
  // dort Tokens aus der geretteten Formel; liefert er keine (404 /
  // keine Referenz gematcht), bleibt der Klartext-Fallback unten.
  const canFetch =
    slot.hasTokens || (slot.role === 'display_calculation' && !!slot.plainText);
  const { data } = useCalcTokens(canFetch ? slot.uuid : null, lang, 'uuid');
  const tokens = useMemo(
    () => (data && data.tokens.length > 0 ? data.tokens : []),
    [data],
  );
  useReportCalcVarMatches(`slot-${slot.uuid}`, tokens, report);

  if (tokens.length > 0) {
    return (
      <>
        <pre className="fm-customfunction-body">
          <code>
            <CalcTokenList tokens={tokens} />
          </code>
        </pre>
        {data?.tokensRecovered && (
          <div className="fm-calc-fallback-hint">
            {t('detail:calculationDetail.recoveredHint', {
              defaultValue: 'Tokens reconstructed from the recovered formula — this instance has no DDR chunk data; built-in functions remain unresolved.',
            })}
          </div>
        )}
      </>
    );
  }
  return (
    <>
      <pre className="fm-customfunction-body">
        <code>{normalizeCalcWhitespace(slot.plainText ?? '')}</code>
      </pre>
      {!slot.hasTokens && !slot.isStatic && (
        <div className="fm-calc-fallback-hint">
          {t('detail:calculationDetail.ddrlessHint', {
            defaultValue: 'Plain text only — this instance has no DDR chunk data, so tokens, tooltips and cross-navigation are unavailable.',
          })}
        </div>
      )}
    </>
  );
};

/**
 * Aufgelöste Merge-Text-Zeile: server-synthetisierte Tokens der reinen
 * Merge-Anker (<<Feld>>, <<$$var>>, valides {{Symbol}} → Get ( … )) — direkt
 * aus dem get-details-Payload gerendert, OHNE get-calc-Fetch (es gibt keine
 * Calculation-Instanz dahinter). ƒ-Anker stehen verbatim in der Zeile, ihre
 * Formeln zeigen die Slot-Einträge darunter. Var-Treffer melden an den
 * Aggregator, damit die $$var-Selektion sektionsübergreifend leuchtet.
 */
const LayoutObjectMergeTextLine: React.FC<{
  mergeText: LayoutObjectMergeText;
  report: ReportVarPart;
}> = ({ mergeText, report }) => {
  const { t } = useTranslation(['detail']);
  useReportCalcVarMatches('merge-text', mergeText.tokens, report);
  return (
    <div className="fm-field-formula">
      <div className="fm-field-formula-label">
        {t('detail:calculationDetail.roles.merge_text', { defaultValue: 'Resolved merge anchors' })}
      </div>
      <pre className="fm-customfunction-body">
        <code>
          <CalcTokenList tokens={mergeText.tokens} />
        </code>
      </pre>
    </div>
  );
};

/**
 * Slot-Sektion: rendert eine (gefilterte) Slot-Teilmenge unter eigenem
 * Heading. Tooltip- und Hide-Slots bekommen so ihre eigenen Sektionen in der
 * Rangfolge; die übrigen Slots (Placeholder, Button-Label, Panel-Title,
 * Popover-Title, Portal-Filter, Web-Viewer-URL) folgen gesammelt. Die
 * Sammel-Sektion trägt zusätzlich die aufgelöste Merge-Text-Zeile als ersten
 * Eintrag (erst der aufgelöste Text, dann die zerlegten Formeln) und rendert
 * dann auch ohne Slots.
 */
const LayoutObjectSlotSection: React.FC<{
  slots: LayoutObjectCalcSlot[];
  heading: string;
  showCount?: boolean;
  report: ReportVarPart;
  mergeText?: LayoutObjectMergeText | null;
}> = ({ slots, heading, showCount = false, report, mergeText = null }) => {
  const { t } = useTranslation(['detail']);
  if (slots.length === 0 && !mergeText) return null;

  // Rollen-Label aus i18n; unbekannte Rollen fallen auf den API-Rollenstring zurück.
  const roleLabel = (slot: LayoutObjectCalcSlot): string => {
    const base = t(`detail:calculationDetail.roles.${slot.role}`, { defaultValue: slot.role }) as string;
    // Mehrfach-Slots nummerieren.
    const siblings = slots.filter(s => s.role === slot.role).length;
    return siblings > 1 ? `${base} #${slot.index}` : base;
  };

  const entryCount = slots.length + (mergeText ? 1 : 0);
  return (
    <div className="object-detail layoutobject-calcs" aria-label={heading}>
      <h2 className="type-detail-heading">
        {heading}{showCount ? ` (${entryCount})` : ''}
      </h2>
      <div className="fm-customfunction fm-layoutobject-calcs">
        {mergeText && <LayoutObjectMergeTextLine mergeText={mergeText} report={report} />}
        {slots.map(slot => (
          <div key={slot.uuid} className="fm-field-formula">
            <div className="fm-field-formula-label">
              {roleLabel(slot)}
              {slot.isStatic && (
                <span className="fm-field-origin"> · {t('detail:calculationDetail.kindStatic', { defaultValue: 'Static value' })}</span>
              )}
              {slot.resultType && (
                <span className="fm-field-origin">
                  {' '}· {t('detail:calculationDetail.resultType', { defaultValue: 'Result type' })}:{' '}
                  {t(`detail:calculationDetail.resultTypes.${slot.resultType}`, { defaultValue: slot.resultType })}
                </span>
              )}
            </div>
            {/* Display-Calculations zweigeteilt (Rohschicht über Kanon):
                erst der Layout-Textanker (<<ƒ:%X:…>>), darunter der
                tokenisierte kanonische Formelkörper. */}
            {slot.layoutFormula && (
              <LayoutFormulaLine formula={slot.layoutFormula} resultType={slot.resultType} />
            )}
            <LayoutObjectCalcSlotFormula slot={slot} report={report} />
          </div>
        ))}
      </div>
    </div>
  );
};

/**
 * Klartext-Darstellung des button-eingebetteten Script-Steps (Grouped Button /
 * Button). Nutzt dieselbe Token-Pipeline wie der Script-Detail-View (kind:'script',
 * 1-Zeilen-Payload) — ScriptViewer/ScriptStepSpan/RefSpan übernehmen das
 * Klartext-Rendering, den Step-Namen-Tooltip (enrich) und die klickbaren
 * Parameter. Ohne eingebetteten Step (0 Zeilen) entfällt die Sektion komplett.
 */
const LayoutObjectStepView: React.FC<{ data: ScriptTokens }> = ({ data }) => {
  const { t } = useTranslation(['detail']);
  if (!data.lines || data.lines.length === 0) return null;

  return (
    <div className="object-detail layoutobject-step" aria-label={t('detail:buttonStep.heading', { defaultValue: 'Button action' }) as string}>
      <h2 className="type-detail-heading">{t('detail:buttonStep.heading', { defaultValue: 'Button action' })}</h2>
      <ScriptViewer tokens={data} hideToolbar />
    </div>
  );
};

/**
 * Kind-Objekt-Sektion (Position 3a — Struktur vor Ereignis-Logik): eine Zeile
 * pro direktem Kind in Segment-Reihenfolge (Z_Order), fünf Spalten
 * # | Label | Typ | Objekt | Trigger. Generisch für jedes Objekt mit Kindern —
 * nur das Überschrifts-Label ist typspezifisch („Segmente" bei Button Bars,
 * sonst „Enthaltene Objekte"). Label-Zelle = button_label-Formel (tokenisiert,
 * mit nachgestelltem Detail-Link — verschachtelte Anchors sind unmöglich),
 * Fallback Text-Inhalt → Name → Typ als Link auf die Kind-Detailansicht.
 * Typ/Objekt = gehoistetes Ziel nach v2 (Event-Trigger verdecken das Objekt
 * nicht mehr); Trigger-Zelle = ScriptTriggers des Kindes (Event → Script) plus
 * ggf. die nicht gehoistete Button-Aktion. Nur die direkte Ebene, keine
 * Rekursion.
 */
const LayoutObjectChildrenTable: React.FC<{
  uuid: string;
  items: LayoutObjectChild[];
  loType: string;
  file: string | null;
  report: ReportVarPart;
}> = ({ uuid, items, loType, file, report }) => {
  const { t } = useTranslation(['detail', 'types']);
  const fmtEvent = useTriggerEventFormat();
  if (items.length === 0) return null;

  const heading = (loType === 'Button Bar'
    ? t('detail:layoutObjectDetail.segmentsHeading', { defaultValue: 'Segments' })
    : t('detail:layoutObjectDetail.childrenHeading', { defaultValue: 'Contained objects' })) as string;

  return (
    <div className="object-detail layoutobject-children" aria-label={heading}>
      <h2 className="type-detail-heading">
        {heading} ({items.length})
      </h2>
      <table className="fm-lo-table">
        <thead>
          <tr>
            <th className="fm-lo-col-num">#</th>
            <th>{t('detail:layoutObjectDetail.colLabel', { defaultValue: 'Label' })}</th>
            <th>{t('detail:layoutObjectDetail.colType', { defaultValue: 'Type' })}</th>
            <th>{t('detail:layoutObjectDetail.colObject', { defaultValue: 'Object' })}</th>
            <th>{t('detail:layoutObjectDetail.colTrigger', { defaultValue: 'Trigger' })}</th>
          </tr>
        </thead>
        <tbody>
          {items.map((child, i) => {
            const detailPath = buildObjectPath(child.uuid, uuid, file);
            const detailTitle = t('detail:layoutObjectDetail.childDetailTitle', {
              defaultValue: 'Open object details',
            }) as string;
            const fallbackLabel =
              child.textContent ??
              child.name ??
              (t(`types:objectTypes.${child.type}`, { defaultValue: child.type }) as string);
            const triggers = child.triggers ?? [];
            const buttonAction = child.buttonAction ?? null;
            const dash = <span className="fm-layout-muted">—</span>;
            return (
              <tr key={child.uuid}>
                <td className="fm-lo-col-num">{i + 1}</td>
                <td>
                  {child.labelCalcUuid || child.labelText ? (
                    <>
                      <InlineCalcFormula
                        calcUuid={child.labelCalcUuid}
                        hasTokens={child.labelHasTokens}
                        plainText={child.labelText}
                        matchKey={`child-${child.uuid}`}
                        report={report}
                      />{' '}
                      <Link
                        className="fm-field-link fm-lo-child-detail"
                        to={detailPath}
                        title={detailTitle}
                        aria-label={detailTitle}
                      >
                        ↗
                      </Link>
                    </>
                  ) : (
                    <Link className="fm-field-link" to={detailPath} title={detailTitle}>
                      {fallbackLabel}
                    </Link>
                  )}
                </td>
                <td className="fm-lo-col-type">
                  {child.target ? (
                    <span className="fm-lo-chip-role">
                      {t(`types:objectTypes.${child.target.type}`, {
                        defaultValue: child.target.type ?? child.target.linkRole,
                      })}
                    </span>
                  ) : (
                    dash
                  )}
                </td>
                <td>
                  {child.target ? (
                    <Link
                      className="fm-field-link"
                      to={buildObjectPath(child.target.uuid, uuid, child.target.file ?? file)}
                    >
                      {child.target.name ?? child.target.uuid}
                    </Link>
                  ) : (
                    dash
                  )}
                </td>
                <td>
                  {triggers.length === 0 && !buttonAction
                    ? dash
                    : (
                      <>
                        {triggers.map((tg, ti) => (
                          <div key={`${tg.action}-${ti}`} className="fm-lo-trigger-script">
                            {/* Event → Trigger-Detail; reiner Text ohne triggerUuid (Alt-API). */}
                            {tg.triggerUuid ? (
                              <Link
                                className="fm-field-link fm-lo-trigger-event"
                                to={buildObjectPath(tg.triggerUuid, uuid, file)}
                                title={t('detail:scriptTriggerDetail.openTrigger', { defaultValue: 'Script-Trigger öffnen' }) as string}
                              >
                                {fmtEvent(tg.action)}
                              </Link>
                            ) : (
                              <span className="fm-lo-trigger-event">{fmtEvent(tg.action)}</span>
                            )}{' '}
                            <span className="fm-layout-trigger-arrow" aria-hidden="true">→</span>{' '}
                            {tg.scriptUuid ? (
                              <Link className="fm-field-link" to={buildObjectPath(tg.scriptUuid, uuid, file)}>
                                {tg.scriptName ?? tg.scriptUuid}
                              </Link>
                            ) : (
                              <span className="fm-layout-muted">{tg.scriptName ?? '—'}</span>
                            )}
                          </div>
                        ))}
                        {buttonAction && (
                          <div className="fm-lo-trigger-script">
                            <span className="fm-lo-trigger-event">
                              {t('detail:buttonStep.heading', { defaultValue: 'Button action' })}
                            </span>{' '}
                            <span className="fm-layout-trigger-arrow" aria-hidden="true">→</span>{' '}
                            <Link
                              className="fm-field-link"
                              to={buildObjectPath(buttonAction.uuid, uuid, buttonAction.file ?? file)}
                            >
                              {buttonAction.name ?? buttonAction.uuid}
                            </Link>
                          </div>
                        )}
                      </>
                    )}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
};

/**
 * Eigenschaften-Panel (Position 2, direkt nach der Ziel-Leiste; ersetzt den
 * GenericObjectDetail-Content-Block): strukturierte Struktur-Eigenschaften
 * als dl nach dem fm-field-props-Muster — Typ (lokalisiert), Name (nur wenn
 * vorhanden), Layoutbereich, Position/Größe kompakt, Verschachtelung mit
 * klickbarem Parent (Gegenrichtung der Kind-Sektion). Layout-, UUID- und
 * Datei-Zeile entfallen bewusst (Rücksprung-Chip bzw. URL/Objekt-Header);
 * die Kanten-Sicht lebt vollständig im Referenzen-Tab.
 */
const LayoutObjectPropsPanel: React.FC<{
  uuid: string;
  loCtx: LayoutObjectContext;
  objectName: string | null;
  file: string | null;
}> = ({ uuid, loCtx, objectName, file }) => {
  const { t } = useTranslation(['detail', 'types']);

  const b = loCtx.bounds ?? null;
  const parent = loCtx.parent ?? null;

  return (
    <div
      className="object-detail layoutobject-props"
      aria-label={t('detail:layoutObjectDetail.propsHeading', { defaultValue: 'Properties' }) as string}
    >
      <h2 className="type-detail-heading">
        {t('detail:layoutObjectDetail.propsHeading', { defaultValue: 'Properties' })}
      </h2>
      <dl className="fm-field-props">
        <dt>{t('detail:layoutObjectDetail.propType', { defaultValue: 'Type' })}</dt>
        <dd>{t(`types:objectTypes.${loCtx.type}`, { defaultValue: loCtx.type })}</dd>
        {objectName && (
          <>
            <dt>{t('detail:layoutObjectDetail.propName', { defaultValue: 'Name' })}</dt>
            <dd>{objectName}</dd>
          </>
        )}
        {loCtx.partType && (
          <>
            <dt>{t('detail:layoutObjectDetail.propPart', { defaultValue: 'Layout part' })}</dt>
            <dd>{loCtx.partType}</dd>
          </>
        )}
        {b && (
          <>
            <dt>{t('detail:layoutObjectDetail.propPosition', { defaultValue: 'Position/size' })}</dt>
            <dd title={`Top ${b.top} · Left ${b.left} · Bottom ${b.bottom} · Right ${b.right}`}>
              {b.top} / {b.left} · {b.right - b.left} × {b.bottom - b.top}
            </dd>
          </>
        )}
        {parent && (
          <>
            <dt>{t('detail:layoutObjectDetail.propNesting', { defaultValue: 'Nesting' })}</dt>
            <dd>
              {loCtx.nestingLevel != null && (
                <>
                  {t('detail:layoutObjectDetail.nestingLevel', {
                    level: loCtx.nestingLevel,
                    defaultValue: 'Level {{level}}',
                  })}
                  {' · '}
                </>
              )}
              <Link className="fm-field-link" to={buildObjectPath(parent.uuid, uuid, file)}>
                {t(`types:objectTypes.${parent.type}`, { defaultValue: parent.type ?? '' })}
                {parent.name ? `: ${parent.name}` : ''}
              </Link>
            </dd>
          </>
        )}
      </dl>
    </div>
  );
};

export interface LayoutObjectDetailProps {
  uuid: string;
  objectType: string;
}

/**
 * LayoutObject-Detail — Sektions-Rangfolge (daten-getrieben, kein Typ-Switch):
 *   1. Ziel-Leiste (Rücksprung + Chips)
 *   2. Eigenschaften-Panel (Typ, Part, Position, Verschachtelung)
 *   3. Button-Action (eingebetteter Step)
 *   4. Kind-Objekt-Sektion (Segmente / Enthaltene Objekte — Struktur vor Ereignis-Logik)
 *   5. Script-Trigger-Tabelle
 *   6. Tooltip-Calculation
 *   7. Hide-Condition
 *   8. Conditional-Formatting-Tabelle
 *   9. Übrige Calc-Slots
 * Jede Sektion rendert genau dann, wenn der Katalog Daten liefert.
 */
export const LayoutObjectDetail: React.FC<LayoutObjectDetailProps> = ({ uuid }) => {
  const { t } = useTranslation(['detail']);
  const lang = useApiLang();
  const currentFile = useCurrentFile();
  const { data } = useScriptTokens(uuid, lang, currentFile);
  const { proxySel, report } = useVarMatchAggregator();

  const file = currentFile ?? data?.object?.file ?? null;
  const slots = useMemo(() => data?.calcSlots ?? [], [data]);
  const tooltipSlots = useMemo(() => slots.filter(s => s.role === 'tooltip'), [slots]);
  const hideSlots = useMemo(() => slots.filter(s => s.role === 'hide'), [slots]);
  const otherSlots = useMemo(
    () => slots.filter(s => s.role !== 'tooltip' && s.role !== 'hide'),
    [slots],
  );

  return (
    <VarSelectionContext.Provider value={proxySel}>
      {data && <LayoutObjectTargetBar uuid={uuid} data={data} file={file} />}
      {data?.layoutObject && (
        <LayoutObjectPropsPanel
          uuid={uuid}
          loCtx={data.layoutObject}
          objectName={data.object?.name ?? null}
          file={file}
        />
      )}
      {/* Textinhalt: der Original-Textblock verbatim — die Layout-
          Wahrheit inkl. aller Merge-Anker und Fließtext (die Berechnungs-
          Slots darunter zeigen nur die zerlegten Formeln). Nur Text-Objekte. */}
      {data?.layoutObject?.type === 'Text' && data.layoutObject.textContent && (
        <div className="object-detail layoutobject-textcontent" aria-label={t('detail:textContent.heading', { defaultValue: 'Text content' }) as string}>
          <h2 className="type-detail-heading">
            {t('detail:textContent.heading', { defaultValue: 'Text content' })}
          </h2>
          <div className="fm-customfunction">
            <pre className="fm-customfunction-body">
              <code>{data.layoutObject.textContent}</code>
            </pre>
          </div>
        </div>
      )}
      {data && <LayoutObjectStepView data={data} />}
      {data && (
        <LayoutObjectChildrenTable
          uuid={uuid}
          items={data.children ?? []}
          loType={data.layoutObject?.type ?? ''}
          file={file}
          report={report}
        />
      )}
      {data && (
        <LayoutObjectTriggerTable
          uuid={uuid}
          triggers={data.triggers ?? []}
          file={file}
          report={report}
        />
      )}
      <LayoutObjectSlotSection
        slots={tooltipSlots}
        heading={t('detail:calculationDetail.roles.tooltip', { defaultValue: 'Tooltip' }) as string}
        report={report}
      />
      <LayoutObjectSlotSection
        slots={hideSlots}
        heading={t('detail:calculationDetail.roles.hide', { defaultValue: 'Hide condition' }) as string}
        report={report}
      />
      {data && <LayoutObjectConditionTable conditions={data.conditions ?? []} report={report} />}
      <LayoutObjectSlotSection
        slots={otherSlots}
        heading={t('detail:calculationDetail.slotsHeading', { defaultValue: 'Calculations' }) as string}
        showCount
        report={report}
        mergeText={data?.mergeText ?? null}
      />
    </VarSelectionContext.Provider>
  );
};
