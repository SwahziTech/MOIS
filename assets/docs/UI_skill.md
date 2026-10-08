\---

name: premium-ui-design
description: Design beautiful, premium, non-AI-looking UI for React (web) and Flutter (mobile) — solid color systems (NO gradients), curated fonts (NO Inter/Roboto), SVG icons (NO emoji), unified icon colors, accessible touch targets, tasteful motion, and a signature curved bottom navigation bar for both platforms. Use this skill whenever building or restyling any screen, component, design system, theme, or navigation so the result looks crafted by a senior designer, not generated.
---

# Premium UI \& UX Design System

Make interfaces that look intentionally crafted. The rules below are what separate a "designed" product from an "AI-generated" one. Follow them and most prompting about visuals becomes unnecessary.

## ROADMAP

1. Pick ONE bold aesthetic direction + dominant color with a sharp accent.
2. Define design tokens (colors, 2 fonts, spacing, radius, shadows) — never raw hex in components.
3. Apply the hard rules: no gradients, no emoji, no Inter/Roboto, one color per icon set.
4. Build the curved bottom nav (Flutter package / React custom component below).
5. Pass the accessibility + interaction + pre-delivery checklists.

\---

## THE HARD RULES (non-negotiable — this is the whole point)

* **NO GRADIENTS.** No linear/radial gradients, gradient text, or gradient borders. Solid flat colors only.
* **NO EMOJI.** Never in UI, labels, headings, toasts, or empty states. Use SVG icons (Lucide, Heroicons, Material Symbols).
* **NO Inter, Roboto, Arial, or system fonts.** Use curated fonts: DM Sans, Plus Jakarta Sans, Space Grotesk, Outfit, Sora, Clash Display, Satoshi, General Sans. Always pair a display font (headings) with a refined body font.
* **ONE COLOR PER ICON SET.** All feature/category icons in a section use the same color (usually `primary`). Multi-colored icon grids look amateur. Exception: semantic status icons (success green ✓, error red ✗).
* **Dominant color + sharp accent** beats an evenly-distributed rainbow palette.
* **Dark mode = desaturated tonal variants, NOT inverted colors.**

\---

## DESIGN TOKENS — CSS (React)

```css
:root {
  --color-primary: #1a365d;
  --color-primary-light: #2a4a7f;
  --color-accent: #e67e22;

  --color-bg: #f8f9fa;
  --color-surface: #ffffff;
  --color-text: #1a1a2e;
  --color-text-secondary: #6b7280;

  --color-success: #10b981;
  --color-error: #ef4444;
  --color-warning: #f59e0b;

  --font-heading: 'DM Sans', sans-serif;
  --font-body: 'Plus Jakarta Sans', sans-serif;

  --space-xs: 4px; --space-s: 8px; --space-m: 16px;
  --space-l: 24px; --space-xl: 32px; --space-xxl: 48px;

  --radius-s: 8px; --radius-m: 12px; --radius-l: 16px; --radius-xl: 24px;

  --shadow-sm: 0 1px 3px rgba(0,0,0,.08);
  --shadow-md: 0 4px 12px rgba(0,0,0,.1);
  --shadow-lg: 0 8px 30px rgba(0,0,0,.12);

  --transition-fast: 150ms ease;
  --transition-normal: 250ms ease;
  --transition-slow: 400ms cubic-bezier(.4,0,.2,1);
}

:root\\\[data-theme="dark"] {
  --color-primary: #3b82f6;
  --color-primary-light: #60a5fa;
  --color-accent: #f59e0b;
  --color-bg: #0f172a;
  --color-surface: #1e293b;
  --color-text: #f1f5f9;
  --color-text-secondary: #94a3b8;
  --shadow-md: 0 4px 12px rgba(0,0,0,.4);
}
```

## DESIGN TOKENS — Flutter

