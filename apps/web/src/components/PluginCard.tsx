import React, { useState, useMemo } from 'react';
import { useTranslation } from 'react-i18next';
import { DisclosureChevron } from './DisclosureChevron';

export interface SettingsSchemaField {
  type: 'string' | 'select' | 'boolean' | 'number';
  label: string;
  description?: string;
  default?: string | number | boolean;
  options?: string[];
}

export interface PluginInfo {
  name: string;
  version: string;
  description: string;
  enabled: boolean;
  routes_prefix?: string;
  settings: Record<string, string | number | boolean>;
  settings_schema?: Record<string, SettingsSchemaField> | null;
  ui?: {
    frontend_module?: string;
    supported_object_types?: string[];
  } | null;
}

interface PluginCardProps {
  plugin: PluginInfo;
  expanded: boolean;
  onToggleExpand: () => void;
  onUpdate: (patch: { enabled?: boolean; settings?: Record<string, unknown> }) => Promise<void>;
  /** Optional plugin-specific content rendered inside the expanded card (e.g. fmIDE's file-status list). */
  extra?: React.ReactNode;
}

export const PluginCard: React.FC<PluginCardProps> = ({ plugin, expanded, onToggleExpand, onUpdate, extra }) => {
  const { t } = useTranslation(['detail']);
  const [draft, setDraft] = useState<Record<string, string | number | boolean>>(plugin.settings);
  const [saving, setSaving] = useState(false);
  const [toggling, setToggling] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const schemaEntries = useMemo(
    () => Object.entries(plugin.settings_schema || {}),
    [plugin.settings_schema],
  );

  const isDirty = useMemo(
    () => schemaEntries.some(([key]) => draft[key] !== plugin.settings[key]),
    [draft, plugin.settings, schemaEntries],
  );

  const handleToggle = async (next: boolean) => {
    setToggling(true);
    setError(null);
    try {
      await onUpdate({ enabled: next });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setToggling(false);
    }
  };

  const handleSave = async () => {
    setSaving(true);
    setError(null);
    try {
      await onUpdate({ settings: draft });
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    } finally {
      setSaving(false);
    }
  };

  const handleFieldChange = (key: string, value: string | number | boolean) => {
    setDraft((prev) => ({ ...prev, [key]: value }));
  };

  return (
    <div className={`plugin-card${expanded ? ' expanded' : ''}`}>
      <div
        className="plugin-card-header"
        role="button"
        tabIndex={0}
        aria-expanded={expanded}
        onClick={onToggleExpand}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            onToggleExpand();
          }
        }}
      >
        <div className="plugin-card-title">
          <DisclosureChevron open={expanded} className="plugin-card-chevron" />
          <h2>{plugin.name}</h2>
          <span className="plugin-card-version">v{plugin.version}</span>
        </div>
        <label
          className="plugin-card-toggle"
          onClick={(e) => e.stopPropagation()}
          onKeyDown={(e) => e.stopPropagation()}
        >
          <input
            type="checkbox"
            checked={plugin.enabled}
            disabled={toggling}
            onChange={(e) => handleToggle(e.target.checked)}
            onClick={(e) => e.stopPropagation()}
          />
          <span>{plugin.enabled ? t('detail:settingsView.statusActive') : t('detail:settingsView.statusInactive')}</span>
        </label>
      </div>

      {/* Plugins without settings: just the description. */}
      {expanded && schemaEntries.length === 0 && plugin.description && (
        <p className="plugin-card-description">{plugin.description}</p>
      )}

      {expanded && schemaEntries.length > 0 && (
        <div className="plugin-card-settings">
          <h3>{t('detail:settingsView.settingsHeading')}</h3>
          {plugin.description && (
            <p className="plugin-card-description plugin-card-description--inset">{plugin.description}</p>
          )}
          {schemaEntries.map(([key, field]) => (
            field.type === 'boolean' ? (
              // Checkbox precedes the label so the text can't wrap under it.
              <div key={key} className="plugin-card-field plugin-card-field--checkbox">
                <label htmlFor={`${plugin.name}-${key}`} className="plugin-card-checkbox-label">
                  <input
                    id={`${plugin.name}-${key}`}
                    type="checkbox"
                    checked={Boolean(draft[key] ?? field.default ?? false)}
                    onChange={(e) => handleFieldChange(key, e.target.checked)}
                  />
                  <span>{field.label}</span>
                </label>
                {field.description && (
                  <span className="plugin-card-field-desc">{field.description}</span>
                )}
              </div>
            ) : (
              <div key={key} className="plugin-card-field">
                <label htmlFor={`${plugin.name}-${key}`}>
                  {field.label}
                  {field.description && (
                    <span className="plugin-card-field-desc"> — {field.description}</span>
                  )}
                </label>
                {field.type === 'select' && field.options ? (
                  <select
                    id={`${plugin.name}-${key}`}
                    value={String(draft[key] ?? field.default ?? '')}
                    onChange={(e) => handleFieldChange(key, e.target.value)}
                  >
                    {field.options.map((opt) => (
                      <option key={opt} value={opt}>{opt}</option>
                    ))}
                  </select>
                ) : field.type === 'number' ? (
                  <input
                    id={`${plugin.name}-${key}`}
                    type="number"
                    value={Number(draft[key] ?? field.default ?? 0)}
                    onChange={(e) => handleFieldChange(key, Number(e.target.value))}
                  />
                ) : (
                  <input
                    id={`${plugin.name}-${key}`}
                    type="text"
                    value={String(draft[key] ?? field.default ?? '')}
                    onChange={(e) => handleFieldChange(key, e.target.value)}
                  />
                )}
              </div>
            )
          ))}

          <div className="plugin-card-actions">
            <button
              type="button"
              onClick={handleSave}
              disabled={!isDirty || saving}
              className="plugin-card-save"
            >
              {saving ? t('detail:settingsView.savingLabel') : t('detail:settingsView.saveLabel')}
            </button>
          </div>
        </div>
      )}

      {expanded && extra && <div className="plugin-card-extra">{extra}</div>}

      {expanded && error && <div className="plugin-card-error">{error}</div>}
    </div>
  );
};
