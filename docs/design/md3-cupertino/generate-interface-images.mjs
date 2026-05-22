// @ts-check
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/** @typedef {{ x: number, y: number, width: number, height: number }} CropBox */
/** @typedef {{ title: string, note: string }} VariantCopy */
/** @typedef {{ section: string, surface: string, primary: string, file: string, secondary: string, secondaryFile: string, defaultChoice: "A" | "B" | "C" }} Surface */
/** @typedef {{ slug: string, files: Record<"A" | "B" | "C", string> } & Surface} ManifestSurface */

const __dirname = dirname(fileURLToPath(import.meta.url));
const outputDir = join(__dirname, "interface-images");

/** @type {Record<"A" | "B" | "C", CropBox>} */
const cropBoxes = {
  A: { x: 38, y: 108, width: 360, height: 628 },
  B: { x: 450, y: 108, width: 360, height: 628 },
  C: { x: 862, y: 108, width: 360, height: 628 }
};

/** @type {Record<string, string>} */
const boardLabels = {
  "01": "Home and navigation",
  "02": "Reader shelf",
  "03": "Dictionary",
  "04": "Hoshi reader",
  "05": "Settings",
  "06": "Import and modals",
  "07": "Creator and Anki",
  "08": "Collections and stats",
  "09": "System and debug",
  "10": "Dictionary management",
  "11": "Reader customization",
  "12": "Media and sentence dialogs",
  "13": "Tags and filters",
  "14": "Profile, language, system",
  "15": "Logs and debug",
  "16": "Empty, loading, error states",
  "18": "Component system"
};

/** @type {Record<string, Record<"A" | "B" | "C", VariantCopy>>} */
const variantCopy = {
  "01": {
    A: { title: "Quiet MD3", note: "Stable Android shell, clear bottom destinations, visible action structure." },
    B: { title: "Cupertino Calm", note: "Large title, lighter chrome, reading-app quietness." },
    C: { title: "Adaptive Workspace", note: "Navigation rail and desktop/tablet structure while preserving mobile tabs." }
  },
  "02": {
    A: { title: "Library Grid/List", note: "Best default for book browsing and selection states." },
    B: { title: "Reading-First Shelf", note: "Calmer shelf with recent reading emphasis." },
    C: { title: "Management Workspace", note: "Denser library operations for tags, import, and batch work." }
  },
  "03": {
    A: { title: "Fast MD3 Search", note: "Search-centric layout for quick lookup." },
    B: { title: "Readable Results", note: "Calm result browsing that avoids input-focus noise." },
    C: { title: "Power Split View", note: "Dense lookup workspace for history, details, and panels." }
  },
  "04": {
    A: { title: "Paper Chrome", note: "Visible but quiet reading controls." },
    B: { title: "Immersive Glass", note: "Content-first reader with floating controls only when needed." },
    C: { title: "Lyrics and Lookup", note: "Audiobook-heavy layout with cue list and dictionary panel." }
  },
  "05": {
    A: { title: "MD3 Settings List", note: "Straightforward settings sections with Android-native structure." },
    B: { title: "Grouped Cupertino Settings", note: "Lower-noise grouped rows for preference-heavy screens." },
    C: { title: "Settings Console", note: "Desktop-friendly settings and diagnostics layout." }
  },
  "06": {
    A: { title: "Step Flow", note: "Clear MD3 import steps for file-heavy workflows." },
    B: { title: "Sheet Flow", note: "Lightweight Cupertino sheet interaction." },
    C: { title: "Import Inspector", note: "Detailed status and logs for complex import paths." }
  },
  "07": {
    A: { title: "Simple Field Form", note: "Clean direct form for card creation." },
    B: { title: "Guided Creator", note: "Stepwise mining flow with more guardrails." },
    C: { title: "Mapping Panel", note: "Power-user layout for fields, preview, and mapping." }
  },
  "08": {
    A: { title: "Scannable Lists", note: "Lists and stats remain efficient and boring." },
    B: { title: "Media Gallery", note: "More visual layout for illustrations and saved media." },
    C: { title: "Analytics Workspace", note: "Dense metrics and comparison layout." }
  },
  "09": {
    A: { title: "Plain System Settings", note: "Simple utility surfaces." },
    B: { title: "Grouped Profile Feel", note: "Profile and system items grouped more calmly." },
    C: { title: "Debug Console", note: "Operational layout for logs, websocket, and system status." }
  },
  "10": {
    A: { title: "Inventory List", note: "Installed dictionaries as a direct MD3 list." },
    B: { title: "Dictionary Inspector", note: "Grouped details with clearer dictionary metadata." },
    C: { title: "Admin Workspace", note: "Table/details/log structure for heavy dictionary work." }
  },
  "11": {
    A: { title: "Controls First", note: "Sliders and switches up front." },
    B: { title: "Preview Studio", note: "Persistent reader preview with grouped controls." },
    C: { title: "Theme Editor", note: "Split CSS/theme editing workspace." }
  },
  "12": {
    A: { title: "Action Sheet", note: "Mobile-safe media actions." },
    B: { title: "Modal Stack", note: "Nested sentence/media inspection." },
    C: { title: "Bottom Workspace", note: "Persistent panel for repeated sentence work." }
  },
  "13": {
    A: { title: "Chip Console", note: "Fast filter chips and simple tag selection." },
    B: { title: "Grouped Tag Manager", note: "Settings-like tag management." },
    C: { title: "Batch Editor", note: "Library-scale tag assignment and cleanup." }
  },
  "14": {
    A: { title: "Settings Hub", note: "Discoverable profile, language, system controls." },
    B: { title: "Account-Like Profiles", note: "Cupertino profile-management rhythm." },
    C: { title: "Utility Console", note: "Compact power-user system surface." }
  },
  "15": {
    A: { title: "Plain Log Viewer", note: "Direct readable logs." },
    B: { title: "Error Inbox", note: "Grouped errors and status cards." },
    C: { title: "Diagnostics Split", note: "Dense diagnostic workspace." }
  },
  "16": {
    A: { title: "Actionable Empty", note: "Short copy with one clear next action." },
    B: { title: "Quiet Skeletons", note: "Low-noise loading and placeholders." },
    C: { title: "Recoverable Error", note: "Error state with visible recovery path." }
  },
  "18": {
    A: { title: "MD3 Token Kit", note: "Standard MD3 components with strict tokens." },
    B: { title: "Cupertino Surface Kit", note: "Grouped rows and translucent accessory surfaces." },
    C: { title: "Hybrid Density Kit", note: "Compact shared grammar for power-user pages." }
  }
};

