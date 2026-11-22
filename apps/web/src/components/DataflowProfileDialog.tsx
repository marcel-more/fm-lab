import { useCallback, useEffect, useMemo, useState } from 'react';
import { useTranslation } from 'react-i18next';
import {
  fetchDataflowProfile,
  putDataflowProfile,
  type DataflowProfile,
  type ProfileCandidateFull,
  type ProfileChange,
} from '../hooks/useDataTrace';

/**
 * Solution profile of the data trace — overview of all candidates per
 * heuristic H1–H4 with bulk confirmation: every open candidate is preselected
 * (uncertain ones are not), single ones can be deselected, one click confirms
 * or rejects the selection. Below, the decided rules with "undo". Nothing is
 * written without a click; the profile lives in the solution bundle
 * (`state/dataflow_profile.json`).
 */

const HEURISTICS = ['H1', 'H2', 'H3', 'H4'] as const;

interface DataflowProfileDialogProps {
  onClose: () => void;
  /** Called after every successful write — the host reloads the trace. */
  onChanged: () => void;
}

export function DataflowProfileDialog({ onClose, onChanged }: DataflowProfileDialogProps) {
  const { t } = useTranslation(['explorer', 'common']);
  const [profile, setProfile] = useState<DataflowProfile | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // Deselected open candidates per heuristic (keys); uncertain ones start deselected.
  const [deselected, setDeselected] = useState<Set<string>>(new Set());

  const applyProfile = useCallback((p: DataflowProfile) => {
    setProfile(p);
    const off = new Set<string>();
    for (const h of Object.values(p.heuristics)) {
      for (const c of h.candidates) if (c.status === 'open' && c.uncertain) off.add(c.key);
    }
    setDeselected(off);
  }, []);

  useEffect(() => {
    fetchDataflowProfile().then(applyProfile).catch((e: unknown) => setError(e instanceof Error ? e.message : String(e)));
  }, [applyProfile]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.stopPropagation();
        onClose();
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [onClose]);

  const write = async (change: ProfileChange) => {
    setBusy(true);
    setError(null);
    try {
      applyProfile(await putDataflowProfile(change));
      onChanged();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const toggle = (key: string) =>
    setDeselected((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });

  const bulk = (id: string, open: ProfileCandidateFull[], status: 'confirmed' | 'rejected') => {
    const except = open.filter((c) => deselected.has(c.key)).map((c) => c.key);
    const includeUncertain = open.some((c) => c.uncertain && !deselected.has(c.key));
    void write({ heuristic: { id, status, except, include_uncertain: includeUncertain } });
  };

  const decided = useMemo(() => profile?.rules ?? [], [profile]);

  return (
    <div className="explorer-data-dialog-backdrop" onClick={onClose}>
      <div
        className="explorer-data-dialog"
        role="dialog"
        aria-modal="true"
        aria-label={t('trace.data.profileDialogTitle') as string}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="explorer-inspect-head">
          <h2 className="explorer-inspect-title">{t('trace.data.profileDialogTitle')}</h2>
          <button type="button" className="explorer-inspect-close" onClick={onClose} aria-label={t('common:close', { defaultValue: 'Schließen' }) as string}>
            ✕
          </button>
        </div>
        <p className="explorer-trace-explainer">{t('trace.data.profileDialogIntro')}</p>
        {error && <p className="explorer-data-error" role="alert">{error}</p>}
        {!profile && !error && <p className="explorer-data-hint">{t('loading')}</p>}

        {profile && HEURISTICS.map((id) => {
          const h = profile.heuristics[id];
          if (!h) return null;
          const open = h.candidates.filter((c) => c.status === 'open');
          const selected = open.filter((c) => !deselected.has(c.key)).length;
          return (
            <section key={id} className="explorer-data-section">
              <h3>
                {id} · {t(`trace.data.ruleKind.${h.kind}`, { defaultValue: h.kind })}
                <span className="explorer-data-counts">
                  {t('trace.data.counts', { open: h.open, confirmed: h.confirmed, rejected: h.rejected })}
                </span>
              </h3>
              <p className="explorer-data-hint">{t(`trace.data.heuristicHint.${id}`)}</p>
              {open.length > 0 && (
                <>
                  <ul className="explorer-data-candidate-list">
                    {open.map((c) => (
                      <li key={c.key}>
                        <label>
                          <input type="checkbox" checked={!deselected.has(c.key)} onChange={() => toggle(c.key)} disabled={busy} />
                          <span className="explorer-data-candidate-name">{c.name}</span>
                          {c.file && <span className="explorer-trace-excluded-file">{c.file}</span>}
                          {c.uncertain && <em className="explorer-data-badge is-approx">{t('trace.data.uncertain')}</em>}
                        </label>
                        {c.sample && c.sample.length > 0 && (
                          <span className="explorer-data-candidate-sample" title={c.sample.join(', ')}>{c.sample.join(' · ')}</span>
                        )}
                      </li>
                    ))}
                  </ul>
                  <div className="explorer-data-way-actions">
                    <button type="button" disabled={busy || selected === 0} onClick={() => bulk(id, open, 'confirmed')}>
                      {t('trace.data.bulkConfirm', { count: selected })}
                    </button>
                    <button type="button" disabled={busy || selected === 0} onClick={() => bulk(id, open, 'rejected')}>
                      {t('trace.data.bulkReject', { count: selected })}
                    </button>
                  </div>
                </>
              )}
            </section>
          );
        })}

        {profile && decided.length > 0 && (
          <section className="explorer-data-section">
            <h3>{t('trace.data.rulesLabel')}</h3>
            <ul className="explorer-data-candidate-list">
              {decided.map((r) => {
                const key = r.key ?? `${r.kind}|${r.pattern ?? `${r.uuid}::${r.file ?? ''}`}`;
                return (
                  <li key={key}>
                    <span className="explorer-data-candidate-name">
                      {t(`trace.data.ruleKind.${r.kind}`, { defaultValue: r.kind })}: {r.name || r.pattern || r.uuid}
                    </span>
                    {r.file && <span className="explorer-trace-excluded-file">{r.file}</span>}
                    <span className={`explorer-data-badge${r.status === 'rejected' ? ' is-approx' : ''}`}>
                      {t(r.status === 'confirmed' ? 'trace.data.statusConfirmed' : 'trace.data.statusRejected')}
                    </span>
                    {r.orphaned && <span className="explorer-data-badge is-approx">{t('trace.data.orphaned')}</span>}
                    <button
                      type="button"
                      className="explorer-focus-details"
                      disabled={busy}
                      onClick={() => void write({
                        rules: [{
                          kind: r.kind,
                          ...(r.pattern !== undefined && r.pattern !== null ? { pattern: r.pattern } : { uuid: r.uuid, file: r.file }),
                          status: 'none',
                        }],
                      })}
                    >
                      {t('trace.data.undo')}
                    </button>
                  </li>
                );
              })}
            </ul>
          </section>
        )}
      </div>
    </div>
  );
}
