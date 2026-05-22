// @ts-check
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

/** @typedef {"A" | "B" | "C"} Choice */
/** @typedef {{ section: string, surface: string, primary: string, file: string, secondary: string, secondaryFile: string, defaultChoice: Choice, slug: string, files: Record<Choice, string> }} ManifestSurface */
/** @typedef {{ label: string, summary: string, bestFor: string, tradeoff: string, choices: Record<string, Choice>, notes: string[] }} DesignPack */

const __dirname = dirname(fileURLToPath(import.meta.url));
const manifestPath = join(__dirname, "interface-images", "manifest.json");
const packsPath = join(__dirname, "design-packs.json");
const outputPath = join(__dirname, "INTERFACE_DECISION_MATRIX.zh-CN.md");
const packOrder = ["md3-practical", "reading-calm", "adaptive-power", "hibiki-balanced"];

/** @type {Record<string, string>} */
const sectionLabels = {
  Entry: "入口和外部壳层",
  Pages: "页面",
  "Shared/support": "共享和支撑组件"
};

/** @type {Record<string, string>} */
const boardLabels = {
  "01": "首页和导航",
  "02": "书架",
  "03": "词典",
  "04": "Hoshi 阅读器",
  "05": "设置",
  "06": "导入和弹窗",
  "07": "制卡和 Anki",
  "08": "收藏和统计",
  "09": "系统和调试",
  "10": "词典管理",
  "11": "阅读自定义",
  "12": "媒体和例句弹窗",
  "13": "标签和筛选",
  "14": "资料、语言、系统",
  "15": "日志和调试",
  "16": "空、加载、错误状态",
  "18": "组件系统"
};

/**
 * @param {string} value
 * @returns {string}
 */
function escapeMarkdown(value) {
  return value.replaceAll("|", "\\|");
}

/**
 * @param {unknown} value
 * @returns {value is Choice}
 */
function isChoice(value) {
  return value === "A" || value === "B" || value === "C";
}

/**
 * @returns {Promise<{ surfaces: ManifestSurface[], packs: Record<string, DesignPack> }>}
 */
async function loadInputs() {
  const manifest = /** @type {{ generatedFrom: string, surfaces: ManifestSurface[] }} */ (JSON.parse(await readFile(manifestPath, "utf8")));
  if (manifest.generatedFrom !== "interface-gallery.html") {
    throw new Error(`Unexpected manifest source: ${manifest.generatedFrom}`);
  }
  const packs = /** @type {Record<string, DesignPack>} */ (JSON.parse(await readFile(packsPath, "utf8")));
  return { surfaces: manifest.surfaces, packs };
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {Record<string, DesignPack>} packs
 * @returns {void}
 */
function validateInputs(surfaces, packs) {
  const seenSurfaces = new Set();
  for (const surface of surfaces) {
    if (seenSurfaces.has(surface.surface)) {
      throw new Error(`Duplicate surface: ${surface.surface}`);
    }
    seenSurfaces.add(surface.surface);
    for (const choice of /** @type {Choice[]} */ (["A", "B", "C"])) {
      if (!surface.files[choice]) {
        throw new Error(`Missing ${choice} image for ${surface.surface}`);
      }
    }
  }
  for (const packId of packOrder) {
    const pack = packs[packId];
    if (!pack) {
      throw new Error(`Missing pack: ${packId}`);
    }
    for (const surface of surfaces) {
      if (!isChoice(pack.choices[surface.primary])) {
        throw new Error(`Pack ${packId} has no choice for board ${surface.primary}`);
      }
    }
  }
}

/**
 * @param {ManifestSurface} surface
 * @param {Record<string, DesignPack>} packs
 * @returns {string}
 */
function renderSurfaceRow(surface, packs) {
  const images = /** @type {Choice[]} */ (["A", "B", "C"])
    .map((choice) => `[${choice}](interface-images/${surface.files[choice]})`)
    .join(" ");
  const packChoices = packOrder
    .map((packId) => `${packs[packId].label}: ${packs[packId].choices[surface.primary]}`)
    .join("<br>");
  const recommended = packs["hibiki-balanced"].choices[surface.primary];
  return `| \`${escapeMarkdown(surface.surface)}\` | ${escapeMarkdown(boardLabels[surface.primary] || surface.primary)} | ${images} | ${packChoices} | ${recommended} | |`;
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {Record<string, DesignPack>} packs
 * @returns {string}
 */
function renderMatrix(surfaces, packs) {
  const sections = [...new Set(surfaces.map((surface) => surface.section))]
    .map((section) => {
      const rows = surfaces
        .filter((surface) => surface.section === section)
        .map((surface) => renderSurfaceRow(surface, packs))
        .join("\n");
      return `## ${sectionLabels[section] || section}

| 界面 | 设计族 | 三张候选图 | 四套整包默认 | 推荐 | 最终选择 |
| --- | --- | --- | --- | --- | --- |
${rows}`;
    })
    .join("\n\n");
  const packLines = packOrder
    .map((packId) => `- \`${packId}\` / ${packs[packId].label}: ${packs[packId].summary}`)
    .join("\n");

  return `# Hibiki MD3 + Cupertino 全界面选择矩阵

这份文件是最终挑图时的中文总表。它从 [interface-images/manifest.json](interface-images/manifest.json) 和 [design-packs.json](design-packs.json) 生成，不手写界面清单。当前覆盖 ${surfaces.length} 个界面/支撑组件，每行都有 A/B/C 三张候选图；完整横向大图和可复制导出在 [interface-pack-comparison.html](interface-pack-comparison.html)。

## 使用方式

先选一个整包作为基准，再只改少量例外。推荐基准仍然是 \`hibiki-balanced\`。如果你想直接点图并导出最终文本，打开 [interface-pack-comparison.html](interface-pack-comparison.html)；如果想在 Markdown 里审查所有界面，用下面的表逐行看图，并在“最终选择”列记 A/B/C。

${packLines}

## 判定规则

- 推荐列来自 \`Hibiki Balanced\`，它不是最终决定，只是当前实现起点。
- “四套整包默认”展示同一个界面在四种整体方向下会选哪张图。
- 最终实现前必须把确认结果保存成 picks 文件，再用 \`generate-implementation-spec.mjs\` 生成规格草案。
- 如果某行不确定，保留推荐值。例外越少，后续 Flutter token 和共享组件越不会分裂。

${sections}

## 生成最终规格

\`\`\`powershell
node .\\generate-implementation-spec.mjs --picks .\\my-final-selection.txt --output .\\IMPLEMENTATION_SPEC_FINAL_DRAFT.md
\`\`\`

本矩阵只负责选择，不代表已经开始 runtime 实现。
`;
}

/**
 * @returns {Promise<void>}
 */
async function main() {
  const { surfaces, packs } = await loadInputs();
  validateInputs(surfaces, packs);
  await writeFile(outputPath, renderMatrix(surfaces, packs), "utf8");
  console.log(`Wrote ${relative(__dirname, outputPath)} for ${surfaces.length} surfaces.`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