/**
 * @param {string} value
 * @returns {string}
 */
function escapeXml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * @param {string} value
 * @returns {string}
 */
function escapeHtml(value) {
  return escapeXml(value).replaceAll("'", "&#39;");
}

/**
 * @param {string} surface
 * @returns {string}
 */
function slugifySurface(surface) {
  return surface.replace(/\.dart$/u, "").replace(/[^a-zA-Z0-9]+/gu, "-").replace(/^-|-$/gu, "").toLowerCase();
}

/**
 * @param {string} value
 * @param {number} maxLength
 * @returns {string[]}
 */
function wrapText(value, maxLength) {
  const words = value.split(/\s+/u);
  /** @type {string[]} */
  const lines = [];
  let line = "";

  /**
   * @param {string} word
   * @returns {string[]}
   */
  function splitLongWord(word) {
    if (word.length <= maxLength) {
      return [word];
    }

    /** @type {string[]} */
    const chunks = [];
    for (let index = 0; index < word.length; index += maxLength) {
      chunks.push(word.slice(index, index + maxLength));
    }
    return chunks;
  }

  for (const word of words) {
    for (const chunk of splitLongWord(word)) {
      if (!line) {
        line = chunk;
      } else if (`${line} ${chunk}`.length <= maxLength) {
        line = `${line} ${chunk}`;
      } else {
        lines.push(line);
        line = chunk;
      }
    }
  }

  if (line) {
    lines.push(line);
  }

  return lines.length > 0 ? lines : [value];
}

/**
 * @param {string[]} lines
 * @param {{ x: number, y: number, fill: string, size: number, weight?: string, lineHeight: number }} options
 * @returns {string}
 */
function renderTextLines(lines, options) {
  return lines.map((line, index) => {
    const y = options.y + index * options.lineHeight;
    const weight = options.weight ? ` font-weight="${options.weight}"` : "";
    return `<text x="${options.x}" y="${y}" fill="${options.fill}" font-family="Inter, Segoe UI, system-ui, sans-serif" font-size="${options.size}"${weight}>${escapeXml(line)}</text>`;
  }).join("\n  ");
}

