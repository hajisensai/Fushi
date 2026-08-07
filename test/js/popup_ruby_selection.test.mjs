// Popup ruby lookup behavior (jsdom real DOM).
//
// postProcessRuby() inserts a visually hidden .ruby-reserve before every ruby
// base so the reading can reserve horizontal space.  Those layout-only text
// nodes must never enter lookup scans: in a mixed kanji/kana word such as
// 打ち合わせ, the hidden あ before 合 otherwise changes the query to
// 打ちあ合わせ and the dictionary can only match the shorter prefix 打ち.
import { test } from "node:test";
import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { readFileSync } from "node:fs";

const SELECTION_URL = new URL(
  "../../hibiki/assets/popup/selection.js",
  import.meta.url,
);
const selectionSrc = readFileSync(SELECTION_URL, "utf8");

function createPopupSelection() {
  const dom = new JSDOM(
    `<!DOCTYPE html><body>
      <div class="glossary-content">
        <ruby><span class="ruby-unit"><span class="ruby-reserve" aria-hidden="true">う</span><span id="start">打</span><rt>う</rt></span></ruby><span>ち</span><ruby><span class="ruby-unit"><span class="ruby-reserve" aria-hidden="true">あ</span><span>合</span><rt id="second-reading">あ</rt></span></ruby><span>わせ。</span>
      </div>
    </body>`,
    { runScripts: "outside-only" },
  );
  const win = dom.window;
  win.Range.prototype.getClientRects = () => [];
  win.Range.prototype.getBoundingClientRect = () => ({
    x: 0,
    y: 0,
    left: 0,
    top: 0,
    right: 0,
    bottom: 0,
    width: 0,
    height: 0,
  });
  win.flutter_inappwebview = { callHandler: () => {} };
  win.eval(selectionSrc);
  return win;
}

test("mixed kanji/kana lookup skips ruby-reserve layout text", () => {
  const win = createPopupSelection();
  const start = win.document.querySelector("#start").firstChild;

  assert.equal(
    win.fushiSelection.selectFromPosition(start, 0, 20),
    "打ち合わせ",
  );
  assert.equal(win.fushiSelection.getSentence(start, 0), "打ち合わせ。");
});

test("furigana hit resolves to the visible ruby base, not its reserve", () => {
  const win = createPopupSelection();
  const reading = win.document.querySelector("#second-reading").firstChild;
  const resolved = win.fushiSelection.resolveRubyBase(reading);

  assert.equal(resolved?.node.textContent, "合");
});
