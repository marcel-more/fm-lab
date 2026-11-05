import React, { useMemo, useState, useCallback } from 'react';
import { useTranslation } from 'react-i18next';
import { API_BASE } from '../../../config/apiBase';
import { useFmideStatus } from '../hooks/useFmideStatus';
import '../styles.css';

/**
 * Collapsible "show files" panel for the fmIDE settings card. Lists every file
 * in the solution (alphabetically) with an install-status column:
 *   installed     → ✅
 *   not installed → – (row shown in muted/grey text)
 *
 * Data comes from /api/fmide/status (a public route, reachable even while the
 * plugin is disabled). The "Rescan" button re-runs the DuckDB catalog scan via
 * the plugin-action endpoint and refreshes the list.
 */
export const FmideFilesPanel: React.FC = () => {
  const { t } = useTranslation(['detail']);
  const [reloadKey, setReloadKey] = useState(0);
  const [rescanning, setRescanning] = useState(false);
  const statuses = useFmideStatus(reloadKey);

  const rescan = useCallback(async () => {
    setRescanning(true);
    try {
      await fetch(`${API_BASE}/api/plugins/fmide/actions/rescan`, { method: 'POST' });
    } catch {
      // ignore — the refetch below surfaces whatever the server has
    } finally {
      setReloadKey((k) => k + 1); // force a fresh /api/fmide/status fetch
      setRescanning(false);
    }
  }, []);

  const rows = useMemo(() => {
    if (!statuses) return [];
    return Object.entries(statuses)
      .map(([file, s]) => ({ file, present: Boolean(s.script_present), version: s.fmide_version }))
      .sort((a, b) => a.file.localeCompare(b.file));
  }, [statuses]);

  const installedCount = rows.filter((r) => r.present).length;

  return (
    <details className="fmide-files-panel">
      <summary className="disclosure-summary">{t('detail:settingsView.fmide.showFiles')}</summary>

      <div className="fmide-files-toolbar">
        <button type="button" className="fmide-rescan-button" onClick={rescan} disabled={rescanning}>
          {rescanning ? t('detail:settingsView.fmide.rescanning') : t('detail:settingsView.fmide.rescan')}
        </button>
        {statuses !== null && (
          <span className="fmide-files-count">
            {t('detail:settingsView.fmide.installedCount', { count: installedCount, total: rows.length })}
          </span>
        )}
      </div>

      {statuses === null ? (
        <div className="fmide-files-loading">{t('detail:settingsView.fmide.loading')}</div>
      ) : rows.length === 0 ? (
        <div className="fmide-files-loading">{t('detail:settingsView.fmide.empty')}</div>
      ) : (
        <table className="fmide-files-table">
          <thead>
            <tr>
              <th>{t('detail:settingsView.fmide.colFile')}</th>
              <th className="fmide-files-version-col">{t('detail:settingsView.fmide.colVersion')}</th>
              <th className="fmide-files-status-col">{t('detail:settingsView.fmide.colStatus')}</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.file} className={r.present ? '' : 'fmide-files-row--absent'}>
                <td>{r.file}</td>
                <td className="fmide-files-version-col">{r.version || '–'}</td>
                <td className="fmide-files-status-col">
                  {r.present
                    ? <span title={t('detail:settingsView.fmide.installed') as string}>✅</span>
                    : <span aria-label={t('detail:settingsView.fmide.notInstalled') as string}>–</span>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </details>
  );
};
