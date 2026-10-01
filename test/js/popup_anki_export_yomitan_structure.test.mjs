// BUG-2825 行为测试（jsdom 真实 DOM）：制卡导出的释义 HTML 必须与 Yomitan 导出到 Anki 的结构一致。
//
// 上游（yomidevs/yomitan@67db60ddc2）：
//   * structured-content-generator.js `createDefinitionImage`：图片外层恒为
//     `<a class="gloss-image-link" target="_blank" rel="noreferrer noopener">`，Anki 导出时
//     `_setImageData` 写 `href = 媒体文件名`；
//   * anki-template-renderer.js `_getStructuredContentHtml` → `_normalizeHtml`：
//     css-style-applier.js `applyClassStyles` 按 ext/data/structured-content-style.json 把命中的
//     规则写成内联样式（在元素已有内联样式之前）并删掉 class；再删掉除 `data-sc*` 外的 data-*。
//
// Fushi 修复前：导出外层是 <span>（Lapis 的 `.definition a span` 宽度上限与
// `.definition a:has(img)` 点击放大全部落空，「絵でわかる慣用句」插图从 2×2 变成一张一行），
// gloss-* class 原样留在卡片上（词典写给弹窗的 CSS 在卡片上生效：旺文社「類語」表头被
// `[data-sc縦中横] > .gloss-sc-span` 改成绝对定位竖排），`data-vertical-align` 没落成样式
// （Pixiv logo 对不齐）。
//
// 这里真执行 popup.js 的两个制卡构建器（constructGlossaryHtml / constructSingleGlossaryHtml），
// 把产出的 HTML 当作卡片重新解析后断言；同时守住弹窗（非导出）路径不变。
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

const popupSrc = readFileSync(
  new URL("../../fushi/assets/popup/popup.js", import.meta.url),
  "utf8",
);
const dictMediaSrc = readFileSync(
  new URL("../../fushi/assets/popup/dict-media.js", import.meta.url),
  "utf8",
);

const IDIOM_DICT = "絵でわかる慣用句";
const PIXIV_DICT = "pixiv";
const OBUNSHA_DICT = "旺文社国語辞典";
const SANSEIDO_DICT = "三省堂国語辞典";

// 旺文社自带 CSS 里把「類語」表头改成绝对定位竖排的那条（用户卡片实测）。
const OBUNSHA_CSS =
  "[data-sc縦中横] > .gloss-sc-span { position: absolute; writing-mode: vertical-rl; }";

function structured(content) {
  return JSON.stringify({ type: "structured-content", content });
}

const ENTRY = {
  expression: "毒を食らわば皿まで",
  reading: "どくをくらわばさらまで",
  frequencies: [],
  pitches: [],
  glossaries: [
    {
      dictionary: IDIOM_DICT,
      definitionTags: "",
      termTags: "",
      content: structured([
        {
          tag: "details",
          content: [
            { tag: "summary", content: "絵でわかる" },
            { tag: "img", path: "img/1.png", width: 300, height: 200, title: "1" },
            { tag: "img", path: "img/2.png", width: 300, height: 200, title: "2" },
            { tag: "img", path: "img/3.png", width: 300, height: 200, title: "3" },
            { tag: "img", path: "img/4.png", width: 300, height: 200, title: "4" },
          ],
        },
      ]),
    },
    {
      dictionary: PIXIV_DICT,
      definitionTags: "",
      termTags: "",
      content: structured([
        {
          tag: "img",
          path: "logo.png",
          width: 1,
          height: 1,
          sizeUnits: "em",
          verticalAlign: "middle",
        },
        "ピクシブ百科事典",
      ]),
    },
    {
      dictionary: OBUNSHA_DICT,
      definitionTags: "",
      termTags: "",
      content: structured([
        {
          tag: "table",
          content: [
            {
              tag: "tr",
              content: [
                { tag: "th", content: { tag: "span", data: { 縦中横: "" }, content: "類語" } },
                { tag: "td", style: { textAlign: "center" }, content: "毒" },
              ],
            },
          ],
        },
      ]),
    },
    {
      dictionary: SANSEIDO_DICT,
      definitionTags: "",
      termTags: "",
      content: structured([
        {
          tag: "a",
          href: "?query=毒",
          content: [
            "毒",
            {
              tag: "span",
              style: { fontSize: "0.65em", verticalAlign: "super" },
              content: { tag: "img", path: "ku.svg", width: 1, height: 1, sizeUnits: "em" },
            },
          ],
        },
      ]),
    },
  ],
};

