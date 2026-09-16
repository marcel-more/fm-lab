const fs = require('fs');
const path = require('path');
const { LRUCache } = require('lru-cache');
const environment = require('../config/environment');

/**
 * Help-Service — bedient den lokalen Claris-Hilfe-Mirror.
 *
 * Quelle:   <htmlCacheRoot>/<lang>/content/<slug>.html
 * Manifest: <htmlCacheRoot>/manifest.json
 *
 * Sprach-Codes des Mirrors entsprechen 1:1 dem URL-Segment der Claris-Site
 * (z.B. 'zh' statt 'zh-Hans'). Das Mapping macht der Reference-Service
 * transparent — hier wird der Mirror-Code direkt benutzt.
 */

const htmlCache = new LRUCache({
  max: 500,
  ttl: environment.reference.htmlCacheTtlMs,
});

let manifest = null;
let manifestLangs = new Set();

// Pro Sprache: Set<slug> der existierenden HTML-Dateien. Wird lazy beim ersten
// Bedarf eingelesen (z.B. für Cross-Link-Validierung) und beim Admin-Reload
// invalidiert.
const slugInventory = new Map();

function htmlRoot() {
  return path.resolve(__dirname, '../../', environment.reference.htmlCacheRoot);
}

function loadManifest() {
  const manifestPath = path.join(htmlRoot(), 'manifest.json');
  if (!fs.existsSync(manifestPath)) {
    manifest = null;
    manifestLangs = new Set();
    return null;
  }
  try {
    const raw = fs.readFileSync(manifestPath, 'utf8');
    manifest = JSON.parse(raw);
    manifestLangs = new Set(
      (manifest.languages || [])
        .filter((l) => !l.incomplete)
        .map((l) => l.code)
    );
    return manifest;
  } catch (e) {
    console.warn(`Failed to load claris-help manifest: ${e.message}`);
    manifest = null;
    manifestLangs = new Set();
    return null;
  }
}

function getManifest() {
  if (manifest === null) loadManifest();
  return manifest;
}

function hasMirrorForLang(lang) {
  if (manifest === null) loadManifest();
  return manifestLangs.has(lang);
}

function getFallbackLang() {
  const m = getManifest();
  return (m && m.fallback_language) || 'en';
}

function htmlPath(lang, slug) {
  const subdir = environment.reference.htmlSubdir || 'content';
  // Schutz vor Path-Traversal: nur slug-Charakter erlauben
  if (!/^[a-z0-9._-]+$/i.test(slug)) return null;
  return path.join(htmlRoot(), lang, subdir, `${slug}.html`);
}

/**
 * Set<slug> aller HTML-Seiten pro Sprache. Wird einmalig pro Lifecycle gelesen
 * und in `slugInventory` gecached. Genutzt für die Existenz-Validierung von
 * Cross-Links beim HTML-Optimieren.
 */
function getSlugInventory(lang) {
  if (slugInventory.has(lang)) return slugInventory.get(lang);
  const subdir = environment.reference.htmlSubdir || 'content';
  const dir = path.join(htmlRoot(), lang, subdir);
  const set = new Set();
  if (fs.existsSync(dir)) {
    try {
      for (const f of fs.readdirSync(dir)) {
        if (f.toLowerCase().endsWith('.html')) {
          set.add(f.slice(0, -5)); // ohne ".html"
        }
      }
    } catch (e) {
      console.warn(`Failed to read slug inventory for '${lang}': ${e.message}`);
    }
  }
  slugInventory.set(lang, set);
  return set;
}

/**
 * True when the mirror holds the slug in ANY installed (complete) language —
 * the existence signal for cross-navigation into the docs page, which itself
 * falls back through `resolveHtml`. Language-independent by design: the docs
 * page of a step/function is reachable as soon as one mirror carries it.
 */
function hasAnyHtml(slug) {
  if (!slug || !/^[a-z0-9._-]+$/i.test(slug)) return false;
  if (manifest === null) loadManifest();
  for (const lang of manifestLangs) {
    if (getSlugInventory(lang).has(slug)) return true;
  }
  return false;
}

function readHtml(lang, slug) {
  const cacheKey = `${lang}::${slug}`;
  if (htmlCache.has(cacheKey)) return htmlCache.get(cacheKey);
  const p = htmlPath(lang, slug);
  if (!p || !fs.existsSync(p)) return null;
  const html = fs.readFileSync(p, 'utf8');
  const entry = { html, path: p, lang };
  htmlCache.set(cacheKey, entry);
  return entry;
}

