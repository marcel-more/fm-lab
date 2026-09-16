import React, { useEffect, useState, useCallback } from 'react';
import { useTranslation } from 'react-i18next';
import { useNavigate } from 'react-router-dom';
import { PluginCard, type PluginInfo } from '../components/PluginCard';
import { SubNav } from '../components/SubNav';
import { StatusBar } from '../components/StatusBar';
import { VersionStatusLine } from '../components/VersionStatusLine';
import { buildBreadcrumb } from '../lib/navigation';
import { useApiLang } from '../hooks/useApiLang';
import { useApiHealth } from '../hooks/useApiHealth';
import { useFeaturesContext } from '../hooks/useFeatures';
import { SolutionsPanel } from '../components/SolutionsPanel';
import { FmideFilesPanel } from '../plugins/fmide/components/FmideFilesPanel';
import { GraphifyExportPanel } from '../plugins/graphify/components/GraphifyExportPanel';
import { fetchFmSpecMeta, type FmSpecMeta } from '../api/fmSpecApi';
import { GitHubLink } from '../components/GitHubLink';
import { AppFooter } from '../components/AppFooter';
import {
  API_BASE,
  ENV_API_BASE,
  ENV_API_URL_PLACEHOLDER,
  getApiUrlOverride,
  setApiUrlOverride,
} from '../config/apiBase';
import './SettingsView.css';

/**
 * REST-API connection settings: an input for the API base URL that overrides
 * the build-time `VITE_API_URL`. The value is stored **per browser** in
 * localStorage (never sent to the server) so it can't affect other clients or
 * repoint a shared backend. A live 🟢/🔴 dot shows whether the URL currently in
 * the field is reachable.
 */
const ApiConnectionSettings: React.FC = () => {
  const { t } = useTranslation(['detail']);
  // Field value = the browser-local override ('' → use .env placeholder).
  const [value, setValue] = useState<string>(() => getApiUrlOverride() ?? '');

  // The URL the field currently resolves to (empty → .env base). This is what we
  // probe live and what we would persist.
  const effectiveTarget = value.trim() || ENV_API_BASE;
  const health = useApiHealth(effectiveTarget);

  const save = useCallback(() => {
    // Browser-local only: persist to localStorage and reload so the new base
    // takes effect across every API call this session. No server round-trip.
    setApiUrlOverride(value.trim() || null);
    window.location.reload();
  }, [value]);

  const dot = health === 'online' ? '🟢' : health === 'offline' ? '🔴' : '⚪️';
  const dotTitle = health === 'online'
    ? t('detail:settingsView.api.statusOnline')
    : health === 'offline'
      ? t('detail:settingsView.api.statusOffline')
      : t('detail:settingsView.api.statusChecking');

  return (
    <section className="api-settings-card">
      <h2 className="api-settings-heading">{t('detail:settingsView.api.heading')}</h2>
      <p className="api-settings-desc">{t('detail:settingsView.api.description')}</p>

      <label className="api-settings-label" htmlFor="api-url-input">
        {t('detail:settingsView.api.label')}
      </label>
      <div className="api-settings-row">
        <input
          id="api-url-input"
          type="url"
          className="api-settings-input"
          value={value}
          placeholder={ENV_API_URL_PLACEHOLDER}
          spellCheck={false}
          autoCapitalize="off"
          autoCorrect="off"
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') save(); }}
        />
        <span
          className="api-settings-status"
          role="status"
          aria-live="polite"
          title={dotTitle as string}
          aria-label={dotTitle as string}
        >
          {dot}
        </span>
        <button className="api-settings-save" onClick={save}>
          {t('detail:settingsView.api.save')}
        </button>
        <button
          className="api-settings-clear"
          onClick={() => setValue('')}
          disabled={value.trim() === ''}
        >
          {t('detail:settingsView.api.clear')}
        </button>
      </div>
    </section>
  );
};

/**
 * fm-spec entry-point panel: shows the three head KPIs from the fm-spec viewer
 * (schema version, FileMaker coverage, build date) and a "Details" button that
 * navigates to the full `/fm-spec` schema viewer. Read-only; degrades to `—`
 * placeholders while loading or when the reference DB is unreachable.
 */