function createPopup() {
  const dom = new JSDOM("<!DOCTYPE html><body><div id=\"entries-container\"></div></body>", {
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });
  const win = dom.window;
  win.flutter_inappwebview = { callHandler: () => Promise.resolve(false) };
  win.matchMedia = (query) => ({
    media: query,
    matches: false,
    addListener() {},
    removeListener() {},
  });
  // buildMinePayload 在渲染字段前开这个登记表（getMediaFilename 往里登记占位符）。
  // popup.js 的顶层 let 只在同一次 eval 里可见，故与源码同一段注入。
  win.eval(`${dictMediaSrc}\n${popupSrc}\n;currentDictionaryMedia = new Map();`);
  win.lookupEntries = [ENTRY];
  win.dictionaryStyles = { [OBUNSHA_DICT]: OBUNSHA_CSS };
  win.hiddenDictionaryNames = [];
  win.embedMedia = true;
  return win;
}

// 把导出的字段 HTML 当成 Anki 卡片重新解析（Lapis 的 .definition 包着字段）。
function asCard(win, html) {
  const card = win.document.createElement("div");
  card.className = "definition";
  card.innerHTML = html;
  return card;
}

function glossaryContentElements(card) {
  // 每条义项的正文在 <li data-dictionary><i>label</i> <span>…</span></li> 的 span 里。
  return Array.from(card.querySelectorAll("li[data-dictionary] > span")).flatMap((span) =>
    Array.from(span.querySelectorAll("*")),
  );
}

function exportedBuilders(win) {
  const single = win.constructSingleGlossaryHtml(0);
  return {
    "{glossary}": win.constructGlossaryHtml(0),
    "{single-glossary} (全部词典拼起来)": Object.values(single).join(""),
  };
}

test("导出图片外层是 Yomitan 同形的 <a target rel href=媒体文件名>，Lapis 的 a 选择器命中", () => {
  const win = createPopup();
  for (const [name, html] of Object.entries(exportedBuilders(win))) {
    const card = asCard(win, html);
    const images = Array.from(card.querySelectorAll("img"));
    assert.equal(images.length, 6, `${name}: 4 张插图 + logo + 句图标都要导出`);
    for (const img of images) {
      const link = img.closest("a[target]");
      assert.ok(link, `${name}: <img src=${img.getAttribute("src")}> 外层必须是 <a>`);
      assert.equal(link.getAttribute("target"), "_blank");
      assert.equal(link.getAttribute("rel"), "noreferrer noopener");
      assert.match(img.getAttribute("src"), /^fushi_dict_\d+\.(png|svg)$/);
      assert.equal(
        link.getAttribute("href"),
        img.getAttribute("src"),
        `${name}: 图片链接 href 必须是同一个媒体文件名（Yomitan _setImageData），不能被交叉引用改写`,
      );
    }
    // Lapis：`.definition a span`（插图宽度上限）与 `.definition a:has(img)`（点击放大）。
    const idiomItem = card.querySelector(`li[data-dictionary="${IDIOM_DICT}"]`);
    const idiomLinks = idiomItem.querySelectorAll("a:has(img)");
    assert.equal(idiomLinks.length, 4, `${name}: 4 张插图都要被 .definition a:has(img) 命中`);
    for (const link of idiomLinks) {
      assert.ok(link.matches(".definition a:has(img)"));
      assert.ok(
        link.querySelector(":scope > span").matches(".definition a span"),
        `${name}: 图片容器必须被 .definition a span 命中`,
      );
    }
  }
});

