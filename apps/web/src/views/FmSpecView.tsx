import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import { SubNav } from '../components/SubNav';
import { StatusBar } from '../components/StatusBar';
import { buildBreadcrumb } from '../lib/navigation';
import { useUrlState } from '../hooks/useUrlState';
import { useApiLang } from '../hooks/useApiLang';
import {
  fetchFmSpecMeta,
  fetchFmSpecSteps,
  fetchFmSpecFunctions,
  fetchFmSpecTriggers,
  fetchFmSpecErrorCodes,
  PLATFORM_LABELS,
  STEP_COMPAT_PLATFORMS,
  type FmSpecMeta,
  type FmSpecStep,
  type FmSpecFunction,
  type FmSpecTrigger,
  type FmSpecErrorCode,
  type RefCategory,
  type StepCompatPlatform,
} from '../api/fmSpecApi';
import { PlatformTags } from '../components/PlatformTags';
import './FmSpecView.css';

/**
 * fm-spec Schema-Viewer (`/fm-spec`).
 *
 * Lesende Inspektion der generativen Referenz-DB: Metadaten-Kopf + fünf Tabs
 * (ScriptSteps · Functions · Triggers · Error Codes · Locales), jeweils mit
 * Live-Suchfilter. Tab-Zustand hängt am URL-Query (`?tab=…`) für Deep-Links /
 * Browser-Back. Klick auf einen Step/Trigger öffnet den Detail-View
 * (`/fm-spec/step/:stepId`, `/fm-spec/trigger/:triggerId`). Triggers und
 * Error Codes (fm_spec ≥ 2.8.0) degradieren auf älteren Referenzen zu leeren
 * Listen — die Tabs bleiben, ihr Inhalt sagt es.
 */

type TabId = 'steps' | 'functions' | 'triggers' | 'errorCodes' | 'locales';
const TABS: TabId[] = ['steps', 'functions', 'triggers', 'errorCodes', 'locales'];

// Functions-Domäne kennt kein zh-Hans → auf Englisch zurückfallen (Steps: alle 11).
const FUNCTION_LANGS = new Set(['en', 'de', 'es', 'fr', 'it', 'nl', 'pt', 'sv', 'ja', 'ko']);

function catName(categories: RefCategory[], id: number): string {
  const c = categories.find((x) => x.id === id);
  return c ? c.name : String(id);
}

