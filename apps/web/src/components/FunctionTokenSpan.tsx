import { API_BASE } from '../config/apiBase';
import React, { useState, useRef, useEffect } from 'react';
import { useNavigate, useParams } from 'react-router-dom';
import { useTranslation } from 'react-i18next';
import type { CalcToken } from '../script/calcTokens';
import { buildObjectPath } from '../lib/navigation';

interface FunctionTokenSpanProps {
  token: CalcToken;
  /** Optional: bereits normalisierter Anzeige-Text (CR → LF). */
  text?: string;
  /**
   * Cross-Reference Highlight: setzt `fm-ref--highlighted`. Wird von
   * CalcTokenSpan durchgereicht, da function-Tokens (anders als field/CF/…)
   * nicht inline dort, sondern in dieser eigenen Komponente gerendert werden.
   */
  highlighted?: boolean;
}

/**
 * Renderer für Calc-Tokens vom Type `function` mit Reference-DB-Anreicherung
 *. Zeigt einen Hover-Tooltip mit lokalisiertem Namen, Signatur,
 * Zweck und einem Link zur lokalen Claris-Hilfe.
 *
 * Tooltip-Strategie:
 *   - Token enriched (functionId vorhanden) → eigener HTML-Popover, KEIN
 *     HTML `title`-Attribut (sonst überlagern sich Browser-Tooltip + Popover).
 *   - Token nicht enriched (Reference-DB nicht attached o.ä.) → Browser-
 *     Tooltip als Fallback mit dem Token-Content selbst.
 */
export const FunctionTokenSpan: React.FC<FunctionTokenSpanProps> = ({ token, text, highlighted }) => {
  const { t } = useTranslation(['detail']);
  const navigate = useNavigate();
  const { uuid: currentUuid } = useParams<{ uuid: string }>();
  const [open, setOpen] = useState(false);
  const hoverTimer = useRef<number | null>(null);
  const isEnriched = typeof token.functionId === 'number';
  const displayText = text ?? token.content;

  // Cross-Navigation zur BuiltinFunction-Detail-Seite
  // wenn das Backend eine synthetische UUID am Token mitliefert. Popover bleibt
  // unverändert — onClick und Hover existieren parallel.
  const navPath = token.uuid
    ? buildObjectPath(token.uuid, currentUuid ?? null)
    : null;
  const handleClick = () => {
    if (navPath) navigate(navPath);
  };

  const startHover = () => {
    if (!isEnriched) return;
    if (hoverTimer.current) window.clearTimeout(hoverTimer.current);
    hoverTimer.current = window.setTimeout(() => setOpen(true), 250);
  };

  const cancelHover = () => {
    if (hoverTimer.current) {
      window.clearTimeout(hoverTimer.current);
      hoverTimer.current = null;
    }
    window.setTimeout(() => setOpen(false), 120);
  };

  useEffect(() => () => {
    if (hoverTimer.current) window.clearTimeout(hoverTimer.current);
  }, []);

  // Help-URL: bevorzugt lokal (rendert in unserer API), Fallback Claris extern.
  // Lokal liegt als /api/reference/help/...; im Browser muss daraus ein
  // absoluter Pfad zur API werden.
  const apiBase = (API_BASE).replace(/\/+$/, '');
  const helpHref = token.functionLocalHelpUrl
    ? `${apiBase}${token.functionLocalHelpUrl}`
    : token.functionHelpUrl;

  // Popover-Titel: GENAU EINE Sprachfassung, die gewählte. Für einen
  // Get-Parameter ist `functionDisplayName` bereits die vollständige
  // lokalisierte Signatur ('Hole ( Seitennummer )') — ein zusätzlich
  // angehängtes ` ( <SubParameter> )` ergab daraus die gemischte Form
  // 'Hole ( Seitennummer ) ( PageNumber )', weil der SubParameter immer der
  // kanonische englische Name ist. Der Anhang bleibt daher nur für den Fall,
  // dass kein lokalisierter Name vorliegt und der Titel auf das nackte 'Get'
  // der Aufspaltung zurückfällt.
  const canonicalName = token.functionCanonicalFull || token.functionCanonical;
  const popoverTitle = token.functionDisplayName
    || `${token.functionCanonical ?? token.content}${token.functionSubParameter ? ` ( ${token.functionSubParameter} )` : ''}`;
  // Redundanz-Filter: Signatur und „Kanonisch:"-Zeile nur zeigen, wenn sie dem
  // Titel nicht ohnehin entsprechen (bei Get-Parametern sind Anzeigename und
  // Signatur identisch). Whitespace-tolerant, weil die Referenz beide Formen
  // führt — 'Get(PageNumber)' und 'Get ( PageNumber )'.
  const norm = (v: string) => v.replace(/\s+/g, '').toLowerCase();
  const sameAsTitle = (v: string) => norm(v) === norm(popoverTitle);

  return (
    <span
      className={`fm-ref fm-ref--function${navPath ? ' fm-ref-link' : ''}${highlighted ? ' fm-ref--highlighted' : ''}`}
      data-ref-type="function"
      // Browser-Tooltip nur als Fallback, wenn keine Reference-Daten vorliegen.
      // Bei enriched-Token zeigt der eigene Popover die vollständigen Infos.
      title={isEnriched ? undefined : (navPath ? `${token.content} (Klick → Detail-Seite)` : token.content)}
      onMouseEnter={startHover}
      onMouseLeave={cancelHover}
      onClick={navPath ? handleClick : undefined}
      role={navPath ? 'link' : undefined}
      tabIndex={navPath ? 0 : undefined}
      onKeyDown={navPath ? (e) => { if (e.key === 'Enter') handleClick(); } : undefined}
    >
      {displayText}
      {open && isEnriched && (
        <span
          className="fm-function-popover"
          role="tooltip"
          onMouseEnter={() => {
            if (hoverTimer.current) window.clearTimeout(hoverTimer.current);
          }}
          onMouseLeave={cancelHover}
        >
          <span className="fm-function-popover-header">
            <strong>{popoverTitle}</strong>
            {token.functionReturnType && (
              <span className="fm-function-popover-return"> → {token.functionReturnType}</span>
            )}
          </span>
          {token.functionSignature && !sameAsTitle(token.functionSignature) && (
            <code className="fm-function-popover-signature">{token.functionSignature}</code>
          )}
          {token.functionPurpose && (
            <span className="fm-function-popover-purpose">{token.functionPurpose}</span>
          )}
          {helpHref && (
            <a
              className="fm-function-popover-link"
              href={helpHref}
              target="_blank"
              rel="noopener noreferrer"
            >
              {token.functionLocalHelpUrl ? t('detail:helpLinks.openLocalClarisHelp') : t('detail:helpLinks.openOnlineClarisHelp')}
            </a>
          )}
          {canonicalName && !sameAsTitle(canonicalName) && (
            <span className="fm-function-popover-canonical">
              {t('detail:helpLinks.canonical')} <code>{canonicalName}</code>
            </span>
          )}
        </span>
      )}
    </span>
  );
};