test("导出义项里没有 gloss-* / structured-content class，属性驱动的样式已内联", () => {
  const win = createPopup();
  for (const [name, html] of Object.entries(exportedBuilders(win))) {
    const card = asCard(win, html);
    const elements = glossaryContentElements(card);
    assert.ok(elements.length > 20, `${name}: 导出树不能是空的`);
    for (const el of elements) {
      const cls = el.getAttribute("class") || "";
      assert.ok(
        !/(^|\s)(gloss-[\w-]+|structured-content)(\s|$)/.test(cls),
        `${name}: 卡片上不应残留生成器 class，发现 <${el.tagName.toLowerCase()} class="${cls}">`,
      );
      for (const attr of Array.from(el.attributes)) {
        if (!attr.name.startsWith("data-")) continue;
        assert.match(
          attr.name,
          /^data-sc(?:[^a-z]|$)/,
          `${name}: 只保留 data-sc*（Yomitan 同口径），发现 ${attr.name}`,
        );
      }
    }

    // Pixiv logo：verticalAlign:'middle' 落成内联 vertical-align:middle（规则来自
    // structured-content-style.json `.gloss-image-link[data-vertical-align=middle]`）。
    const logoLink = card
      .querySelector(`li[data-dictionary="${PIXIV_DICT}"] img`)
      .closest("a");
    assert.equal(logoLink.style.verticalAlign, "middle", `${name}: data-vertical-align 必须转成样式`);
    assert.equal(logoLink.hasAttribute("data-vertical-align"), false);
    // em 图容器按规则 `[data-size-units=em] .gloss-image-container{font-size:1em}`。
    assert.equal(logoLink.querySelector(":scope > span").style.fontSize, "1em");

    // 非 em 插图的容器是 Yomitan 的 font-size:1px（usedWidth em = usedWidth px）。
    const idiomContainer = card
      .querySelector(`li[data-dictionary="${IDIOM_DICT}"] img`)
      .closest("a")
      .querySelector(":scope > span");
    assert.equal(idiomContainer.style.fontSize, "1px");
    assert.equal(idiomContainer.style.width, "300em");

    // 旺文社表格：th/td 规则内联，td 自己的内联样式保留（同一个 style 属性里，不出现第二个 style）。
    const obunsha = card.querySelector(`li[data-dictionary="${OBUNSHA_DICT}"]`);
    const th = obunsha.querySelector("th");
    const td = obunsha.querySelector("td");
    assert.equal(th.style.fontWeight, "bold");
    assert.equal(td.style.borderStyle, "solid");
    assert.equal(td.style.textAlign, "center", `${name}: 词典自己的单元格样式不能被表格规则顶掉`);
    assert.equal(obunsha.querySelector("table").style.borderCollapse, "collapse");
    // data-sc縦中横 原样保留（Yomitan 也保留），但词典写给弹窗的
    // `[data-sc縦中横] > .gloss-sc-span` 在卡片上命中不到。
    const tategaki = obunsha.querySelector("th > span");
    assert.ok(tategaki.hasAttribute("data-sc縦中横"));
    assert.ok(html.includes("<style>"), `${name}: 词典 CSS 仍以 <style> 随卡下发（Yomitan 同样）`);
    assert.equal(
      card.querySelectorAll(
        `.yomitan-glossary [data-dictionary="${OBUNSHA_DICT}"] [data-sc縦中横] > .gloss-sc-span`,
      ).length,
      0,
      `${name}: 词典写给弹窗的 class 选择器不能在卡片上命中`,
    );
  }
});

test("文本交叉引用照旧改写成 fushi 深链，内含的图标链接保留媒体 href", () => {
  const win = createPopup();
  const card = asCard(win, win.constructGlossaryHtml(0));
  const item = card.querySelector(`li[data-dictionary="${SANSEIDO_DICT}"]`);
  // 两层 <a> 在 HTML 解析时会被拆开（Yomitan 卡同样如此），所以按 href 找。
  const anchors = Array.from(item.querySelectorAll("a[href]"));
  assert.ok(
    anchors.some((a) => a.getAttribute("href").startsWith("fushi://lookup?word=")),
    "文本交叉引用必须改写成 fushi 深链",
  );
  const iconLink = item.querySelector("img").closest("a");
  assert.match(iconLink.getAttribute("href"), /^fushi_dict_\d+\.svg$/);
  // 三省堂「句」图标：与 Yomitan 卡一样，嵌套 <a> 被解析器拆开后图标落到 0.65em 上标之外，
  // 按正文字号显示（外层是 <span> 时不拆，图标被上标缩成 13px 并上浮）。
  assert.equal(
    iconLink.closest('span[style*="0.65em"]'),
    null,
    "图标链接不应再困在 0.65em 的上标 span 里",
  );
});

test("弹窗（非导出）路径不变：<a> 无 href、保留 class 与 data-*，不内联规则样式", () => {
  const win = createPopup();
  const node = win.createDefinitionImage(
    { path: "logo.png", width: 1, height: 1, sizeUnits: "em", verticalAlign: "middle" },
    PIXIV_DICT,
    false,
  );
  const link = node.classList.contains("gloss-image-link")
    ? node
    : node.querySelector(".gloss-image-link");
  assert.ok(link, "弹窗图片仍是 .gloss-image-link");
  assert.equal(link.tagName, "A");
  assert.equal(link.getAttribute("target"), "_blank");
  assert.equal(link.getAttribute("rel"), "noreferrer noopener");
  assert.equal(link.hasAttribute("href"), false, "弹窗图片点击走灯箱，不带 href");
  assert.equal(link.dataset.verticalAlign, "middle", "弹窗靠 popup.css 的属性选择器出样式");
  assert.equal(link.style.verticalAlign, "", "弹窗不内联导出规则");

  const parent = win.document.createElement("div");
  win.renderStructuredContent(
    parent,
    { tag: "span", data: { 縦中横: "" }, content: "類語" },
    null,
    OBUNSHA_DICT,
    false,
  );
  assert.ok(parent.querySelector("span.gloss-sc-span[data-sc縦中横]"), "弹窗保留 gloss-sc-* class");
});
