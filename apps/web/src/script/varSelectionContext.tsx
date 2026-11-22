import React, { createContext, useContext, useEffect, useRef } from 'react';
import type { CalcToken } from './calcTokens';
import type { ScriptRef } from './types';

/**
 * View-lokale Variablen-Auswahl.
 *
 * Klick auf ein Variable-Token selektiert die Variable; alle Vorkommen im
 * aktuellen Detail-View werden hervorgehoben (`fm-ref--var-selected`). Anders
 * als der server-gestützte `?ref=`-Mechanismus (HighlightRefContext, UUID-Set)
 * ist die Auswahl rein namensbasiert: Calc-Variable-Tokens tragen keine UUID
 * (Let-Variablen und CF-Parameter haben nicht einmal einen Katalog-Eintrag),
 * der Schlüssel ist deshalb `<scope>:<name lowercase>` — der Name inklusive
 * Sigil, damit `$x` (Script-Variable) und `x` (Let-Variable) getrennt bleiben.
 *
 * Der Schlüssel ist zugleich der `?var=`-URL-Wert (DetailView trägt ihn via
 * useUrlState). Provider: genau einer, in der DetailView. Konsumenten: die
 * Token-Blatt-Komponenten CalcTokenSpan und RefSpan; ohne Provider (fm-spec,
 * Dashboards) degradieren beide auf das bisherige, nicht-klickbare Verhalten.
 */

export interface VarSelection {
  /** Aktuell selektierter varKey oder null. */
  selectedKey: string | null;
  /** Klick-Toggle: gleicher Key → Auswahl aufheben, anderer Key → ersetzen. */
  toggle: (key: string) => void;
  /**
   * Trefferzahl + Original-Schreibweise aus dem aktiven View (für die
   * VarSelectionPill). Views melden datenbasiert (Tokens/Refs), nicht per
   * DOM-Query — analog zum onLiveMatchCount-Kanal der RefOriginPill.
   */
  reportMatches: (count: number, displayName: string | null) => void;
}

export const VarSelectionContext = createContext<VarSelection | null>(null);

export function useVarSelection(): VarSelection | null {
  return useContext(VarSelectionContext);
}

const SCOPES = new Set(['local', 'global', 'superglobal']);

/** Kanonischer Auswahl-Schlüssel: `<scope>:<name lowercase>` (Name mit Sigil). */
export function makeVarKey(scope: string | null | undefined, name: string): string {
  const s = scope && SCOPES.has(scope) ? scope : 'local';
  return `${s}:${name.toLowerCase()}`;
}

export function varKeyFromCalcToken(token: CalcToken): string {
  return makeVarKey(token.scope, token.content);
}

export function varKeyFromScriptRef(ref: ScriptRef): string {
  return makeVarKey(ref.scope, ref.name);
}

/** Namens-Anteil eines Keys — Anzeige-Fallback, wenn kein View gemeldet hat. */
export function varKeyName(key: string): string {
  const i = key.indexOf(':');
  return i >= 0 ? key.slice(i + 1) : key;
}

/** Scope-Anteil eines Keys ('local' | 'global' | 'superglobal'). */
export function varKeyScope(key: string): string {
  const i = key.indexOf(':');
  return i > 0 ? key.slice(0, i) : 'local';
}

/**
 * Validiert/kanonisiert einen rohen `?var=`-Wert. Split am ERSTEN `:` —
 * der Scope-Enum enthält selbst keinen Doppelpunkt, Namen mit Sonderzeichen
 * (`${a:b}`) bleiben intakt. Ungültige Werte → null (stilles Degradieren).
 */
export function parseVarParam(raw: string | null | undefined): string | null {
  if (!raw) return null;
  const i = raw.indexOf(':');
  if (i <= 0) return null;
  const scope = raw.slice(0, i);
  const name = raw.slice(i + 1);
  if (!SCOPES.has(scope) || !name) return null;
  return `${scope}:${name.toLowerCase()}`;
}

