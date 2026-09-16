import React, { useMemo } from 'react';
import { Link } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { useScriptTriggerDetail } from '../hooks/useScriptTriggerDetail';
import { useCalcTokens } from '../hooks/useCalcTokens';
import { useApiLang } from '../hooks/useApiLang';
import { useCurrentFile } from '../lib/currentFileContext';
import { useTriggerEventFormat, useTriggerCompat } from '../lib/triggerEvents';
import { PlatformTags } from './PlatformTags';
import { buildObjectPath } from '../lib/navigation';
import { CalcTokenList, normalizeCalcWhitespace } from './CalcTokenSpan';
import { LoadingSpinner } from './LoadingSpinner';
import { ErrorMessage } from './ErrorMessage';
import type { ScriptTriggerDetailPayload } from '../script/calcTokens';

interface ScriptTriggerDetailProps {
  uuid: string;
}

/**
 * Parameter-Formel des Triggers: tokenisiert (DDR-Instanz) mit Fallback auf
 * den strukturellen Klartext, plus Deeplink auf die Calculation-Detailseite.
 */
const TriggerParamFormula: React.FC<{
  uuid: string;
  file: string | null;
  trigger: ScriptTriggerDetailPayload['trigger'];
}> = ({ uuid, file, trigger }) => {
  const { t } = useTranslation(['detail']);
  const lang = useApiLang();
  const { data } = useCalcTokens(
    trigger.paramHasTokens && trigger.paramCalcUuid ? trigger.paramCalcUuid : null,
    lang,
    'uuid',
  );
  const tokens = useMemo(
    () => (trigger.paramHasTokens && data && data.tokens.length > 0 ? data.tokens : []),
    [trigger.paramHasTokens, data],
  );

  const detailTitle = t('detail:scriptTriggerDetail.openParamCalc', {
    defaultValue: 'Open calculation details',
  }) as string;

  return (
    <>
      {tokens.length > 0 ? (
        <code className="fm-lo-inline-calc">
          <CalcTokenList tokens={tokens} />
        </code>
      ) : trigger.paramText ? (
        <code className="fm-lo-inline-calc">{normalizeCalcWhitespace(trigger.paramText)}</code>
      ) : (
        <span className="fm-layout-muted">—</span>
      )}
      {trigger.paramCalcUuid && (
        <>
          {' '}
          <Link
            className="fm-field-link fm-lo-child-detail"
            to={buildObjectPath(trigger.paramCalcUuid, uuid, file)}
            title={detailTitle}
            aria-label={detailTitle}
          >
            ↗
          </Link>
        </>
      )}
    </>
  );
};

/**
 * Detailseite eines ScriptTrigger-Objekts: Event (lokalisiert), Modi-Scope,
 * Script-Link, Owner-Breadcrumb (Datei › Layout › Objekt via trigger_owner-
 * Kette) sowie Parameter-Formel und — für OnWindowTransaction — das
 * Transaktions-Parameterfeld mit seinen Namens-Kandidaten. Die Referenzen
 * rendert der umgebende DetailView-Tab wie bei jedem Objekt.
 */