/**
 * @param {string} html
 * @returns {Surface[]}
 */
function parseSurfaces(html) {
  const regex = /\{ section: "([^"]+)", surface: "([^"]+)", primary: "([^"]+)", file: "([^"]+)", secondary: "([^"]+)", secondaryFile: "([^"]+)", defaultChoice: "([ABC])" \}/gu;
  /** @type {Surface[]} */
  const surfaces = [];
  for (const match of html.matchAll(regex)) {
    surfaces.push({
      section: match[1],
      surface: match[2],
      primary: match[3],
      file: match[4],
      secondary: match[5],
      secondaryFile: match[6],
      /** @type {"A" | "B" | "C"} */
      defaultChoice: match[7]
    });
  }
  return surfaces;
}

/**
 * @param {Surface[]} surfaces
 * @returns {void}
 */
function assertSurfaceData(surfaces) {
  if (surfaces.length !== 84) {
    throw new Error(`Expected 84 surfaces, got ${surfaces.length}.`);
  }

  const seen = new Set();
  for (const surface of surfaces) {
    if (seen.has(surface.surface)) {
      throw new Error(`Duplicate surface: ${surface.surface}.`);
    }
    seen.add(surface.surface);
    if (!boardLabels[surface.primary]) {
      throw new Error(`Unknown primary board ${surface.primary} for ${surface.surface}.`);
    }
    if (!boardLabels[surface.secondary]) {
      throw new Error(`Unknown secondary board ${surface.secondary} for ${surface.surface}.`);
    }
    if (!variantCopy[surface.primary]) {
      throw new Error(`Missing variant copy for ${surface.primary}.`);
    }
  }
}

/**
 * @param {Surface} surface
 * @param {"A" | "B" | "C"} choice
 * @returns {string}
 */
