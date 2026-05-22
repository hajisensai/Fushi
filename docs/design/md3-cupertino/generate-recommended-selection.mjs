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
const defaultPackId = "hibiki-balanced";
const packIndexFile = "pack-selection-index.html";
const interfacePackComparisonFile = "interface-pack-comparison.html";
const packOrder = ["md3-practical", "reading-calm", "adaptive-power", "hibiki-balanced"];
const boardOrder = ["01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12", "13", "14", "15", "16", "18"];

/** @type {Record<string, { title: string, markdownFile: string, htmlFile: string, kind: string }>} */
const packOutputs = {
  "md3-practical": {
    title: "MD3 Practical 逐界面整包选择",
    markdownFile: "SELECTION_MD3_PRACTICAL.zh-CN.md",
    htmlFile: "selection-md3-practical.html",
    kind: "整包基准"
  },
  "reading-calm": {
    title: "Reading Calm 逐界面整包选择",
    markdownFile: "SELECTION_READING_CALM.zh-CN.md",
    htmlFile: "selection-reading-calm.html",
    kind: "整包基准"
  },
  "adaptive-power": {
    title: "Adaptive Power 逐界面整包选择",
    markdownFile: "SELECTION_ADAPTIVE_POWER.zh-CN.md",
    htmlFile: "selection-adaptive-power.html",
    kind: "整包基准"
  },
  "hibiki-balanced": {
    title: "Hibiki Balanced 逐界面推荐选择",
    markdownFile: "RECOMMENDED_SELECTION_HIBIKI_BALANCED.zh-CN.md",
    htmlFile: "recommended-selection-hibiki-balanced.html",
    kind: "推荐基准"
  }
};

/** @type {Record<string, { summary: string, bestFor: string, tradeoff: string, notes: string[] }>} */
const packCopyZh = {
  "md3-practical": {
    summary: "Android 原生清晰度、可预期控件和最低实现风险。",
    bestFor: "优先要一致、直接、快速落地，而不是更柔和的阅读氛围。",
    tradeoff: "阅读器和偏好页会偏工具化，不如 Cupertino 倾向方案安静。",
    notes: [
      "基准：MD3 Practical。",
      "视觉默认使用 Material 3 组件。",
      "工作流保持直接，阅读器 chrome 不做装饰化处理。"
    ]
  },
  "reading-calm": {
    summary: "分组设置、安静阅读 chrome 和更柔和的移动端导航节奏。",
    bestFor: "希望 Hibiki 首先像一个能长时间阅读的应用。",
    tradeoff: "管理密集的页面可能需要显式例外，才能保持足够信息密度。",
    notes: [
      "基准：Reading Calm。",
      "优先使用分组设置、大标题节奏和半透明阅读/附件 chrome。",
      "词典结果保持可浏览，不把输入焦点当作唯一中心。"
    ]
  },
  "adaptive-power": {
    summary: "高密度工作区、分栏、检查器，以及平板/桌面就绪结构。",
    bestFor: "词典管理、制卡映射、标签和诊断是主要使用场景。",
    tradeoff: "手机 casual 阅读会显得偏重，阅读器通常需要改例外。",
    notes: [
      "基准：Adaptive Power。",
      "优先使用导航栏/侧栏、分栏、检查器、持久预览和紧凑共享组件。",
      "移动端必须把高密度面板折叠成 sheet，不能硬塞桌面布局。"
    ]
  },
  "hibiki-balanced": {
    summary: "阅读界面保持安静，管理界面保持密度，共享组件 token 严格统一。",
    bestFor: "作为最终确认前的推荐默认基准，再按单界面改少量例外。",
    tradeoff: "它不是纯 A/B/C 单一风格，所以实现时必须用严格 token 控住一致性。",
    notes: [
      "基准：Hibiki Balanced。",
      "阅读保持安静，管理界面保持密度。",
      "共享组件使用混合密度，避免页面各自漂移。"
    ]
  }
};

/** @type {Record<string, string>} */
const sectionLabels = {
  Entry: "入口和外部壳层",
  Pages: "页面",
  "Shared/support": "共享和支撑组件"
};

/** @type {Record<string, { label: string, scope: string }>} */
const boardLabels = {
  "01": { label: "首页和导航", scope: "主壳层、底部导航、宽屏导航栏、顶部动作。" },
  "02": { label: "书架", scope: "书库、历史、封面、选择模式、导入入口。" },
  "03": { label: "词典", scope: "搜索、历史、结果浏览、弹出查词栈。" },
  "04": { label: "Hoshi 阅读器", scope: "阅读 chrome、查词浮层、有声书播放栏、歌词模式。" },
  "05": { label: "设置", scope: "个人资料、主题、阅读设置、显示、Anki、更新、日志。" },
  "06": { label: "导入和弹窗", scope: "图书导入、有声书导入、词典导入、选择器弹窗。" },
  "07": { label: "制卡和 Anki", scope: "挖卡字段、Anki 设置、录音、裁剪、分词。" },
  "08": { label: "收藏和统计", scope: "书签、收藏句、阅读统计、插图查看。" },
  "09": { label: "系统和调试", scope: "语言、资料管理、杂项设置、日志、WebSocket。" },
  "10": { label: "词典管理", scope: "已安装词典、导入进度、排序、CSS、音频源。" },
  "11": { label: "阅读自定义", scope: "显示设置、自定义字体、自定义主题、书籍 CSS、模糊选项。" },
  "12": { label: "媒体和例句弹窗", scope: "媒体条目、编辑弹窗、来源选择、例句、stash、录音。" },
  "13": { label: "标签和筛选", scope: "标签管理、标签选择、筛选 sheet、批量标签操作。" },
  "14": { label: "资料、语言、系统", scope: "资料、语言、杂项设置、WebSocket、应用图标选择。" },
  "15": { label: "日志和调试", scope: "调试日志、错误日志、诊断、低内存和导入消息。" },
  "16": { label: "空、加载、错误状态", scope: "共享空状态、加载、错误、占位页面。" },
  "18": { label: "组件系统", scope: "按钮、行、搜索、sheet、占位、弹窗、选择语法。" }
};

