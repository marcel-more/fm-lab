/**
 * Toast store — one transient message at a time for the whole app (a new
 * message replaces the current one), with an optional action button and an
 * auto-dismiss timer that holds while the toast is hovered or focused.
 * `components/Toast.tsx` renders it once in App.tsx; anything can call
 * `showToast` without prop drilling.
 *
 * Runtime-import-free on purpose: the unit tests under `apps/web/tests/` run
 * the factory directly with Node's test runner and type stripping, timers
 * injected.
 */

export type ToastTone = 'info' | 'error';

export interface ToastAction {
  label: string;
  onAction: () => void;
}

export interface ToastInput {
  message: string;
  tone?: ToastTone;
  action?: ToastAction;
  /** Auto-dismiss delay; defaults to TOAST_DURATION_MS. */
  durationMs?: number;
}

export interface Toast {
  id: number;
  message: string;
  tone: ToastTone;
  action: ToastAction | null;
  durationMs: number;
}

export const TOAST_DURATION_MS = 6000;

export interface ToastTimers {
  setTimer: (fn: () => void, ms: number) => unknown;
  clearTimer: (handle: unknown) => void;
  now: () => number;
}

export interface ToastStore {
  show: (input: ToastInput) => number;
  /** Dismisses the current toast; with an id only if that toast is still shown. */
  dismiss: (id?: number) => void;
  /** Pauses auto-dismiss for one reason (e.g. 'hover', 'focus'). */
  hold: (reason: string) => void;
  /** Lifts one hold; the timer resumes with the remaining time once none is left. */
  release: (reason: string) => void;
  get: () => Toast | null;
  subscribe: (listener: () => void) => () => void;
}

export function createToastStore(timers: ToastTimers): ToastStore {
  let current: Toast | null = null;
  let nextId = 1;
  let handle: unknown = null;
  let deadline = 0;
  let remaining = 0;
  const holds = new Set<string>();
  const listeners = new Set<() => void>();

  const notify = () => { for (const l of listeners) l(); };

  const stopTimer = () => {
    if (handle !== null) timers.clearTimer(handle);
    handle = null;
  };

  const startTimer = (ms: number) => {
    stopTimer();
    deadline = timers.now() + ms;
    const id = current?.id;
    handle = timers.setTimer(() => {
      handle = null;
      if (current && current.id === id) dismiss(id);
    }, ms);
  };

  function show(input: ToastInput): number {
    const durationMs = input.durationMs ?? TOAST_DURATION_MS;
    current = {
      id: nextId++,
      message: input.message,
      tone: input.tone ?? 'info',
      action: input.action ?? null,
      durationMs,
    };
    remaining = durationMs;
    // A replacing toast inherits the holds: the pointer may still rest on it.
    if (holds.size === 0) startTimer(durationMs);
    else stopTimer();
    notify();
    return current.id;
  }

  function dismiss(id?: number): void {
    if (!current || (id !== undefined && current.id !== id)) return;
    stopTimer();
    current = null;
    holds.clear();
    notify();
  }

  function hold(reason: string): void {
    if (!current) return;
    if (holds.size === 0 && handle !== null) {
      remaining = Math.max(0, deadline - timers.now());
      stopTimer();
    }
    holds.add(reason);
  }

  function release(reason: string): void {
    if (!holds.delete(reason) || holds.size > 0 || !current) return;
    startTimer(remaining);
  }

  return {
    show,
    dismiss,
    hold,
    release,
    get: () => current,
    subscribe: (listener) => {
      listeners.add(listener);
      return () => { listeners.delete(listener); };
    },
  };
}

const store = createToastStore({
  setTimer: (fn, ms) => globalThis.setTimeout(fn, ms),
  clearTimer: (h) => globalThis.clearTimeout(h as ReturnType<typeof setTimeout>),
  now: () => Date.now(),
});

export const showToast = store.show;
export const dismissToast = store.dismiss;
export const holdToast = store.hold;
export const releaseToast = store.release;
export const getToast = store.get;
export const subscribeToast = store.subscribe;