function renderVariantSvg(surface, choice) {
  const crop = cropBoxes[choice];
  const copy = variantCopy[surface.primary][choice];
  const isDefault = choice === surface.defaultChoice;
  const titleId = `${slugifySurface(surface.surface)}-${choice}-title`;
  const descId = `${slugifySurface(surface.surface)}-${choice}-desc`;
  const board = boardLabels[surface.primary];
  const secondary = boardLabels[surface.secondary];
  const surfaceLines = wrapText(surface.surface, 34);
  const noteLines = wrapText(copy.note, 58).slice(0, 2);
  const titleY = surfaceLines.length > 1 ? 52 : 58;
  const metaY = surfaceLines.length > 1 ? 98 : 86;
  const pillY = surfaceLines.length > 1 ? 118 : 106;
  const variantTitleY = surfaceLines.length > 1 ? 139 : 127;
  const noteY = surfaceLines.length > 1 ? 170 : 158;
  const cropY = surfaceLines.length > 1 ? 202 : 184;
  const cropHeight = surfaceLines.length > 1 ? 644 : 680;

  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="520" height="900" viewBox="0 0 520 900" role="img" aria-labelledby="${titleId} ${descId}">
  <title id="${titleId}">${escapeXml(surface.surface)} ${choice} design option</title>
  <desc id="${descId}">${escapeXml(copy.title)} option for ${escapeXml(surface.surface)}. Primary board: ${escapeXml(board)}. Secondary support: ${escapeXml(secondary)}.</desc>
  <rect width="520" height="900" fill="#f6f7f4"/>
  <rect x="22" y="22" width="476" height="856" rx="18" fill="#ffffff" stroke="#dfe5e1"/>
  ${renderTextLines(surfaceLines, { x: 44, y: titleY, fill: "#172126", size: 22, weight: "800", lineHeight: 24 })}
  <text x="44" y="${metaY}" fill="#66747c" font-family="Inter, Segoe UI, system-ui, sans-serif" font-size="14">${escapeXml(surface.section)} / ${escapeXml(board)}</text>
  <rect x="44" y="${pillY}" width="76" height="32" rx="16" fill="${isDefault ? "#d6e9e7" : "#eef2ef"}" stroke="${isDefault ? "#214f5f" : "#dfe5e1"}"/>
  <text x="82" y="${pillY + 21}" text-anchor="middle" fill="#214f5f" font-family="Inter, Segoe UI, system-ui, sans-serif" font-size="15" font-weight="800">${choice}${isDefault ? " default" : ""}</text>
  <text x="134" y="${variantTitleY}" fill="#172126" font-family="Inter, Segoe UI, system-ui, sans-serif" font-size="16" font-weight="800">${escapeXml(copy.title)}</text>
  ${renderTextLines(noteLines, { x: 44, y: noteY, fill: "#66747c", size: 13, lineHeight: 17 })}
  <svg x="65" y="${cropY}" width="390" height="${cropHeight}" viewBox="${crop.x} ${crop.y} ${crop.width} ${crop.height}" preserveAspectRatio="xMidYMid meet">
    <image href="../${escapeXml(surface.file)}" x="0" y="0" width="1260" height="760"/>
  </svg>
  <rect x="44" y="832" width="432" height="28" rx="14" fill="#fbfcf7" stroke="#dfe5e1"/>
  <text x="260" y="851" text-anchor="middle" fill="#66747c" font-family="Inter, Segoe UI, system-ui, sans-serif" font-size="12">Supports ${escapeXml(secondary)} via ${escapeXml(surface.secondaryFile)}</text>
</svg>
`;
}

/**
 * @param {ManifestSurface[]} manifestSurfaces
 * @returns {string}
 */
function renderIndexHtml(manifestSurfaces) {
  const cards = manifestSurfaces.map((surface, index) => {
    const board = boardLabels[surface.primary];
    const secondary = boardLabels[surface.secondary];
    const variants = /** @type {("A" | "B" | "C")[]} */ (["A", "B", "C"]).map((choice) => {
      const copy = variantCopy[surface.primary][choice];
      return `
          <figure class="variant" data-choice="${choice}" aria-pressed="false">
            <button type="button" aria-label="Pick ${choice} for ${escapeHtml(surface.surface)}">
              <img src="${escapeHtml(surface.files[choice])}" alt="${escapeHtml(surface.surface)} ${choice} ${escapeHtml(copy.title)}">
              <figcaption><strong>${choice}. ${escapeHtml(copy.title)}</strong><span>${choice === surface.defaultChoice ? "default" : "option"}</span></figcaption>
            </button>
            <a class="image-link" href="${escapeHtml(surface.files[choice])}">Open image</a>
          </figure>`;
    }).join("");

    return `
      <article class="surface-card" data-index="${index}" data-active="false" data-surface="${escapeHtml(surface.surface)}" data-section="${escapeHtml(surface.section)}" data-default="${surface.defaultChoice}" data-primary="${escapeHtml(board)}" data-secondary="${escapeHtml(secondary)}" data-search="${escapeHtml(`${surface.surface} ${surface.section} ${board} ${secondary}`.toLowerCase())}">
        <header>
          <div>
            <h2>${escapeHtml(surface.surface)}</h2>
            <p>${escapeHtml(surface.section)} / Primary: ${escapeHtml(board)} / Supports: ${escapeHtml(secondary)}</p>
          </div>
          <span class="pill">Default ${surface.defaultChoice}</span>
        </header>
        <div class="variants">${variants}
        </div>
      </article>`;
  }).join("");

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hibiki Interface Images</title>
  <style>
    :root {
      color-scheme: light;
      --bg: #f6f7f4;
      --panel: #ffffff;
      --ink: #172126;
      --muted: #66747c;
      --line: #dfe5e1;
      --brand: #214f5f;
      --brand-soft: #d6e9e7;
      --shadow: 0 18px 44px rgba(23, 33, 38, 0.08);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font-family: Inter, "Segoe UI", system-ui, sans-serif;
      letter-spacing: 0;
    }

    header.top {
      position: sticky;
      top: 0;
      z-index: 2;
      border-bottom: 1px solid var(--line);
      background: rgba(246, 247, 244, 0.94);
      backdrop-filter: blur(18px);
    }

    .bar, main {
      max-width: 1320px;
      margin: 0 auto;
      padding: 18px 22px;
    }

    .bar {
      display: flex;
      gap: 16px;
      align-items: center;
      justify-content: space-between;
    }

    h1, h2, p { margin: 0; }
    h1 { font-size: 28px; line-height: 1.1; }
    h2 { font-size: 18px; line-height: 1.2; }
    p { color: var(--muted); font-size: 13px; line-height: 1.5; }
    a { color: var(--brand); font-weight: 800; text-decoration: none; }

    .nav, .filters, .pick-actions, .review-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      justify-content: flex-end;
    }

    .nav a, .filters button, .pick-actions button, .review-actions button, .pill, .image-link {
      display: inline-flex;
      align-items: center;
      min-height: 32px;
      padding: 0 10px;
      border: 1px solid var(--line);
      border-radius: 16px;
      background: var(--panel);
      color: var(--brand);
      font-size: 12px;
      font-weight: 800;
      white-space: nowrap;
    }

    .filters, .pick-actions, .review-actions {
      justify-content: flex-start;
      margin: 16px 0;
    }

    .filters button, .pick-actions button, .review-actions button {
      cursor: pointer;
    }

    .filters button[aria-pressed="true"], .pick-actions button[aria-pressed="true"], .review-actions button[aria-pressed="true"] {
      border-color: var(--brand);
      background: var(--brand-soft);
      box-shadow: inset 0 0 0 1px var(--brand);
    }

    .search {
      flex: 1 1 280px;
      min-height: 34px;
      padding: 0 12px;
      border: 1px solid var(--line);
      border-radius: 17px;
      color: var(--ink);
      font: inherit;
    }

    .summary, .surface-card, .copy-panel {
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--panel);
      box-shadow: var(--shadow);
    }

    .summary {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 20px;
      align-items: center;
      padding: 18px;
    }

    .counts {
      display: grid;
      grid-template-columns: repeat(3, minmax(90px, 1fr));
      gap: 8px;
    }

    .count {
      padding: 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fbfcf7;
    }

    .count strong {
      display: block;
      color: var(--brand);
      font-size: 24px;
      line-height: 1;
    }

    .copy-panel {
      margin-top: 16px;
      padding: 14px;
    }

    .output {
      display: block;
      width: 100%;
      min-height: 150px;
      margin-top: 10px;
      padding: 12px;
      resize: vertical;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #172126;
      color: #d8f2e6;
      font: 12px/1.55 Consolas, "SFMono-Regular", monospace;
      letter-spacing: 0;
    }

    .status {
      color: var(--muted);
      font-size: 13px;
      font-weight: 700;
    }

    .gallery {
      display: grid;
      gap: 18px;
      margin-top: 18px;
    }

    .surface-card {
      overflow: hidden;
      scroll-margin-top: 96px;
    }

    .surface-card[data-active="true"] {
      border-color: var(--brand);
      box-shadow: 0 20px 54px rgba(33, 79, 95, 0.18);
    }

    .surface-card > header {
      display: flex;
      gap: 12px;
      align-items: flex-start;
      justify-content: space-between;
      padding: 16px 18px;
      border-bottom: 1px solid var(--line);
    }

    .variants {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 14px;
      padding: 14px;
      background: #eef2ef;
    }

    .variant {
      margin: 0;
      overflow: hidden;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
    }

    .variant[aria-pressed="true"] {
      border-color: var(--brand);
      box-shadow: inset 0 0 0 2px var(--brand);
    }

    .variant button {
      display: block;
      width: 100%;
      padding: 0;
      border: 0;
      background: transparent;
      color: inherit;
      cursor: pointer;
      text-align: left;
      font: inherit;
      letter-spacing: 0;
    }

    .variant img {
      display: block;
      width: 100%;
      height: auto;
      background: #f6f7f4;
    }

    figcaption {
      display: flex;
      gap: 8px;
      align-items: center;
      justify-content: space-between;
      padding: 10px 12px;
      border-top: 1px solid var(--line);
      color: var(--muted);
      font-size: 12px;
    }

    .variant[aria-pressed="true"] figcaption {
      background: var(--brand-soft);
    }

    figcaption strong {
      color: var(--ink);
    }

    .image-link {
      justify-content: center;
      width: calc(100% - 20px);
      margin: 0 10px 10px;
      min-height: 30px;
      background: #fbfcf7;
    }

    .hidden { display: none; }

    @media (max-width: 980px) {
      .bar, .summary { display: block; }
      .nav, .counts { justify-content: flex-start; margin-top: 12px; }
      .variants { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <header class="top">
    <div class="bar">
      <div>
        <h1>Hibiki Interface Images</h1>
        <p>Standalone A/B/C image files for every mapped UI surface.</p>
      </div>
      <nav class="nav" aria-label="Design navigation">
        <a href="../gallery.html">Main picker</a>
        <a href="../interface-gallery.html">Interface gallery</a>
        <a href="../INTERFACE_PICKS.md">Interface picks</a>
      </nav>
    </div>
  </header>
  <main>
    <section class="summary" aria-label="Image pack summary">
      <div>
        <h2>One interface, three concrete images</h2>
        <p>These files are generated from the same board mappings as the picker. Pick one image per interface, use the review queue to move through every surface, then copy the result.</p>
      </div>
      <div class="counts">
        <div class="count"><strong>84</strong><p>UI surfaces</p></div>
        <div class="count"><strong>252</strong><p>image files</p></div>
        <div class="count"><strong>3</strong><p>choices each</p></div>
      </div>
    </section>
    <section class="filters" aria-label="Interface filters">
      <button type="button" data-section="all" aria-pressed="true">All</button>
      <button type="button" data-section="Entry" aria-pressed="false">Entry</button>
      <button type="button" data-section="Pages" aria-pressed="false">Pages</button>
      <button type="button" data-section="Shared/support" aria-pressed="false">Shared/support</button>
      <input class="search" id="search" type="search" placeholder="Filter surfaces or boards" aria-label="Filter surfaces or boards">
    </section>
    <section class="copy-panel" aria-label="Generated picks">
      <div class="review-actions" aria-label="Review queue controls">
        <button type="button" id="previous-surface">Previous surface</button>
        <button type="button" id="next-surface">Next surface</button>
        <button type="button" id="next-unpicked">Next unpicked</button>
        <button type="button" id="only-unpicked" aria-pressed="false">Only unpicked</button>
        <span class="status" id="review-status">Review queue ready.</span>
      </div>
      <div class="pick-actions">
        <button type="button" id="use-defaults">Use defaults</button>
        <button type="button" id="clear-picks">Clear picks</button>
        <button type="button" id="copy-picks">Copy result</button>
        <span class="status" id="status">No picks yet.</span>
      </div>
      <textarea class="output" id="output" readonly aria-label="Generated image picks"></textarea>
    </section>
    <section class="gallery" id="gallery" aria-label="Generated interface images">${cards}
    </section>
  </main>
  <script>
    (() => {
      const storageKey = "hibiki-md3-cupertino-interface-image-picks";
      const search = document.getElementById("search");
      const output = document.getElementById("output");
      const status = document.getElementById("status");
      const reviewStatus = document.getElementById("review-status");
      const onlyUnpickedButton = document.getElementById("only-unpicked");
      let activeSection = "all";
      let activeIndex = 0;
      let onlyUnpicked = false;
      let picks = loadPicks();

      function loadPicks() {
        try {
          return JSON.parse(window.localStorage.getItem(storageKey) || "{}");
        } catch (_error) {
          return {};
        }
      }

      function savePicks() {
        try {
          window.localStorage.setItem(storageKey, JSON.stringify(picks));
        } catch (_error) {
          status.textContent = "Could not save choices in this browser.";
        }
      }

      function selectedChoice(card) {
        return picks[card.dataset.surface] || card.dataset.default;
      }

      function surfaceCards() {
        return Array.from(document.querySelectorAll(".surface-card"));
      }

      function explicitPicked(card) {
        return Boolean(picks[card.dataset.surface]);
      }

      function visibleCards() {
        return surfaceCards().filter((card) => !card.classList.contains("hidden"));
      }

      function updateOutput() {
        const cards = surfaceCards();
        const chosen = cards.filter((card) => Boolean(picks[card.dataset.surface])).length;
        const lines = cards.map((card) => {
          const choice = selectedChoice(card);
          return \`\${card.dataset.surface}: \${choice} (\${card.dataset.primary}; supports \${card.dataset.secondary})\`;
        });
        output.value = \`Interface image picks:\\n\${lines.join("\\n")}\\nNotes:\`;
        status.textContent = \`\${chosen} explicit picks / \${cards.length} surfaces. Defaults fill the rest.\`;
      }

      function updateCards() {
        surfaceCards().forEach((card) => {
          const selected = selectedChoice(card);
          card.dataset.active = String(Number(card.dataset.index) === activeIndex);
          card.querySelectorAll(".variant").forEach((variant) => {
            variant.setAttribute("aria-pressed", String(variant.dataset.choice === selected));
          });
        });
        updateReviewStatus();
      }

      function setPick(card, choice) {
        picks = { ...picks, [card.dataset.surface]: choice };
        savePicks();
        applyFilters({ keepFocus: true });
        updateCards();
        updateOutput();
      }

      function surfaceMatchesFilter(card, query) {
        const sectionMatch = activeSection === "all" || card.dataset.section === activeSection;
        const searchMatch = !query || card.dataset.search.includes(query);
        const unpickedMatch = !onlyUnpicked || !explicitPicked(card);
        return sectionMatch && searchMatch && unpickedMatch;
      }

      function focusCard(index, options = {}) {
        const cards = surfaceCards();
        if (!cards.length) {
          return;
        }

        const clamped = Math.max(0, Math.min(cards.length - 1, index));
        activeIndex = clamped;
        updateCards();

        if (options.scroll !== false) {
          cards[activeIndex].scrollIntoView({ behavior: options.smooth ? "smooth" : "auto", block: "start" });
        }
      }

      function focusFirstVisible() {
        const firstVisible = visibleCards()[0];
        if (!firstVisible) {
          updateReviewStatus();
          return;
        }

        const index = Number(firstVisible.dataset.index);
        if (Number.isFinite(index) && index !== activeIndex) {
          focusCard(index, { scroll: false });
          return;
        }

        updateCards();
      }

      function focusNearestVisible(startIndex) {
        const cards = surfaceCards();
        for (let step = 0; step < cards.length; step += 1) {
          const candidate = cards[(startIndex + step) % cards.length];
          if (!candidate.classList.contains("hidden")) {
            focusCard(Number(candidate.dataset.index), { scroll: false });
            return;
          }
        }

        updateReviewStatus();
      }

      function nextVisible(delta) {
        const cards = visibleCards();
        if (!cards.length) {
          updateReviewStatus();
          return;
        }

        const currentVisibleIndex = Math.max(0, cards.findIndex((card) => Number(card.dataset.index) === activeIndex));
        const nextIndex = (currentVisibleIndex + delta + cards.length) % cards.length;
        focusCard(Number(cards[nextIndex].dataset.index), { smooth: true });
      }

      function nextUnpicked() {
        const cards = surfaceCards();
        if (!cards.length) {
          updateReviewStatus();
          return;
        }

        for (let step = 1; step <= cards.length; step += 1) {
          const candidate = cards[(activeIndex + step) % cards.length];
          if (!explicitPicked(candidate) && !candidate.classList.contains("hidden")) {
            focusCard(Number(candidate.dataset.index), { smooth: true });
            return;
          }
        }

        reviewStatus.textContent = "No unpicked surfaces are visible under the current filters.";
      }

      function updateReviewStatus() {
        const cards = surfaceCards();
        const visible = visibleCards();
        const activeCard = cards[activeIndex];
        const picked = cards.filter(explicitPicked).length;
        const visiblePicked = visible.filter(explicitPicked).length;
        if (!activeCard) {
          reviewStatus.textContent = "No surfaces available.";
          return;
        }

        const visiblePosition = visible.findIndex((card) => Number(card.dataset.index) === activeIndex) + 1;
        const queuePosition = visiblePosition > 0 ? \`\${visiblePosition} / \${visible.length} visible\` : "outside current filter";
        reviewStatus.textContent = \`Reviewing \${Number(activeCard.dataset.index) + 1} / \${cards.length}: \${activeCard.dataset.surface} (\${queuePosition}; \${visiblePicked} / \${visible.length} visible picked; \${picked} / \${cards.length} total picked).\`;
      }

      function applyFilters(options = {}) {
        const query = search.value.trim().toLowerCase();
        surfaceCards().forEach((card) => {
          card.classList.toggle("hidden", !surfaceMatchesFilter(card, query));
        });
        onlyUnpickedButton.setAttribute("aria-pressed", String(onlyUnpicked));
        if (!options.keepFocus) {
          focusFirstVisible();
          return;
        }
        if (surfaceCards()[activeIndex]?.classList.contains("hidden")) {
          focusNearestVisible(activeIndex);
          return;
        }
        updateCards();
      }

      document.querySelectorAll("[data-section]").forEach((button) => {
        button.addEventListener("click", () => {
          activeSection = button.dataset.section;
          document.querySelectorAll("[data-section]").forEach((candidate) => {
            candidate.setAttribute("aria-pressed", String(candidate === button));
          });
          applyFilters();
        });
      });

      search.addEventListener("input", applyFilters);

      document.getElementById("previous-surface").addEventListener("click", () => nextVisible(-1));

      document.getElementById("next-surface").addEventListener("click", () => nextVisible(1));

      document.getElementById("next-unpicked").addEventListener("click", nextUnpicked);

      onlyUnpickedButton.addEventListener("click", () => {
        onlyUnpicked = !onlyUnpicked;
        applyFilters();
      });

      surfaceCards().forEach((card) => {
        card.querySelectorAll(".variant button").forEach((button) => {
          button.addEventListener("click", () => setPick(card, button.closest(".variant").dataset.choice));
        });
      });

      document.getElementById("use-defaults").addEventListener("click", () => {
        picks = {};
        surfaceCards().forEach((card) => {
          picks[card.dataset.surface] = card.dataset.default;
        });
        savePicks();
        applyFilters({ keepFocus: true });
        updateCards();
        updateOutput();
      });

      document.getElementById("clear-picks").addEventListener("click", () => {
        picks = {};
        savePicks();
        applyFilters({ keepFocus: true });
        updateCards();
        updateOutput();
      });

      document.getElementById("copy-picks").addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(output.value);
          status.textContent = "Copied image picks.";
        } catch (_error) {
          status.textContent = "Clipboard unavailable; select and copy the text manually.";
        }
      });

      applyFilters({ keepFocus: true });
      updateOutput();
    })();
  </script>
</body>
</html>
`;
}