/** @type {Record<string, Record<Choice, { label: string, why: string }>>} */
const choiceCopy = {
  "01": {
    A: { label: "安静 MD3 手机壳层", why: "保留 Android 原生导航和清楚动作，适合低风险主壳层。" },
    B: { label: "Cupertino 大标题壳层", why: "降低顶部噪音，让入口更像阅读应用。" },
    C: { label: "自适应手机/宽屏壳层", why: "手机保留底部导航，宽屏使用 rail/sidebar，后续桌面和平板不会变成拉伸手机页。" }
  },
  "02": {
    A: { label: "MD3 网格/列表书架", why: "书架要能扫封面、状态和选择模式，MD3 列表/网格最稳。" },
    B: { label: "阅读优先书架", why: "突出继续阅读，减少管理感。" },
    C: { label: "高密度管理书架", why: "适合标签、导入和批量书库维护。" }
  },
  "03": {
    A: { label: "快速 MD3 搜索", why: "适合一次性输入和立即查词。" },
    B: { label: "可浏览结果", why: "Hibiki 的查词结果需要浏览和递归查找，不能总把焦点拉回输入框。" },
    C: { label: "分栏查词工作区", why: "适合历史、详情和面板并排的重度查词。" }
  },
  "04": {
    A: { label: "纸面 chrome 阅读器", why: "控件可见但克制，适合保守阅读器改造。" },
    B: { label: "沉浸安静阅读器", why: "正文优先，播放栏、查词、歌词只在需要时出现，最符合长时间阅读。" },
    C: { label: "歌词和查词重布局", why: "适合有声书、cue 列表、查词面板同时高频使用。" }
  },
  "05": {
    A: { label: "MD3 设置列表", why: "直接、低风险、符合 Android 设置习惯。" },
    B: { label: "Cupertino 分组设置", why: "设置项很多时，分组卡住信息密度和节奏，读起来更安静。" },
    C: { label: "设置控制台", why: "适合宽屏诊断和高级偏好集中管理。" }
  },
  "06": {
    A: { label: "MD3 步骤导入", why: "导入流程必须明确、可恢复、可解释，步骤流最不容易骗用户。" },
    B: { label: "轻量 sheet 流", why: "适合简单选择和短流程。" },
    C: { label: "导入检查器", why: "适合复杂导入状态、日志和错误排查。" }
  },
  "07": {
    A: { label: "简单字段表单", why: "适合低频制卡和少字段操作。" },
    B: { label: "引导式制卡", why: "适合新用户一步步完成挖卡。" },
    C: { label: "映射面板", why: "Anki 和字段映射是重复工作，密度、预览、映射面板比向导更实用。" }
  },
  "08": {
    A: { label: "可扫列表", why: "收藏和统计需要快速扫描，不需要过多装饰。" },
    B: { label: "媒体图库", why: "适合插图和视觉素材为主的页面。" },
    C: { label: "分析工作区", why: "适合指标、趋势、比较和大量统计。" }
  },
  "09": {
    A: { label: "朴素系统设置", why: "系统页保持直接，不制造仪表盘噪音。" },
    B: { label: "分组资料感", why: "适合资料和账户类信息。" },
    C: { label: "调试控制台", why: "系统和调试项需要密度、状态、日志入口，不能伪装成普通偏好。" }
  },
  "10": {
    A: { label: "库存列表", why: "适合简单查看已安装词典。" },
    B: { label: "词典检查器", why: "适合查看词典元数据和结构内容。" },
    C: { label: "管理工作区", why: "词典导入、排序、CSS、音频源是重操作，必须高密度、明确反馈。" }
  },
  "11": {
    A: { label: "控件优先", why: "适合快速改滑块、开关、分段控件。" },
    B: { label: "预览工作室", why: "阅读自定义必须边调边看，预览比纯设置列表更重要。" },
    C: { label: "主题编辑器", why: "适合 CSS/主题代码和预览并排。" }
  },
  "12": {
    A: { label: "手机动作 sheet", why: "媒体和例句弹窗要短路径完成动作，MD3/Cupertino sheet 都能安全收束。" },
    B: { label: "模态栈", why: "适合嵌套查看句子和媒体详情。" },
    C: { label: "底部工作区", why: "适合重复处理句子和媒体的持久面板。" }
  },
  "13": {
    A: { label: "Chip 控制台", why: "适合简单筛选和标签选择。" },
    B: { label: "分组标签管理", why: "适合设置式管理。" },
    C: { label: "批量编辑器", why: "标签是库级操作，批量选择、清理、应用必须高效。" }
  },
  "14": {
    A: { label: "设置中心", why: "资料、语言、系统入口要清楚可发现。" },
    B: { label: "账户式资料", why: "适合更强个人资料氛围。" },
    C: { label: "工具控制台", why: "适合高级系统工具集合。" }
  },
  "15": {
    A: { label: "朴素日志查看", why: "日志页第一任务是诚实展示文本和时间，不要用装饰掩盖错误。" },
    B: { label: "错误收件箱", why: "适合聚合错误并分组处理。" },
    C: { label: "诊断分栏", why: "适合密集诊断和上下文并排。" }
  },
  "16": {
    A: { label: "可行动空状态", why: "空、加载、错误状态要短文案和明确恢复动作，别伪装成功。" },
    B: { label: "安静骨架屏", why: "适合等待内容加载时减少跳动。" },
    C: { label: "可恢复错误状态", why: "适合复杂错误和诊断路径。" }
  },
  "18": {
    A: { label: "MD3 token kit", why: "适合完全标准 Material 组件。" },
    B: { label: "Cupertino surface kit", why: "适合安静表面、分组行、柔和弹层。" },
    C: { label: "混合密度组件", why: "共享组件必须同时服务阅读页和管理页，用混合密度避免页面各自发明样式。" }
  }
};

/**
 * @param {string[]} args
 * @param {number} index
 * @param {string} flag
 * @returns {string}
 */
function readFlagValue(args, index, flag) {
  const value = args[index + 1];
  if (!value || value.startsWith("--")) {
    throw new Error(`Missing value for ${flag}.`);
  }
  return value;
}

/**
 * @param {string[]} args
 * @returns {{ allPacks: boolean, packId: string, markdownPath?: string, htmlPath?: string, indexPath: string, comparisonPath: string }}
 */