/**
 * Resolver mit Sprach-Fallback. Kaskade:
 *   1. <lang>/content/<slug>.html  →  source = 'html-cache:<lang>'
 *   2. <fallback>/content/<slug>.html  →  source = 'html-cache:fallback:<fb>'
 *   3. null  →  Caller setzt source = 'db-only'
 */
function resolveHtml(lang, slug) {
  // Primär-Sprache
  if (hasMirrorForLang(lang)) {
    const entry = readHtml(lang, slug);
    if (entry) return { ...entry, source: `html-cache:${lang}` };
  }
  // Fallback-Sprache
  const fb = getFallbackLang();
  if (fb && fb !== lang && hasMirrorForLang(fb)) {
    const entry = readHtml(fb, slug);
    if (entry) return { ...entry, source: `html-cache:fallback:${fb}` };
  }
  return null;
}

/**
 * Status-Übersicht aus dem Manifest. Schlankes Format für /api/reference/help/status.
 */
function getStatus() {
  const m = getManifest();
  if (!m) {
    return {
      available: false,
      root: htmlRoot(),
      languages: [],
    };
  }
  return {
    available: true,
    root: htmlRoot(),
    fallbackLanguage: m.fallback_language,
    fetchedAt: m.fetched_at,
    languages: (m.languages || []).map((l) => ({
      code: l.code,
      mirrorDir: l.url_lang_segment,
      htmlPages: l.html_pages,
      assetFiles: l.asset_files,
      sizeBytes: l.total_size_bytes,
      fetchedAt: l.fetched_at,
      incomplete: !!l.incomplete,
    })),
  };
}

/**
 * Optimiert den Body-Inhalt der MadCap-Help-Seite:
 *   1. Alles vor dem ersten <h1> entfernen (Navigation, Search, Breadcrumbs).
 *   2. <p class="feedback">…</p> entfernen.
 *   3. <div class="footer-alt">…</div> entfernen (enthält Copyright + Legal-Link).
 *   4. Cross-Links (`<a href="<slug>.html">` ohne Pfadpräfix) auf
 *      /api/reference/help/<lang>/<slug> mappen. Existiert das Ziel im Mirror
 *      nicht, wird der Link in ein <span class="fm-help-deadlink"> entwertet
 *      (Text bleibt erhalten, Link geht aber nirgendwo hin).
 *   5. Relative Asset-Pfade `../Skins/...`, `../Resources/...`, `../assets/...`
 *      auf `/api/reference/_static/<lang>/...` umschreiben.
 *
 * Mirror-Sprachcode (z.B. 'zh' statt 'zh-Hans') wird beibehalten — der Caller
 * gibt uns bereits den Mirror-Code (siehe reference.controller).
 */
function optimizeBody(body, lang) {
  // 1. Body auf den Bereich ab <h1> begrenzen.
  const h1Match = body.match(/<h1[\s>]/i);
  if (h1Match) {
    body = body.slice(h1Match.index);
  }

  // 2. Feedback-Paragraph entfernen.
  body = body.replace(/<p[^>]*class="[^"]*\bfeedback\b[^"]*"[^>]*>[\s\S]*?<\/p>/gi, '');

  // 3. Footer-Alt-Block (Copyright + Legal-Link) entfernen.
  // Das footer-alt-div enthält genau ein verschachteltes home-master-page-footer-alt-div,
  // welches zwei Kind-divs hat. Pattern auf das einzelne <div class="footer-alt"> beschränkt,
  // greift mit ausgewogenem Nesting (3 Closing-divs für die innere Struktur).
  body = body.replace(
    /<div[^>]*class="[^"]*\bfooter-alt\b[^"]*"[^>]*>[\s\S]*?<\/div>\s*<\/div>\s*<\/div>/gi,
    ''
  );

  // Fallback für den seltenen Fall, dass nur der Legal-Link übrig bleibt
  // (defensiv, falls Claris das Markup künftig ändert).
  body = body.replace(
    /<p[^>]*>\s*<a[^>]*id="footer-legal-info"[^>]*>[\s\S]*?<\/a>\s*<\/p>/gi,
    ''
  );

  // 4. Cross-Links umschreiben — pure Filename-Verweise (kein Slash, keine
  // Protokoll-URL, kein Hash-only). Die Pre-Validierung nutzt das Slug-Inventory
  // der Ziel-Sprache. Bei Anchor-Suffix (#section) den Anker erhalten.
  const slugs = getSlugInventory(lang);
  body = body.replace(
    /(<a\b[^>]*\bhref=")([^":/?#]+?)\.html(#[^"]*)?("[^>]*>)([\s\S]*?)(<\/a>)/gi,
    (match, prefix, slug, anchor, suffix, inner, closer) => {
      if (slugs.has(slug)) {
        const rewritten = `/api/reference/help/${encodeURIComponent(lang)}/${slug}${anchor || ''}`;
        return `${prefix}${rewritten}${suffix}${inner}${closer}`;
      }
      // Ziel existiert nicht — Link entwerten, Text behalten.
      return `<span class="fm-help-deadlink">${inner}</span>`;
    }
  );

  // 5a. Relative ../-Pfade → /api/reference/_static/<lang>/<rel> (z.B. Skins/, Resources/, assets/)
  body = body.replace(/(href|src)="\.\.\/([^"]+)"/g, (m, attr, rel) => {
    return `${attr}="/api/reference/_static/${encodeURIComponent(lang)}/${rel}"`;
  });

  // 5b. Relative Pfade ohne ../-Prefix sind seitenrelativ und zeigen damit auf
  // <lang>/content/<rel>. Wir mappen `resources/...` explizit (häufig in MadCap),
  // andere ergänzbare Verzeichnisse können hier später hinzukommen.
  body = body.replace(/(href|src)="(resources\/[^"]+)"/g, (m, attr, rel) => {
    return `${attr}="/api/reference/_static/${encodeURIComponent(lang)}/content/${rel}"`;
  });

  return body;
}

