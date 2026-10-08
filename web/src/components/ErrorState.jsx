import { AlertCircle } from 'lucide-react';

export default function ErrorState({ message, onRetry }) {
  return (
    <div className="error-state">
      <AlertCircle size={32} color="var(--color-error)" strokeWidth={1.5} />
      <div className="error-state-title">Something went wrong</div>
      {message && <pre className="error-state-desc">{message}</pre>}
      {onRetry && (
        <button className="btn btn-outline" onClick={onRetry} style={{ marginTop: 8 }}>
          Try again
        </button>
      )}
    </div>
  );
}