function parseArgs(args) {
  const result = {
    allPacks: false,
    packId: defaultPackId,
    /** @type {string | undefined} */
    markdownPath: undefined,
    /** @type {string | undefined} */
    htmlPath: undefined,
    indexPath: join(__dirname, packIndexFile),
    comparisonPath: join(__dirname, interfacePackComparisonFile)
  };
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    if (arg === "--all-packs") {
      result.allPacks = true;
    } else if (arg === "--pack") {
      result.packId = readFlagValue(args, index, arg);
      index += 1;
    } else if (arg === "--markdown") {
      result.markdownPath = readFlagValue(args, index, arg);
      index += 1;
    } else if (arg === "--html") {
      result.htmlPath = readFlagValue(args, index, arg);
      index += 1;
    } else if (arg === "--index") {
      result.indexPath = readFlagValue(args, index, arg);
      index += 1;
    } else if (arg === "--comparison") {
      result.comparisonPath = readFlagValue(args, index, arg);
      index += 1;
    } else if (arg === "--help") {
      console.log("Usage: node generate-recommended-selection.mjs [--all-packs] [--pack hibiki-balanced] [--markdown output.md] [--html output.html] [--index output.html] [--comparison output.html]");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  if (result.allPacks && (result.markdownPath || result.htmlPath)) {
    throw new Error("--markdown and --html can only be used with a single --pack.");
  }
  return result;
}

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
 * @returns {string}
 */
function escapeScriptJson(value) {
  return JSON.stringify(value)
    .replaceAll("<", "\\u003c")
    .replaceAll(">", "\\u003e")
    .replaceAll("&", "\\u0026")
    .replaceAll("\u2028", "\\u2028")
    .replaceAll("\u2029", "\\u2029");
}

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
 * @param {Record<string, DesignPack>} packs
 * @returns {void}
 */
function validatePacks(packs) {
  for (const [packId, pack] of Object.entries(packs)) {
    if (!pack.label || !pack.summary || !pack.bestFor || !pack.tradeoff || !Array.isArray(pack.notes)) {
      throw new Error(`Invalid pack shape: ${packId}`);
    }
    for (const boardId of boardOrder) {
      if (!isChoice(pack.choices?.[boardId])) {
        throw new Error(`Pack ${packId} has no valid choice for board ${boardId}.`);
      }
    }
  }
}

/**
 * @param {string} packId
 * @returns {{ title: string, markdownFile: string, htmlFile: string, kind: string }}
 */
function outputForPack(packId) {
  const output = packOutputs[packId];
  if (!output) {
    throw new Error(`Missing output config for pack ${packId}.`);
  }
  return output;
}

/**
 * @param {string} packId
 * @returns {{ summary: string, bestFor: string, tradeoff: string, notes: string[] }}
 */
function copyForPack(packId) {
  const copy = packCopyZh[packId];
  if (!copy) {
    throw new Error(`Missing Chinese copy for pack ${packId}.`);
  }
  return copy;
}

/**
 * @param {ManifestSurface} surface
 * @param {DesignPack} pack
 * @returns {Choice}
 */
function selectedChoice(surface, pack) {
  return pack.choices[surface.primary];
}

/**
 * @param {ManifestSurface} surface
 * @param {DesignPack} pack
 * @returns {{ choice: Choice, label: string, why: string }}
 */
function selectionCopy(surface, pack) {
  const choice = selectedChoice(surface, pack);
  const copy = choiceCopy[surface.primary]?.[choice];
  if (!copy) {
    throw new Error(`Missing choice copy for board ${surface.primary} choice ${choice}.`);
  }
  return { choice, ...copy };
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {DesignPack} pack
 * @returns {Map<string, Record<Choice, number>>}
 */
function boardCounts(surfaces, pack) {
  /** @type {Map<string, Record<Choice, number>>} */
  const counts = new Map();
  for (const surface of surfaces) {
    const current = counts.get(surface.primary) || { A: 0, B: 0, C: 0 };
    current[selectedChoice(surface, pack)] += 1;
    counts.set(surface.primary, current);
  }
  return counts;
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {DesignPack} pack
 * @returns {string}
 */
function renderMarkdown(surfaces, pack, packId) {
  const output = outputForPack(packId);
  const packCopy = copyForPack(packId);
  const countsByBoard = boardCounts(surfaces, pack);
  const boardRows = boardOrder.map((boardId) => {
    const counts = countsByBoard.get(boardId) || { A: 0, B: 0, C: 0 };
    const board = boardLabels[boardId];
    const choice = pack.choices[boardId];
    const copy = choiceCopy[boardId][choice];
    return `| ${boardId} | ${board.label} | ${choice} | ${counts.A}/${counts.B}/${counts.C} | ${copy.label} | ${board.scope} |`;
  }).join("\n");

  const sectionBlocks = [...new Set(surfaces.map((surface) => surface.section))].map((section) => {
    const rows = surfaces.filter((surface) => surface.section === section).map((surface) => {
      const copy = selectionCopy(surface, pack);
      const imageFile = surface.files[copy.choice];
      const alternatives = /** @type {Choice[]} */ (["A", "B", "C"]).map((choice) => `[${choice}](interface-images/${surface.files[choice]})`).join(" ");
      return `| \`${surface.surface}\` | ${copy.choice} | [选择图](interface-images/${imageFile}) | ${escapeMarkdown(copy.label)} | ${escapeMarkdown(copy.why)} | ${alternatives} |`;
    }).join("\n");
    return `## ${sectionLabels[section] || section}\n\n| 界面 | 选择 | 选择图 | 方向 | 为什么 | 其它图 |\n| --- | --- | --- | --- | --- | --- |\n${rows}`;
  }).join("\n\n");

  return `# ${output.title}

这份文件把 \`${pack.label}\` 展开到全部 84 个界面/支撑组件。它不是最终用户确认；它是 ${output.kind}，方便你逐行看图并指出例外。

## 选择结论

- Pack: \`${packId}\`
- Surfaces: ${surfaces.length}
- Images available: ${surfaces.length * 3}
- Selection source: [design-packs.json](design-packs.json)
- Full visual page: [${output.htmlFile}](${output.htmlFile})
- Pack index: [${packIndexFile}](${packIndexFile})
- Interface pack comparison: [${interfacePackComparisonFile}](${interfacePackComparisonFile})
- All A/B/C choices: [interface-images/index.html](interface-images/index.html)

## 整体规则

${packCopy.notes.map((note) => `- ${note}`).join("\n")}

## 适用判断

- 适合：${packCopy.bestFor}
- 代价：${packCopy.tradeoff}

## Board 展开

Choice counts 是该 board 作为 primary board 的界面选择分布，格式为 \`A/B/C\`。

| Board | 区域 | Pack 选择 | Choice counts | 方向 | 作用域 |
| --- | --- | --- | --- | --- | --- |
${boardRows}

${sectionBlocks}

## 确认格式

如果接受这套默认值，回复：

\`\`\`text
Pack: ${packId}
\`\`\`

如果只改少量例外，回复：

\`\`\`text
Pack: ${packId}
reader_hoshi_page.dart: B
dictionary_dialog_page.dart: C
\`\`\`

不要在确认前改运行时代码。确认后再把选择重新生成到实现规格，并写 Flutter 实施计划。
`;
}

/**
 * @param {ManifestSurface} surface
 * @param {DesignPack} pack
 * @returns {string}
 */
function renderSurfaceCard(surface, pack) {
  const copy = selectionCopy(surface, pack);
  const selectedImage = surface.files[copy.choice];
  const alternatives = /** @type {Choice[]} */ (["A", "B", "C"]).map((choice) => {
    const active = choice === copy.choice ? "true" : "false";
    return `<a href="interface-images/${escapeHtml(surface.files[choice])}" aria-current="${active}">${choice}</a>`;
  }).join("");
  return `<article class="surface-card" id="${escapeHtml(surface.slug)}" data-section="${escapeHtml(surface.section)}" data-choice="${copy.choice}">
    <img src="interface-images/${escapeHtml(selectedImage)}" alt="${escapeHtml(surface.surface)} ${copy.choice} recommended image">
    <div class="surface-body">
      <p class="meta">${escapeHtml(sectionLabels[surface.section] || surface.section)} / ${escapeHtml(boardLabels[surface.primary].label)}</p>
      <h3>${escapeHtml(surface.surface)}</h3>
      <p><strong>${copy.choice} · ${escapeHtml(copy.label)}</strong></p>
      <p>${escapeHtml(copy.why)}</p>
      <div class="alternatives" aria-label="${escapeHtml(surface.surface)} alternatives">${alternatives}</div>
    </div>
  </article>`;
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {DesignPack} pack
 * @param {string} packId
 * @returns {string}
 */
function renderHtml(surfaces, pack, packId) {
  const output = outputForPack(packId);
  const cards = surfaces.map((surface) => renderSurfaceCard(surface, pack)).join("\n");
  const countsByBoard = boardCounts(surfaces, pack);
  const boardChips = boardOrder.map((boardId) => {
    const counts = countsByBoard.get(boardId) || { A: 0, B: 0, C: 0 };
    const choice = pack.choices[boardId];
    return `<span><b>${boardId}</b>${escapeHtml(boardLabels[boardId].label)}<strong>${choice}</strong><small>${counts.A}/${counts.B}/${counts.C}</small></span>`;
  }).join("\n");
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${escapeHtml(output.title)}</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #1f2528;
      --muted: #667277;
      --line: #d7dddf;
      --page: #f6f8f4;
      --surface: #ffffff;
      --surface-2: #eef5f1;
      --accent: #2f6f61;
      --accent-2: #365f8d;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif;
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
      padding: 28px clamp(18px, 5vw, 64px) 22px;
      background: #fcfdfb;
      border-bottom: 1px solid var(--line);
    }

    main {
      padding: 22px clamp(14px, 4vw, 54px) 44px;
    }

    h1,
    h2,
    h3,
    p {
      margin: 0;
    }

    h1 {
      max-width: 880px;
      font-size: 3rem;
      line-height: 1.08;
      letter-spacing: 0;
    }

    h2 {
      margin-top: 28px;
      font-size: 1.55rem;
      letter-spacing: 0;
    }

    h3 {
      font-size: 1rem;
      line-height: 1.25;
      letter-spacing: 0;
      overflow-wrap: anywhere;
    }

    .lead {
      max-width: 960px;
      margin-top: 12px;
      color: var(--muted);
      line-height: 1.65;
    }

    .toolbar {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin-top: 18px;
    }

    .toolbar a,
    .alternatives a {
      min-height: 36px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--surface);
      color: var(--ink);
      font-weight: 800;
      text-decoration: none;
      padding: 8px 11px;
    }

    .toolbar a:hover,
    .alternatives a:hover {
      border-color: var(--accent);
      color: var(--accent);
    }

    .board-strip {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(138px, 1fr));
      gap: 8px;
      margin-top: 18px;
      max-width: 1180px;
    }

    .board-strip span {
      display: grid;
      grid-template-columns: auto 1fr auto;
      gap: 6px;
      align-items: center;
      min-height: 44px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--surface);
      padding: 8px;
      font-size: 0.82rem;
    }

    .board-strip small {
      grid-column: 2 / 4;
      color: var(--muted);
    }

    .board-strip strong {
      color: var(--accent);
    }

    .surface-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
      gap: 14px;
      margin-top: 14px;
    }

    .surface-card {
      display: grid;
      grid-template-rows: auto 1fr;
      min-width: 0;
      border: 1px solid var(--line);
      background: var(--surface);
    }

    .surface-card img {
      display: block;
      width: 100%;
      aspect-ratio: 360 / 628;
      object-fit: cover;
      border-bottom: 1px solid var(--line);
      background: #eef1ed;
    }

    .surface-body {
      display: grid;
      gap: 8px;
      padding: 12px;
    }

    .surface-body p {
      color: var(--muted);
      line-height: 1.45;
    }

    .surface-body strong {
      color: var(--ink);
    }

    .meta {
      font-size: 0.78rem;
      font-weight: 800;
      text-transform: uppercase;
    }

    .alternatives {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 2px;
    }

    .alternatives a[aria-current="true"] {
      background: var(--surface-2);
      border-color: rgba(47, 111, 97, 0.6);
      color: var(--accent);
    }

    @media (max-width: 820px) {
      h1 {
        font-size: 2.2rem;
      }
    }
  </style>