/**
 * Liefert nur das <select>-Element für die Sprachauswahl (oder leeren String,
 * wenn weniger als zwei Sprachen den Slug haben). Wird vom Header-Builder als
 * Inline-Element rechts neben dem Theme-Toggle eingesetzt.
 */
function buildLangSelect(slug, currentLang) {
  if (!slug) return '';
  const m = getManifest();
  if (!m || !Array.isArray(m.languages)) return '';

  const opts = [];
  for (const l of m.languages) {
    if (l.incomplete) continue;
    const code = l.code;
    const slugs = getSlugInventory(code);
    if (slugs.has(slug)) opts.push({ code, label: code.toUpperCase() });
  }
  if (opts.length < 2) return '';
  if (!opts.some((o) => o.code === currentLang)) return '';

  const tags = opts.map((o) => {
    const sel = o.code === currentLang ? ' selected' : '';
    const href = `/api/reference/help/${encodeURIComponent(o.code)}/${encodeURIComponent(slug)}`;
    return `<option value="${href}"${sel}>${o.label}</option>`;
  }).join('');

  return `<select class="fm-help-lang-select" aria-label="Sprache" onchange="if(this.value)location.href=this.value">${tags}</select>`;
}

/**
 * Vollständige Optimierung einer MadCap-Help-Seite (inkl. <head>-Pfaden).
 * Liefert eine renderbare HTML-Seite zurück, in der:
 *   - <head>-Asset-Pfade (../Skins/, ../Resources/) auf /api/reference/_static gehen
 *   - <body> durch optimizeBody() bereinigt ist
 *   - Wenn `slug` übergeben wird, am Body-Anfang ein dezentes Sprachschalter-
 *     Dropdown eingefügt wird (nur für Sprachen, die diesen Slug haben)
 *   - Theme-Switcher (Light/Dark/Auto) wird immer eingefügt; Theme aus localStorage
 *     wird inline geladen, bevor der Body sichtbar ist (kein FOUC)
 */
function optimizeHelpHtml(html, lang, slug = null) {
  // Head-Asset-Pfade umschreiben — wichtig damit die Page beim direkten Öffnen
  // im Browser CSS und Scripts findet. Zusätzlich Theme-Variablen + Pre-Hydration
  // im Head, damit der Background-Wechsel passiert bevor der Body sichtbar wird.
  let out = html.replace(/<head([^>]*)>([\s\S]*?)<\/head>/i, (m, attrs, head) => {
    let fixedHead = head.replace(/(href|src)="\.\.\/([^"]+)"/g, (mm, attr, rel) => {
      return `${attr}="/api/reference/_static/${encodeURIComponent(lang)}/${rel}"`;
    });
    // Seitenrelative `resources/`-Pfade → de/content/resources/...
    fixedHead = fixedHead.replace(/(href|src)="(resources\/[^"]+)"/g, (mm, attr, rel) => {
      return `${attr}="/api/reference/_static/${encodeURIComponent(lang)}/content/${rel}"`;
    });
    return `<head${attrs}>${fixedHead}${buildThemeStyles()}${buildThemePreHydration()}</head>`;
  });
  // Body-Optimierung + Header-Leiste (Title links, Theme-Toggle + Sprache rechts).
  // Der ursprüngliche MadCap-Body wird in einen `.fm-help-page-body`-Wrapper
  // gesetzt, damit er Padding bekommt und nicht direkt an die Header-Linie stößt.
  const header = buildHelpHeader({
    title: 'Claris-Hilfe',
    langSelect: buildLangSelect(slug, lang),
  });
  out = out.replace(/<body([^>]*)>([\s\S]*?)<\/body>/i, (m, attrs, body) => {
    return `<body${attrs}>${header}<div class="fm-help-page-body">${optimizeBody(body, lang)}</div></body>`;
  });
  return out;
}

