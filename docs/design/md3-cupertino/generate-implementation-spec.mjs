// @ts-check
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/** @typedef {"A" | "B" | "C"} Choice */
/** @typedef {{ section: string, surface: string, primary: string, file: string, secondary: string, secondaryFile: string, defaultChoice: Choice, slug: string, files: Record<Choice, string> }} ManifestSurface */
/** @typedef {"md3-practical" | "reading-calm" | "adaptive-power" | "hibiki-balanced"} PackName */
/** @typedef {{ choices: Map<string, Choice>, boardChoices: Map<string, Choice>, notes: string[] }} ParsedPicks */

const __dirname = dirname(fileURLToPath(import.meta.url));
const manifestPath = join(__dirname, "interface-images", "manifest.json");
const defaultOutputPath = join(__dirname, "IMPLEMENTATION_SPEC_DRAFT.md");
const boardOrder = ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12", "13", "14", "15", "16", "18"];

/** @type {Record<string, { file: string, label: string, scope: string }>} */
const boards = {
  "01": { file: "01-home-navigation.svg", label: "Home and navigation", scope: "Main shell, bottom tabs, navigation rail, top actions." },
  "02": { file: "02-reader-shelf.svg", label: "Reader shelf", scope: "Library, history, covers, selection, import entry points." },
  "03": { file: "03-dictionary.svg", label: "Dictionary", scope: "Search, history, result browsing, popup lookup stack." },
  "04": { file: "04-reader.svg", label: "Hoshi reader", scope: "Reading chrome, lookup overlay, audiobook bar, lyrics mode." },
  "05": { file: "05-settings.svg", label: "Settings", scope: "Profile, theme, reader settings, display, Anki, updates, logs." },
  "06": { file: "06-import-and-modals.svg", label: "Import and modals", scope: "Book import, audiobook import, dictionary import, picker dialogs." },
  "07": { file: "07-creator-anki.svg", label: "Creator and Anki", scope: "Card mining fields, Anki settings, recorder, crop, segmentation." },
  "08": { file: "08-collections-stats.svg", label: "Collections and stats", scope: "Bookmarks, favorite sentences, reading statistics, illustration viewer." },
  "09": { file: "09-system-debug.svg", label: "System and debug", scope: "Language, profile management, miscellaneous settings, logs, websocket." },
  "10": { file: "10-dictionary-management.svg", label: "Dictionary management", scope: "Installed dictionaries, import progress, ordering, CSS, audio sources." },
  "11": { file: "11-reader-customization.svg", label: "Reader customization", scope: "Display settings, custom fonts, custom theme, book CSS, blur options." },
  "12": { file: "12-media-and-sentences.svg", label: "Media and sentence dialogs", scope: "Media item dialogs, edit dialogs, source picker, examples, stash, recorder." },
  "13": { file: "13-tags-and-filters.svg", label: "Tags and filters", scope: "Tag management, tag picker, tag filter sheet, batch tag assignment." },
  "14": { file: "14-profile-language-system.svg", label: "Profile, language, system", scope: "Profiles, language, miscellaneous settings, websocket, app icon choices." },
  "15": { file: "15-logs-and-debug.svg", label: "Logs and debug", scope: "Debug log, error log, diagnostics, low-memory and import messages." },
  "16": { file: "16-empty-loading-error-states.svg", label: "Empty, loading, error states", scope: "Shared empty, loading, error, placeholder states." },
  "18": { file: "18-component-system.svg", label: "Component system", scope: "Shared buttons, rows, search, sheets, placeholders, popups, and selection grammar." }
};

