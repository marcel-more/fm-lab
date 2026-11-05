import { useSyncExternalStore, type FocusEvent } from 'react';
import { useTranslation } from 'react-i18next';
import { useEscapeStack } from '../hooks/useEscapeStack';
import {
  dismissToast, getToast, holdToast, releaseToast, subscribeToast,
} from '../lib/toastStore';
import './Toast.css';

/**
 * App-wide toast (mounted once in App.tsx): the current message of the toast
 * store, bottom center, with an optional action button and a close button.
 * The live region stays in the DOM while empty so screen readers announce a
 * new message. Escape closes it; hover and focus hold the auto-dismiss.
 */
export function Toast() {
  const { t } = useTranslation(['common']);
  const toast = useSyncExternalStore(subscribeToast, getToast);

  useEscapeStack([
    () => {
      if (!getToast()) return false;
      dismissToast();
      return true;
    },
  ]);

  const onBlur = (e: FocusEvent<HTMLDivElement>) => {
    if (!e.currentTarget.contains(e.relatedTarget as Node | null)) releaseToast('focus');
  };

  return (
    <div className="toast-region" role="status" aria-live="polite">
      {toast && (
        <div
          className={`toast toast--${toast.tone}`}
          onMouseEnter={() => holdToast('hover')}
          onMouseLeave={() => releaseToast('hover')}
          onFocus={() => holdToast('focus')}
          onBlur={onBlur}
        >
          <span className="toast__message">{toast.message}</span>
          {toast.action && (
            <button
              type="button"
              className="toast__action"
              onClick={() => {
                toast.action?.onAction();
                dismissToast(toast.id);
              }}
            >
              {toast.action.label}
            </button>
          )}
          <button
            type="button"
            className="toast__close"
            aria-label={t('common:close') as string}
            title={t('common:close') as string}
            onClick={() => dismissToast(toast.id)}
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" aria-hidden="true">
              <line x1="6" y1="6" x2="18" y2="18" />
              <line x1="18" y1="6" x2="6" y2="18" />
            </svg>
          </button>
        </div>
      )}
    </div>
  );
}
