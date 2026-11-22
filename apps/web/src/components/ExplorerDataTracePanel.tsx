import { NoDdrNotice } from './NoDdrNotice';
import { useTranslation } from 'react-i18next';
import type {
  DataTraceStartStep,
  DataProfileCandidate,
  DataTraceBlindSpots,
  DataTraceDir,
  DataTraceProfile,
  DataTraceStats,
} from '../hooks/useDataTrace';
import { DATA_TRACE_FIELD_LEVELS_MAX } from '../hooks/useDataTrace';
import type { TraceExcludedItem } from '../hooks/useTrace';
import { DATA_FLOW_ROLE_COLORS } from '../lib/graphColors';

/**
 * Controls of the data trace (`mode=data`) in the Explorer filter panel —
 * the sister of {@link ExplorerTracePanel} for the flow trace.
 *
 * Field levels (the direction is a tab of the ways list), the switches for control edges,
 * sinks, reset ways and the solution profile, the profile hints on the current
 * trace (confirm / reject per candidate, bulk dialog), boundary exclusions,
 * blind spots and a legend of the flow roles. "Trace" stays untranslated.
 */

export interface DataTraceControlValues {
  dir: DataTraceDir;
  fieldLevels: number;
  includeControl: boolean;
  includeSinks: boolean;
  includeReset: boolean;
  profile: boolean;
}

interface ExplorerDataTracePanelProps {
  /** Type of the start object (Field · Variable); null while loading. */
  startType: string | null;
  /** Step anchor of a local variable start; null = whole script. */
  startStep: DataTraceStartStep | null;
  onClearAnchor: () => void;
  values: DataTraceControlValues;
  /** Ways expanded via "follow source" — shown as a resettable counter. */
  expandedWays: number;
  stats: DataTraceStats | null;
  blindSpots: DataTraceBlindSpots | null;
  profile: DataTraceProfile | null;
  excluded: TraceExcludedItem[];
  /** Candidate key being written (disables its buttons). */
  profileBusy: string | null;
  profileError: string | null;
  onChange: (patch: Partial<DataTraceControlValues>) => void;
  onResetExpansion: () => void;
  onRemoveExclude: (id: string) => void;
  onClearExcludes: () => void;
  onDecideCandidate: (c: DataProfileCandidate, status: 'confirmed' | 'rejected') => void;
  onOpenProfile: () => void;
  onExitTrace: () => void;
}

const LEGEND_ROLES = ['start', 'field', 'step', 'variable', 'param', 'calc', 'entry', 'control', 'sink', 'blind'] as const;