</head>
<body>
  <header>
    <h1>${escapeHtml(output.title)}</h1>
    <p class="lead">这是 ${escapeHtml(pack.label)} 展开到全部 ${surfaces.length} 个界面/支撑组件后的可视化 ${escapeHtml(output.kind)}。每张卡显示当前选择图，也保留 A/B/C 三个备选入口。</p>
    <nav class="toolbar" aria-label="Related design documents">
      <a href="SELECTION_GUIDE.zh-CN.md">中文选择指南</a>
      <a href="${packIndexFile}">整包逐界面索引</a>
      <a href="${interfacePackComparisonFile}">按界面横向比较</a>
      <a href="${escapeHtml(output.markdownFile)}">中文逐界面表</a>
      <a href="interface-images/index.html">全部 A/B/C 图库</a>
      <a href="IMPLEMENTATION_SPEC_HIBIKI_BALANCED.md">推荐实现规格</a>
      <a href="design-pack-gallery.html">整包方案图库</a>
    </nav>
    <div class="board-strip" aria-label="Board choices for ${escapeHtml(packId)}">
      ${boardChips}
    </div>
  </header>
  <main>
    <h2>推荐界面图</h2>
    <section class="surface-grid" aria-label="Recommended surface selections">
      ${cards}
    </section>
  </main>