/** @type {Record<string, Record<Choice, string>>} */
const choiceMeaning = {
  "01": { A: "Quiet MD3 mobile shell", B: "Cupertino calm large-title shell", C: "Adaptive mobile plus wider-layout shell" },
  "02": { A: "MD3 grid/list shelf", B: "Reading-first calm shelf", C: "Dense management workspace" },
  "03": { A: "Fast MD3 search", B: "Readable result browsing", C: "Power split lookup workspace" },
  "04": { A: "Paper chrome reader", B: "Immersive calm reader", C: "Lyrics and lookup heavy reader" },
  "05": { A: "MD3 settings list", B: "Grouped Cupertino settings", C: "Settings console" },
  "06": { A: "Step-based MD3 flow", B: "Lightweight sheet flow", C: "Import inspector" },
  "07": { A: "Simple field form", B: "Guided creator", C: "Mapping panel" },
  "08": { A: "Scannable lists", B: "Media gallery", C: "Analytics workspace" },
  "09": { A: "Plain system settings", B: "Grouped profile feel", C: "Debug console" },
  "10": { A: "Inventory list", B: "Dictionary inspector", C: "Admin workspace" },
  "11": { A: "Controls first", B: "Preview studio", C: "Theme editor" },
  "12": { A: "Mobile action sheet", B: "Modal stack", C: "Bottom workspace" },
  "13": { A: "Chip console", B: "Grouped tag manager", C: "Batch editor" },
  "14": { A: "Settings hub", B: "Account-like profiles", C: "Utility console" },
  "15": { A: "Plain log viewer", B: "Error inbox", C: "Diagnostics split" },
  "16": { A: "Actionable empty state", B: "Quiet skeleton state", C: "Recoverable error state" },
  "18": { A: "MD3 token kit", B: "Cupertino surface kit", C: "Hybrid density kit" }
};

/** @type {Record<string, string>} */
const groupContracts = {
  Entry: "Entry surfaces define the app shell, process-text popup shell, and floating dictionary shell. They must keep startup/loading/error behavior separate from regular page content.",
  Pages: "Page surfaces define route-level layout and interaction rhythm. They inherit shared tokens, but may use a board-specific choice when the screen has a clear workflow need.",
  "Shared/support": "Shared and support surfaces define reusable Flutter components. They must prevent page-by-page styling drift and should be implemented before broad page rewrites."
};

/** @type {Record<PackName, { label: string, choices: Record<string, Choice>, notes: string[] }>} */
const packs = {
  "md3-practical": {
    label: "MD3 Practical",
    choices: Object.fromEntries(boardOrder.map((boardId) => [boardId, "A"])),
    notes: [
      "Baseline: MD3 Practical.",
      "Use Material 3 components as the visible default.",
      "Keep workflows direct and avoid decorative reader chrome."
    ]
  },
  "reading-calm": {
    label: "Reading Calm",
    choices: Object.fromEntries(boardOrder.map((boardId) => [boardId, "B"])),
    notes: [
      "Baseline: Reading Calm.",
      "Prefer grouped settings, large-title rhythm, and translucent reader/accessory chrome.",
      "Keep dictionary results readable instead of input-focused."
    ]
  },
  "adaptive-power": {
    label: "Adaptive Power",
    choices: Object.fromEntries(boardOrder.map((boardId) => [boardId, "C"])),
    notes: [
      "Baseline: Adaptive Power.",
      "Favor navigation rail/sidebar, split panes, inspectors, persistent previews, and compact shared components.",
      "Keep mobile layouts usable by collapsing dense panels into sheets."
    ]
  },
  "hibiki-balanced": {
    label: "Hibiki Balanced",
    choices: {
      "01": "C",
      "02": "A",
      "03": "B",
      "04": "B",
      "05": "B",
      "06": "A",
      "07": "C",
      "08": "A",
      "09": "C",
      "10": "C",
      "11": "B",
      "12": "A",
      "13": "C",
      "14": "A",
      "15": "A",
      "16": "A",
      "18": "C"
    },
    notes: [
      "Baseline: Hibiki Balanced.",
      "Reader stays calm; management surfaces stay dense.",
      "Shared components use hybrid density so pages do not drift."
    ]
  }
};

/**
 * @param {string[]} args
 * @returns {{ picksPath?: string, outputPath: string, packName?: PackName }}
 */
