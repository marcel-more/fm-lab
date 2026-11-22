import React from 'react';
import { useTranslation } from 'react-i18next';
import { useNoDdrFiles } from '../hooks/useDataTrace';
import './PluginPlatformBadge.css';

interface NoDdrBadgeProps {
  fileName: string;
}

/**
 * Badge for Field and Script detail views when the object's file was exported
 * without DDR info: formula references are missing there, so the references,
 * usage counts and data traces of this object are incomplete. Renders nothing
 * while probing or when the file carries DDR info.
 */
export const NoDdrBadge: React.FC<NoDdrBadgeProps> = ({ fileName }) => {
  const { t } = useTranslation(['detail']);
  const noDdr = useNoDdrFiles();
  if (!noDdr || !noDdr.includes(fileName)) return null;
  return (
    <div className="plugin-platform-badge" title={t('detail:noDdr.tooltip') as string}>
      <span className="plugin-platform-status">{t('detail:noDdr.label')}</span>
      <span className="plugin-platform-meta">{t('detail:noDdr.meta')}</span>
    </div>
  );
};