</body>
</html>
`;
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {Record<string, DesignPack>} packs
 * @returns {string}
 */
function renderPackIndex(surfaces, packs) {
  const cards = packOrder.map((packId) => {
    const pack = packs[packId];
    const output = outputForPack(packId);
    const packCopy = copyForPack(packId);
    if (!pack) {
      throw new Error(`Unknown pack in packOrder: ${packId}`);
    }
    const countsByBoard = boardCounts(surfaces, pack);
    const totalCounts = { A: 0, B: 0, C: 0 };
    for (const counts of countsByBoard.values()) {
      totalCounts.A += counts.A;
      totalCounts.B += counts.B;
      totalCounts.C += counts.C;
    }
    const boardSummary = boardOrder.map((boardId) => {
      const choice = pack.choices[boardId];
      return `<span><b>${boardId}</b>${escapeHtml(boardLabels[boardId].label)}<strong>${choice}</strong></span>`;
    }).join("");
    return `<article class="pack-card">
      <div>
        <p class="eyebrow">${escapeHtml(output.kind)}</p>
        <h2>${escapeHtml(pack.label)}</h2>
        <p>${escapeHtml(packCopy.summary)}</p>
      </div>
      <dl>
        <div><dt>Pack</dt><dd>${escapeHtml(packId)}</dd></div>
        <div><dt>界面</dt><dd>${surfaces.length}</dd></div>
        <div><dt>A/B/C</dt><dd>${totalCounts.A}/${totalCounts.B}/${totalCounts.C}</dd></div>
      </dl>
      <p><strong>适合：</strong>${escapeHtml(packCopy.bestFor)}</p>
      <p><strong>代价：</strong>${escapeHtml(packCopy.tradeoff)}</p>
      <div class="links">
        <a href="${escapeHtml(output.htmlFile)}">看 84 张当前选择图</a>
        <a href="${escapeHtml(output.markdownFile)}">看中文逐界面表</a>
      </div>
      <div class="boards" aria-label="${escapeHtml(pack.label)} board choices">${boardSummary}</div>
    </article>`;
  }).join("\n");

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hibiki MD3 + Cupertino 整包逐界面索引</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #202528;
      --muted: #667177;
      --line: #d8dddf;
      --page: #f7f8f4;
      --surface: #ffffff;
      --accent: #2f6f61;
      --accent-2: #365f8d;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif;
    }

    * {
      box-sizing: border-box;
    }

    body {
      margin: 0;
      background: var(--page);
      color: var(--ink);
    }

    header,
    main {
      padding-inline: clamp(16px, 5vw, 64px);
    }

    header {
      padding-block: 30px 22px;
      background: #fcfdfb;
      border-bottom: 1px solid var(--line);
    }

    main {
      padding-block: 22px 46px;
    }

    h1,
    h2,
    p {
      margin: 0;
    }

    h1 {
      max-width: 920px;
      font-size: 3rem;
      line-height: 1.08;
      letter-spacing: 0;
    }

    h2 {
      font-size: 1.35rem;
      letter-spacing: 0;
    }

    .lead {
      max-width: 940px;
      margin-top: 12px;
      color: var(--muted);
      line-height: 1.65;
    }

    .toolbar,
    .links {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
    }

    .toolbar {
      margin-top: 18px;
    }

    a {
      min-height: 36px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--surface);
      color: var(--ink);
      font-weight: 800;
      text-decoration: none;
      padding: 8px 11px;
    }

    a:hover {
      border-color: var(--accent);
      color: var(--accent);
    }

    .pack-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 16px;
    }

    .pack-card {
      display: grid;
      gap: 14px;
      align-content: start;
      border: 1px solid var(--line);
      background: var(--surface);
      padding: 16px;
    }

    .pack-card p {
      color: var(--muted);
      line-height: 1.55;
    }

    .pack-card strong {
      color: var(--ink);
    }

    .eyebrow {
      margin-bottom: 6px;
      color: var(--accent) !important;
      font-size: 0.78rem;
      font-weight: 900;
      text-transform: uppercase;
    }

    dl {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 8px;
      margin: 0;
    }

    dt {
      color: var(--muted);
      font-size: 0.78rem;
      font-weight: 800;
    }

    dd {
      margin: 2px 0 0;
      font-weight: 900;
      overflow-wrap: anywhere;
    }

    .boards {
      display: grid;
      gap: 6px;
    }

    .boards span {
      display: grid;
      grid-template-columns: auto 1fr auto;
      gap: 6px;
      align-items: center;
      min-height: 34px;
      border-top: 1px solid var(--line);
      padding-top: 6px;
      color: var(--muted);
      font-size: 0.84rem;
    }

    .boards strong {
      color: var(--accent-2);
      font-size: 0.95rem;
    }

    @media (max-width: 820px) {
      h1 {
        font-size: 2.2rem;
      }

      dl {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <header>
    <h1>Hibiki MD3 + Cupertino 整包逐界面索引</h1>
    <p class="lead">四套整包都已展开成完整 84 界面视图。先选一个整包，再去对应页面看每个界面的当前选择图；需要例外时，再回到全部 A/B/C 图库逐项替换。</p>
    <nav class="toolbar" aria-label="Related design documents">
      <a href="SELECTION_GUIDE.zh-CN.md">中文选择指南</a>
      <a href="${interfacePackComparisonFile}">按界面横向比较</a>
      <a href="design-pack-gallery.html">12 图整包速览</a>
      <a href="interface-images/index.html">全部 A/B/C 图库</a>
      <a href="INTERFACE_PICKS.md">逐界面填写表</a>
    </nav>
  </header>
  <main>
    <section class="pack-grid" aria-label="Pack selection pages">
      ${cards}
    </section>
  </main>
</body>
</html>
`;
}

/**
 * @param {ManifestSurface} surface
 * @param {Record<string, DesignPack>} packs
 * @returns {string}
 */
function renderComparisonCard(surface, packs) {
  /** @type {Choice[]} */
  const choices = ["A", "B", "C"];
  const packPills = packOrder.map((packId) => {
    const pack = packs[packId];
    if (!pack) {
      throw new Error(`Unknown pack in packOrder: ${packId}`);
    }
    const choice = selectedChoice(surface, pack);
    const output = outputForPack(packId);
    return `<span data-choice="${choice}"><b>${choice}</b>${escapeHtml(pack.label)}<a href="${escapeHtml(output.htmlFile)}#${escapeHtml(surface.slug)}">pack 页</a></span>`;
  }).join("");
  const optionCards = choices.map((choice) => {
    const copy = choiceCopy[surface.primary]?.[choice];
    if (!copy) {
      throw new Error(`Missing choice copy for board ${surface.primary} choice ${choice}.`);
    }
    const packNames = packOrder
      .filter((packId) => selectedChoice(surface, packs[packId]) === choice)
      .map((packId) => packs[packId].label);
    const chosenBy = packNames.length ? packNames.join(" / ") : "无整包默认选择";
    return `<figure class="choice-card" data-surface="${escapeHtml(surface.surface)}" data-choice="${choice}" aria-selected="false">
      <a href="interface-images/${escapeHtml(surface.files[choice])}" aria-label="${escapeHtml(surface.surface)} ${choice} full image">
        <img src="interface-images/${escapeHtml(surface.files[choice])}" alt="${escapeHtml(surface.surface)} ${choice} example">
      </a>
      <figcaption>
        <strong>${choice} · ${escapeHtml(copy.label)}</strong>
        <span>${escapeHtml(copy.why)}</span>
        <em>${escapeHtml(chosenBy)}</em>
        <button type="button" data-role="choice-select" data-surface="${escapeHtml(surface.surface)}" data-choice="${choice}">选择 ${choice}</button>
      </figcaption>
    </figure>`;
  }).join("");
  return `<article class="comparison-card" id="${escapeHtml(surface.slug)}" data-surface="${escapeHtml(surface.surface)}" data-section="${escapeHtml(surface.section)}" data-board="${escapeHtml(surface.primary)}">
    <div class="surface-head">
      <div>
        <p class="eyebrow">${escapeHtml(sectionLabels[surface.section] || surface.section)} / ${escapeHtml(boardLabels[surface.primary].label)}</p>
        <h2>${escapeHtml(surface.surface)} <span class="selected-badge" data-role="selected-badge">未选</span> <span class="review-badge" data-role="review-badge">未审</span></h2>
        <p>${escapeHtml(boardLabels[surface.primary].scope)}</p>
      </div>
      <div class="pack-pills" aria-label="${escapeHtml(surface.surface)} pack choices">
        ${packPills}
      </div>
    </div>
    <div class="choice-grid" aria-label="${escapeHtml(surface.surface)} A B C images">
      ${optionCards}
    </div>
  </article>`;
}

/**
 * @param {ManifestSurface[]} surfaces
 * @param {Record<string, DesignPack>} packs
 * @returns {string}
 */
