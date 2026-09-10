// 词头逐字点击的**行为**测试（jsdom 真 DOM）。
//
// 用户 2026-09-10 反馈：弹窗词头「置かない」点中间的 か，应该查「かない」（从这个字
// 到词尾的剩下那段），而不是把整个词头原样再搜一遍——那是一次空转查询，点了等于没点。
// 旧实现只把**汉字**包成可点格（.kanji-inline），假名落在 else 分支上，于是整词重查。
//
// 为什么必须是行为测试：popup.js 的注释里写满了 `.kanji-inline` / `expression` 这些
// 被断言的名字，纯源码扫描守卫会被注释喂成假绿（同仓 popup-mine-key 已实测过这种
// 变异）。这里把 KANJI_PATTERN + wrapExpressionInlineKanji + resolveExpressionTapTarget
// 从真源码切出来丢进 jsdom 真执行，直接对着 DOM 断言「点哪个字 → 查什么串」。
// 切片锚点都有断言，源码重排会让本测试红而不是静默失效。
//
// DOM fixture 就是 postProcessRuby 实际吐出的形状（.ruby-unit / .ruby-reserve 孪生体 /
// BUG-1487 的 .ruby-rt 中性 span），因为下标是按「可见基字的文档序」累加的——读音和
// 孪生体一旦漏进来，下标就会整体错位。
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

const POPUP_URL = new URL("../../fushi/assets/popup/popup.js", import.meta.url);

function sliceHeadwordTapCode() {
  const src = readFileSync(POPUP_URL, "utf8");

  const kanjiStart = src.indexOf("const KANJI_RANGE =");
  assert.ok(kanjiStart >= 0, "切片锚失效：找不到 KANJI_RANGE");
  const kanjiEnd = src.indexOf("\n", src.indexOf("const KANJI_PATTERN ="));
  assert.ok(kanjiEnd > kanjiStart, "切片锚失效：找不到 KANJI_PATTERN");

  const wrapStart = src.indexOf("function wrapExpressionInlineKanji(container) {");
  assert.ok(wrapStart >= 0, "切片锚失效：找不到 wrapExpressionInlineKanji");
  const wrapEnd = src.indexOf("\nfunction createEntryHeader(entry, idx) {", wrapStart);
  assert.ok(wrapEnd > wrapStart, "切片锚失效：找不到 createEntryHeader");

  const slice = src.slice(kanjiStart, kanjiEnd) + "\n" + src.slice(wrapStart, wrapEnd);
  // 真切到了两个实现，而不是切出一段空壳。
  assert.ok(
    slice.includes("function resolveExpressionTapTarget"),
    "切片里没有 resolveExpressionTapTarget",
  );
  return slice;
}

const HEADWORD_TAP_CODE = sliceHeadwordTapCode();

/// 造一个 postProcessRuby 之后的词头：expression 逐字建 DOM，kanjiReadings 里给了读音
/// 的字包成 .ruby-unit（含 .ruby-reserve 孪生体 + .ruby-rt）。
function createHeadword(expression, rubyOn = {}) {
  const dom = new JSDOM("<!DOCTYPE html><body></body>", {
    runScripts: "outside-only",
  });
  const win = dom.window;
  const root = win.document.createElement("span");
  root.className = "expression";
  for (const ch of expression) {
    const reading = rubyOn[ch];
    if (!reading) {
      root.appendChild(win.document.createTextNode(ch));
      continue;
    }
    const ruby = win.document.createElement("ruby");
    const unit = win.document.createElement("span");
    unit.className = "ruby-unit";
    const reserve = win.document.createElement("span");
    reserve.className = "ruby-reserve";
    reserve.setAttribute("aria-hidden", "true");
    reserve.textContent = reading;
    unit.appendChild(reserve);
    unit.appendChild(win.document.createTextNode(ch));
    const rtBox = win.document.createElement("span");
    rtBox.className = "ruby-rt";
    const rt = win.document.createElement("rt");
    rt.textContent = reading;
    rtBox.appendChild(rt);
    unit.appendChild(rtBox);
    ruby.appendChild(unit);
    root.appendChild(ruby);
  }
  win.document.body.appendChild(root);
  win.eval(HEADWORD_TAP_CODE);
  win.wrapExpressionInlineKanji(root);
  return { win, root };
}