```dart
class AppColors {
  static const primary = Color(0xFF1A365D);
  static const primaryLight = Color(0xFF2A4A7F);
  static const accent = Color(0xFFE67E22);
  static const background = Color(0xFFF7F8FC);
  static const surface = Color(0xFFFFFFFF);
  static const textPrimary = Color(0xFF1A202C);
  static const textSecondary = Color(0xFF718096);
  static const success = Color(0xFF10B981);
  static const error = Color(0xFFE53E3E);
  static const warning = Color(0xFFF59E0B);
  static const darkBackground = Color(0xFF0F172A);
  static const darkSurface = Color(0xFF1E293B);
  static const darkTextPrimary = Color(0xFFF1F5F9);
  static const darkTextSecondary = Color(0xFF94A3B8);
}

class AppTheme {
  static ThemeData get light => ThemeData(
    brightness: Brightness.light,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.light(
      primary: AppColors.primary, secondary: AppColors.accent,
      surface: AppColors.surface, error: AppColors.error,
    ),
    textTheme: \\\_text(AppColors.textPrimary, AppColors.textSecondary),
    appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0),
  );
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.darkBackground,
    colorScheme: ColorScheme.dark(
      primary: AppColors.primaryLight, secondary: AppColors.accent,
      surface: AppColors.darkSurface, error: AppColors.error,
    ),
    textTheme: \\\_text(AppColors.darkTextPrimary, AppColors.darkTextSecondary),
  );
  static TextTheme \\\_text(Color p, Color s) => TextTheme(
    headlineLarge:  GoogleFonts.dmSans(fontSize: 32, fontWeight: FontWeight.w800, color: p),
    headlineMedium: GoogleFonts.dmSans(fontSize: 24, fontWeight: FontWeight.w700, color: p),
    headlineSmall:  GoogleFonts.dmSans(fontSize: 18, fontWeight: FontWeight.w600, color: p),
    bodyLarge:  GoogleFonts.plusJakartaSans(fontSize: 16, color: p),
    bodyMedium: GoogleFonts.plusJakartaSans(fontSize: 14, color: s),
    labelLarge: GoogleFonts.plusJakartaSans(fontSize: 14, fontWeight: FontWeight.w600, color: p),
  );
}
```

## TYPOGRAPHY \& MOTION

* Type scale: 12, 14, 16, 18, 24, 32. Body 16px, line-height 1.5–1.75, max line 65–75 chars.
* Motion: 150–300ms micro-interactions, ≤400ms transitions. Animate **only** `transform`/`opacity`.
* Ease-out entering, ease-in exiting; exit = 60–70% of enter duration; stagger lists 30–50ms.
* Always respect `prefers-reduced-motion`. Max 1–2 animated elements per view.
* Press feedback: scale 0.92–0.95. Skeleton loaders, not spinners. Empty states = illustration + message + CTA.

\---

## SIGNATURE CURVED BOTTOM NAV — Flutter

```yaml
dependencies:
  curved\\\_navigation\\\_bar: ^1.0.6
```

```dart
CurvedNavigationBar(
  key: \\\_navKey,
  index: \\\_currentIndex(context),
  height: 60,
  color: Colors.white,
  buttonBackgroundColor: Colors.white,
  backgroundColor: Colors.transparent,   // match page bg
  animationDuration: const Duration(milliseconds: 400),
  animationCurve: Curves.easeOutCubic,
  items: const \\\[
    Icon(Icons.home\\\_rounded, size: 26, color: Color(0xFF1565C0)),
    Icon(Icons.menu\\\_book\\\_rounded, size: 26, color: Color(0xFF1565C0)),
    Icon(Icons.person\\\_rounded, size: 26, color: Color(0xFF1565C0)),
  ],
  onTap: \\\_onTap,
)
```

Rules: sync `index` with GoRouter location; keep `height` 55–65; max 5 items (sidebar on desktop ≥800px).

## SIGNATURE CURVED BOTTOM NAV — React (no library)