function renderInterfacePackComparison(surfaces, packs) {
  const sections = [...new Set(surfaces.map((surface) => surface.section))].map((section) => {
    const count = surfaces.filter((surface) => surface.section === section).length;
    return `<a href="#section-${escapeHtml(section.replaceAll("/", "-").toLowerCase())}">${escapeHtml(sectionLabels[section] || section)} <b>${count}</b></a>`;
  }).join("");
  const packButtons = packOrder.map((packId) => {
    const pack = packs[packId];
    if (!pack) {
      throw new Error(`Unknown pack in packOrder: ${packId}`);
    }
    return `<button type="button" data-role="load-pack" data-pack-id="${escapeHtml(packId)}">${escapeHtml(pack.label)}</button>`;
  }).join("");
  const sectionBlocks = [...new Set(surfaces.map((surface) => surface.section))].map((section) => {
    const sectionCards = surfaces.filter((surface) => surface.section === section).map((surface) => renderComparisonCard(surface, packs)).join("\n");
    const id = `section-${section.replaceAll("/", "-").toLowerCase()}`;
    return `<section id="${escapeHtml(id)}">
      <h2>${escapeHtml(sectionLabels[section] || section)}</h2>
      <div class="comparison-stack">${sectionCards}</div>
    </section>`;
  }).join("\n");
  const comparisonData = {
    defaultPackId,
    surfaces: surfaces.map((surface) => ({
      surface: surface.surface,
      section: surface.section,
      slug: surface.slug
    })),
    packs: Object.fromEntries(packOrder.map((packId) => {
      const pack = packs[packId];
      if (!pack) {
        throw new Error(`Unknown pack in packOrder: ${packId}`);
      }
      return [packId, {
        label: pack.label,
        choices: Object.fromEntries(surfaces.map((surface) => [surface.surface, selectedChoice(surface, pack)]))
      }];
    }))
  };

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Hibiki MD3 + Cupertino 按界面横向比较</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #202528;
      --muted: #657076;
      --line: #d9dee0;
      --page: #f7f8f4;
      --surface: #ffffff;
      --surface-2: #eef5f1;
      --accent: #2f6f61;
      --accent-2: #365f8d;
      --choice-a: #2f6f61;
      --choice-b: #365f8d;
      --choice-c: #7a5a23;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei", sans-serif;
    }

    * {
      box-sizing: border-box;
    }

    html {
      scroll-behavior: smooth;
    }

    body {
      margin: 0;
      background: var(--page);
      color: var(--ink);
    }

    header,
    main {
      padding-inline: clamp(14px, 4vw, 54px);
    }

    header {
      position: sticky;
      top: 0;
      z-index: 2;
      padding-block: 22px 16px;
      background: rgba(252, 253, 251, 0.96);
      border-bottom: 1px solid var(--line);
      backdrop-filter: blur(18px);
    }

    main {
      padding-block: 22px 48px;
    }

    h1,
    h2,
    h3,
    p,
    figure {
      margin: 0;
    }

    h1 {
      max-width: 960px;
      font-size: 2.65rem;
      line-height: 1.08;
      letter-spacing: 0;
    }

    h2 {
      font-size: 1.35rem;
      letter-spacing: 0;
    }

    .lead {
      max-width: 1040px;
      margin-top: 10px;
      color: var(--muted);
      line-height: 1.6;
    }

    .toolbar,
    .section-jump,
    .selection-actions {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      margin-top: 14px;
    }

    button,
    a {
      font: inherit;
      color: inherit;
    }

    .toolbar a,
    .section-jump a,
    .pack-pills a,
    .selection-actions button,
    .choice-card button {
      min-height: 34px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: var(--surface);
      color: var(--ink);
      font-weight: 800;
      text-decoration: none;
      padding: 7px 10px;
      cursor: pointer;
    }

    .toolbar a:hover,
    .section-jump a:hover,
    .pack-pills a:hover,
    .selection-actions button:hover,
    .choice-card button:hover {
      border-color: var(--accent);
      color: var(--accent);
    }

    .selection-panel {
      display: grid;
      gap: 10px;
      margin-top: 14px;
      border: 1px solid var(--line);
      background: var(--surface);
      padding: 12px;
    }

    .selection-panel h2 {
      font-size: 1rem;
    }

    .selection-summary {
      color: var(--muted);
      line-height: 1.45;
    }

    .selection-actions button[aria-pressed="true"] {
      border-color: var(--accent);
      background: var(--surface-2);
      color: var(--accent);
    }

    .selection-output {
      width: 100%;
      min-height: 148px;
      resize: vertical;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 10px;
      color: var(--ink);
      background: #fbfcfa;
      font: 0.86rem/1.45 ui-monospace, SFMono-Regular, Consolas, "Liberation Mono", monospace;
    }

    .selection-status {
      min-height: 20px;
      color: var(--accent-2);
      font-weight: 800;
    }

    .section-jump a {
      display: inline-flex;
      gap: 6px;
      align-items: center;
      color: var(--muted);
    }

    main > section + section {
      margin-top: 28px;
    }

    .comparison-stack {
      display: grid;
      gap: 18px;
      margin-top: 12px;
    }

    .comparison-card {
      display: grid;
      gap: 14px;
      border: 1px solid var(--line);
      background: var(--surface);
      padding: 14px;
    }

    .surface-head {
      display: grid;
      grid-template-columns: minmax(0, 1fr) minmax(260px, 420px);
      gap: 16px;
      align-items: start;
    }

    .surface-head h2 {
      overflow-wrap: anywhere;
    }

    .selected-badge {
      display: inline-flex;
      align-items: center;
      min-height: 26px;
      margin-left: 6px;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 3px 8px;
      color: var(--muted);
      font-size: 0.78rem;
      font-weight: 900;
      vertical-align: middle;
    }

    .review-badge {
      display: inline-flex;
      align-items: center;
      min-height: 26px;
      margin-left: 4px;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 3px 8px;
      color: var(--muted);
      font-size: 0.78rem;
      font-weight: 900;
      vertical-align: middle;
    }

    .comparison-card[data-reviewed="true"] .review-badge {
      color: var(--accent);
      border-color: rgba(47, 111, 97, 0.35);
      background: rgba(47, 111, 97, 0.08);
    }

    .comparison-card[data-review-filter-hidden="true"] {
      display: none;
    }

    .comparison-card[data-selected-choice="A"] .selected-badge {
      color: var(--choice-a);
      border-color: rgba(47, 111, 97, 0.35);
      background: rgba(47, 111, 97, 0.08);
    }

    .comparison-card[data-selected-choice="B"] .selected-badge {
      color: var(--choice-b);
      border-color: rgba(54, 95, 141, 0.35);
      background: rgba(54, 95, 141, 0.08);
    }

    .comparison-card[data-selected-choice="C"] .selected-badge {
      color: var(--choice-c);
      border-color: rgba(122, 90, 35, 0.35);
      background: rgba(122, 90, 35, 0.08);
    }

    .surface-head p {
      margin-top: 6px;
      color: var(--muted);
      line-height: 1.45;
    }

    .eyebrow {
      margin-top: 0 !important;
      color: var(--accent) !important;
      font-size: 0.78rem;
      font-weight: 900;
      text-transform: uppercase;
    }

    .pack-pills {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 8px;
    }

    .pack-pills span {
      display: grid;
      grid-template-columns: auto 1fr auto;
      gap: 7px;
      align-items: center;
      min-height: 40px;
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 7px;
      color: var(--muted);
      font-size: 0.82rem;
      line-height: 1.2;
    }

    .pack-pills b {
      color: var(--ink);
      font-size: 1rem;
    }

    .pack-pills span[data-choice="A"] b {
      color: var(--choice-a);
    }

    .pack-pills span[data-choice="B"] b {
      color: var(--choice-b);
    }

    .pack-pills span[data-choice="C"] b {
      color: var(--choice-c);
    }

    .pack-pills a {
      min-height: 28px;
      padding: 5px 7px;
      font-size: 0.75rem;
      white-space: nowrap;
    }

    .choice-grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 12px;
    }

    .choice-card {
      display: grid;
      grid-template-rows: auto 1fr;
      min-width: 0;
      border: 1px solid var(--line);
      background: #fbfcfa;
    }

    .choice-card[aria-selected="true"] {
      border-color: var(--accent-2);
      box-shadow: 0 0 0 3px rgba(54, 95, 141, 0.13);
    }

    .choice-card img {
      display: block;
      width: 100%;
      aspect-ratio: 360 / 628;
      object-fit: cover;
      border-bottom: 1px solid var(--line);
      background: #eef1ed;
    }

    figcaption {
      display: grid;
      gap: 6px;
      padding: 10px;
    }

    figcaption strong {
      line-height: 1.25;
      overflow-wrap: anywhere;
    }

    figcaption span,
    figcaption em {
      color: var(--muted);
      font-style: normal;
      line-height: 1.42;
    }

    figcaption em {
      font-size: 0.82rem;
      font-weight: 800;
    }

    .choice-card button {
      justify-self: start;
      min-height: 32px;
      margin-top: 2px;
      padding: 6px 10px;
    }

    .choice-card button[aria-pressed="true"] {
      color: #fff;
      border-color: var(--accent-2);
      background: var(--accent-2);
    }

    .choice-card[data-choice="A"] strong {
      color: var(--choice-a);
    }

    .choice-card[data-choice="B"] strong {
      color: var(--choice-b);
    }

    .choice-card[data-choice="C"] strong {
      color: var(--choice-c);
    }

    @media (max-width: 1180px) {
      .surface-head {
        grid-template-columns: 1fr;
      }
    }

    @media (max-width: 860px) {
      header {
        position: static;
      }

      h1 {
        font-size: 2.05rem;
      }

      .choice-grid {
        grid-template-columns: 1fr;
      }

      .pack-pills {
        grid-template-columns: 1fr;
      }
    }
  </style>