function parseArgs(args) {
  /** @type {{ picksPath?: string, outputPath: string, packName?: PackName }} */
  const result = { outputPath: defaultOutputPath };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--picks") {
      result.picksPath = args[index + 1];
      index += 1;
    } else if (arg === "--pack") {
      const packName = args[index + 1];
      if (!Object.hasOwn(packs, packName)) {
        throw new Error(`Unknown pack: ${packName}. Valid packs: ${Object.keys(packs).join(", ")}`);
      }
      result.packName = /** @type {PackName} */ (packName);
      index += 1;
    } else if (arg === "--output") {
      result.outputPath = args[index + 1];
      index += 1;
    } else if (arg === "--help") {
      console.log("Usage: node generate-implementation-spec.mjs [--pack md3-practical|reading-calm|adaptive-power|hibiki-balanced] [--picks picks.txt] [--output IMPLEMENTATION_SPEC.md]");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return result;
}

/**
 * @param {PackName} packName
 * @returns {ParsedPicks}
 */
function picksFromPack(packName) {
  const pack = packs[packName];
  return {
    choices: new Map(),
    boardChoices: new Map(Object.entries(pack.choices)),
    notes: [...pack.notes]
  };
}

/**
 * @param {ParsedPicks} base
 * @param {ParsedPicks} override
 * @returns {ParsedPicks}
 */
function mergePicks(base, override) {
  return {
    choices: new Map([...base.choices, ...override.choices]),
    boardChoices: new Map([...base.boardChoices, ...override.boardChoices]),
    notes: [...base.notes, ...override.notes]
  };
}

/**
 * @param {string} raw
 * @returns {ParsedPicks}
 */