function cells(root) {
  return Array.from(root.querySelectorAll(".expr-char"));
}

function tap(win, expression, target) {
  return win.resolveExpressionTapTarget(expression, target);
}

test("点词头假名查「从该字到词尾」，不是整词重搜", () => {
  const expression = "置かない";
  const { win, root } = createHeadword(expression, { 置: "お" });
  const [ka] = cells(root).filter((c) => c.textContent === "か");

  const hit = tap(win, expression, ka);
  assert.equal(hit.term, "かない");
  assert.equal(hit.anchorEl, ka);

  const [na] = cells(root).filter((c) => c.textContent === "な");
  assert.equal(tap(win, expression, na).term, "ない");
});

test("词头每个可见字都是自己的点击格，读音与孪生体不进格", () => {
  const expression = "置かない";
  const { root } = createHeadword(expression, { 置: "お" });

  assert.deepEqual(
    cells(root).map((c) => c.textContent),
    ["置", "か", "な", "い"],
  );
  assert.deepEqual(
    cells(root).map((c) => c.getAttribute("data-char-index")),
    ["0", "1", "2", "3"],
  );
  // 孪生体和 <rt> 里的「お」都没有被包成可点格（包了就会让下标整体错位）。
  assert.equal(root.querySelector(".ruby-reserve").textContent, "お");
  assert.equal(root.querySelector(".ruby-reserve .expr-char"), null);
  assert.equal(root.querySelector("rt .expr-char"), null);
});

test("汉字格仍查单字（汉字卡入口不变）", () => {
  const expression = "置かない";
  const { win, root } = createHeadword(expression, { 置: "お" });
  const [oku] = cells(root).filter((c) => c.textContent === "置");

  assert.ok(oku.classList.contains("kanji-inline"));
  const hit = tap(win, expression, oku);
  assert.equal(hit.term, "置");
  assert.equal(hit.anchorEl, oku);
});

test("点读音/空隙落空时退回整词（调用方旧行为）", () => {
  const expression = "置かない";
  const { win, root } = createHeadword(expression, { 置: "お" });

  assert.equal(tap(win, expression, root.querySelector("rt")), null);
  assert.equal(tap(win, expression, root), null);
  assert.equal(tap(win, expression, null), null);
});

test("下标是 UTF-16 域，代理对不会把后面的字整体切歪", () => {
  // 𠮟 是 U+20B9F（代理对，长度 2），且不在 KANJI_PATTERN 的范围里 → 普通字格。
  const expression = "\u{20B9F}かない";
  const { win, root } = createHeadword(expression);

  assert.deepEqual(
    cells(root).map((c) => c.getAttribute("data-char-index")),
    ["0", "2", "3", "4"],
  );
  const [ka] = cells(root).filter((c) => c.textContent === "か");
  assert.equal(tap(win, expression, ka).term, "かない");
});

test("重复后处理是幂等的（首词条被走两遍，BUG-1098 同款）", () => {
  const expression = "置かない";
  const { win, root } = createHeadword(expression, { 置: "お" });
  const before = cells(root).length;

  win.wrapExpressionInlineKanji(root);

  assert.equal(cells(root).length, before);
  assert.equal(root.querySelector(".expr-char .expr-char"), null);
  const [ka] = cells(root).filter((c) => c.textContent === "か");
  assert.equal(tap(win, expression, ka).term, "かない");
});

test("字面与 expression 对不上时退回整词，绝不查错位串", () => {
  const expression = "置かない";
  const { win, root } = createHeadword(expression, { 置: "お" });
  const [ka] = cells(root).filter((c) => c.textContent === "か");

  ka.setAttribute("data-char-index", "2"); // 人为错位：2 号位是「な」
  assert.equal(tap(win, expression, ka), null);
});
