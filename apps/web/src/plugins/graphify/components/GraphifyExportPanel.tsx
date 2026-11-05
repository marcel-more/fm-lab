import React, { useCallback, useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { API_BASE } from '../../../config/apiBase';
import '../styles.css';

/**
 * graphify export panel — rendered inside the plugin's settings card (via the
 * `extra` slot in SettingsView). Shows a short description, an "Export" button,
 * a live progress bar (driven by the /api/graphify/export SSE stream, parsed the
 * same way as XmlConvertControl), and the last-export result / recent files.
 */

interface GraphifyExportPanelProps {
  /** Live enabled flag from the plugin card — export only works when enabled. */
  enabled: boolean;
}

interface LastExport {
  ok: boolean | null;
  finished_at: string | null;
  relPath: string | null;
  nodes: number | null;
  edges: number | null;
  bytes: number | null;
}

interface ExportFile {
  filename: string;
  relPath: string;
  size: number;
  mtime: string;
}

interface StatusResponse {
  output_dir: string;
  running: boolean;
  last_export: LastExport | null;
  files: ExportFile[];
}

function formatBytes(bytes: number | null | undefined): string {
  if (bytes == null) return '–';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function formatNumber(n: number | null | undefined): string {
  if (n == null) return '–';
  return n.toLocaleString();
}

export const GraphifyExportPanel: React.FC<GraphifyExportPanelProps> = ({ enabled }) => {
  const { t } = useTranslation(['detail']);

  const [status, setStatus] = useState<'idle' | 'running' | 'done' | 'error'>('idle');
  const [progress, setProgress] = useState(0);
  const [phase, setPhase] = useState('');
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [serverStatus, setServerStatus] = useState<StatusResponse | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const loadStatus = useCallback(async () => {
    try {
      const res = await fetch(`${API_BASE}/api/graphify/status`);
      const json = await res.json();
      if (json.success) setServerStatus(json.data as StatusResponse);
    } catch {
      // panel still works without the status read
    }
  }, []);

  useEffect(() => {
    loadStatus();
    return () => abortRef.current?.abort();
  }, [loadStatus]);

  const phaseLabel = useCallback((id: string): string => {
    if (!id) return '';
    return t(`detail:settingsView.graphify.phase.${id}`, { defaultValue: id }) as string;
  }, [t]);

  const startExport = useCallback(async () => {
    if (status === 'running' || !enabled) return;
    setStatus('running');
    setProgress(0);
    setPhase('');
    setErrorMsg(null);

    const ac = new AbortController();
    abortRef.current = ac;
    const url = `${API_BASE.replace(/\/+$/, '')}/api/graphify/export`;

    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { Accept: 'text/event-stream', 'Content-Type': 'application/json' },
        body: '{}',
        signal: ac.signal,
      });

      if (!res.ok || !res.body) {
        const text = await res.text().catch(() => '');
        setStatus('error');
        setErrorMsg(`HTTP ${res.status} ${res.statusText}: ${text}`.trim());
        return;
      }

      const reader = res.body.getReader();
      const decoder = new TextDecoder('utf-8');
      let buffer = '';
      let doneOk: boolean | null = null;
      let sawError: string | null = null;

      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });

        let sepIdx;
        while ((sepIdx = buffer.indexOf('\n\n')) >= 0) {
          const frame = buffer.slice(0, sepIdx);
          buffer = buffer.slice(sepIdx + 2);
          for (const line of frame.split('\n')) {
            if (!line.startsWith('data:')) continue;
            const payload = line.slice(5).trimStart();
            if (!payload) continue;
            let evt: Record<string, unknown>;
            try { evt = JSON.parse(payload); } catch { continue; }

            switch (evt.event) {
              case 'progress': {
                const pct = typeof evt.pct === 'number' ? evt.pct : Number(evt.pct ?? 0);
                if (Number.isFinite(pct)) setProgress(Math.max(0, Math.min(100, pct)));
                if (typeof evt.phase === 'string') setPhase(evt.phase);
                break;
              }
              case 'error': {
                sawError = typeof evt.message === 'string' ? evt.message : 'export failed';
                break;
              }
              case 'done': {
                doneOk = evt.ok !== false;
                break;
              }
            }
          }
        }
      }

      setProgress(100);
      if (doneOk === false || sawError) {
        setStatus('error');
        setErrorMsg(sawError || (t('detail:settingsView.graphify.failed') as string));
      } else {
        setStatus('done');
      }
      await loadStatus();
    } catch (err) {
      if ((err as Error).name === 'AbortError') return;
      setStatus('error');
      setErrorMsg((err as Error).message || String(err));
    } finally {
      abortRef.current = null;
    }
  }, [status, enabled, loadStatus, t]);

  const isRunning = status === 'running';
  const last = serverStatus?.last_export ?? null;

  return (
    <div className="graphify-panel">
      {!enabled && (
        <p className="graphify-disabled-hint">{t('detail:settingsView.graphify.enableFirst')}</p>
      )}

      {isRunning ? (
        <div className="graphify-progress-wrap">
          <div
            className="graphify-progress"
            role="progressbar"
            aria-valuenow={progress}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-label={phase ? `${phaseLabel(phase)} · ${progress}%` : `${progress}%`}
          >
            <div className="graphify-progress__fill" style={{ width: `${progress}%` }} />
          </div>
          <span className="graphify-progress__label">
            {phaseLabel(phase)} · {progress}%
          </span>
        </div>
      ) : (
        <button
          type="button"
          className="graphify-export-btn"
          onClick={startExport}
          disabled={!enabled || isRunning}
        >
          {t('detail:settingsView.graphify.exportButton')}
        </button>
      )}

      {status === 'done' && (
        <p className="graphify-result graphify-result--ok">
          {t('detail:settingsView.graphify.doneMessage')}
        </p>
      )}
      {status === 'error' && errorMsg && (
        <p className="graphify-result graphify-result--error">{errorMsg}</p>
      )}

      {last && last.relPath && (
        <div className="graphify-last">
          <h4>{t('detail:settingsView.graphify.lastExport')}</h4>
          <table className="graphify-last-table">
            <tbody>
              <tr>
                <td>{t('detail:settingsView.graphify.colFile')}</td>
                <td><code>{last.relPath}</code></td>
              </tr>
              <tr>
                <td>{t('detail:settingsView.graphify.colNodes')}</td>
                <td>{formatNumber(last.nodes)}</td>
              </tr>
              <tr>
                <td>{t('detail:settingsView.graphify.colEdges')}</td>
                <td>{formatNumber(last.edges)}</td>
              </tr>
              <tr>
                <td>{t('detail:settingsView.graphify.colSize')}</td>
                <td>{formatBytes(last.bytes)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      )}

      {serverStatus && serverStatus.files.length > 0 && (
        <details className="graphify-files">
          <summary className="disclosure-summary">
            {t('detail:settingsView.graphify.recentFiles', { count: serverStatus.files.length })}
          </summary>
          <ul className="graphify-files-list">
            {serverStatus.files.slice(0, 10).map((f) => (
              <li key={f.filename}>
                <code>{f.relPath}</code> <span className="graphify-files-size">{formatBytes(f.size)}</span>
              </li>
            ))}
          </ul>
        </details>
      )}
    </div>
  );
};
