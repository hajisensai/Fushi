// @ts-check
import { readdir, readFile } from "node:fs/promises";
import { join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

/** @typedef {{ section: string, surface: string, primary: string, file: string, secondary: string, secondaryFile: string, defaultChoice: string }} Surface */
/** @typedef {{ slug: string, files: Record<"A" | "B" | "C", string> } & Surface} ManifestSurface */

const designDir = fileURLToPath(new URL(".", import.meta.url));
const repoRoot = join(designDir, "..", "..", "..");
const libDir = join(repoRoot, "hibiki", "lib");
const coveragePath = join(designDir, "COVERAGE.md");
const galleryPath = join(designDir, "interface-gallery.html");
const manifestPath = join(designDir, "interface-images", "manifest.json");
const decisionMatrixPath = join(designDir, "INTERFACE_DECISION_MATRIX.zh-CN.md");
const imageDir = join(designDir, "interface-images");

const uiPattern = /Widget\s+build\s*\(|extends\s+(?:StatelessWidget|StatefulWidget|ConsumerWidget|ConsumerStatefulWidget|BasePage|BaseSourcePage|BaseTabPage)|showDialog\s*\(|showModal|AlertDialog\s*\(|BottomSheet|ListTile\s*\(/u;
const surfaceRegex = /\{ section: "([^"]+)", surface: "([^"]+)", primary: "([^"]+)", file: "([^"]+)", secondary: "([^"]+)", secondaryFile: "([^"]+)", defaultChoice: "([ABC])" \}/gu;
const coverageRowRegex = /^\| `([^`]+\.dart)` \| `([^`]+\.svg)` \| `([^`]+\.svg)` \|$/gmu;
const decisionMatrixRowRegex = /^\| `([^`]+\.dart)` \| [^|]+ \| \[A\]\(interface-images\/([^)]+)\) \[B\]\(interface-images\/([^)]+)\) \[C\]\(interface-images\/([^)]+)\) \|/gmu;

/**
 * @param {string} directory
 * @returns {Promise<string[]>}
 */
async function listDartFiles(directory) {
  /** @type {string[]} */
  const files = [];
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...await listDartFiles(path));
    } else if (entry.isFile() && entry.name.endsWith(".dart") && !entry.name.endsWith(".g.dart")) {
      files.push(path);
    }
  }
  return files;
}

/**
 * @param {string} html
 * @returns {Surface[]}
 */
function parseGallerySurfaces(html) {
  /** @type {Surface[]} */
  const surfaces = [];
  for (const match of html.matchAll(surfaceRegex)) {
    surfaces.push({
      section: match[1],
      surface: match[2],
      primary: match[3],
      file: match[4],
      secondary: match[5],
      secondaryFile: match[6],
      defaultChoice: match[7]
    });
  }
  return surfaces;
}

/**
 * @param {string} markdown
 * @returns {Map<string, { primaryFile: string, secondaryFile: string }>}
 */
function parseCoverageRows(markdown) {
  /** @type {Map<string, { primaryFile: string, secondaryFile: string }>} */
  const rows = new Map();
  for (const match of markdown.matchAll(coverageRowRegex)) {
    if (rows.has(match[1])) {
      throw new Error(`Duplicate coverage row: ${match[1]}`);
    }
    rows.set(match[1], { primaryFile: match[2], secondaryFile: match[3] });
  }
  return rows;
}

/**
 * @param {string} markdown
 * @returns {Map<string, Record<"A" | "B" | "C", string>>}
 */
function parseDecisionMatrixRows(markdown) {
  /** @type {Map<string, Record<"A" | "B" | "C", string>>} */
  const rows = new Map();
  for (const match of markdown.matchAll(decisionMatrixRowRegex)) {
    if (rows.has(match[1])) {
      throw new Error(`Duplicate decision matrix row: ${match[1]}`);
    }
    rows.set(match[1], { A: match[2], B: match[3], C: match[4] });
  }
  return rows;
}

/**
 * @param {Surface} surface
 * @returns {string}
 */
function surfaceKey(surface) {
  return `${surface.section}:${surface.surface}`;
}

/**
 * @param {string[]} failures
 * @param {string} message
 * @returns {void}
 */
function failIf(failures, message) {
  failures.push(message);
}

/**
 * @returns {Promise<void>}
 */