/**
 * Interaktions-Props für ein klickbares Variable-Token (Klick + Enter/Space,
 * Button-Rolle, aria-pressed). Ohne Provider → leeres Objekt (nicht klickbar).
 * Gemeinsam genutzt von CalcTokenSpan, RefSpan und dem CF-Parameter-Header.
 *
 * Mit `open` (die Variable ist ein Katalogobjekt mit Detailansicht):
 *   - Klick / Enter öffnet die Detailansicht der Variable,
 *   - ⌘/Strg-Klick öffnet sie in einem neuen Tab,
 *   - Shift- oder Option/Alt-Klick (bzw. Shift+Enter, Leertaste) schaltet die
 *     Hervorhebung aller Vorkommen um.
 * Ohne `open` (CF-Parameter, Let-Variablen) schaltet jeder Klick die Hervorhebung.
 */
export interface VarClickProps {
  onClick: React.MouseEventHandler<HTMLElement>;
  onKeyDown: React.KeyboardEventHandler<HTMLElement>;
  role: 'button';
  tabIndex: number;
  'aria-pressed': boolean;
}

/**
 * Sprungziel eines Variable-Tokens: App-Pfad + Navigation des Hosts. `path`
 * als Funktion erhält das geklickte Element — so kann der Pfad Kontext der
 * Klickstelle mitnehmen (Schritt-Anker der Script-Zeile).
 */
export interface VarOpenTarget {
  path: string | ((target: HTMLElement) => string);
  navigate: (path: string) => void;
}

const pathOf = (open: VarOpenTarget, el: HTMLElement) =>
  (typeof open.path === 'function' ? open.path(el) : open.path);

export function varClickProps(
  varSel: VarSelection | null,
  key: string,
  open?: VarOpenTarget | null,
): Partial<VarClickProps> {
  if (!varSel) return {};
  const toggle = () => varSel.toggle(key);
  return {
    onClick: (e) => {
      if (!open || e.shiftKey || e.altKey) {
        toggle();
        return;
      }
      e.preventDefault();
      const path = pathOf(open, e.currentTarget);
      if (e.metaKey || e.ctrlKey) window.open(path, '_blank', 'noopener');
      else open.navigate(path);
    },
    role: 'button',
    tabIndex: 0,
    'aria-pressed': varSel.selectedKey === key,
    onKeyDown: (e) => {
      if (e.key === 'Enter' && open && !e.shiftKey && !e.altKey) {
        e.preventDefault();
        open.navigate(pathOf(open, e.currentTarget));
      } else if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        toggle();
      }
    },
  };
}

/**
 * Zählt die zur Auswahl passenden Variable-Tokens einer Calc-Token-Liste und
 * liefert die Original-Schreibweise des ersten Treffers (Pill-Anzeige).
 */
export function countCalcVarMatches(
  tokens: CalcToken[],
  selectedKey: string | null,
): { count: number; displayName: string | null } {
  if (!selectedKey) return { count: 0, displayName: null };
  let count = 0;
  let displayName: string | null = null;
  for (const tok of tokens) {
    if (tok.type !== 'variable') continue;
    if (varKeyFromCalcToken(tok) !== selectedKey) continue;
    count++;
    if (!displayName) displayName = tok.content;
  }
  return { count, displayName };
}

/**
 * Deep-Link-Scroll: Lädt eine Seite MIT gesetzter `?var=`-Auswahl, wird das
 * erste markierte Token angefahren (analog zum highlightSig-Scroll der
 * Viewer). Klicks im View scrollen bewusst NICHT — der Benutzer ist bereits
 * an der Klick-Stelle; deshalb konsumiert der Hook seinen einmaligen Versuch,
 * sobald der View bereit ist (`ready`), und bleibt danach inert.
 */
export function useVarDeepLinkScroll(
  rootRef: React.RefObject<HTMLElement | null>,
  ready: boolean = true,
): void {
  const varSel = useVarSelection();
  const consumed = useRef(false);
  const selectedKey = varSel?.selectedKey ?? null;
  useEffect(() => {
    if (!ready || consumed.current) return;
    consumed.current = true;
    if (!selectedKey || !rootRef.current) return;
    const id = requestAnimationFrame(() => {
      const first = rootRef.current?.querySelector('.fm-ref--var-selected');
      if (first) first.scrollIntoView({ behavior: 'smooth', block: 'center' });
    });
    return () => cancelAnimationFrame(id);
  }, [ready, selectedKey, rootRef]);
}