function parsePicks(raw) {
  /** @type {ParsedPicks} */
  const parsed = { choices: new Map(), boardChoices: new Map(), notes: [] };
  let inNotes = false;
  for (const line of raw.split(/\r?\n/u)) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }
    if (/^notes\s*:?$/iu.test(trimmed)) {
      inNotes = true;
      continue;
    }
    if (inNotes) {
      parsed.notes.push(trimmed);
      continue;
    }

    const surfaceMatch = trimmed.match(/^`?([^`:]+\.dart)`?\s*:\s*([ABC])\b/iu);
    if (surfaceMatch) {
      parsed.choices.set(surfaceMatch[1], /** @type {Choice} */ (surfaceMatch[2].toUpperCase()));
      continue;
    }

    const boardMatch = trimmed.match(/^`?(\d{2})`?\s*:\s*([ABC])\b/iu);
    if (boardMatch) {
      parsed.boardChoices.set(boardMatch[1], /** @type {Choice} */ (boardMatch[2].toUpperCase()));
    }
  }
  return parsed;
}

/**
 * @param {ManifestSurface} surface
 * @param {ParsedPicks} picks
 * @returns {{ choice: Choice, source: string }}
 */
function selectedChoice(surface, picks) {
  const explicit = picks.choices.get(surface.surface);
  if (explicit) {
    return { choice: explicit, source: "explicit surface pick" };
  }
  const board = picks.boardChoices.get(surface.primary);
  if (board) {
    return { choice: board, source: "board pick" };
  }
  return { choice: surface.defaultChoice, source: "default" };
}

/**
 * @param {string} boardId
 * @param {Choice} choice
 * @returns {string}
 */
function describeChoice(boardId, choice) {
  return choiceMeaning[boardId]?.[choice] || `${choice} direction`;
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {ParsedPicks} picks
 * @returns {Map<string, Record<Choice, number>>}
 */
function boardChoiceCounts(surfaces, picks) {
  /** @type {Map<string, Record<Choice, number>>} */
  const counts = new Map();
  for (const surface of surfaces) {
    const selected = selectedChoice(surface, picks).choice;
    const current = counts.get(surface.primary) || { A: 0, B: 0, C: 0 };
    current[selected] += 1;
    counts.set(surface.primary, current);
  }
  return counts;
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {ParsedPicks} picks
 * @param {string} sourceLabel
 * @returns {string}
 */
function renderSpec(surfaces, picks, sourceLabel) {
  const countsBySection = new Map();
  for (const surface of surfaces) {
    countsBySection.set(surface.section, (countsBySection.get(surface.section) || 0) + 1);
  }
  const countsByBoard = boardChoiceCounts(surfaces, picks);
  const explicitCount = surfaces.filter((surface) => picks.choices.has(surface.surface)).length;
  const boardPickCount = picks.boardChoices.size;
  const imageCount = surfaces.length * 3;

  const boardRows = boardOrder.map((boardId) => {
    const board = boards[boardId];
    const counts = countsByBoard.get(boardId) || { A: 0, B: 0, C: 0 };
    const total = counts.A + counts.B + counts.C;
    const dominant = /** @type {Choice} */ (["A", "B", "C"].reduce((best, choice) => counts[/** @type {Choice} */ (choice)] > counts[/** @type {Choice} */ (best)] ? choice : best, "A"));
    const direction = total > 0 ? `${dominant}: ${describeChoice(boardId, dominant)}` : "Support-only in current surface map";
    return `| ${boardId} | [${board.file}](${board.file}) | ${board.label} | ${counts.A}/${counts.B}/${counts.C} | ${direction} | ${board.scope} |`;
  }).join("\n");

  const sectionBlocks = [...countsBySection.keys()].map((section) => {
    const rows = surfaces.filter((surface) => surface.section === section).map((surface) => {
      const selected = selectedChoice(surface, picks);
      const imageFile = `interface-images/${surface.files[selected.choice]}`;
      const primary = boards[surface.primary];
      const secondary = boards[surface.secondary];
      return `| \`${surface.surface}\` | ${selected.choice} | [image](${imageFile}) | ${selected.source} | ${surface.primary} ${primary?.label || ""} | ${surface.secondary} ${secondary?.label || ""} |`;
    }).join("\n");
    return `### ${section}\n\n${groupContracts[section]}\n\n| Surface | Choice | Selected image | Source | Primary board | Support board |\n| --- | --- | --- | --- | --- | --- |\n${rows}`;
  }).join("\n\n");

  const userNotes = picks.notes.length > 0 ? picks.notes.map((note) => `- ${note}`).join("\n") : "- No user notes imported yet.";

  return `# Hibiki MD3 + Cupertino implementation spec draft

This is the bridge from visual A/B/C choices to a runtime implementation plan. It is not the final implementation approval until the user confirms the selected choices.

## Selection Source

- Source: ${sourceLabel}
- Surfaces: ${surfaces.length}
- Generated image choices: ${imageCount}
- Sections: ${[...countsBySection.entries()].map(([section, count]) => `${section} ${count}`).join(", ")}
- Explicit surface picks imported: ${explicitCount}
- Board-level picks imported: ${boardPickCount}
- Draft status: ${explicitCount + boardPickCount > 0 ? "user choices imported" : "defaults only; waiting for user choices"}

## Non-Negotiable Design Contract

- Use Flutter Material 3 as the base: \`ThemeData(useMaterial3: true)\`, \`ColorScheme\`, \`TextTheme\`, Material 3 buttons, bars, chips, sheets, menus, and dialogs.
- Add Cupertino behavior only where it improves reading calm or preference density: large titles, grouped settings, quiet translucent reader chrome, stable bottom accessory bars, and predictable sheet transitions.
- Current EPUB rendering is Hoshi. Reader implementation must stay on \`ReaderHoshiPage\`, \`ReaderHoshiSource\`, \`reader_pagination_scripts.dart\`, \`reader_content_styles.dart\`, \`reader_selection_scripts.dart\`, Hoshi resource interception, and \`window.hoshiReader\`.
- Do not rename persisted TTU/Hoshi compatibility keys unless a migration is explicitly designed and tested.
- Do not solve the redesign by page-local decoration. Shared tokens and components come first, then page groups inherit them.
- Dense operational surfaces may be compact, but they must not fake state. Empty, loading, error, import, and debug states need honest copy and visible recovery actions.

## Board Direction Summary

Choice counts are \`A/B/C\` across the exact mapped surfaces that use each board as their primary board.
Boards marked support-only are still part of the design language, but they currently appear only as secondary/support references in the surface matrix.

| Board | Image | Area | Choice counts | Dominant direction | Scope |
| --- | --- | --- | --- | --- | --- |
${boardRows}

## Runtime Architecture

1. Token layer: create one MD3 + Cupertino token source for color, radius, spacing, text scale, elevation, scrim, and motion. Keep cards at 8px radius or less unless the chosen board says a component is a sheet or modal.
2. Shared component layer: implement reusable search, list rows, grouped settings rows, bottom sheets, popups, segmented controls, icon buttons, placeholders, toast/snackbar surfaces, and reader accessory bars before rewriting individual pages.
3. Shell layer: update app entry, tab shell, navigation rail, popup dictionary shell, and floating dictionary shell without changing route state ownership.
4. Feature page layer: apply the selected surface choices by group. Route-level files should compose shared components instead of inventing local visual grammar.
5. Reader layer: treat Hoshi reader, dictionary lookup, audiobook bar, lyrics, restore state, and display settings as one interaction surface. Validate layout against WebView bounds, body bounds, and playback chrome bounds.

## Surface Matrix

${sectionBlocks}

## Imported Notes

${userNotes}

## Implementation Gates

Before runtime implementation starts:

1. User confirms this spec or supplies revised picks.
2. Run \`node docs\\design\\md3-cupertino\\verify-interface-coverage.mjs\` and keep \`interfaceCoverage=ok\`.
3. Write the implementation plan from this spec, grouped by shared components first and page families second.

Before claiming runtime completion:

1. Run \`D:\\flutter_sdk\\flutter_extracted\\flutter\\bin\\dart.bat format .\`.
2. Run \`D:\\flutter_sdk\\flutter_extracted\\flutter\\bin\\flutter.bat test\`.
3. For Hoshi reader UI changes, validate on a real emulator or the user-specified device with screenshots/UI hierarchy/log evidence.
4. Reader manual validation must cover cover image page, long vertical text page, audiobook bar bottom layout, play/pause, previous/next cue, follow-audio jump, chapter boundary behavior, first open after import, and restart restore.
`;
}

