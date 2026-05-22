// @ts-check
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/** @typedef {"A" | "B" | "C"} Choice */
/** @typedef {{ section: string, surface: string, primary: string, file: string, secondary: string, secondaryFile: string, defaultChoice: Choice, slug: string, files: Record<Choice, string> }} ManifestSurface */
/** @typedef {{ label: string, summary: string, bestFor: string, tradeoff: string, choices: Record<string, Choice>, notes: string[] }} DesignPack */
/** @typedef {{ surface: string, label: string }} PreviewSurface */

const __dirname = dirname(fileURLToPath(import.meta.url));
const manifestPath = join(__dirname, "interface-images", "manifest.json");
const packsPath = join(__dirname, "design-packs.json");
const outputPath = join(__dirname, "design-pack-gallery.html");
const boardOrder = ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12", "13", "14", "15", "16", "18"];

/** @type {Record<string, string>} */
const boardLabels = {
  "01": "Shell",
  "02": "Shelf",
  "03": "Dictionary",
  "04": "Reader",
  "05": "Settings",
  "06": "Import",
  "07": "Creator",
  "08": "Collections",
  "09": "System",
  "10": "Dictionaries",
  "11": "Reader setup",
  "12": "Media",
  "13": "Tags",
  "14": "Profile",
  "15": "Logs",
  "16": "States",
  "18": "Components"
};

/** @type {PreviewSurface[]} */
const previewSurfaces = [
  { surface: "home_page.dart", label: "Home shell" },
  { surface: "reader_hoshi_page.dart", label: "Hoshi reader" },
  { surface: "home_dictionary_page.dart", label: "Dictionary home" },
  { surface: "dictionary_result_page.dart", label: "Result browser" },
  { surface: "dictionary_dialog_page.dart", label: "Dictionary admin" },
  { surface: "display_settings_page.dart", label: "Display settings" },
  { surface: "custom_theme_page.dart", label: "Theme studio" },
  { surface: "anki_settings_page.dart", label: "Anki mapping" },
  { surface: "collections_page.dart", label: "Collections" },
  { surface: "tag_management_page.dart", label: "Tags" },
  { surface: "debug_log_page.dart", label: "Debug log" },
  { surface: "base_tab_page.dart", label: "Shared shell" }
];

/**
 * @param {string} value
 * @returns {string}
 */
function escapeHtml(value) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

/**
 * @param {unknown} value
 * @returns {value is Choice}
 */
function isChoice(value) {
  return value === "A" || value === "B" || value === "C";
}

/**
 * @param {Record<string, DesignPack>} packs
 * @returns {void}
 */
function validatePacks(packs) {
  for (const [packId, pack] of Object.entries(packs)) {
    if (!pack.label || !pack.summary || !pack.bestFor || !pack.tradeoff || !Array.isArray(pack.notes)) {
      throw new Error(`Invalid design pack shape: ${packId}`);
    }
    for (const boardId of boardOrder) {
      if (!isChoice(pack.choices?.[boardId])) {
        throw new Error(`Pack ${packId} has no valid choice for board ${boardId}.`);
      }
    }
  }
}

/**
 * @param {ManifestSurface[]} surfaces
 * @returns {Map<string, ManifestSurface>}
 */
function surfaceMap(surfaces) {
  return new Map(surfaces.map((surface) => [surface.surface, surface]));
}

/**
 * @param {DesignPack} pack
 * @returns {Record<Choice, number>}
 */
function choiceCounts(pack) {
  /** @type {Record<Choice, number>} */
  const counts = { A: 0, B: 0, C: 0 };
  for (const choice of Object.values(pack.choices)) {
    counts[choice] += 1;
  }
  return counts;
}

/**
 * @param {string} packId
 * @returns {string}
 */
function specCommand(packId) {
  return `node .\\generate-implementation-spec.mjs --pack ${packId} --output .\\IMPLEMENTATION_SPEC_DRAFT.md`;
}

/**
 * @param {DesignPack} pack
 * @returns {string}
 */
function renderBoardChips(pack) {
  return boardOrder.map((boardId) => {
    const choice = pack.choices[boardId];
    return `<span class="board-chip"><b>${boardId}</b><span>${escapeHtml(boardLabels[boardId])}</span><strong>${choice}</strong></span>`;
  }).join("\n");
}

/**
 * @param {DesignPack} pack
 * @param {Map<string, ManifestSurface>} surfaces
 * @returns {string}
 */
function renderPreviewGrid(pack, surfaces) {
  return previewSurfaces.map((preview) => {
    const surface = surfaces.get(preview.surface);
    if (!surface) {
      throw new Error(`Missing preview surface: ${preview.surface}`);
    }
    const choice = pack.choices[surface.primary];
    const imageFile = surface.files[choice];
    return `<figure class="preview-tile" data-choice="${choice}">
      <img src="interface-images/${escapeHtml(imageFile)}" alt="${escapeHtml(pack.label)} ${escapeHtml(preview.label)} ${choice}">
      <figcaption>
        <strong>${escapeHtml(preview.label)}</strong>
        <span>${choice} from board ${surface.primary}</span>
      </figcaption>
    </figure>`;
  }).join("\n");
}