/**
 * @returns {Promise<void>}
 */
async function main() {
  const galleryHtml = await readFile(join(__dirname, "interface-gallery.html"), "utf8");
  const surfaces = parseSurfaces(galleryHtml);
  assertSurfaceData(surfaces);

  const relativeOutput = relative(__dirname, outputDir);
  if (relativeOutput !== "interface-images") {
    throw new Error(`Refusing to write outside expected output directory: ${outputDir}`);
  }

  await rm(outputDir, { recursive: true, force: true });
  await mkdir(outputDir, { recursive: true });

  /** @type {ManifestSurface[]} */
  const manifestSurfaces = [];
  for (const surface of surfaces) {
    const slug = slugifySurface(surface.surface);
    /** @type {Record<"A" | "B" | "C", string>} */
    const files = { A: `${slug}-A.svg`, B: `${slug}-B.svg`, C: `${slug}-C.svg` };
    for (const choice of /** @type {("A" | "B" | "C")[]} */ (["A", "B", "C"])) {
      await writeFile(join(outputDir, files[choice]), renderVariantSvg(surface, choice), "utf8");
    }
    manifestSurfaces.push({ ...surface, slug, files });
  }

  await writeFile(join(outputDir, "index.html"), renderIndexHtml(manifestSurfaces), "utf8");
  await writeFile(join(outputDir, "manifest.json"), `${JSON.stringify({ generatedFrom: "interface-gallery.html", surfaces: manifestSurfaces }, null, 2)}\n`, "utf8");
  await writeFile(join(outputDir, "README.md"), renderReadme(), "utf8");

  console.log(`Generated ${manifestSurfaces.length * 3} interface images for ${manifestSurfaces.length} surfaces.`);
}

/**
 * @returns {string}
 */
function renderReadme() {
  return `# Hibiki interface image pack

This folder contains generated A/B/C image choices for every mapped MD3 + Cupertino UI surface.

- \`index.html\` shows all 84 surfaces with three standalone images each, saves picks in the browser, and copies a complete \`Interface image picks\` result.
- The \`index.html\` review queue can step to the previous surface, next surface, next unpicked surface, or filter down to only unpicked surfaces.
- \`manifest.json\` records the surface-to-file mapping.
- \`*-A.svg\`, \`*-B.svg\`, and \`*-C.svg\` are the direct image choices.

Regenerate from the design folder with:

\`\`\`powershell
node .\\generate-interface-images.mjs
\`\`\`

The generator reads \`interface-gallery.html\`, so the gallery remains the source of truth for surface mappings and defaults.
`;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
