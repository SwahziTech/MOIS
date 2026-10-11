import { AlertCircle } from 'lucide-react';

/**
 * User-facing load error. Never pass raw database errors here (PRD §10.12);
 * log them with console.error and show a plain message instead.
 */
export default function ErrorState({ message = "We couldn't load this data. Please try again.", onRetry }) {
  return (
    <div className="error-state" role="alert">
      <AlertCircle size={32} color="var(--color-error)" strokeWidth={1.5} />
      <div className="error-state-title">Something went wrong</div>
      <p className="error-state-desc">{message}</p>
      {onRetry && (
        <button type="button" className="btn btn-outline" onClick={onRetry} style={{ marginTop: 8 }}>
          Try again
        </button>
      )}
    </div>
  );
}