/**
 * @param {string} packId
 * @param {DesignPack} pack
 * @param {Map<string, ManifestSurface>} surfaces
 * @returns {string}
 */
function renderPack(packId, pack, surfaces) {
  const counts = choiceCounts(pack);
  const recommended = packId === "hibiki-balanced" ? `\n      <span class="recommended">Recommended baseline</span>` : "";
  const notes = pack.notes.map((note) => `<li>${escapeHtml(note)}</li>`).join("\n");
  return `<section class="pack" id="${escapeHtml(packId)}" data-pack="${escapeHtml(packId)}">
    <div class="pack-header">
      <div>
        <p class="eyebrow">${escapeHtml(packId)}</p>
        <h2>${escapeHtml(pack.label)}</h2>
        <p class="summary">${escapeHtml(pack.summary)}</p>
      </div>${recommended}
    </div>
    <div class="pack-meta">
      <p><strong>Best fit</strong>${escapeHtml(pack.bestFor)}</p>
      <p><strong>Trade-off</strong>${escapeHtml(pack.tradeoff)}</p>
      <p><strong>Mix</strong>A ${counts.A} / B ${counts.B} / C ${counts.C}</p>
    </div>
    <div class="board-strip" aria-label="${escapeHtml(pack.label)} board choices">
      ${renderBoardChips(pack)}
    </div>
    <div class="command-row">
      <code>${escapeHtml(specCommand(packId))}</code>
      <button type="button" data-pack-command="${escapeHtml(packId)}">Use this pack</button>
    </div>
    <ul class="notes">
      ${notes}
    </ul>
    <div class="preview-grid" aria-label="${escapeHtml(pack.label)} representative surface images">
    ${renderPreviewGrid(pack, surfaces)}
    </div>
  </section>`;
}

/**
 * @param {Record<string, DesignPack>} packs
 * @param {ManifestSurface[]} surfaces
 * @returns {string}
 */
