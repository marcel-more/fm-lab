import { useTranslation } from 'react-i18next';
import type { TraceEntry, TraceEntryKey, TraceExcludedItem, TraceSuggestion } from '../hooks/useTrace';

/**
 * Trace mode controls + entry chooser.
 *
 * `ExplorerTracePanel` replaces the depth slider / direction radios inside the
 * Explorer filter panel while the trace mode is active: three budget steppers
 * (up / down / trigger cascade), the opt-in switches (local variables, buttons,
 * upstream touch) and a legend of the trace roles. The feature name "Trace"
 * itself stays untranslated in every locale — only tooltips and
 * descriptions are localized.
 *
 * `ExplorerTraceEntryChooser` is the canvas overlay a layout start shows before
 * the first fetch: one card per entry preset with seed counter + name sample.
 */

export interface TraceControlValues {
  upDepth: number;
  downDepth: number;
  triggerDepth: number;
  expandUp: boolean;
  includeLocalVars: boolean;
  includeButtons: boolean;
  /** Interaktions-Events (Keystroke & Co.) in die Kaskade aufnehmen. */
  includeInteractionTriggers: boolean;
}

interface ExplorerTracePanelProps {
  values: TraceControlValues;
  /** Effektives Einstiegs-Preset (aus Antwort/URL); null solange unbekannt. */
  entry: TraceEntryKey | null;
  /** Verfügbare Presets (Layout-Starts) — >1 Einträge ⇒ Umschalter anzeigen. */
  entries: TraceEntry[] | null;
  /** Aktive Boundary-Ausschlüsse als Chips (katalog-angereichert). */
  excluded: TraceExcludedItem[];
  /** Server-Vorschläge (Score-absteigend, bereits Ausgeschlossene gefiltert). */
  suggestions: TraceSuggestion[];
  onChange: (patch: Partial<TraceControlValues>) => void;
  onEntryChange: (entry: TraceEntryKey) => void;
  /** Einzelnen Ausschluss aufheben (Chip-Klick). */
  onRemoveExclude: (id: string) => void;
  /** Alle Ausschlüsse aufheben. */
  onClearExcludes: () => void;
  /** Vorschlag übernehmen (Chip-Klick → Exclude-Liste). */
  onApplySuggestion: (id: string) => void;
  /** Alle Vorschläge übernehmen. */
  onApplyAllSuggestions: () => void;
  /** Zurück in den Nachbarschafts-Modus (?focus= auf dem Startobjekt). */
  onExitTrace: () => void;
}

/** Budget-Grenzen — spiegeln den Validator (graphTrace-Schema). */
const UP_MAX = 16;
const DOWN_MAX = 16;
const TDEPTH_MAX = 3;

/** Legende: traceRole → Marker-Stil (deckungsgleich mit dem Cytoscape-Stylesheet). */
const LEGEND: { key: string; marker: React.CSSProperties }[] = [
  { key: 'chain', marker: { border: '2.5px solid #646cff' } },
  { key: 'touched', marker: { border: '1.5px solid var(--color-text-secondary, #888)' } },
  { key: 'triggered', marker: { border: '3px double #b45ce8' } },
  { key: 'triggerTouched', marker: { border: '1.5px solid #b45ce8', opacity: 0.7 } },
  { key: 'owner', marker: { border: '1.5px dashed var(--color-text-secondary, #888)', opacity: 0.6 } },
  { key: 'excluded', marker: { border: '2px dashed #e8a33d', opacity: 0.6 } },
  { key: 'induced', marker: { borderTop: '2px dotted var(--color-text-secondary, #888)', borderRadius: 0, height: 0, marginTop: 6 } },
];

function BudgetStepper(props: {
  id: string;
  label: string;
  hint: string;
  value: number;
  min: number;
  max: number;
  onChange: (v: number) => void;
}) {
  const { id, label, hint, value, min, max, onChange } = props;
  return (
    <label className="explorer-trace-budget" htmlFor={id} title={hint}>
      <span>{label}</span>
      <input
        id={id}
        type="number"
        min={min}
        max={max}
        step={1}
        value={value}
        onChange={(e) => {
          const v = Math.round(Number(e.target.value));
          if (Number.isFinite(v)) onChange(Math.min(max, Math.max(min, v)));
        }}
      />
    </label>
  );
}