</head>
<body>
  <header>
    <h1>Hibiki MD3 + Cupertino 按界面横向比较</h1>
    <p class="lead">每个界面一张卡：左侧是界面名和设计板块，右侧标出四套整包各自选 A/B/C，下方并排展示该界面的三张候选图。用它来快速决定例外，不需要在四个整包页面之间来回跳。</p>
    <nav class="toolbar" aria-label="Related design documents">
      <a href="SELECTION_GUIDE.zh-CN.md">中文选择指南</a>
      <a href="${packIndexFile}">整包逐界面索引</a>
      <a href="interface-images/index.html">全部 A/B/C 图库</a>
      <a href="INTERFACE_PICKS.md">逐界面填写表</a>
    </nav>
    <section class="selection-panel" aria-label="Final selection exporter">
      <h2>直接在本页挑最终方案</h2>
      <p class="selection-summary" data-role="selection-summary">正在载入选择状态。</p>
      <div class="selection-actions" aria-label="Load pack baseline">
        ${packButtons}
      </div>
      <textarea id="selection-output" class="selection-output" readonly spellcheck="false" aria-label="Copyable final selection"></textarea>
      <div class="selection-actions" aria-label="Selection actions">
        <button type="button" data-role="mark-reviewed">标记当前界面已审</button>
        <button type="button" data-role="next-unreviewed">跳到下一个未审</button>
        <button type="button" data-role="only-unreviewed" aria-pressed="false">只看未审</button>
        <button type="button" data-role="copy-selection">复制最终选择文本</button>
        <button type="button" data-role="reset-selection">重置为 Hibiki Balanced</button>
      </div>
      <p class="selection-status" data-role="selection-status" aria-live="polite"></p>
    </section>
    <nav class="section-jump" aria-label="Jump to interface groups">
      ${sections}
    </nav>
  </header>
  <main>
    ${sectionBlocks}
  </main>
  <script type="application/json" id="selection-data">${escapeScriptJson(comparisonData)}</script>
  <script>
    (() => {
      const data = JSON.parse(document.getElementById("selection-data").textContent);
      const storageKey = "hibiki-md3-cupertino-interface-comparison-v1";
      const choices = new Set(["A", "B", "C"]);
      const output = document.getElementById("selection-output");
      const summary = document.querySelector("[data-role='selection-summary']");
      const status = document.querySelector("[data-role='selection-status']");
      const packButtons = Array.from(document.querySelectorAll("[data-role='load-pack']"));
      const choiceButtons = Array.from(document.querySelectorAll("[data-role='choice-select']"));
      const markReviewedButton = document.querySelector("[data-role='mark-reviewed']");
      const nextUnreviewedButton = document.querySelector("[data-role='next-unreviewed']");
      const onlyUnreviewedButton = document.querySelector("[data-role='only-unreviewed']");

      let activeSurface = data.surfaces[0] ? data.surfaces[0].surface : "";
      let onlyUnreviewed = false;
      let state = loadState();

      function validPackId(packId) {
        return Boolean(packId && data.packs[packId]);
      }

      function packChoices(packId) {
        return data.packs[packId].choices;
      }

      function choicesForPack(packId) {
        const baseline = packChoices(packId);
        return Object.fromEntries(data.surfaces.map((surface) => [surface.surface, baseline[surface.surface]]));
      }

      function normalizeState(value) {
        const packId = validPackId(value && value.packId) ? value.packId : data.defaultPackId;
        const baseline = choicesForPack(packId);
        const inputChoices = value && typeof value.choices === "object" && value.choices ? value.choices : {};
        const reviewed = new Set(Array.isArray(value && value.reviewed) ? value.reviewed.filter((surface) => baseline[surface]) : []);
        for (const surface of data.surfaces) {
          const choice = inputChoices[surface.surface];
          if (choices.has(choice)) {
            baseline[surface.surface] = choice;
          }
        }
        return { packId, choices: baseline, reviewed: Array.from(reviewed) };
      }

      function loadState() {
        try {
          const stored = localStorage.getItem(storageKey);
          return normalizeState(stored ? JSON.parse(stored) : null);
        } catch {
          return normalizeState(null);
        }
      }

      function saveState() {
        localStorage.setItem(storageKey, JSON.stringify(state));
      }

      function setStatus(message) {
        status.textContent = message;
      }

      function exceptionSurfaces() {
        const baseline = packChoices(state.packId);
        return data.surfaces.filter((surface) => state.choices[surface.surface] !== baseline[surface.surface]);
      }

      function reviewedSet() {
        return new Set(Array.isArray(state.reviewed) ? state.reviewed : []);
      }

      function reviewedCount() {
        return reviewedSet().size;
      }

      function isReviewed(surfaceName) {
        return reviewedSet().has(surfaceName);
      }

      function setReviewed(surfaceName, reviewed) {
        const next = reviewedSet();
        if (reviewed) {
          next.add(surfaceName);
        } else {
          next.delete(surfaceName);
        }
        state.reviewed = Array.from(next);
      }

      function exportedText() {
        const exceptions = exceptionSurfaces();
        const lines = ["Pack: " + state.packId, "例外:"];
        if (exceptions.length === 0) {
          lines.push("# 无例外，使用整包默认选择。");
        } else {
          for (const surface of exceptions) {
            lines.push(surface.surface + ": " + state.choices[surface.surface]);
          }
        }
        lines.push("", "Notes:", "- 从 interface-pack-comparison.html 导出。");
        lines.push("- 已审界面：" + reviewedCount() + " / " + data.surfaces.length + "。");
        return lines.join("\\n");
      }

      function currentSurfaceName() {
        if (activeSurface && data.surfaces.some((surface) => surface.surface === activeSurface)) {
          return activeSurface;
        }
        return data.surfaces[0] ? data.surfaces[0].surface : "";
      }

      function visibleArticles() {
        return Array.from(document.querySelectorAll(".comparison-card")).filter((article) => article.dataset.reviewFilterHidden !== "true");
      }

      function focusArticle(article) {
        if (!article) {
          return;
        }
        activeSurface = article.dataset.surface;
        article.scrollIntoView({ behavior: "smooth", block: "start" });
        render();
      }

      function render() {
        const exceptions = exceptionSurfaces();
        const reviewed = reviewedSet();
        output.value = exportedText();
        summary.textContent = "当前基准：" + data.packs[state.packId].label + "；已选择 " + data.surfaces.length + " 个界面；已审 " + reviewed.size + " / " + data.surfaces.length + "；相对基准有 " + exceptions.length + " 个例外。复制下面文本即可生成实现规格。";
        for (const packButton of packButtons) {
          packButton.setAttribute("aria-pressed", packButton.dataset.packId === state.packId ? "true" : "false");
        }
        for (const article of document.querySelectorAll(".comparison-card")) {
          const selected = state.choices[article.dataset.surface];
          const articleReviewed = reviewed.has(article.dataset.surface);
          article.dataset.selectedChoice = selected;
          article.dataset.reviewed = articleReviewed ? "true" : "false";
          article.dataset.reviewFilterHidden = onlyUnreviewed && articleReviewed ? "true" : "false";
          const badge = article.querySelector("[data-role='selected-badge']");
          if (badge) {
            badge.textContent = "当前 " + selected;
          }
          const reviewBadge = article.querySelector("[data-role='review-badge']");
          if (reviewBadge) {
            reviewBadge.textContent = articleReviewed ? "已审" : "未审";
          }
          for (const card of article.querySelectorAll(".choice-card")) {
            card.setAttribute("aria-selected", card.dataset.choice === selected ? "true" : "false");
          }
        }
        for (const button of choiceButtons) {
          const selected = state.choices[button.dataset.surface] === button.dataset.choice;
          button.setAttribute("aria-pressed", selected ? "true" : "false");
          button.textContent = selected ? "已选 " + button.dataset.choice : "选择 " + button.dataset.choice;
        }
        onlyUnreviewedButton.setAttribute("aria-pressed", onlyUnreviewed ? "true" : "false");
        markReviewedButton.textContent = isReviewed(currentSurfaceName()) ? "当前界面取消已审" : "标记当前界面已审";
      }

      function loadPack(packId) {
        state = { packId, choices: choicesForPack(packId), reviewed: [] };
        saveState();
        render();
        setStatus("已载入 " + data.packs[packId].label + " 作为基准。");
      }

      for (const packButton of packButtons) {
        packButton.addEventListener("click", () => loadPack(packButton.dataset.packId));
      }

      for (const button of choiceButtons) {
        button.addEventListener("click", () => {
          activeSurface = button.dataset.surface;
          state.choices[button.dataset.surface] = button.dataset.choice;
          setReviewed(button.dataset.surface, true);
          saveState();
          render();
          setStatus(button.dataset.surface + " 已选择 " + button.dataset.choice + "。");
        });
      }

      for (const article of document.querySelectorAll(".comparison-card")) {
        article.addEventListener("focusin", () => {
          activeSurface = article.dataset.surface;
          render();
        });
        article.addEventListener("click", (event) => {
          if (event.target.closest("a, button")) {
            return;
          }
          activeSurface = article.dataset.surface;
          render();
        });
      }

      markReviewedButton.addEventListener("click", () => {
        const surfaceName = currentSurfaceName();
        setReviewed(surfaceName, !isReviewed(surfaceName));
        saveState();
        render();
        setStatus(surfaceName + (isReviewed(surfaceName) ? " 已标记为已审。" : " 已取消已审。"));
      });
      nextUnreviewedButton.addEventListener("click", () => {
        const articles = Array.from(document.querySelectorAll(".comparison-card"));
        const startIndex = Math.max(0, articles.findIndex((article) => article.dataset.surface === currentSurfaceName()));
        const ordered = articles.slice(startIndex + 1).concat(articles.slice(0, startIndex + 1));
        const next = ordered.find((article) => !isReviewed(article.dataset.surface));
        if (!next) {
          setStatus("全部界面都已审。");
          return;
        }
        focusArticle(next);
        setStatus("已跳到未审界面：" + next.dataset.surface + "。");
      });
      onlyUnreviewedButton.addEventListener("click", () => {
        onlyUnreviewed = !onlyUnreviewed;
        render();
        const first = visibleArticles()[0];
        if (first) {
          activeSurface = first.dataset.surface;
          render();
        }
        setStatus(onlyUnreviewed ? "现在只显示未审界面。" : "已显示全部界面。");
      });
      document.querySelector("[data-role='reset-selection']").addEventListener("click", () => loadPack(data.defaultPackId));
      document.querySelector("[data-role='copy-selection']").addEventListener("click", async () => {
        output.focus();
        output.select();
        try {
          await navigator.clipboard.writeText(output.value);
          setStatus("已复制最终选择文本。");
        } catch {
          document.execCommand("copy");
          setStatus("已选中文本；如果浏览器阻止复制，请手动复制。");
        }
      });

      render();
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
  const args = parseArgs(process.argv.slice(2));
  const { surfaces, packs } = await loadInputs();
  validatePacks(packs);
  const selectedPackIds = args.allPacks ? packOrder : [args.packId];
  for (const packId of selectedPackIds) {
    const pack = packs[packId];
    if (!pack) {
      throw new Error(`Unknown pack: ${packId}. Valid packs: ${Object.keys(packs).join(", ")}`);
    }
    const output = outputForPack(packId);
    const markdownPath = args.markdownPath ? args.markdownPath : join(__dirname, output.markdownFile);
    const htmlPath = args.htmlPath ? args.htmlPath : join(__dirname, output.htmlFile);
    await writeFile(markdownPath, renderMarkdown(surfaces, pack, packId), "utf8");
    await writeFile(htmlPath, renderHtml(surfaces, pack, packId), "utf8");
    console.log(`Wrote ${relative(__dirname, markdownPath)} and ${relative(__dirname, htmlPath)} for ${surfaces.length} surfaces.`);
  }
  if (args.allPacks) {
    await writeFile(args.indexPath, renderPackIndex(surfaces, packs), "utf8");
    console.log(`Wrote ${relative(__dirname, args.indexPath)}.`);
    await writeFile(args.comparisonPath, renderInterfacePackComparison(surfaces, packs), "utf8");
    console.log(`Wrote ${relative(__dirname, args.comparisonPath)}.`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
