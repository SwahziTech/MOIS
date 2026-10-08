export default function LoadingSpinner({ size = 24, label }) {
  return (
    <div className="loading-overlay" style={{ flexDirection: 'column', gap: 12 }}>
      <div
        className="spinner"
        style={{ width: size, height: size, borderWidth: size < 20 ? 2 : 2.5 }}
      />
      {label && (
        <div style={{ fontSize: 'var(--text-sm)', color: 'var(--text-muted)' }}>{label}</div>
      )}
    </div>
  );
}

/** Inline row-level skeleton for tables */
export function SkeletonRow({ cols = 5 }) {
  return (
    <tr>
      {Array.from({ length: cols }).map((_, i) => (
        <td key={i}>
          <div
            className="skeleton"
            style={{ height: 14, width: i === 0 ? '60%' : '80%' }}
          />
        </td>
      ))}
    </tr>
  );
}

/** Block skeleton for card content */
export function SkeletonBlock({ lines = 3 }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 10, padding: '20px' }}>
      {Array.from({ length: lines }).map((_, i) => (
        <div
          key={i}
          className="skeleton"
          style={{ height: 14, width: i === 0 ? '45%' : `${70 - i * 10}%` }}
        />
      ))}
    </div>
  );
}
