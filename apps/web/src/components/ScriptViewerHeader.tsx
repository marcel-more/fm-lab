import React from 'react';
import { useTranslation } from 'react-i18next';
import type { ViewMode } from '../script/types';
import { BulkToggleButton, BulkToggleGroup, CollapseAllIcon, CollapseLinesIcon, ExpandAllIcon } from './BulkToggle';

export type FilterStyle = 'dim' | 'hide';

interface ScriptViewerHeaderProps {
  stepCount: number;
  mode: ViewMode;
  onModeChange: (mode: ViewMode) => void;
  filterStyle: FilterStyle;
  onFilterStyleChange: (style: FilterStyle) => void;
  onExpandAll: () => void;
  onCollapseAll: () => void;
  onCollapseMultiline: () => void;
}

const MODE_IDS: ViewMode[] = [
  'normal',
  'compact',
  'comments-only',
  'control-only',
  'subscript-only',
  'assignments-only',
  'executive-only',
];

const MODE_TO_KEY: Record<ViewMode, string> = {
  'normal':           'normal',
  'compact':          'compact',
  'comments-only':    'commentsOnly',
  'control-only':     'controlOnly',
  'subscript-only':   'subscriptOnly',
  'assignments-only': 'assignmentsOnly',
  'executive-only':   'executiveOnly',
};

export const ScriptViewerHeader: React.FC<ScriptViewerHeaderProps> = ({
  stepCount,
  mode,
  onModeChange,
  filterStyle,
  onFilterStyleChange,
  onExpandAll,
  onCollapseAll,
  onCollapseMultiline,
}) => {
  const { t } = useTranslation(['common', 'detail']);
  const filterDisabled = mode === 'normal';
  return (
    <div className="fm-script-header">
      <h2 className="type-detail-heading fm-script-title">
        {t('detail:scriptViewer.title')} <span className="fm-script-count">{t('detail:scriptViewer.stepCount', { count: stepCount })}</span>
      </h2>
      <div className="fm-script-actions">
        <label className="fm-script-mode">
          <span className="fm-script-mode-label">{t('detail:scriptViewer.viewLabel')}</span>
          <select
            value={mode}
            onChange={(e) => onModeChange(e.target.value as ViewMode)}
            aria-label={t('detail:scriptViewer.viewAria') as string}
          >
            {MODE_IDS.map(id => (
              <option key={id} value={id}>{t(`detail:scriptViewer.modes.${MODE_TO_KEY[id]}`)}</option>
            ))}
          </select>
        </label>
        <div
          className={`fm-filter-toggle${filterDisabled ? ' fm-filter-toggle--disabled' : ''}`}
          role="radiogroup"
          aria-label={t('detail:scriptViewer.filterStyleAria') as string}
          aria-disabled={filterDisabled}
          title={(filterDisabled
            ? t('detail:scriptViewer.filterStyleTitleDisabled')
            : t('detail:scriptViewer.filterStyleTitleEnabled')) as string}
        >
          <button
            type="button"
            role="radio"
            aria-checked={filterStyle === 'dim'}
            className={filterStyle === 'dim' ? 'is-active' : ''}
            onClick={() => onFilterStyleChange('dim')}
            disabled={filterDisabled}
          >
            {t('detail:scriptViewer.filterDim')}
          </button>
          <button
            type="button"
            role="radio"
            aria-checked={filterStyle === 'hide'}
            className={filterStyle === 'hide' ? 'is-active' : ''}
            onClick={() => onFilterStyleChange('hide')}
            disabled={filterDisabled}
          >
            {t('detail:scriptViewer.filterHide')}
          </button>
        </div>
        <div className="fm-script-fold-buttons">
          <BulkToggleGroup>
            <BulkToggleButton icon={<ExpandAllIcon />} label={t('common:actions.expandAll') as string} onClick={onExpandAll} />
            <BulkToggleButton icon={<CollapseAllIcon />} label={t('common:actions.collapseAll') as string} onClick={onCollapseAll} />
          </BulkToggleGroup>
          <BulkToggleGroup>
            <BulkToggleButton
              icon={<CollapseLinesIcon />}
              label={t('common:actions.collapseMultilineCalcs') as string}
              onClick={onCollapseMultiline}
            />
          </BulkToggleGroup>
        </div>
      </div>
    </div>
  );
};