export function FmSpecView() {
  const { t, i18n } = useTranslation(['fmSpec', 'nav']);
  const navigate = useNavigate();
  // Auf einen unterstützten Referenz-Code normalisieren (en-US → en). i18n.language
  // (volles Regions-Tag) bleibt der Datumsformatierung unten vorbehalten.
  const uiLang = useApiLang();
  const fnLang = FUNCTION_LANGS.has(uiLang) ? uiLang : 'en';

  const [tab, setTab] = useUrlState<TabId>('tab', 'steps', {
    parse: (raw) => (TABS.includes(raw as TabId) ? (raw as TabId) : 'steps'),
    serialize: (v) => (v === 'steps' ? null : v),
  });
  const [search, setSearch] = useUrlState('q', '');
  const [platform, setPlatform] = useUrlState('platform', '');

  const [meta, setMeta] = useState<FmSpecMeta | null>(null);
  const [metaErr, setMetaErr] = useState<string | null>(null);
  const [steps, setSteps] = useState<FmSpecStep[] | null>(null);
  const [stepCats, setStepCats] = useState<RefCategory[]>([]);
  const [functions, setFunctions] = useState<FmSpecFunction[] | null>(null);
  const [fnCats, setFnCats] = useState<RefCategory[]>([]);
  const [triggers, setTriggers] = useState<FmSpecTrigger[] | null>(null);
  const [errorCodes, setErrorCodes] = useState<FmSpecErrorCode[] | null>(null);
  const [listErr, setListErr] = useState<string | null>(null);

  const breadcrumbs = buildBreadcrumb({ kind: 'fmSpec' }, t);
  const dash = t('fmSpec:dash');

  // Kopf-Metadaten immer laden.
  useEffect(() => {
    let cancelled = false;
    fetchFmSpecMeta()
      .then((d) => { if (!cancelled) { setMeta(d); setMetaErr(null); } })
      .catch((e) => { if (!cancelled) setMetaErr(e.message || 'error'); });
    return () => { cancelled = true; };
  }, []);

  // Steps lazy bei erster Aktivierung (bzw. Sprachwechsel).
  useEffect(() => {
    if (tab !== 'steps' || steps !== null) return;
    let cancelled = false;
    fetchFmSpecSteps(uiLang)
      .then((d) => { if (!cancelled) { setSteps(d.steps); setStepCats(d.categories); setListErr(null); } })
      .catch((e) => { if (!cancelled) setListErr(e.message || 'error'); });
    return () => { cancelled = true; };
  }, [tab, steps, uiLang]);

  // Functions lazy bei erster Aktivierung.
  useEffect(() => {
    if (tab !== 'functions' || functions !== null) return;
    let cancelled = false;
    fetchFmSpecFunctions(fnLang)
      .then((d) => { if (!cancelled) { setFunctions(d.functions); setFnCats(d.categories); setListErr(null); } })
      .catch((e) => { if (!cancelled) setListErr(e.message || 'error'); });
    return () => { cancelled = true; };
  }, [tab, functions, fnLang]);

  // Triggers lazy bei erster Aktivierung (Labels der UI-Sprache).
  useEffect(() => {
    if (tab !== 'triggers' || triggers !== null) return;
    let cancelled = false;
    fetchFmSpecTriggers(uiLang)
      .then((d) => { if (!cancelled) { setTriggers(d); setListErr(null); } })
      .catch((e) => { if (!cancelled) setListErr(e.message || 'error'); });
    return () => { cancelled = true; };
  }, [tab, triggers, uiLang]);

  // Error codes lazy bei erster Aktivierung (Meldung der UI-Sprache, EN-Fallback).
  useEffect(() => {
    if (tab !== 'errorCodes' || errorCodes !== null) return;
    let cancelled = false;
    fetchFmSpecErrorCodes(uiLang)
      .then((d) => { if (!cancelled) { setErrorCodes(d); setListErr(null); } })
      .catch((e) => { if (!cancelled) setListErr(e.message || 'error'); });
    return () => { cancelled = true; };
  }, [tab, errorCodes, uiLang]);

  // Sprachwechsel → geladene Listen invalidieren (lokalisierte Spalten neu holen).
  useEffect(() => {
    setSteps(null);
    setFunctions(null);
    setTriggers(null);
    setErrorCodes(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [uiLang]);

  const q = search.trim().toLowerCase();

  // Plattform-Filter-Optionen je Tab: Steps kennen alle 7 Spalten der
  // Claris-Tabelle; Functions nur die Plattformen, für die kuratierte
  // Bindungsdaten existieren (Referenz ≥ 1.12.0 — sonst kein Menü).
  const fnPlatforms = useMemo(() => {
    const present = new Set<string>();
    for (const f of functions ?? []) {
      for (const a of f.platformAffinity ?? []) present.add(a.platform);
    }
    return STEP_COMPAT_PLATFORMS.filter((p) => present.has(p));
  }, [functions]);
  // Triggers: nur mit trigger_compat (fm_spec ≥ 2.8.0) — sonst kein Menü.
  const triggerCompatAvailable = useMemo(() => (triggers ?? []).some((x) => x.compat !== null), [triggers]);
  const platformOptions: StepCompatPlatform[] =
    tab === 'steps' ? STEP_COMPAT_PLATFORMS
    : tab === 'functions' ? fnPlatforms
    : tab === 'triggers' && triggerCompatAvailable ? STEP_COMPAT_PLATFORMS
    : [];
  // Eine im aktuellen Tab nicht verfügbare Auswahl ist inaktiv (nicht löschend):
  // Tab-Wechsel behält die URL-Auswahl, filtert aber nie ins Leere.
  const activePlatform = platformOptions.includes(platform as StepCompatPlatform)
    ? (platform as StepCompatPlatform) : null;

  const filteredSteps = useMemo(() => {
    if (!steps) return [];
    return steps.filter((s) => {
      // Tri-State: true=Yes, null=Partial — beide zählen als "läuft";
      // nur explizites false fällt heraus. Fehlende compat-Zeile = keine
      // Claris-Aussage → bleibt sichtbar (nie als inkompatibel behandeln).
      if (activePlatform && s.compat && s.compat[activePlatform] === false) return false;
      if (!q) return true;
      const hay = [s.stepId, s.name, s.categoryId, catName(stepCats, s.categoryId), s.originVersion]
        .filter((v) => v != null).join(' ').toLowerCase();
      return hay.includes(q);
    });
  }, [steps, stepCats, q, activePlatform]);

  const filteredFns = useMemo(() => {
    if (!functions) return [];
    return functions.filter((f) => {
      if (activePlatform && !(f.platformAffinity ?? []).some((a) => a.platform === activePlatform)) return false;
      if (!q) return true;
      const hay = [f.functionId, f.name, catName(fnCats, f.categoryId), f.returnType, f.originVersion]
        .filter((v) => v != null).join(' ').toLowerCase();
      return hay.includes(q);
    });
  }, [functions, fnCats, q, activePlatform]);

  const filteredTriggers = useMemo(() => {
    if (!triggers) return [];
    return triggers.filter((x) => {
      // Tri-State wie Steps: nur explizites false fällt heraus; Partial (null)
      // und fehlende Compat-Zeile bleiben sichtbar.
      if (activePlatform && x.compat && x.compat[activePlatform] === false) return false;
      if (!q) return true;
      const hay = [x.triggerId, x.eventName, x.label, x.level, x.sinceVersion]
        .filter((v) => v != null).join(' ').toLowerCase();
      return hay.includes(q);
    });
  }, [triggers, q, activePlatform]);

  const filteredErrorCodes = useMemo(() => {
    if (!errorCodes) return [];
    if (!q) return errorCodes;
    // Zahl → Bereichs-Treffer (5123 findet 5000-5499); Text → Meldung / Scope.
    if (/^-?\d+$/.test(q)) {
      const n = Number(q);
      return errorCodes.filter((e) => n >= e.codeFrom && n <= e.codeTo);
    }
    return errorCodes.filter((e) =>
      e.codeText.includes(q) || e.scope === q
      || e.message.toLowerCase().includes(q) || e.messageEn.toLowerCase().includes(q));
  }, [errorCodes, q]);

  const filteredLocales = useMemo(() => {
    const locales = meta?.locales ?? [];
    if (!q) return locales;
    return locales.filter((l) => l.code.toLowerCase().includes(q));
  }, [meta, q]);

  const rm = meta?.referenceMeta;
  const counts = meta?.counts;
  const builtAt = rm?.built_at ? new Date(rm.built_at).toLocaleDateString(i18n.language) : dash;

  const totalForTab =
    tab === 'steps' ? (steps?.length ?? 0)
    : tab === 'functions' ? (functions?.length ?? 0)
    : tab === 'triggers' ? (triggers?.length ?? 0)
    : tab === 'errorCodes' ? (errorCodes?.length ?? 0)
    : (meta?.locales.length ?? 0);
  const shownForTab =
    tab === 'steps' ? filteredSteps.length
    : tab === 'functions' ? filteredFns.length
    : tab === 'triggers' ? filteredTriggers.length
    : tab === 'errorCodes' ? filteredErrorCodes.length
    : filteredLocales.length;
  const searchHint = tab === 'errorCodes' ? (t('fmSpec:errorCodes.search.hint') as string) : undefined;

  return (
    <div className="app fmspec-view">
      <SubNav breadcrumbs={breadcrumbs} />
      <StatusBar />

      <div className="fmspec-page">
        <header className="fmspec-header">
          <h1 className="fmspec-title">{t('fmSpec:title')}</h1>
          <p className="fmspec-subtitle">{t('fmSpec:subtitle')}</p>
        </header>

        {metaErr ? (
          <div className="fmspec-error">{t('fmSpec:error')}: {metaErr}</div>
        ) : (
          <section className="fmspec-kpis">
            <Kpi label={t('fmSpec:header.schemaVersion')} value={rm?.schema_version ?? dash} />
            <Kpi label={t('fmSpec:header.coverage')} value={rm?.shape_coverages ? rm.shape_coverages.split(',').join(' · ') : (rm?.filemaker_coverage ?? dash)} />
            <Kpi label={t('fmSpec:header.docCoverage')} value={rm?.doc_coverage ?? dash} />
            <Kpi label={t('fmSpec:header.built')} value={builtAt} />
            <Kpi label={t('fmSpec:header.steps')} value={counts ? String(counts.scriptSteps) : dash} />
            <Kpi label={t('fmSpec:header.functions')} value={counts ? String(counts.functions) : dash} />
            <Kpi
              label={t('fmSpec:header.locales')}
              value={counts ? t('fmSpec:header.localesValue', { steps: counts.stepLocales, functions: counts.functionLocales }) as string : dash}
            />
            <Kpi
              label={t('fmSpec:header.grammar')}
              value={counts ? t('fmSpec:header.grammarValue', { covered: counts.grammarSteps, total: counts.scriptSteps }) as string : dash}
            />
            {/* Runtime & diagnostics (fm_spec ≥ 2.8.0) — only when the build ships them. */}
            {meta?.diagnosticsAvailable && counts && (
              <>
                <Kpi label={t('fmSpec:header.triggers')} value={String(counts.triggers ?? 0)} />
                <Kpi label={t('fmSpec:header.errorCodes')} value={String(counts.errorCodes ?? 0)} />
              </>
            )}
          </section>
        )}

        <p className="fmspec-attribution">{t('fmSpec:header.attribution')}</p>

        <div className="fmspec-toolbar">
          <div className="fmspec-tabs" role="tablist" aria-label={t('fmSpec:title') as string}>
            {TABS.map((id) => (
              <button
                key={id}
                type="button"
                role="tab"
                aria-selected={tab === id}
                className={`fmspec-tab${tab === id ? ' active' : ''}`}
                onClick={() => setTab(id)}
              >
                {t(`fmSpec:tabs.${id}`)}
              </button>
            ))}
          </div>
          <span className="fmspec-count">{t('fmSpec:list.count', { shown: shownForTab, total: totalForTab })}</span>
          {platformOptions.length > 0 && (
            <select
              className="fmspec-platform-filter"
              value={activePlatform ?? ''}
              onChange={(e) => setPlatform(e.target.value)}
              aria-label={t('fmSpec:search.platformLabel') as string}
              title={t(tab === 'functions' ? 'fmSpec:search.platformFnHint' : tab === 'triggers' ? 'fmSpec:search.platformTriggerHint' : 'fmSpec:search.platformStepHint') as string}
            >
              <option value="">{t('fmSpec:search.platformAll')}</option>
              {platformOptions.map((p) => (
                <option key={p} value={p}>{PLATFORM_LABELS[p]}</option>
              ))}
            </select>
          )}
          <input
            type="search"
            className="fmspec-search"
            placeholder={t('fmSpec:search.placeholder') as string}
            aria-label={t('fmSpec:search.placeholder') as string}
            title={searchHint}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
        </div>

        {listErr && tab !== 'locales' && <div className="fmspec-error">{t('fmSpec:error')}: {listErr}</div>}

        {tab === 'steps' && (
          <div className="fmspec-table-wrap">
            <table className="fmspec-table">
              <thead>
                <tr>
                  <th className="num">{t('fmSpec:steps.col.id')}</th>
                  <th>{t('fmSpec:steps.col.name')}</th>
                  <th className="num">{t('fmSpec:steps.col.categoryId')}</th>
                  <th>{t('fmSpec:steps.col.category')}</th>
                  <th>{t('fmSpec:steps.col.originVersion')}</th>
                  <th>{t('fmSpec:steps.col.grammar')}</th>
                </tr>
              </thead>
              <tbody>
                {filteredSteps.map((s) => (
                  <tr
                    key={s.stepId}
                    className="fmspec-row--clickable"
                    tabIndex={0}
                    onClick={() => navigate(`/fm-spec/step/${s.stepId}`)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); navigate(`/fm-spec/step/${s.stepId}`); }
                    }}
                  >
                    <td className="num">{s.stepId}</td>
                    <td>{s.name}</td>
                    <td className="num">{s.categoryId}</td>
                    <td>{catName(stepCats, s.categoryId)}</td>
                    <td>{s.originVersion ?? dash}</td>
                    <td>
                      {s.hasGrammar
                        ? <span className="fmspec-badge fmspec-badge--yes">{t('fmSpec:steps.grammarYes')}</span>
                        : <span className="fmspec-badge fmspec-badge--no">{t('fmSpec:steps.grammarNo')}</span>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {steps === null && !listErr && <div className="fmspec-loading">{t('fmSpec:loading')}</div>}
          </div>
        )}

        {tab === 'functions' && (
          <div className="fmspec-table-wrap">
            <table className="fmspec-table">
              <thead>
                <tr>
                  <th className="num">{t('fmSpec:functions.col.id')}</th>
                  <th>{t('fmSpec:functions.col.name')}</th>
                  <th>{t('fmSpec:functions.col.category')}</th>
                  <th>{t('fmSpec:functions.col.returnType')}</th>
                  <th>{t('fmSpec:functions.col.originVersion')}</th>
                  <th>{t('fmSpec:functions.col.removedInVersion')}</th>
                </tr>
              </thead>
              <tbody>
                {filteredFns.map((f) => (
                  <tr
                    key={f.functionId}
                    className="fmspec-row--clickable"
                    tabIndex={0}
                    onClick={() => navigate(`/fm-spec/function/${f.functionId}`)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); navigate(`/fm-spec/function/${f.functionId}`); }
                    }}
                  >
                    <td className="num">{f.functionId}</td>
                    <td>{f.name}</td>
                    <td>{catName(fnCats, f.categoryId)}</td>
                    <td>{f.returnType ?? dash}</td>
                    <td>{f.originVersion ?? dash}</td>
                    <td>{f.removedInVersion ?? dash}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {functions === null && !listErr && <div className="fmspec-loading">{t('fmSpec:loading')}</div>}
          </div>
        )}

        {tab === 'triggers' && (
          <div className="fmspec-table-wrap">
            <table className="fmspec-table">
              <thead>
                <tr>
                  <th className="num">{t('fmSpec:triggers.col.id')}</th>
                  <th>{t('fmSpec:triggers.col.event')}</th>
                  <th>{t('fmSpec:triggers.col.label')}</th>
                  <th>{t('fmSpec:triggers.col.level')}</th>
                  <th>{t('fmSpec:triggers.col.since')}</th>
                  <th>{t('fmSpec:triggers.col.parameter')}</th>
                  <th>{t('fmSpec:triggers.col.platforms')}</th>
                </tr>
              </thead>
              <tbody>
                {filteredTriggers.map((x) => (
                  <tr
                    key={x.triggerId}
                    className="fmspec-row--clickable"
                    tabIndex={0}
                    onClick={() => navigate(`/fm-spec/trigger/${x.triggerId}`)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); navigate(`/fm-spec/trigger/${x.triggerId}`); }
                    }}
                  >
                    <td className="num">{x.triggerId}</td>
                    <td>{x.eventName}</td>
                    <td>{x.label !== x.eventName ? x.label : dash}</td>
                    <td>{t(`fmSpec:triggers.level.${x.level}`, { defaultValue: x.level })}</td>
                    <td>{x.sinceVersion ?? dash}</td>
                    <td>{x.parameterCapable ? t('fmSpec:triggers.paramYes') : t('fmSpec:triggers.paramNo')}</td>
                    <td>{x.compat ? <PlatformTags compat={x.compat} /> : dash}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {triggers === null && !listErr && <div className="fmspec-loading">{t('fmSpec:loading')}</div>}
            {triggers !== null && triggers.length === 0 && <div className="fmspec-loading">{t('fmSpec:triggers.unavailable')}</div>}
          </div>
        )}

        {tab === 'errorCodes' && (
          <div className="fmspec-table-wrap">
            <table className="fmspec-table">
              <thead>
                <tr>
                  <th className="num">{t('fmSpec:errorCodes.col.code')}</th>
                  <th>{t('fmSpec:errorCodes.col.message')}</th>
                  <th>{t('fmSpec:errorCodes.col.scope')}</th>
                </tr>
              </thead>
              <tbody>
                {filteredErrorCodes.map((e) => (
                  <tr key={e.codeFrom}>
                    <td className="num mono">{e.codeText}</td>
                    <td>
                      {e.message}
                      {e.message !== e.messageEn && <div className="fmspec-muted">{e.messageEn}</div>}
                    </td>
                    <td>
                      <span
                        className={`fmspec-badge ${e.scope === 'web' ? 'fmspec-badge--no' : 'fmspec-badge--yes'}`}
                        title={t(`fmSpec:errorCodes.scopeHint.${e.scope}`, { defaultValue: e.scope }) as string}
                      >
                        {t(`fmSpec:errorCodes.scope.${e.scope}`, { defaultValue: e.scope })}
                      </span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {errorCodes === null && !listErr && <div className="fmspec-loading">{t('fmSpec:loading')}</div>}
            {errorCodes !== null && errorCodes.length === 0 && <div className="fmspec-loading">{t('fmSpec:errorCodes.unavailable')}</div>}
          </div>
        )}

        {tab === 'locales' && (
          <div className="fmspec-table-wrap">
            <table className="fmspec-table">
              <thead>
                <tr>
                  <th>{t('fmSpec:locales.col.code')}</th>
                  <th className="num">{t('fmSpec:locales.col.steps')}</th>
                  <th className="num">{t('fmSpec:locales.col.functions')}</th>
                  <th className="num">{t('fmSpec:locales.col.parameters')}</th>
                </tr>
              </thead>
              <tbody>
                {filteredLocales.map((l) => (
                  <tr key={l.code}>
                    <td className="mono">{l.code}</td>
                    <td className="num">{l.steps}</td>
                    <td className="num">{l.functions}</td>
                    <td className="num">{l.stepParameters}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            {!meta && !metaErr && <div className="fmspec-loading">{t('fmSpec:loading')}</div>}
          </div>
        )}
      </div>
    </div>
  );
}

function Kpi({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="fmspec-kpi">
      <span className="fmspec-kpi__label">{label}</span>
      <span className={`fmspec-kpi__value${mono ? ' mono' : ''}`}>{value}</span>
    </div>
  );
}

export default FmSpecView;