export function ExplorerDataTracePanel(props: ExplorerDataTracePanelProps) {
  const {
    startType, startStep, onClearAnchor, values, expandedWays, stats, blindSpots, profile, excluded, profileBusy, profileError,
    onChange, onResetExpansion, onRemoveExclude, onClearExcludes, onDecideCandidate, onOpenProfile, onExitTrace,
  } = props;
  const { t } = useTranslation(['explorer']);
  const up = values.dir === 'up';

  const blind = blindSpots
    ? ([
        ['dynamicWrites', blindSpots.dynamicWrites],
        ['dynamicCalls', blindSpots.dynamicCalls],
        ['dynamicSql', blindSpots.dynamicSql],
        ['uninitialized', blindSpots.uninitialized],
        ['approxEdges', blindSpots.approxEdges],
        ['disabledSteps', stats?.disabledSteps ?? 0],
        ['contextOpen', stats?.contextOpen ?? 0],
      ] as const).filter(([, n]) => n > 0)
    : [];

  const applied = profile && profile.enabled
    ? ([
        ['technicalLayout', profile.applied.technicalLayout],
        ['boundaryScript', profile.applied.boundaryScript],
        ['uiStateVariable', profile.applied.uiStateVariable],
        ['hubVariable', profile.applied.hubVariable],
        ['hubReaders', profile.applied.hubReaders],
      ] as const).filter(([, n]) => n > 0)
    : [];

  return (
    <>
      {/* Eigenname „Trace" bewusst unübersetzt. */}
      <div className="explorer-filter-section">
        <div className="explorer-filter-label-row">
          <span className="explorer-filter-label">Trace · {t('trace.data.title')}</span>
          <button
            type="button"
            className="explorer-focus-details"
            onClick={onExitTrace}
            title={t('trace.exitHint') as string}
          >
            {t('trace.exit')}
          </button>
        </div>
        <p className="explorer-trace-explainer">
          {t(`${up ? 'trace.data.explainerUp' : 'trace.data.explainerDown'}${startType === 'Variable' ? 'Variable' : ''}`)}
        </p>
        {startStep && (
          <div className="explorer-data-anchor">
            <span className="explorer-data-sublabel">{t('trace.data.anchorLabel')}</span>
            <span className="explorer-data-anchor-text" title={startStep.scriptName ?? undefined}>
              {t(startStep.role === 'set' ? 'trace.data.anchorSet' : 'trace.data.anchorRead', {
                script: startStep.scriptName ?? '?',
                n: startStep.stepIndex !== null ? startStep.stepIndex + 1 : '?',
                step: startStep.stepName ?? '',
              })}
            </span>
            <button type="button" className="explorer-focus-details" onClick={onClearAnchor} title={t('trace.data.clearAnchorHint') as string}>
              {t('trace.data.clearAnchor')}
            </button>
          </div>
        )}
      </div>

      <div className="explorer-filter-section">
        <span className="explorer-filter-label">{t('trace.budgets')}</span>
        <div className="explorer-trace-budgets">
          <label className="explorer-trace-budget" htmlFor="trace-field-levels" title={t('trace.data.fieldLevelsHint') as string}>
            <span>{t('trace.data.fieldLevels')}</span>
            <input
              id="trace-field-levels"
              type="number"
              min={1}
              max={DATA_TRACE_FIELD_LEVELS_MAX}
              step={1}
              value={values.fieldLevels}
              onChange={(e) => {
                const v = Math.round(Number(e.target.value));
                if (Number.isFinite(v)) onChange({ fieldLevels: Math.min(DATA_TRACE_FIELD_LEVELS_MAX, Math.max(1, v)) });
              }}
            />
          </label>
        </div>
        {expandedWays > 0 && (
          <div className="explorer-filter-label-row explorer-data-expanded">
            <span>{t('trace.data.expandedWays', { count: expandedWays })}</span>
            <button type="button" className="explorer-focus-details" onClick={onResetExpansion}>
              {t('trace.data.resetExpansion')}
            </button>
          </div>
        )}
      </div>

      <div className="explorer-filter-section">
        <span className="explorer-filter-label">{t('trace.options')}</span>
        <div className="explorer-trace-toggles">
          <label title={t('trace.data.controlHint') as string}>
            <input type="checkbox" checked={values.includeControl} onChange={(e) => onChange({ includeControl: e.target.checked })} />
            {t('trace.data.control')}
          </label>
          {up ? (
            <label title={t('trace.data.resetHint') as string}>
              <input type="checkbox" checked={values.includeReset} onChange={(e) => onChange({ includeReset: e.target.checked })} />
              {t('trace.data.resetWays')}
            </label>
          ) : (
            <label title={t('trace.data.sinksHint') as string}>
              <input type="checkbox" checked={values.includeSinks} onChange={(e) => onChange({ includeSinks: e.target.checked })} />
              {t('trace.data.sinks')}
            </label>
          )}
          <label title={t('trace.data.profileHint') as string}>
            <input type="checkbox" checked={values.profile} onChange={(e) => onChange({ profile: e.target.checked })} />
            {t('trace.data.profile')}
          </label>
        </div>
      </div>

      <div className="explorer-filter-section">
        <div className="explorer-filter-label-row">
          <span className="explorer-filter-label">{t('trace.data.profileLabel')}</span>
          <button type="button" className="explorer-focus-details" onClick={onOpenProfile} title={t('trace.data.profileManageHint') as string}>
            {t('trace.data.profileManage')}
          </button>
        </div>
        {profile && (
          <p className="explorer-trace-explainer">
            {profile.enabled
              ? t('trace.data.profileState', { count: profile.confirmed })
              : t('trace.data.profileOff')}
            {profile.orphaned > 0 && <> · {t('trace.data.profileOrphaned', { count: profile.orphaned })}</>}
          </p>
        )}
        {applied.length > 0 && (
          <ul className="explorer-data-notes">
            {applied.map(([k, n]) => (
              <li key={k}>{t(`trace.data.applied.${k}`, { count: n })}</li>
            ))}
          </ul>
        )}
        {profile && profile.candidates.length > 0 && (
          <>
            <span className="explorer-data-sublabel">{t('trace.data.candidatesLabel')}</span>
            <ul className="explorer-data-candidates">
              {profile.candidates.map((c) => (
                <li key={c.key} title={t(`trace.data.heuristicHint.${c.heuristic}`, { defaultValue: '' }) as string}>
                  <span className="explorer-data-candidate-text">
                    {t(`trace.data.candidate.${c.kind}`, { name: c.name })}
                    {c.uncertain && <em> · {t('trace.data.uncertain')}</em>}
                  </span>
                  <span className="explorer-data-candidate-actions">
                    <button
                      type="button"
                      disabled={profileBusy === c.key}
                      onClick={() => onDecideCandidate(c, 'confirmed')}
                      title={t('trace.data.confirmHint') as string}
                      aria-label={t('trace.data.confirm') as string}
                    >
                      ✓
                    </button>
                    <button
                      type="button"
                      disabled={profileBusy === c.key}
                      onClick={() => onDecideCandidate(c, 'rejected')}
                      title={t('trace.data.rejectHint') as string}
                      aria-label={t('trace.data.reject') as string}
                    >
                      ✕
                    </button>
                  </span>
                </li>
              ))}
            </ul>
          </>
        )}
        {profileError && <p className="explorer-data-error" role="alert">{profileError}</p>}
      </div>

      {excluded.length > 0 && (
        <div className="explorer-filter-section">
          <div className="explorer-filter-label-row">
            <span className="explorer-filter-label">{t('trace.excludedLabel')}</span>
            <button type="button" className="explorer-focus-details" onClick={onClearExcludes} title={t('trace.clearExcludesHint') as string}>
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

      <NoDdrNotice files={blindSpots?.noDdr?.files} />

      {(blind.length > 0 || (stats && stats.truncatedBy.length > 0)) && (
        <div className="explorer-filter-section">
          <span className="explorer-filter-label">{t('trace.data.blindSpots')}</span>
          <ul className="explorer-data-notes">
            {stats?.truncatedBy.map((k) => (
              k === 'field_levels'
                ? <li key={`cut-${k}`}>{t('trace.data.cutFieldLevels', { count: stats.cutFieldLevels })}</li>
                : <li key={`cut-${k}`} className="is-warning">{t(`trace.data.truncatedBy.${k}`, { defaultValue: k })}</li>
            ))}
            {blind.map(([k, n]) => (
              <li key={k} title={t(`trace.data.blind.${k}Hint`, { defaultValue: '' }) as string}>
                {t(`trace.data.blind.${k}`, { count: n })}
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="explorer-filter-section">
        <span className="explorer-filter-label">{t('trace.legend')}</span>
        <ul className="explorer-trace-legend">
          {LEGEND_ROLES.map((role) => (
            <li key={role}>
              <span
                className="explorer-trace-legend-marker"
                style={{ border: `2.5px ${role === 'control' || role === 'sink' ? 'dashed' : 'solid'} ${DATA_FLOW_ROLE_COLORS[role]}` }}
                aria-hidden="true"
              />
              <span>{t(`trace.data.roles.${role}`)}</span>
            </li>
          ))}
          <li>
            <span className="explorer-trace-legend-marker" style={{ borderTop: '2px solid #22c55e', borderRadius: 0, height: 0, marginTop: 6 }} aria-hidden="true" />
            <span>{t('trace.data.edges.data')}</span>
          </li>
          <li>
            <span className="explorer-trace-legend-marker" style={{ borderTop: '2px dashed #22c55e', borderRadius: 0, height: 0, marginTop: 6 }} aria-hidden="true" />
            <span>{t('trace.data.edges.approx')}</span>
          </li>
          <li>
            <span className="explorer-trace-legend-marker" style={{ borderTop: '2px dotted #64748b', borderRadius: 0, height: 0, marginTop: 6 }} aria-hidden="true" />
            <span>{t('trace.data.edges.flow')}</span>
          </li>
          <li>
            <span className="explorer-trace-legend-marker" style={{ borderTop: '2px solid #ec4899', borderRadius: 0, height: 0, marginTop: 6 }} aria-hidden="true" />
            <span>{t('trace.data.edges.entry')}</span>
          </li>
          <li>
            <span className="explorer-trace-legend-marker" style={{ border: '2px dashed #e8a33d', opacity: 0.6 }} aria-hidden="true" />
            <span>{t('trace.data.roles.profileStop')}</span>
          </li>
        </ul>
      </div>
    </>
  );
}