function renderHtml(packs, surfaces) {
  const surfacesByName = surfaceMap(surfaces);
  const packSections = Object.entries(packs).map(([packId, pack]) => renderPack(packId, pack, surfacesByName)).join("\n");
  const packTabs = Object.entries(packs).map(([packId, pack]) => `<a href="#${escapeHtml(packId)}">${escapeHtml(pack.label)}</a>`).join("\n");
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hibiki MD3 + Cupertino design pack gallery</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #1f2528;
      --muted: #637076;
      --line: #d7dddf;
      --page: #f6f8f4;
      --surface: #ffffff;
      --surface-2: #eef5f1;
      --accent: #2f6f61;
      --accent-2: #365f8d;
      --danger: #8a4a3a;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      background: var(--page);
      color: var(--ink);
    }

    header {
      background: #fcfdfb;
      border-bottom: 1px solid var(--line);
      padding: 28px clamp(18px, 5vw, 64px) 22px;
    }

    main {
      padding: 22px clamp(14px, 4vw, 54px) 44px;
    }

    h1,
    h2,
    p {
      margin: 0;
    }

    h1 {
      max-width: 820px;
      font-size: 3rem;
      line-height: 1.05;
      letter-spacing: 0;
    }

    h2 {
      font-size: 2rem;
      line-height: 1.1;
      letter-spacing: 0;
    }

    .lead {
      max-width: 920px;
      margin-top: 14px;
      color: var(--muted);
      font-size: 1rem;
      line-height: 1.65;
    }

    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      align-items: center;
      margin-top: 20px;
    }

    .toolbar a,
    button {
      min-height: 38px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--surface);
      color: var(--ink);
      font: inherit;
      font-weight: 700;
      text-decoration: none;
      padding: 9px 12px;
      cursor: pointer;
    }

    .toolbar a:hover,
    button:hover {
      border-color: var(--accent);
      color: var(--accent);
    }

    .selection {
      margin-top: 18px;
      padding: 14px 16px;
      border: 1px solid var(--line);
      background: var(--surface-2);
      display: grid;
      gap: 8px;
      max-width: 980px;
    }

    .selection code,
    .command-row code {
      display: block;
      overflow-wrap: anywhere;
      color: #243a45;
      font-size: 0.92rem;
    }

    .pack {
      margin-top: 24px;
      padding: clamp(18px, 3vw, 28px);
      border: 1px solid var(--line);
      border-radius: 0;
      background: var(--surface);
    }

    .pack:target {
      outline: 3px solid rgba(47, 111, 97, 0.24);
      outline-offset: 4px;
    }

    .pack[data-selected] {
      border-color: rgba(47, 111, 97, 0.72);
    }
    .pack-header {
      display: flex;
      justify-content: space-between;
      gap: 18px;
      align-items: flex-start;
      border-bottom: 1px solid var(--line);
      padding-bottom: 16px;
    }

    .eyebrow {
      color: var(--accent-2);
      font-size: 0.78rem;
      font-weight: 800;
      text-transform: uppercase;
    }

    .summary {
      max-width: 780px;
      margin-top: 8px;
      color: var(--muted);
      line-height: 1.55;
    }

    .recommended {
      flex: 0 0 auto;
      border: 1px solid rgba(47, 111, 97, 0.28);
      border-radius: 8px;
      background: #e7f2ed;
      color: var(--accent);
      font-size: 0.82rem;
      font-weight: 800;
      padding: 8px 11px;
    }

    .pack-meta {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 12px;
      margin-top: 16px;
    }

    .pack-meta p {
      border-left: 3px solid var(--line);
      padding-left: 12px;
      color: var(--muted);
      line-height: 1.45;
    }

    .pack-meta strong {
      display: block;
      color: var(--ink);
      margin-bottom: 4px;
    }
    .board-strip {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(118px, 1fr));
      gap: 8px;
      margin-top: 18px;
    }

    .board-chip {
      display: grid;
      grid-template-columns: auto 1fr auto;
      gap: 8px;
      align-items: center;
      min-height: 38px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #f9fbf8;
      padding: 7px 9px;
      font-size: 0.82rem;
    }

    .board-chip span {
      color: var(--muted);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    .board-chip strong {
      color: var(--accent);
    }

    .command-row {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 10px;
      align-items: center;
      margin-top: 18px;
      border: 1px solid var(--line);
      background: var(--surface-2);
      padding: 10px;
    }

    .notes {
      display: grid;
      gap: 6px;
      margin: 14px 0 0;
      padding-left: 20px;
      color: var(--muted);
      line-height: 1.45;
    }

    .preview-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
      gap: 14px;
      margin-top: 18px;
    }

    .preview-tile {
      margin: 0;
      min-width: 0;
      border: 1px solid var(--line);
      background: #fcfdfb;
    }

    .preview-tile img {
      display: block;
      width: 100%;
      aspect-ratio: 360 / 628;
      object-fit: cover;
      border-bottom: 1px solid var(--line);
      background: #eef1ed;
    }

    .preview-tile figcaption {
      display: flex;
      justify-content: space-between;
      gap: 8px;
      padding: 9px 10px;
      color: var(--muted);
      font-size: 0.83rem;
      line-height: 1.3;
    }

    .preview-tile strong {
      color: var(--ink);
    }
    @media (max-width: 820px) {
      h1 {
        font-size: 2.25rem;
      }

      h2 {
        font-size: 1.55rem;
      }

      .pack-header,
      .command-row,
      .preview-tile figcaption {
        display: grid;
      }

      .pack-meta {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <header>
    <h1>Hibiki MD3 + Cupertino design pack gallery</h1>
    <p class="lead">Pick a whole-app baseline first, then use the per-interface image picker for exceptions. The preview images below are pulled from the same 84-surface, 252-image manifest used by the implementation spec generator.</p>
    <nav class="toolbar" aria-label="Pack navigation">
      ${packTabs}
      <a href="interface-images/index.html">Per-interface images</a>
      <a href="IMPLEMENTATION_SPEC_DRAFT.md">Current spec draft</a>
      <a href="DESIGN_PACKS.md">Pack notes</a>
    </nav>
    <div class="selection" aria-live="polite">
      <strong id="selected-label">Selected pack: Hibiki Balanced</strong>
      <code id="selected-command">${escapeHtml(specCommand("hibiki-balanced"))}</code>
    </div>
  </header>
  <main>
    ${packSections}
  </main>
  <script>
    const label = document.getElementById("selected-label");
    const command = document.getElementById("selected-command");
    const packLabels = ${JSON.stringify(Object.fromEntries(Object.entries(packs).map(([packId, pack]) => [packId, pack.label])))};
    const commands = ${JSON.stringify(Object.fromEntries(Object.keys(packs).map((packId) => [packId, specCommand(packId)])))};

    function selectPack(packId) {
      localStorage.setItem("hibiki-md3-cupertino-pack", packId);
      label.textContent = "Selected pack: " + packLabels[packId];
      command.textContent = commands[packId];
      document.querySelectorAll(".pack").forEach((section) => {
        section.toggleAttribute("data-selected", section.dataset.pack === packId);
      });
    }

    document.querySelectorAll("[data-pack-command]").forEach((button) => {
      button.addEventListener("click", () => {
        selectPack(button.dataset.packCommand);
      });
    });

    const savedPack = localStorage.getItem("hibiki-md3-cupertino-pack");
    selectPack(packLabels[savedPack] ? savedPack : "hibiki-balanced");
  </script>
</body>
</html>
`;
}

/**
 * @returns {Promise<void>}
 */
async function main() {
  const manifest = /** @type {{ generatedFrom: string, surfaces: ManifestSurface[] }} */ (JSON.parse(await readFile(manifestPath, "utf8")));
  if (manifest.generatedFrom !== "interface-gallery.html") {
    throw new Error(`Unexpected manifest source: ${manifest.generatedFrom}`);
  }
  const packs = /** @type {Record<string, DesignPack>} */ (JSON.parse(await readFile(packsPath, "utf8")));
  validatePacks(packs);
  const html = renderHtml(packs, manifest.surfaces);
  await writeFile(outputPath, html, "utf8");
  console.log(`Wrote ${relative(__dirname, outputPath)} for ${Object.keys(packs).length} packs.`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
