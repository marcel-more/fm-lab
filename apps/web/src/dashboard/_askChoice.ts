/**
 * Types and pure rules of the generic `ask` addition of an ActionSpec (dialog in
 * ActionAskHost.tsx, dispatch in actions.ts). Unit-tested in tests/askChoice.test.ts.
 */

export interface AskOption {
  /** Referenced by `choice.options[].onlyWith`. */
  id?: string;
  label: string;
  args?: Record<string, unknown>;
  /** Selection channel that must hold a value, else the option is disabled. */
  requiresSelection?: string;
}

/** One entry of the radio group `ask.choice` (e.g. a file format). */
export interface AskChoiceOption {
  id?: string;
  label: string;
  args?: Record<string, unknown>;
  /** Ids of the option buttons usable with this choice; the others are disabled. */
  onlyWith?: string[];
}

/**
 * Radio group above the option buttons: the chosen entry merges its `args`
 * too (action args < choice args < option args). The last choice is
 * remembered per page in the browser.
 */
export interface AskChoice {
  label?: string;
  options: AskChoiceOption[];
}

export interface AskSpec {
  title?: string;
  choice?: AskChoice;
  options: AskOption[];
}

/** Whether `option` can run: selection present and allowed by the chosen entry. */
export function askOptionUsable(
  option: AskOption,
  choice: AskChoiceOption | undefined,
  selection: Record<string, string | null>,
): boolean {
  if (option.requiresSelection && selection[option.requiresSelection] == null) return false;
  if (choice?.onlyWith && !(option.id && choice.onlyWith.includes(option.id))) return false;
  return true;
}

/** Args of the chosen option, merged over those of the chosen radio entry. */
export function mergeAskArgs(option: AskOption, choice: AskChoiceOption | undefined): Record<string, unknown> {
  return { ...(choice?.args ?? {}), ...(option.args ?? {}) };
}