async function main() {
  const [coverageMarkdown, galleryHtml, manifestRaw, decisionMatrixMarkdown, imageEntries, dartFiles] = await Promise.all([
    readFile(coveragePath, "utf8"),
    readFile(galleryPath, "utf8"),
    readFile(manifestPath, "utf8"),
    readFile(decisionMatrixPath, "utf8"),
    readdir(imageDir, { withFileTypes: true }),
    listDartFiles(libDir)
  ]);

  const coverageRows = parseCoverageRows(coverageMarkdown);
  const gallerySurfaces = parseGallerySurfaces(galleryHtml);
  const manifest = /** @type {{ generatedFrom: string, surfaces: ManifestSurface[] }} */ (JSON.parse(manifestRaw));
  const decisionMatrixRows = parseDecisionMatrixRows(decisionMatrixMarkdown);
  const svgNames = new Set(imageEntries.filter((entry) => entry.isFile() && entry.name.endsWith(".svg")).map((entry) => entry.name));

  /** @type {{ name: string, path: string }[]} */
  const uiFiles = [];
  for (const file of dartFiles) {
    const content = await readFile(file, "utf8");
    if (uiPattern.test(content)) {
      uiFiles.push({
        name: file.split(sep).at(-1) || file,
        path: relative(repoRoot, file)
      });
    }
  }

  /** @type {string[]} */
  const failures = [];
  if (manifest.generatedFrom !== "interface-gallery.html") {
    failIf(failures, `Unexpected manifest source: ${manifest.generatedFrom}`);
  }

  const mappedNames = new Set(coverageRows.keys());
  const uiFileNames = new Map();
  for (const file of uiFiles) {
    const paths = uiFileNames.get(file.name) || [];
    paths.push(file.path);
    uiFileNames.set(file.name, paths);
  }

  for (const [name, paths] of uiFileNames.entries()) {
    if (paths.length > 1) {
      failIf(failures, `Duplicate UI filename cannot be represented by basename coverage: ${name} => ${paths.join(", ")}`);
    }
  }

  const unmappedUiFiles = uiFiles.filter((file) => !mappedNames.has(file.name));
  for (const file of unmappedUiFiles) {
    failIf(failures, `Unmapped UI-building file: ${file.path}`);
  }

  const galleryKeys = new Set(gallerySurfaces.map(surfaceKey));
  if (galleryKeys.size !== gallerySurfaces.length) {
    failIf(failures, "Duplicate surfaces exist in interface-gallery.html.");
  }

  const manifestKeys = new Set(manifest.surfaces.map(surfaceKey));
  if (manifestKeys.size !== manifest.surfaces.length) {
    failIf(failures, "Duplicate surfaces exist in interface-images/manifest.json.");
  }

  for (const surface of gallerySurfaces) {
    if (!coverageRows.has(surface.surface)) {
      failIf(failures, `Gallery surface is missing from COVERAGE.md: ${surface.surface}`);
      continue;
    }
    const row = coverageRows.get(surface.surface);
    if (row && (row.primaryFile !== surface.file || row.secondaryFile !== surface.secondaryFile)) {
      failIf(failures, `Coverage/gallery board mismatch for ${surface.surface}: coverage=${row.primaryFile},${row.secondaryFile}; gallery=${surface.file},${surface.secondaryFile}`);
    }
  }

  for (const surface of manifest.surfaces) {
    if (!galleryKeys.has(surfaceKey(surface))) {
      failIf(failures, `Manifest surface is missing from interface-gallery.html: ${surface.surface}`);
    }
    const matrixRow = decisionMatrixRows.get(surface.surface);
    if (!matrixRow) {
      failIf(failures, `Manifest surface is missing from INTERFACE_DECISION_MATRIX.zh-CN.md: ${surface.surface}`);
    }
    for (const choice of /** @type {("A" | "B" | "C")[]} */ (["A", "B", "C"])) {
      const file = surface.files[choice];
      if (!file || !svgNames.has(file)) {
        failIf(failures, `Missing image for ${surface.surface} ${choice}: ${file || "(empty)"}`);
      }
      if (matrixRow && matrixRow[choice] !== file) {
        failIf(failures, `Decision matrix image mismatch for ${surface.surface} ${choice}: matrix=${matrixRow[choice]}, manifest=${file}`);
      }
    }
  }

  for (const surface of gallerySurfaces) {
    if (!manifestKeys.has(surfaceKey(surface))) {
      failIf(failures, `Gallery surface is missing from manifest: ${surface.surface}`);
    }
  }

  for (const surfaceName of decisionMatrixRows.keys()) {
    if (!manifest.surfaces.some((surface) => surface.surface === surfaceName)) {
      failIf(failures, `Decision matrix surface is missing from manifest: ${surfaceName}`);
    }
  }

  const expectedImageCount = manifest.surfaces.length * 3;
  if (svgNames.size !== expectedImageCount) {
    failIf(failures, `Expected ${expectedImageCount} SVG images, found ${svgNames.size}.`);
  }

  if (failures.length > 0) {
    console.error(failures.join("\n"));
    process.exitCode = 1;
    return;
  }

  console.log(`nonGeneratedDart=${dartFiles.length}`);
  console.log(`uiMatched=${uiFiles.length}`);
  console.log(`coverageRows=${coverageRows.size}`);
  console.log(`gallerySurfaces=${gallerySurfaces.length}`);
  console.log(`manifestSurfaces=${manifest.surfaces.length}`);
  console.log(`decisionMatrixRows=${decisionMatrixRows.size}`);
  console.log(`svgImages=${svgNames.size}`);
  console.log("unmappedUiFiles=0");
  console.log("interfaceCoverage=ok");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
