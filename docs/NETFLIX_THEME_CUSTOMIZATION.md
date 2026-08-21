# Netflix Theme Customization Guide for Jellyfin Web

This document outlines the architecture, implementation, and injection workflow for the custom **Netflix Dark Theme** tailored for Jellyfin Web.

---

## 1. Overview & Architecture

The Netflix theme for Jellyfin transforms the standard web client interface into a modern, cinematic streaming experience inspired by Netflix.

### Key Visual & Design Pillars:
- **Primary Color Palette:**
  - Background Base: Pure Deep Charcoal / Black (`#141414`, `#080808`)
  - Accent / Primary Brand: Netflix Red (`#E50914`)
  - Secondary Accent / Hover Red: `#B81D24` / `#FF0A16`
  - Text Hierarchy: Primary `#FFFFFF`, Secondary `#B3B3B3`, Muted `#808080`
- **Hero Banner:** Full-bleed cinematic backdrop with smooth bottom and side gradient fades (`linear-gradient(to top, #141414 10%, transparent 90%)`), prominent bold typography, and rounded action buttons.
- **Card Hover Zoom:** Smooth 3D hardware-accelerated transform scaling (`scale3d(1.08, 1.08, 1)` or `scale(1.06)`), elevated z-index, and subtle glowing drop shadows (`box-shadow: 0 10px 25px rgba(0, 0, 0, 0.8), 0 0 15px rgba(229, 9, 20, 0.3)`).
- **Glassmorphism & Header:** Semi-transparent top navigation bar (`backdrop-filter: blur(12px)`) that dynamically gains opacity on scroll.

---

## 2. Directory & Injection Points

- **Jellyfin Web Root Directory:** `F:\Jellyfin\server\jellyfin-web`
- **Target Injection File:** `F:\Jellyfin\server\jellyfin-web\index.html`
- **Alternative Admin Injection:** Jellyfin Dashboard > **General** > **Custom CSS** field (persists across web client updates if managed through server configuration).

---

## 3. Direct DOM Manipulation Hooks vs. Static CSS

### Static CSS Styling (Recommended for Layout & Aesthetics)
Static CSS handles 95% of the visual overhaul by overriding Jellyfin's default CSS variables and class selectors:
- `.skinHeader`, `.mainDrawer`, `.card`, `.cardScalable`, `.cardBoxStore`
- CSS Custom Properties (`--theme-accent-color`, `--card-border-radius`, etc.)
- Smooth CSS transitions with `will-change: transform` for high refresh-rate displays.

### Dynamic DOM Hooks (Advanced Enhancements)
For features that CSS alone cannot achieve (such as injecting dynamic hero backdrop trailers, custom detail overlay modals, or dynamic title logos), dynamic JavaScript injection into `index.html` or a custom plugin script can hook into Jellyfin's client router:
```javascript
// Example: Hooking into view transitions to trigger hero transformations
document.addEventListener('viewshow', function (e) {
    const activeView = e.target;
    if (activeView.id === 'homeTab' || activeView.classList.contains('homePage')) {
        // Apply dynamic hero banner enhancements or trailer overlays
        console.log('[NetflixTheme] Home view active - Initializing Hero components');
    }
});
```

---

## 4. Responsive Design Considerations

### 1. 4K & Ultra-Wide Displays (21:9 / 32:9 / 3840x2160+)
- Max-width containers for rows are relaxed or set to proportional viewport widths (`96vw`) to prevent excessive dead space on ultra-wide screens.
- Card grid columns use responsive auto-fill rules: `grid-template-columns: repeat(auto-fill, minmax(220px, 1fr))` ensuring smooth scaling from 1080p to 4K without jagged spacing.
- Text sizes use fluid scaling (`clamp(1.5rem, 2.5vw, 3rem)`) for hero titles so they remain readable at 10-foot distances.

### 2. Standard Desktop & Laptops (1080p / 1440p)
- Card hover zoom uses `transform-origin: center center` (or edge-aware transform origins) with a subtle delay to avoid layout thrashing during fast mouse movement.
- Tooltips and card metadata popovers are constrained within viewport boundaries.