export const ScriptTriggerDetail: React.FC<ScriptTriggerDetailProps> = ({ uuid }) => {
  const { t } = useTranslation(['detail', 'common', 'types']);
  const currentFile = useCurrentFile();
  const { data, loading, error, retry } = useScriptTriggerDetail(uuid, currentFile);
  const fmtEvent = useTriggerEventFormat();
  const compatOf = useTriggerCompat();

  if (loading) return <LoadingSpinner message={t('common:loading') as string} />;
  if (error) return <ErrorMessage message={error} onRetry={retry} />;
  if (!data) return <div className="no-references">{t('common:noData')}</div>;

  const { trigger, owner, fieldCandidates } = data;
  const file = data.object.file ?? null;

  const modes: string[] = [];
  if (trigger.browseMode) modes.push(t('detail:layoutObjectDetail.modeBrowse', { defaultValue: 'Browse mode' }) as string);
  if (trigger.findMode) modes.push(t('detail:layoutObjectDetail.modeFind', { defaultValue: 'Find mode' }) as string);
  if (trigger.previewMode) modes.push(t('detail:layoutObjectDetail.modePreview', { defaultValue: 'Preview mode' }) as string);

  const hasParam = !!(trigger.paramCalcUuid || trigger.paramText);

  // Owner-Breadcrumb: Datei › Layout › Objekt. Der Layout-Link trägt den
  // Trigger als ref → das Trigger-Panel des Layouts hebt die Zeile hervor.
  const ownerCrumbs: React.ReactNode[] = [];
  if (owner) {
    if (owner.type === 'LayoutObject' && owner.layoutUuid) {
      ownerCrumbs.push(
        <Link key="layout" className="fm-field-link" to={buildObjectPath(owner.layoutUuid, uuid, file)}>
          {owner.layoutName ?? owner.layoutUuid}
        </Link>,
      );
    }
    ownerCrumbs.push(
      <Link key="owner" className="fm-field-link" to={buildObjectPath(owner.uuid, uuid, owner.file ?? file)}>
        {owner.name ?? owner.uuid}
      </Link>,
    );
  }

  return (
    <div className="object-detail scripttrigger-detail" aria-label={t('detail:scriptTriggerDetail.heading', { defaultValue: 'Script trigger' }) as string}>
      <h2 className="type-detail-heading">
        {t('detail:scriptTriggerDetail.heading', { defaultValue: 'Script trigger' })}
      </h2>
      <table className="fm-lo-table">
        <tbody>
          <tr>
            <th scope="row">{t('detail:scriptTriggerDetail.eventLabel', { defaultValue: 'Event' })}</th>
            <td className="fm-lo-trigger-event">
              {trigger.action ? fmtEvent(trigger.action) : <span className="fm-layout-muted">—</span>}
            </td>
          </tr>
          {/* Runtime compatibility of the EVENT (fm_spec trigger_compat ≥ 2.8.0,
              tri-state: Partial marked, No omitted). Row absent on older
              references — never a guessed value. */}
          {compatOf(trigger.triggerId) && (
            <tr>
              <th scope="row">{t('detail:scriptTriggerDetail.platformsLabel', { defaultValue: 'Platforms' })}</th>
              <td><PlatformTags compat={compatOf(trigger.triggerId)!} /></td>
            </tr>
          )}
          <tr>
            <th scope="row">{t('detail:scriptTriggerDetail.modesLabel', { defaultValue: 'Active in' })}</th>
            <td>
              {modes.length > 0 ? modes.join(' · ') : <span className="fm-layout-muted">—</span>}
            </td>
          </tr>
          <tr>
            <th scope="row">{t('detail:scriptTriggerDetail.scriptLabel', { defaultValue: 'Script' })}</th>
            <td>
              <span className="fm-layout-trigger-arrow" aria-hidden="true">→</span>{' '}
              {trigger.scriptUuid ? (
                <Link className="fm-field-link" to={buildObjectPath(trigger.scriptUuid, uuid, trigger.scriptFile ?? file)}>
                  {trigger.scriptName ?? trigger.scriptUuid}
                </Link>
              ) : (
                <span className="fm-layout-muted">{trigger.scriptName ?? '—'}</span>
              )}
              {trigger.scriptFile && trigger.scriptFile !== file && (
                <span className="fm-layout-muted"> ({trigger.scriptFile})</span>
              )}
            </td>
          </tr>
          <tr>
            <th scope="row">{t('detail:scriptTriggerDetail.ownerLabel', { defaultValue: 'Attached to' })}</th>
            <td>
              {owner ? (
                <>
                  <span className="fm-lo-chip-role">
                    {t(`types:objectTypes.${owner.type}`, { defaultValue: owner.type })}
                  </span>{' '}
                  {file && owner.type !== 'File' && <span className="fm-layout-muted">{file} › </span>}
                  {ownerCrumbs.map((crumb, i) => (
                    <React.Fragment key={i}>
                      {i > 0 && <span className="fm-layout-muted"> › </span>}
                      {crumb}
                    </React.Fragment>
                  ))}
                </>
              ) : (
                <span className="fm-layout-muted">—</span>
              )}
            </td>
          </tr>
          {hasParam && (
            <tr>
              <th scope="row">{t('detail:scriptTriggerDetail.paramLabel', { defaultValue: 'Script parameter' })}</th>
              <td>
                <TriggerParamFormula uuid={uuid} file={file} trigger={trigger} />
              </td>
            </tr>
          )}
          {trigger.scriptParameterFieldName && (
            <tr>
              <th scope="row">{t('detail:scriptTriggerDetail.paramFieldLabel', { defaultValue: 'Parameter field' })}</th>
              <td>
                <code className="fm-lo-inline-calc">{trigger.scriptParameterFieldName}</code>
                {fieldCandidates.length > 0 ? (
                  <div className="scripttrigger-candidates">
                    <span className="fm-layout-muted">
                      {t('detail:scriptTriggerDetail.paramFieldCandidates', { defaultValue: 'Candidates:' })}
                    </span>{' '}
                    {fieldCandidates.map((c, i) => (
                      <React.Fragment key={c.uuid}>
                        {i > 0 && ', '}
                        <Link className="fm-field-link" to={buildObjectPath(c.uuid, uuid, c.file ?? file)}>
                          {c.name ?? c.uuid}
                        </Link>
                      </React.Fragment>
                    ))}
                  </div>
                ) : (
                  <div className="fm-layout-muted">
                    {t('detail:scriptTriggerDetail.paramFieldOrphan', { defaultValue: 'No matching field in this file (orphaned name)' })}
                  </div>
                )}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
};