/**
 * Inline-Script vor dem Body-Render: liest `localStorage['fm-help-theme']`
 * und setzt `data-theme` auf <html>, damit der Dark-Mode greift, bevor der
 * Body gemalt wird (vermeidet FOUC). Akzeptiert 'light' | 'dark' | 'auto'.
 */
function buildThemePreHydration() {
  return `
<script>
(function(){
  try {
    var t = localStorage.getItem('fm-help-theme') || 'auto';
    var resolved = t;
    if (t === 'auto') {
      resolved = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }
    document.documentElement.setAttribute('data-theme', resolved);
    document.documentElement.setAttribute('data-theme-mode', t);
  } catch(e) {}
})();
</script>
`.trim();
}

/**
 * Globales Theme-CSS für Light/Dark-Mode der MadCap-Help-Seiten. Greift via
 * `[data-theme="dark"]` auf <html>, das vom Pre-Hydration-Script gesetzt wird.
 *
 * Strategie: MadCap-CSS lädt mit hartkodierten Farben — wir überschreiben mit
 * höherer Spezifizität (`html[data-theme="dark"] body`) statt `!important`,
 * damit Inline-Styles in einzelnen Topics weiter Vorrang haben können.
 */
function buildThemeStyles() {
  return `
<style id="fm-help-theme-styles">
  /* Light-Mode-Defaults — MadCap-CSS bleibt unverändert wirksam. */
  html[data-theme="light"] body { background: #ffffff; color: #213547; }

  /* Dark-Mode — überschreibt MadCap-Standardfarben. */
  html[data-theme="dark"] {
    color-scheme: dark;
  }
  html[data-theme="dark"] body,
  html[data-theme="dark"] .body-container,
  html[data-theme="dark"] .topic-content,
  html[data-theme="dark"] .container {
    background: #16191f;
    color: #e6e8ec;
  }
  html[data-theme="dark"] h1,
  html[data-theme="dark"] h2,
  html[data-theme="dark"] h3,
  html[data-theme="dark"] h4,
  html[data-theme="dark"] h5,
  html[data-theme="dark"] h6 {
    color: #f5f7fa;
  }
  html[data-theme="dark"] a { color: #8ab4ff; }
  html[data-theme="dark"] a:visited { color: #b48aff; }
  html[data-theme="dark"] a:hover { color: #a3c4ff; }
  html[data-theme="dark"] code,
  html[data-theme="dark"] pre,
  html[data-theme="dark"] kbd,
  html[data-theme="dark"] samp,
  html[data-theme="dark"] tt {
    background: #1f242c;
    color: #e0e6f0;
    border-color: #303640;
  }
  html[data-theme="dark"] table,
  html[data-theme="dark"] th,
  html[data-theme="dark"] td {
    border-color: #303640 !important;
    background-color: transparent;
    color: inherit;
  }
  html[data-theme="dark"] thead th,
  html[data-theme="dark"] tr:nth-child(even) td {
    background: #1c2027;
  }
  html[data-theme="dark"] hr { border-color: #303640; }
  html[data-theme="dark"] blockquote {
    background: #1c2027;
    border-left-color: #444a55;
    color: #c8ccd3;
  }
  /* MadCap-spezifische Tote-Link-Klasse + eigene Dead-Link-Markierung */
  html[data-theme="dark"] .fm-help-deadlink { color: #888c95; }
  /* Bilder im Dark-Mode etwas dimmen, damit sie nicht knallen. */
  html[data-theme="dark"] img:not([src*=".svg"]) { opacity: 0.88; }
</style>
`.trim();
}