export function ExplorerTracePanel(props: ExplorerTracePanelProps) {
  const { values, entry, entries, excluded, suggestions, onChange, onEntryChange, onRemoveExclude, onClearExcludes, onApplySuggestion, onApplyAllSuggestions, onExitTrace } = props;
  const { t } = useTranslation(['explorer']);

  // Layout-Starts: Preset-Umschalter (Zähler je Preset); Script-Starts haben nur
  // das triviale Preset → kein Umschalter.
  const switchable = (entries ?? []).filter((e) => e.entry !== 'script');

  return (
    <>
      {/* Eigenname „Trace" bewusst unübersetzt. */}
      <div className="explorer-filter-section">
        <div className="explorer-filter-label-row">
          <span className="explorer-filter-label">Trace</span>
          <button
            type="button"
            className="explorer-focus-details"
            onClick={onExitTrace}
            title={t('trace.exitHint') as string}
          >
            {t('trace.exit')}
          </button>
        </div>
        <p className="explorer-trace-explainer">{t('trace.explainer')}</p>
      </div>

      {switchable.length > 1 && (
        <div className="explorer-filter-section">
          <span className="explorer-filter-label">{t('trace.entryLabel')}</span>
          <div className="explorer-trace-entries" role="radiogroup" aria-label={t('trace.entryLabel') as string}>
            {switchable.map((e) => (
              <button
                key={e.entry}
                type="button"
                role="radio"
                aria-checked={entry === e.entry}
                className={`explorer-segment${entry === e.entry ? ' is-active' : ''}`}
                disabled={e.seedCount === 0}
                onClick={() => onEntryChange(e.entry)}
                title={t(`trace.entryHints.${e.entry}`) as string}
              >
                {t(`trace.entries.${e.entry}`)}
                <span className="explorer-chip-count">{e.seedCount}</span>
              </button>
            ))}
          </div>
        </div>
      )}

      <div className="explorer-filter-section">
        <span className="explorer-filter-label">{t('trace.budgets')}</span>
        <div className="explorer-trace-budgets">
          <BudgetStepper
            id="trace-up"
            label={t('trace.upDepth') as string}
            hint={t('trace.upDepthHint') as string}
            value={values.upDepth}
            min={0}
            max={UP_MAX}
            onChange={(v) => onChange({ upDepth: v })}
          />
          <BudgetStepper
            id="trace-down"
            label={t('trace.downDepth') as string}
            hint={t('trace.downDepthHint') as string}
            value={values.downDepth}
            min={0}
            max={DOWN_MAX}
            onChange={(v) => onChange({ downDepth: v })}
          />
          <BudgetStepper
            id="trace-tdepth"
            label={t('trace.triggerDepth') as string}
            hint={t('trace.triggerDepthHint') as string}
            value={values.triggerDepth}
            min={0}
            max={TDEPTH_MAX}
            onChange={(v) => onChange({ triggerDepth: v })}
          />
        </div>
      </div>

      <div className="explorer-filter-section">
        <span className="explorer-filter-label">{t('trace.options')}</span>
        <div className="explorer-trace-toggles">
          <label title={t('trace.localVarsHint') as string}>
            <input
              type="checkbox"
              checked={values.includeLocalVars}
              onChange={(e) => onChange({ includeLocalVars: e.target.checked })}
            />
            {t('trace.localVars')}
          </label>
          <label title={t('trace.buttonsHint') as string}>
            <input
              type="checkbox"
              checked={values.includeButtons}
              onChange={(e) => onChange({ includeButtons: e.target.checked })}
            />
            {t('trace.buttons')}
          </label>
          <label title={t('trace.interactionTriggersHint') as string}>
            <input
              type="checkbox"
              checked={values.includeInteractionTriggers}
              onChange={(e) => onChange({ includeInteractionTriggers: e.target.checked })}
            />
            {t('trace.interactionTriggers')}
          </label>
          <label title={t('trace.expandUpHint') as string}>
            <input
              type="checkbox"
              checked={values.expandUp}
              onChange={(e) => onChange({ expandUp: e.target.checked })}
            />
            {t('trace.expandUp')}
          </label>
        </div>
      </div>

      {excluded.length > 0 && (
        <div className="explorer-filter-section">
          <div className="explorer-filter-label-row">
            <span className="explorer-filter-label">{t('trace.excludedLabel')}</span>
            <button
              type="button"
              className="explorer-focus-details"
              onClick={onClearExcludes}
              title={t('trace.clearExcludesHint') as string}
            >
              {t('trace.clearExcludes')}
            </button>
          </div>
          <div className="explorer-trace-excluded">
            {excluded.map((x) => (
              <button
                key={x.id}
                type="button"
                className="explorer-trace-excluded-chip"
                title={t('trace.removeExcludeHint') as string}
                onClick={() => onRemoveExclude(x.id)}
              >
                <span className="explorer-trace-excluded-label">{x.label ?? x.uuid}</span>
                {x.file && <span className="explorer-trace-excluded-file">{x.file}</span>}
                <span aria-hidden="true">✕</span>
              </button>
            ))}
          </div>
        </div>
      )}

      {suggestions.length > 0 && (
        <div className="explorer-filter-section">
          <div className="explorer-filter-label-row">
            <span className="explorer-filter-label">{t('trace.suggestionsLabel')}</span>
            <button
              type="button"
              className="explorer-focus-details"
              onClick={onApplyAllSuggestions}
              title={t('trace.applyAllSuggestionsHint') as string}
            >
              {t('trace.applyAllSuggestions')}
            </button>
          </div>
          <div className="explorer-trace-excluded">
            {suggestions.map((s) => (
              <button
                key={s.id}
                type="button"
                className="explorer-trace-excluded-chip explorer-trace-suggestion-chip"
                title={t('trace.suggestionHint', { trig: s.trigIn, calls: s.fanIn, touch: s.touchOut }) as string}
                onClick={() => onApplySuggestion(s.id)}
              >
                <span aria-hidden="true">+</span>
                <span className="explorer-trace-excluded-label">{s.label}</span>
                {s.file && <span className="explorer-trace-excluded-file">{s.file}</span>}
              </button>
            ))}
          </div>
        </div>
      )}

      <div className="explorer-filter-section">
        <span className="explorer-filter-label">{t('trace.legend')}</span>
        <ul className="explorer-trace-legend">
          {LEGEND.map(({ key, marker }) => (
            <li key={key}>
              <span className="explorer-trace-legend-marker" style={marker} aria-hidden="true" />
              <span>{t(`trace.roles.${key}`)}</span>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}

interface ExplorerTraceEntryChooserProps {
  entries: TraceEntry[];
  /** true = das zuvor gewählte Preset lieferte 0 Seeds (Hinweis statt leerem Graph). */
  emptyEntry: boolean;
  onChoose: (entry: TraceEntryKey) => void;
}

/** Canvas-Overlay eines Layout-Starts — Einstiegspfad wählen (Stufe-0-Presets). */
export function ExplorerTraceEntryChooser(props: ExplorerTraceEntryChooserProps) {
  const { entries, emptyEntry, onChoose } = props;
  const { t } = useTranslation(['explorer']);
  const choices = entries.filter((e) => e.entry !== 'script');

  return (
    <div className="graph-explorer-placeholder explorer-trace-chooser">
      <h3>{t('trace.entryTitle')}</h3>
      {emptyEntry && <p className="explorer-trace-chooser-empty">{t('trace.emptyEntry')}</p>}
      <div className="explorer-trace-chooser-list">
        {choices.map((e) => (
          <button
            key={e.entry}
            type="button"
            className="explorer-trace-chooser-item"
            disabled={e.seedCount === 0}
            onClick={() => onChoose(e.entry)}
          >
            <span className="explorer-trace-chooser-name">
              {t(`trace.entries.${e.entry}`)}
              {e.isDefault && <em> · {t('trace.entryDefault')}</em>}
            </span>
            <span className="explorer-trace-chooser-count">
              {t('trace.seedCount', { count: e.seedCount })}
            </span>
            {e.seedsSample.length > 0 && (
              <span className="explorer-trace-chooser-sample" title={e.seedsSample.join(', ')}>
                {e.seedsSample.join(' · ')}
              </span>
            )}
          </button>
        ))}
      </div>
    </div>
  );
}
