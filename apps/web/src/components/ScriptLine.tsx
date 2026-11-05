import React from 'react';
import { useTranslation } from 'react-i18next';
import type { ScriptLineToken, FoldRange, MarginRole } from '../script/types';
import { stepNameClass, getStepRole } from '../script/stepRoles';
import { DisclosureChevron } from './DisclosureChevron';
import { ScriptLineContent } from './ScriptLineContent';
import { isUuidHighlighted, useHighlightRefUuids, useScriptSearchQuery } from '../script/highlightContext';

interface ScriptLineProps {
  line: ScriptLineToken;
  marginRole: MarginRole | null;
  hidden: boolean;
  foldStarts: FoldRange[] | undefined;
  folded: boolean;
  onToggleFold: (startLine: number) => void;
}

export const ScriptLine: React.FC<ScriptLineProps> = React.memo(({
  line,
  marginRole,
  hidden,
  foldStarts,
  folded,
  onToggleFold,
}) => {
  const { t } = useTranslation(['detail']);
  const isFoldable = !!foldStarts && foldStarts.length > 0;
  const role = getStepRole(line.stepId);
  const stepClass = line.stepName ? `fm-step--${stepNameClass(line.stepName)}` : '';
  // Cross-Reference-Highlight:
  // wenn das back_references-Match-Set diese Step-UUID enthält (z.B. weil
  // Origin = ScriptStepType "Set Variable"), bekommt die Zeile eine
  // orange Outline — analog zum LayoutCanvas-Highlight.
  const highlightSet = useHighlightRefUuids();
  const lineHighlighted = isUuidHighlighted(highlightSet, line.stepUuid ?? null);
  const className = [
    'fm-line',
    `fm-line--${line.kind}`,
    !line.enabled && 'fm-line--disabled',
    hidden && 'fm-line--hidden',
    folded && 'fm-line--folded',
    line.kind === 'step' && stepClass,
    `fm-role--${role}`,
    lineHighlighted && 'fm-line--ref-highlighted',
  ].filter(Boolean).join(' ');

  // Indent in CSS-Custom-Property → CSS regelt Padding
  const style: React.CSSProperties = {
    ['--fm-indent' as string]: line.indent,
  };

  const handleFoldClick = () => {
    if (!isFoldable || !foldStarts || foldStarts.length === 0) return;
    onToggleFold(foldStarts[0].startLine);
  };

  const marginClass = marginRole ? `fm-margin--${marginRole}` : '';

  return (
    <li
      className={className}
      style={style}
      data-line={line.line}
      data-kind={line.kind}
      data-role={role}
      data-step-name={line.stepName ?? ''}
      data-step-uuid={line.stepUuid ?? ''}
    >
      <span className={`fm-margin-bar ${marginClass}`} aria-hidden="true" />
      <span className="fm-line-num">{line.line}</span>
      <span className="fm-fold-caret">
        {isFoldable ? (
          <button
            type="button"
            className="fm-fold-btn"
            onClick={handleFoldClick}
            aria-label={(folded ? t('detail:scriptLine.expand') : t('detail:scriptLine.collapse')) as string}
            title={(folded ? t('detail:scriptLine.expand') : t('detail:scriptLine.collapse')) as string}
          >
            <DisclosureChevron open={!folded} />
          </button>
        ) : null}
      </span>
      <span className="fm-line-content">
        {line.kind === 'empty' ? (
          <span className="fm-empty">&nbsp;</span>
        ) : line.kind === 'comment' ? (
          <CommentBody text={line.text ?? ''} folded={folded} />
        ) : (
          <ScriptLineContent text={line.text ?? ''} refs={line.refs} folded={folded} line={line} />
        )}
      </span>
    </li>
  );
});

ScriptLine.displayName = 'ScriptLine';

/**
 * Multi-line Kommentare mit Zeilenumbrüchen (\r oder \n) korrekt darstellen.
 * Jede Sub-Zeile bekommt das führende '#' als visuelles Präfix — das Backend
 * liefert den Inhalt ohne Markierung. Im gefolderten Zustand zeigen wir nur
 * die erste Sub-Zeile + '…'.
 *
 * Such-Highlight: Comments enthalten keine Refs und werden vom Token-Match
 * nicht erfasst. Wenn der ScriptSearchQueryContext einen Query liefert,
 * splitten wir den Sub-Zeilen-Text case-insensitive und markieren Treffer
 * per <mark class="fm-comment-search-match">.
 */
const CommentBody: React.FC<{ text: string; folded?: boolean }> = ({ text, folded }) => {
  const query = useScriptSearchQuery();
  const subLines = text.split(/\r\n|\r|\n/);
  const visible = folded && subLines.length > 1 ? subLines.slice(0, 1) : subLines;
  return (
    <span className="fm-comment">
      {visible.map((sub, i) => (
        <span key={i} className={`fm-comment-line${i > 0 ? ' fm-comment-line--cont' : ''}`}>
          <span className="fm-comment-prefix">#</span>
          {' '}
          {renderCommentText(sub, query)}
        </span>
      ))}
      {folded && subLines.length > 1 && <span className="fm-fold-ellipsis"> …</span>}
    </span>
  );
};

function renderCommentText(text: string, query: string | null): React.ReactNode {
  if (!query) return text;
  const lower = text.toLowerCase();
  const out: React.ReactNode[] = [];
  let pos = 0;
  let n = 0;
  while (pos < text.length) {
    const idx = lower.indexOf(query, pos);
    if (idx < 0) {
      out.push(text.slice(pos));
      break;
    }
    if (idx > pos) out.push(text.slice(pos, idx));
    out.push(
      <mark key={`m-${n++}`} className="fm-comment-search-match">
        {text.slice(idx, idx + query.length)}
      </mark>,
    );
    pos = idx + query.length;
  }
  return out;
}