/**
 * SVG-Icon-Markup für Sonne und Mond — 1:1 die gleichen Pfade wie der
 * `ThemeToggle`-Button im Frontend (`apps/web/src/components/ThemeToggle.tsx`),
 * damit die Hilfe-Seiten das gleiche optische Sprache haben.
 */
const SUN_SVG = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2"/><path d="M12 20v2"/><path d="m4.93 4.93 1.41 1.41"/><path d="m17.66 17.66 1.41 1.41"/><path d="M2 12h2"/><path d="M20 12h2"/><path d="m4.93 19.07 1.41-1.41"/><path d="m17.66 6.34 1.41-1.41"/></svg>`;
const MOON_SVG = `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>`;

/**
 * Header-Leiste für Hilfe-Seiten (Claris- und Plugin-Doku). Eine Zeile mit
 * Untertrennung, links der Titel ("Claris-Hilfe", "MBS Plugin-Hilfe"), rechts
 * Theme-Toggle und (optional) Sprachauswahl. CSS + Toggle-Script sind im
 * Header-Snippet enthalten — keine externen Abhängigkeiten.
 *
 * Theme-Toggle: einfacher 2-State (Light/Dark), gleiche Icons wie
 * `ThemeToggle.tsx` im Frontend. Das vom Pre-Hydration-Script gesetzte
 * `data-theme` wird respektiert; Klick wechselt das Gegenteil und persistiert
 * in `localStorage['fm-help-theme']`.
 */
function buildHelpHeader({ title, titleHref = null, langSelect = '', navLinks = [] }) {
  const titleHtml = titleHref
    ? `<a class="fm-help-header-title" href="${escapeText(titleHref)}">${escapeText(title)}</a>`
    : `<h1 class="fm-help-header-title">${escapeText(title)}</h1>`;
  const navHtml = (Array.isArray(navLinks) && navLinks.length > 0)
    ? `<nav class="fm-help-header-nav" aria-label="Bereiche">${
        navLinks.map((l) => `<a class="fm-help-header-navlink" href="${escapeText(l.href)}">${escapeText(l.label)}</a>`).join('')
      }</nav>`
    : '';
  return `
<style>
  .fm-help-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.55rem 1.25rem;
    border-bottom: 1px solid #e0e0e0;
    background: #ffffff;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    position: sticky;
    top: 0;
    z-index: 1000;
  }
  html[data-theme="dark"] .fm-help-header {
    background: #16191f;
    border-bottom-color: #303640;
  }
  .fm-help-header-title {
    font-size: 0.95rem;
    font-weight: 600;
    color: #213547;
    margin: 0;
    text-decoration: none;
  }
  a.fm-help-header-title:hover { color: #646cff; }
  html[data-theme="dark"] .fm-help-header-title { color: #e6e8ec; }
  html[data-theme="dark"] a.fm-help-header-title:hover { color: #8a91ff; }
  .fm-help-header-nav {
    display: flex;
    align-items: center;
    gap: 0.85rem;
    margin-right: auto;
    margin-left: 1.25rem;
    padding-left: 1.25rem;
    border-left: 1px solid #e0e0e0;
  }
  html[data-theme="dark"] .fm-help-header-nav { border-left-color: #303640; }
  .fm-help-header-navlink {
    font-size: 0.85rem;
    color: #555;
    text-decoration: none;
  }
  .fm-help-header-navlink:hover { color: #646cff; text-decoration: underline; }
  html[data-theme="dark"] .fm-help-header-navlink { color: #b8bdc7; }
  html[data-theme="dark"] .fm-help-header-navlink:hover { color: #8a91ff; }
  .fm-help-header-actions {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .fm-help-theme-toggle {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    padding: 0;
    border: none;
    border-radius: 50%;
    background: transparent;
    color: #767676;
    cursor: pointer;
    transition: background-color 0.15s, color 0.15s;
  }
  .fm-help-theme-toggle:hover {
    color: #646cff;
    background-color: rgba(100, 108, 255, 0.06);
  }
  html[data-theme="dark"] .fm-help-theme-toggle { color: #8a8f99; }
  html[data-theme="dark"] .fm-help-theme-toggle:hover {
    color: #8a91ff;
    background-color: rgba(138, 145, 255, 0.10);
  }
  .fm-help-lang-select {
    appearance: none;
    -webkit-appearance: none;
    background: #ffffff;
    color: #213547;
    border: 1px solid #c0c0c0;
    border-radius: 4px;
    padding: 3px 22px 3px 8px;
    font-size: 12px;
    font-weight: 500;
    line-height: 1.4;
    cursor: pointer;
    background-image: url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='10' height='6' viewBox='0 0 10 6'><path fill='%23666' d='M0 0l5 6 5-6z'/></svg>");
    background-repeat: no-repeat;
    background-position: right 6px center;
  }
  .fm-help-lang-select:focus { outline: 2px solid #646cff; outline-offset: 1px; }
  html[data-theme="dark"] .fm-help-lang-select {
    background-color: #232831;
    color: #e6e8ec;
    border-color: #444a55;
  }
  /* Doku-Inhalt etwas einrücken, damit er nicht direkt an die Header-Linie
   * stößt — das gleiche Padding rechts/links wie der Header. */
  .fm-help-page-body {
    padding: 1rem 1.25rem 3rem;
    max-width: 1020px;
    margin: 0 auto;
  }
</style>
<header class="fm-help-header" role="banner">
  ${titleHtml}
  ${navHtml}
  <div class="fm-help-header-actions">
    ${langSelect}
    <button type="button" class="fm-help-theme-toggle" id="fm-help-theme-btn" aria-pressed="false" aria-label="Theme umschalten" title="Theme umschalten">
      <span class="fm-help-theme-icon-light">${SUN_SVG}</span>
      <span class="fm-help-theme-icon-dark" hidden>${MOON_SVG}</span>
    </button>
  </div>
</header>
<script>
(function(){
  var btn = document.getElementById('fm-help-theme-btn');
  if (!btn) return;
  var iconLight = btn.querySelector('.fm-help-theme-icon-light');
  var iconDark  = btn.querySelector('.fm-help-theme-icon-dark');
  function apply(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    var dark = theme === 'dark';
    btn.setAttribute('aria-pressed', String(dark));
    btn.setAttribute('aria-label', dark ? 'Zum Light-Mode wechseln' : 'Zum Dark-Mode wechseln');
    btn.setAttribute('title', dark ? 'Zum Light-Mode wechseln' : 'Zum Dark-Mode wechseln');
    // Im Dark-Mode den Mond zeigen, im Light den Sonnen-Icon (analog Frontend).
    if (iconLight) iconLight.hidden = dark;
    if (iconDark)  iconDark.hidden  = !dark;
  }
  // Initial-Sync: das Pre-Hydration-Script hat data-theme schon gesetzt; wir
  // lesen nur den Status und schalten die Icons entsprechend.
  apply(document.documentElement.getAttribute('data-theme') === 'dark' ? 'dark' : 'light');
  btn.addEventListener('click', function(){
    var next = document.documentElement.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('fm-help-theme', next); } catch(e) {}
    apply(next);
  });
})();
</script>
`.trim();
}