```tsx
export function CurvedNavBar({ items, color = '#fff', activeColor = '#1565C0', bgColor = '#f8f9fa' }) {
  const nav = useNavigate(); const loc = useLocation();
  const active = Math.max(0, items.findIndex(i => loc.pathname === i.path));
  const w = 100 / items.length; const c = w \\\* active + w / 2;
  return (
    <nav className="curved-nav" style={{ '--bar-color': color, '--bg-color': bgColor }}>
      <svg className="curved-nav\\\_\\\_curve" viewBox="0 0 100 16" preserveAspectRatio="none">
        <path d={`M 0 16 L ${c-12} 16 Q ${c-6} 16 ${c-4} 10 Q ${c} -2 ${c+4} 10 Q ${c+6} 16 ${c+12} 16 L 100 16 L 0 16 Z`} fill={color}/>
      </svg>
      <div className="curved-nav\\\_\\\_bar" style={{ backgroundColor: color }}>
        {items.map((it, i) => (
          <button key={it.path} className={`curved-nav\\\_\\\_item ${i===active?'curved-nav\\\_\\\_item--active':''}`}
            onClick={() => nav(it.path)} aria-label={it.label} aria-current={i===active?'page':undefined}>
            <span className="curved-nav\\\_\\\_icon" style={i===active?{backgroundColor:activeColor,color:'#fff'}:{}}>{it.icon}</span>
            {i!==active \\\&\\\& <span className="curved-nav\\\_\\\_label">{it.label}</span>}
          </button>
        ))}
      </div>
    </nav>
  );
}
```

```css
.curved-nav{position:fixed;bottom:0;left:0;right:0;z-index:100;height:70px;pointer-events:none}
.curved-nav\\\_\\\_curve{position:absolute;top:-15px;left:0;width:100%;height:16px}
.curved-nav\\\_\\\_path{transition:d .4s cubic-bezier(.4,0,.2,1)}
.curved-nav\\\_\\\_bar{position:absolute;bottom:0;left:0;right:0;height:60px;display:flex;align-items:center;
  justify-content:space-around;padding:0 8px;pointer-events:auto;box-shadow:0 -2px 12px rgba(0,0,0,.06)}
.curved-nav\\\_\\\_item{display:flex;flex-direction:column;align-items:center;gap:2px;flex:1;border:none;
  background:none;cursor:pointer;transition:transform .15s ease}
.curved-nav\\\_\\\_item:active{transform:scale(.92)}
.curved-nav\\\_\\\_icon{display:flex;align-items:center;justify-content:center;width:40px;height:40px;
  border-radius:50%;transition:all .4s cubic-bezier(.4,0,.2,1);color:#6b7280}
.curved-nav\\\_\\\_item--active .curved-nav\\\_\\\_icon{transform:translateY(-28px);width:50px;height:50px;
  box-shadow:0 4px 16px rgba(0,0,0,.15)}
.curved-nav\\\_\\\_label{font-size:10px;font-weight:500;color:#6b7280}
@media (prefers-reduced-motion:reduce){.curved-nav\\\_\\\_path,.curved-nav\\\_\\\_icon{transition:none}}
```

Add `padding-bottom: 80px` to page content; hide the bar on desktop (≥1024px) and use a sidebar.

\---

## ACCESSIBILITY \& INTERACTION (priority order)

1. Contrast ≥4.5:1 text; visible 2–4px focus rings; `aria-label` on icon buttons; tab order matches visual order. Color is never the only indicator.
2. Touch targets ≥44×44pt (iOS) / ≥48×48dp (Android); 8px+ between targets; tap feedback <100ms; disable buttons during async.
3. Mobile-first breakpoints 375/768/1024/1440; no horizontal scroll; safe-area compliance; desktop max width 1200–1440px.
4. Visible labels per field (not placeholder-only); validate on blur; errors below the field with how-to-fix; confirm destructive actions.

## PRE-DELIVERY CHECKLIST

* \[ ] Zero gradients, zero emoji, zero Inter/Roboto/system fonts
* \[ ] One unified icon color per section
* \[ ] Semantic tokens only (no hardcoded hex in components)
* \[ ] Light + dark both tested, contrast ≥4.5:1
* \[ ] Touch targets ≥44/48; press states don't shift layout
* \[ ] Motion ≤400ms, transform/opacity only, reduced-motion respected
* \[ ] Curved nav synced to router, hidden on desktop

