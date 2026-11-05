import type { ReactNode } from 'react';
import { SubNav } from './SubNav';
import { StatusBar } from './StatusBar';
import { TitleBox } from './TitleBox';
import type { BreadcrumbItem } from '../types';

interface SubPageHeaderProps {
  title?: string;
  subtitle?: ReactNode;
  breadcrumbs?: BreadcrumbItem[];
  /** Custom back handler. Default (StatusBar): navigate(-1), fallback "/". */
  onBack?: () => void;
  /** Optional slot rendered left of the meta navi (language + theme). */
  actions?: ReactNode;
}

/**
 * SubPageHeader — composition of the unified `<SubNav>` (Ebene 3) and
 * `<StatusBar>` (Ebene 4) plus an optional title row (Ebene 6). Used by the
 * dashboard route wrappers. The LanguageSelector + ThemeToggle meta navi
 * now comes for free via `<SubNav>`.
 */
export function SubPageHeader({
  title,
  subtitle,
  breadcrumbs,
  onBack,
  actions,
}: SubPageHeaderProps) {
  return (
    <>
      <SubNav breadcrumbs={breadcrumbs ?? []} actions={actions} />
      <StatusBar onBack={onBack} />
      {title && <TitleBox title={title} subtitle={subtitle} />}
    </>
  );
}
