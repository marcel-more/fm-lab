import { useEffect, useState } from 'react';
import { useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { SubNav } from '../components/SubNav';
import { StatusBar } from '../components/StatusBar';
import { PlatformTags } from '../components/PlatformTags';
import { buildBreadcrumb } from '../lib/navigation';
import { useApiLang } from '../hooks/useApiLang';
import { fetchTriggerDetail, resolveHelpHref, type TriggerDetail } from '../api/fmSpecApi';
import './FmSpecView.css';

/**
 * fm-spec trigger detail (`/fm-spec/trigger/:triggerId`): one script-trigger
 * event — slot id, level, since-version, parameter capability, the platform
 * line from trigger_compat (tri-state, Partial marked; absent on references
 * older than fm-spec 2.8.0) and the localized dialog labels of all 11 locales
 * with their Claris help pages. Mirror of the step detail, without grammar.
 */

/** Claris help mirror dir per reference language (zh-Hans is served under `zh`). */
function helpLang(language: string): string {
  return language === 'zh-Hans' ? 'zh' : language;
}

export function FmSpecTriggerView() {
  const { triggerId } = useParams();
  const { t } = useTranslation(['fmSpec', 'nav']);
  const uiLang = useApiLang();
  const dash = t('fmSpec:dash');

  const [data, setData] = useState<TriggerDetail | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    if (!triggerId) return;
    let cancelled = false;
    setData(null); setErr(null);
    fetchTriggerDetail(triggerId, uiLang)
      .then((d) => { if (!cancelled) setData(d); })
      .catch((e) => { if (!cancelled) setErr(e.message || 'error'); });
    return () => { cancelled = true; };
  }, [triggerId, uiLang]);

  const name = data?.eventName ?? (triggerId ? `Trigger ${triggerId}` : '');
  const breadcrumbs = buildBreadcrumb({ kind: 'fmSpecTrigger', name }, t);
  const helpHref = data ? resolveHelpHref(data.localHelpUrl, data.helpUrl) : null;

  return (
    <div className="app fmspec-view">
      <SubNav breadcrumbs={breadcrumbs} />
      <StatusBar />

      <div className="fmspec-page">
        <header className="fmspec-header">
          <h1 className="fmspec-title">
            {name}
            {data && <span className="fmspec-title__id">#{data.triggerId}</span>}
            {helpHref && (
              <a className="fmspec-title__doclink" href={helpHref} target="_blank" rel="noreferrer">
                {t('fmSpec:clarisHelp')}
              </a>
            )}
          </h1>
          {data && (
            <p className="fmspec-subtitle">
              {t('fmSpec:triggers.col.level')}: {t(`fmSpec:triggers.level.${data.level}`, { defaultValue: data.level })}
              {' · '}{t('fmSpec:triggers.col.since')}: {data.sinceVersion ?? dash}
              {' · '}{t('fmSpec:triggers.col.parameter')}: {data.parameterCapable ? t('fmSpec:triggers.paramYes') : t('fmSpec:triggers.paramNo')}
              {data.hasParameterFieldAttr && <> ({t('fmSpec:trigger.parameterField')})</>}
              {' · '}{t('fmSpec:step.slug')}: <span className="mono">{data.urlSlug}</span>
            </p>
          )}
          {/* Platform compatibility (trigger_compat, fm_spec >= 2.8.0): Yes +
              Partial listed, Partial marked, No omitted. No line at all when
              the reference predates the table — never a guessed value. */}
          {data && (
            <p className="fmspec-subtitle">
              {data.compat
                ? <PlatformTags compat={data.compat} label={t('fmSpec:step.compat.label') as string} />
                : <span className="fmspec-muted">{t('fmSpec:trigger.compat.unavailable')}</span>}
            </p>
          )}
        </header>

        {err && <div className="fmspec-error">{t('fmSpec:error')}: {err}</div>}
        {!data && !err && <div className="fmspec-loading">{t('fmSpec:loading')}</div>}

        {data && (
          <section className="fmspec-section">
            <h2 className="fmspec-section__title">{t('fmSpec:trigger.section.labels')}</h2>
            <div className="fmspec-table-wrap">
              <table className="fmspec-table">
                <thead>
                  <tr>
                    <th>{t('fmSpec:step.localized.language')}</th>
                    <th>{t('fmSpec:trigger.localized.label')}</th>
                    <th>{t('fmSpec:step.localized.help')}</th>
                  </tr>
                </thead>
                <tbody>
                  {data.labels.map((l) => {
                    const href = `https://help.claris.com/${helpLang(l.language)}/pro-help/content/${data.urlSlug}.html`;
                    return (
                      <tr key={l.language}>
                        <td className="mono">{l.language}</td>
                        <td>{l.label}</td>
                        <td><a href={href} target="_blank" rel="noreferrer">{t('fmSpec:help.open')}</a></td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          </section>
        )}
      </div>
    </div>
  );
}

export default FmSpecTriggerView;
