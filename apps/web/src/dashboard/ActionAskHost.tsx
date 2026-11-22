import { useEffect, useRef, useState } from 'react';
import { useTranslation } from 'react-i18next';
import { askOptionUsable, mergeAskArgs, registerAskHandler } from './actions';
import type { AskChoiceOption, AskOption, AskSpec } from './actions';

// The last radio entry of `ask.choice` per page (e.g. the export format):
// a per-viewer convenience — without storage the first entry is used.
const CHOICE_KEY = 'fmlab.dashboard.askChoice:';

function choiceKey(choice: AskChoiceOption, index: number): string {
  return choice.id ?? String(index);
}

function rememberedChoice(ask: AskSpec): number {
  const options = ask.choice?.options ?? [];
  try {
    const stored = window.localStorage.getItem(CHOICE_KEY + window.location.pathname);
    const index = options.findIndex((c, i) => choiceKey(c, i) === stored);
    return index >= 0 ? index : 0;
  } catch {
    return 0;
  }
}

function rememberChoice(ask: AskSpec, index: number): void {
  const choice = ask.choice?.options?.[index];
  if (!choice) return;
  try {
    window.localStorage.setItem(CHOICE_KEY + window.location.pathname, choiceKey(choice, index));
  } catch {
    /* private mode / blocked storage: nothing to remember */
  }
}

interface Pending {
  ask: AskSpec;
  selection: Record<string, string | null>;
  resolve: (option: AskOption | null) => void;
}

/**
 * Dialog of the generic `ask` addition of an ActionSpec (see actions.ts): shows
 * the options as buttons; an option with `requiresSelection` is disabled while
 * that selection channel is empty. An optional radio group `choice` (e.g. the
 * file format) sits above the buttons; its entry's `onlyWith` disables the
 * buttons it does not fit. Cancel, Esc or a click on the backdrop = no action.
 * One host per rendered dashboard (DashboardRenderer).
 *
 * Native <dialog> with showModal(): focus stays inside, Esc closes, the page
 * behind is inert.
 */
export function ActionAskHost() {
  const { t } = useTranslation(['dashboard']);
  const [pending, setPending] = useState<Pending | null>(null);
  const [choiceIndex, setChoiceIndex] = useState(0);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const pendingRef = useRef<Pending | null>(null);
  pendingRef.current = pending;

  useEffect(() => {
    registerAskHandler((ask, selection) => new Promise<AskOption | null>((resolve) => {
      pendingRef.current?.resolve(null);
      setChoiceIndex(rememberedChoice(ask));
      setPending({ ask, selection, resolve });
    }));
    return () => {
      registerAskHandler(null);
      pendingRef.current?.resolve(null);
    };
  }, []);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    if (pending && !dialog.open) {
      dialog.showModal();
      // showModal focuses the first focusable element — with a radio group that
      // would be the first entry, not the action; start on the first usable button.
      dialog.querySelector<HTMLButtonElement>('.dash-ask__option:not(:disabled)')?.focus();
    }
    if (!pending && dialog.open) dialog.close();
  }, [pending]);

  const choices = pending?.ask.choice?.options ?? [];
  const choice: AskChoiceOption | undefined = choices[choiceIndex];

  const finish = (option: AskOption | null) => {
    if (option && pending?.ask.choice) rememberChoice(pending.ask, choiceIndex);
    pendingRef.current?.resolve(option ? { ...option, args: mergeAskArgs(option, choice) } : null);
    setPending(null);
  };


  return (
    <dialog
      ref={dialogRef}
      className="dash-ask"
      aria-labelledby="dash-ask-title"
      onCancel={(e) => { e.preventDefault(); finish(null); }}
      onClick={(e) => { if (e.target === dialogRef.current) finish(null); }}
    >
      {pending && (
        <div className="dash-ask__body">
          <h2 id="dash-ask-title" className="dash-ask__title">{pending.ask.title || t('ask.title')}</h2>
          {choices.length > 0 && (
            <fieldset className="dash-ask__choice">
              {pending.ask.choice?.label && <legend className="dash-ask__choice-label">{pending.ask.choice.label}</legend>}
              {choices.map((entry, i) => (
                <label key={choiceKey(entry, i)} className="dash-ask__choice-option">
                  <input
                    type="radio"
                    name="dash-ask-choice"
                    checked={i === choiceIndex}
                    onChange={() => setChoiceIndex(i)}
                  />
                  <span>{entry.label}</span>
                </label>
              ))}
            </fieldset>
          )}
          <div className="dash-ask__options">
            {pending.ask.options.map((option, i) => {
              const usable = askOptionUsable(option, choice, pending.selection);
              const noSelection = !!option.requiresSelection && pending.selection[option.requiresSelection] == null;
              return (
                <button
                  key={i}
                  type="button"
                  className="dash-ask__option"
                  disabled={!usable}
                  title={usable ? undefined : t(noSelection ? 'ask.needsSelection' : 'ask.notForChoice')}
                  onClick={() => finish(option)}
                >
                  {option.label}
                </button>
              );
            })}
          </div>
          <div className="dash-ask__footer">
            <button type="button" className="dash-ask__cancel" onClick={() => finish(null)}>
              {t('ask.cancel')}
            </button>
          </div>
        </div>
      )}
    </dialog>
  );
}