/**
 * @returns {Promise<void>}
 */
async function main() {
  const args = parseArgs(process.argv.slice(2));
  const manifest = /** @type {{ generatedFrom: string, surfaces: ManifestSurface[] }} */ (JSON.parse(await readFile(manifestPath, "utf8")));
  if (manifest.generatedFrom !== "interface-gallery.html") {
    throw new Error(`Unexpected manifest source: ${manifest.generatedFrom}`);
  }

  const packPicks = args.packName ? picksFromPack(args.packName) : { choices: new Map(), boardChoices: new Map(), notes: [] };
  const filePicks = args.picksPath ? parsePicks(await readFile(args.picksPath, "utf8")) : { choices: new Map(), boardChoices: new Map(), notes: [] };
  const picks = mergePicks(packPicks, filePicks);
  const sources = [];
  if (args.packName) {
    sources.push(`${packs[args.packName].label} pack`);
  }
  if (args.picksPath) {
    sources.push(relative(__dirname, args.picksPath));
  }
  const sourceLabel = sources.length > 0 ? sources.join(" + ") : "manifest defaults; user choices pending";
  const spec = renderSpec(manifest.surfaces, picks, sourceLabel);
  await writeFile(args.outputPath, spec, "utf8");
  console.log(`Wrote ${relative(__dirname, args.outputPath)} for ${manifest.surfaces.length} surfaces.`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