### 3. Mobile & Touch Clients (iOS / Android Web / PWA)
- Hover scale effects are disabled on touch-enabled devices via `@media (hover: none)` to prevent sticky touch-hover artifacts.
- Navigation bar collapses into a bottom or slide-out drawer with high touch targets (minimum 44x44px hitboxes).
- Backdrop gradients are simplified to conserve GPU memory and battery life on mobile devices.

---

## 5. Complete Custom CSS Rules

Below is the complete, self-contained CSS stylesheet for the Netflix Dark Theme.

```css
/* ==========================================================================
   NETFLIX DARK THEME FOR JELLYFIN WEB
   ========================================================================== */

:root {
  --nf-red: #E50914;
  --nf-red-hover: #B81D24;
  --nf-red-glow: rgba(229, 9, 20, 0.35);
  --nf-bg-dark: #141414;
  --nf-bg-card: #181818;
  --nf-bg-elevated: #232323;
  --nf-text-main: #FFFFFF;
  --nf-text-sub: #A3A3A3;
  --nf-radius-sm: 4px;
  --nf-radius-md: 8px;
  --nf-transition-fast: 0.2s cubic-bezier(0.25, 1, 0.5, 1);
  --nf-transition-smooth: 0.35s cubic-bezier(0.16, 1, 0.3, 1);
}

/* Base Body & Background */
body, .backgroundContainer, .mainAnimatedPages {
  background-color: var(--nf-bg-dark) !important;
  color: var(--nf-text-main);
  font-family: 'Netflix Sans', 'Helvetica Neue', Helvetica, Arial, sans-serif !important;
}

/* Header & Navigation Bar (Glassmorphism) */
.skinHeader {
  background-color: rgba(20, 20, 20, 0.75) !important;
  backdrop-filter: blur(16px);
  -webkit-backdrop-filter: blur(16px);
  border-bottom: 1px solid rgba(255, 255, 255, 0.06);
  transition: background-color var(--nf-transition-smooth);
}

.skinHeader.semiTransparent {
  background-color: rgba(20, 20, 20, 0.95) !important;
}

/* Header Buttons & Logo */
.headerLeft .emby-button, .headerRight .emby-button {
  color: var(--nf-text-main) !important;
  transition: color var(--nf-transition-fast), transform var(--nf-transition-fast);
}

.headerLeft .emby-button:hover, .headerRight .emby-button:hover {
  color: var(--nf-red) !important;
  transform: scale(1.05);
}

/* Navigation Drawer */
.mainDrawer {
  background-color: #111111 !important;
  box-shadow: 4px 0 24px rgba(0, 0, 0, 0.85);
  border-right: 1px solid #222222;
}

.navMenuOption-selected {
  background-color: rgba(229, 9, 20, 0.15) !important;
  color: var(--nf-red) !important;
  border-left: 4px solid var(--nf-red);
}

/* ==========================================================================
   Hero Banner Styling
   ========================================================================== */

.homePage .heroBanner,
.itemBackdrop {
  position: relative;
  background-size: cover;
  background-position: center 20%;
}

.itemBackdrop::after {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: linear-gradient(
    to top,
    var(--nf-bg-dark) 8%,
    rgba(20, 20, 20, 0.6) 40%,
    rgba(20, 20, 20, 0.2) 80%,
    transparent 100%
  ),
  linear-gradient(
    to right,
    var(--nf-bg-dark) 0%,
    rgba(20, 20, 20, 0.5) 25%,
    transparent 60%
  );
  pointer-events: none;
}

/* Hero Typography */
.itemName {
  font-weight: 800 !important;
  letter-spacing: -0.5px;
  color: var(--nf-text-main) !important;
  text-shadow: 0 2px 10px rgba(0, 0, 0, 0.85);
}

/* Netflix Primary Action Button */
.btnPlay, .raised.emby-button-focusscale {
  background-color: var(--nf-red) !important;
  color: #FFFFFF !important;
  border-radius: var(--nf-radius-sm) !important;
  font-weight: 700 !important;
  padding: 0.65em 1.6em !important;
  box-shadow: 0 4px 14px var(--nf-red-glow);
  transition: transform var(--nf-transition-fast), background-color var(--nf-transition-fast), box-shadow var(--nf-transition-fast) !important;
}

.btnPlay:hover, .raised.emby-button-focusscale:hover {
  background-color: var(--nf-red-hover) !important;
  transform: scale(1.05);
  box-shadow: 0 6px 20px rgba(229, 9, 20, 0.6);
}

/* Secondary Action Buttons (More Info / Trailer) */
.button-flat.emby-button {
  background-color: rgba(109, 109, 110, 0.7) !important;
  color: #FFFFFF !important;
  border-radius: var(--nf-radius-sm) !important;
  backdrop-filter: blur(8px);
  font-weight: 600 !important;
  transition: background-color var(--nf-transition-fast), transform var(--nf-transition-fast);
}

.button-flat.emby-button:hover {
  background-color: rgba(109, 109, 110, 0.4) !important;
  transform: scale(1.04);
}

/* ==========================================================================
   Media Cards & Hover Zoom Transitions
   ========================================================================== */

.card {
  transition: transform var(--nf-transition-smooth), z-index 0s, box-shadow var(--nf-transition-smooth);
  will-change: transform, box-shadow;
  border-radius: var(--nf-radius-md);
  overflow: visible !important;
}

.cardBox {
  background-color: var(--nf-bg-card);
  border-radius: var(--nf-radius-md);
  overflow: hidden;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.5);
  transition: box-shadow var(--nf-transition-smooth), background-color var(--nf-transition-smooth);
  border: 1px solid rgba(255, 255, 255, 0.05);
}

/* Desktop Hover Zoom Effect */
@media (hover: hover) and (pointer: fine) {
  .card:hover {
    transform: scale3d(1.08, 1.08, 1.08) translateZ(0);
    z-index: 100;
  }

  .card:hover .cardBox {
    background-color: var(--nf-bg-elevated);
    box-shadow: 0 14px 28px rgba(0, 0, 0, 0.8), 0 0 16px var(--nf-red-glow);
    border-color: rgba(229, 9, 20, 0.3);
  }
}

.cardScalable {
  border-radius: var(--nf-radius-md);
  overflow: hidden;
}

.cardImageContainer {
  background-color: #1a1a1a;
}

/* Card Titles & Details */
.cardText {
  color: var(--nf-text-main);
  font-weight: 600;
}

.cardText-secondary {
  color: var(--nf-text-sub) !important;
  font-size: 0.85em;
}

/* Indicators & Progress Bars */
.itemProgressBar {
  background: rgba(0, 0, 0, 0.6);
  height: 4px;
  border-radius: 2px;
}

.itemProgressBarForeground {
  background-color: var(--nf-red) !important;
  box-shadow: 0 0 8px var(--nf-red);
}

.playedIndicator {
  background: var(--nf-red) !important;
  border-radius: 50%;
  color: #FFFFFF;
}

.countIndicator {
  background: var(--nf-red) !important;
  font-weight: 700;
  border-radius: 4px;
}

/* ==========================================================================
   Responsive Rules for Ultra-Wide, 4K, and Mobile
   ========================================================================== */

/* 4K & Ultra-wide displays */
@media (min-width: 2560px) {
  .homeSectionsContainer, .sections {
    width: 96vw;
    max-width: none;
    margin: 0 auto;
  }

  .cardText {
    font-size: 1.1rem;
  }
  
  .itemName {
    font-size: clamp(2.5rem, 3.5vw, 4.5rem) !important;
  }
}

/* Mobile & Touch Viewports */
@media (max-width: 768px) {
  .card:hover {
    transform: none !important;
  }
  
  .skinHeader {
    backdrop-filter: blur(10px);
    background-color: rgba(20, 20, 20, 0.9) !important;
  }
  
  .itemName {
    font-size: 1.75rem !important;
  }
}
```

---

## 6. Injection Procedure into `index.html`

To permanently inject the theme into Jellyfin Web on the server host:

1. Navigate to the web client root:
   ```bash
   cd F:\Jellyfin\server\jellyfin-web
   ```
2. Create or copy the CSS into `custom-netflix-theme.css` in the same folder.
3. Open `index.html` in an editor.
4. Locate the closing `</head>` tag.
5. Add the stylesheet link or inline `<style>` block directly before `</head>`:
   ```html
   <!-- Netflix Dark Custom Theme -->
   <link rel="stylesheet" href="custom-netflix-theme.css">
   </head>
   ```
6. Clear the browser cache or reload Jellyfin Web with `Ctrl + F5` to inspect and verify the new theme.