const FmSpecPanel: React.FC = () => {
  const { t, i18n } = useTranslation(['detail', 'fmSpec']);
  const navigate = useNavigate();
  const [meta, setMeta] = useState<FmSpecMeta | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetchFmSpecMeta()
      .then((d) => { if (!cancelled) setMeta(d); })
      .catch(() => { /* keep placeholders on error */ });
    return () => { cancelled = true; };
  }, []);

  const dash = '—';
  const rm = meta?.referenceMeta;
  const builtAt = rm?.built_at ? new Date(rm.built_at).toLocaleDateString(i18n.language) : dash;

  return (
    <section className="fmspec-panel">
      <div className="fmspec-panel__head">
        <h2 className="api-settings-heading">{t('detail:settingsView.fmSpec.heading')}</h2>
      </div>
      <div className="fmspec-panel__row">
        <div className="fmspec-panel__kpis">
          <div className="fmspec-panel__kpi">
            <span className="fmspec-panel__kpi-label">{t('fmSpec:header.schemaVersion')}</span>
            <span className="fmspec-panel__kpi-value">{rm?.schema_version ?? dash}</span>
          </div>
          <div className="fmspec-panel__kpi">
            <span className="fmspec-panel__kpi-label">{t('fmSpec:header.coverage')}</span>
            <span className="fmspec-panel__kpi-value">{rm?.filemaker_coverage ?? dash}</span>
          </div>
          <div className="fmspec-panel__kpi">
            <span className="fmspec-panel__kpi-label">{t('fmSpec:header.docCoverage')}</span>
            <span className="fmspec-panel__kpi-value">{rm?.doc_coverage ?? dash}</span>
          </div>
          <div className="fmspec-panel__kpi">
            <span className="fmspec-panel__kpi-label">{t('fmSpec:header.built')}</span>
            <span className="fmspec-panel__kpi-value">{builtAt}</span>
          </div>
        </div>
        <button
          type="button"
          className="fmspec-panel__details"
          onClick={() => navigate('/fm-spec')}
        >
          {t('detail:settingsView.fmSpec.details')}
        </button>
      </div>
    </section>
  );
};

export const SettingsView: React.FC = () => {
  const { t } = useTranslation(['detail', 'nav']);
  const lang = useApiLang();
  const { refresh: refreshFeatures } = useFeaturesContext();
  const [plugins, setPlugins] = useState<PluginInfo[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expandedName, setExpandedName] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const res = await fetch(`${API_BASE}/api/plugins?lang=${encodeURIComponent(lang)}`);
      const json = await res.json();
      if (!json.success) throw new Error(json.error?.message || (t('detail:settingsView.loadError') as string));
      setPlugins(json.data);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoading(false);
    }
  }, [lang, t]);

  useEffect(() => {
    load();
  }, [load]);

  const handleUpdate = useCallback(async (
    name: string,
    patch: { enabled?: boolean; settings?: Record<string, unknown> },
  ) => {
    const res = await fetch(`${API_BASE}/api/plugins/${encodeURIComponent(name)}?lang=${encodeURIComponent(lang)}`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(patch),
    });
    const json = await res.json();
    if (!json.success) throw new Error(json.error?.message || (t('detail:settingsView.saveError') as string));

    // Refetch the plugin list (merged state) and the app-wide feature flags so
    // enable/disable and config changes take effect immediately — no restart,
    // no page reload (e.g. the fmIDE 🦄 actions appear/disappear at once).
    await Promise.all([load(), refreshFeatures()]);
  }, [lang, load, t, refreshFeatures]);

  return (
    <div className="settings-view">
      {/* GitHub link appears in the nav header only here on the settings page
          (via the SubNav `actions` slot), left of the language selector —
          deliberately absent from the neutral SubNav on every other page. */}
      <SubNav
        breadcrumbs={buildBreadcrumb({ kind: 'settings' }, t)}
        actions={<GitHubLink />}
      />
      <StatusBar message={<VersionStatusLine />} />
      <div className="settings-header">
        <h1>{t('detail:settingsView.title')}</h1>
      </div>

      <ApiConnectionSettings />

      <SolutionsPanel />

      <FmSpecPanel />

      {loading && <div className="settings-loading">{t('detail:settingsView.loading')}</div>}
      {error && <div className="settings-error">{error}</div>}

      {!loading && !error && plugins.length === 0 && (
        <div className="settings-empty">{t('detail:settingsView.empty')}</div>
      )}

      <div className="plugin-list">
        {plugins.map((plugin) => (
          <PluginCard
            key={plugin.name}
            plugin={plugin}
            expanded={expandedName === plugin.name}
            onToggleExpand={() => setExpandedName((prev) => (prev === plugin.name ? null : plugin.name))}
            onUpdate={(patch) => handleUpdate(plugin.name, patch)}
            extra={
              plugin.name === 'fmide'
                ? <FmideFilesPanel />
                : plugin.name === 'graphify'
                  ? <GraphifyExportPanel enabled={plugin.enabled} />
                  : undefined
            }
          />
        ))}
      </div>

      <AppFooter />
    </div>
  );
};