/**
 * Mini-Escape für plain text in Header-Title o.ä. — vermeidet HTML-Injection
 * bei dynamisch eingesetzten Strings. Die anderen Templates dieses Moduls
 * arbeiten mit fixen Strings; `escapeText` ist explizit nur für Caller-Daten.
 */
function escapeText(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * Extrahiert ein eingebettetes HTML-Fragment für /embed-Endpoints.
 * Nutzt `optimizeBody()` für die einheitliche Filter-/Rewrite-Pipeline.
 */
function extractEmbed(htmlEntry) {
  if (!htmlEntry) return null;
  const { html, lang } = htmlEntry;
  const bodyMatch = html.match(/<body[^>]*>([\s\S]*?)<\/body>/i);
  const body = bodyMatch ? bodyMatch[1] : html;
  return optimizeBody(body, lang);
}

function clearCache() {
  htmlCache.clear();
  manifest = null;
  manifestLangs = new Set();
  slugInventory.clear();
}

module.exports = {
  getManifest,
  hasMirrorForLang,
  getFallbackLang,
  htmlPath,
  readHtml,
  resolveHtml,
  hasAnyHtml,
  getStatus,
  extractEmbed,
  optimizeHelpHtml,
  getSlugInventory,
  htmlRoot,
  clearCache,
  // Theme-Helfer für andere Doku-Endpunkte (MBS-Plugin etc.) — gleiches
  // Pre-Hydration + Dark-CSS + Header-Builder, damit alle Doc-Pages konsistent
  // aussehen. `buildHelpHeader` rendert die 1-zeilige Navigationsleiste mit
  // Title links und Theme-Toggle + optional Sprachauswahl rechts.
  buildThemeStyles,
  buildThemePreHydration,
  buildHelpHeader,
  buildLangSelect,
};
