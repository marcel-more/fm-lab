import React from 'react';
import { useTranslation } from 'react-i18next';
import { useVersionManifest } from '../hooks/useVersionManifest';
import './VersionStatusLine.css';

/**
 * Versions-Status-Balken — rendert hinter dem „Zurück"-Button auf
 * /settings die sechs Kern-Versionen, getrennt durch ` · `:
 *
 *   FM-Lab v0.8.9 · API v0.8.9 · Frontend v0.8.9 · XML Konverter v5.1.0 · Engine v2.22.0 · DB Schema v1.7.0 · fm-spec v1.2.0
 *
 * Mapping:
 *   FM-Lab        = manifest.version (global)
 *   API           = components.rest_api.version
 *   Frontend      = __APP_VERSION__ (Build-Zeit-Injektion — die tatsächlich
 *                   gebaute Bundle-Version, wahrheitsgetreu zum laufenden Build)
 *   XML Konverter = components.xml_import.version
 *   Engine        = components.xml_import.engine_version (interne Konverter-
 *                   Kennung, die Changelog und Import-Log zitieren; Segment
 *                   entfällt bei Manifesten ohne das Feld)
 *   DB Schema     = components.schema.version
 *   fm-spec       = components.fm_spec.version
 *
 * Alle Segmente werden als reiner Versionsstring gezeigt (kein Link). Der
 * Einstieg in den fm-spec Schema-Viewer erfolgt über das eigene fm-spec-Panel
 * auf der Einstellungen-Seite. Plugins und Skills stehen bewusst NICHT im
 * Balken. Bei Fehler/Offline (Manifest null) rendert die Komponente nichts.
 */
export const VersionStatusLine: React.FC = () => {
  const { t } = useTranslation(['detail']);
  const manifest = useVersionManifest();

  if (!manifest) return null;

  const segments: { label: string; version: string | null | undefined }[] = [
    { label: t('detail:settingsView.versions.fmlab'), version: manifest.version },
    { label: t('detail:settingsView.versions.api'), version: manifest.components?.rest_api?.version },
    { label: t('detail:settingsView.versions.frontend'), version: __APP_VERSION__ },
    { label: t('detail:settingsView.versions.xmlConverter'), version: manifest.components?.xml_import?.version },
    ...(manifest.components?.xml_import?.engine_version
      ? [{ label: t('detail:settingsView.versions.xmlEngine'), version: manifest.components.xml_import.engine_version }]
      : []),
    { label: t('detail:settingsView.versions.dbSchema'), version: manifest.components?.schema?.version },
    { label: t('detail:settingsView.versions.fmSpec'), version: manifest.components?.fm_spec?.version },
  ];

  return (
    <span className="version-status-line">
      {segments.map((seg, i) => (
        <React.Fragment key={seg.label}>
          {i > 0 && <span className="version-status-line__sep"> · </span>}
          <span className="version-status-line__item">
            {seg.label} v{seg.version ?? '?'}
          </span>
        </React.Fragment>
      ))}
    </span>
  );
};
