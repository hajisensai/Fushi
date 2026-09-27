// BUG-1062 / BUG-1061 behavior test: the Anki mining payload built by popup.js
// must match upstream Yomitan's exported glossary, in two respects the user hit:
//
// BUG-1061 — `{glossary}` label had a self-invented ordinal. Yomitan's
//   `glossary-single` anki template emits `(definitionTags…, dictionaryAlias)`
//   with NO number, and this repo's own constructSingleGlossaryHtml
//   (`{glossary-first}` / `{single-glossary-*}`) already agreed. Only
//   constructGlossaryHtml prefixed an index, so cards read "(1, 词典名)".
//
// BUG-1062 / BUG-2742 — exported definition images must get Yomitan's box.
//   Yomitan's importer stores the dictionary JSON `width`/`height` as
//   preferredWidth/preferredHeight and replaces width/height with the media
//   file's REAL pixel size; its structured-content-generator then writes
//   `width: {usedWidth}em`, and the Anki export inlines
//   structured-content-style.json: `.gloss-image-container{font-size:1px}`,
//   overridden to `1em` only for `[data-size-units=em]`. So a non-em image is
//   usedWidth px and an em image is usedWidth card-font-sizes (checked against
//   real Yomitan cards: 明鏡 `font-size:1px;width:150em`, 語彙力
//   `font-size:1px;font-size:1em;width:8.57143em`).
//   popup.js has no real sizes in its database, so an image declaring only one
//   dimension (語彙力: `height:10, sizeUnits:'em'`) fell back to `width = 100`
//   → a 100em × 10em strip, squeezed to the card width with the picture shrunk
//   and centred in it. buildMinePayload now measures the real sizes first.
//   (BUG-1062 had pinned every export to `font-size:1em`, which blew non-em
//   images up to the card width; BUG-2742 restores Yomitan's 1px rule.)
//
// This EXECUTES the real popup.js against a minimal fake DOM. Reverting either
// fix turns this red.
//
// Run: node fushi/test/pages/popup_glossary_export_parity_test.js
// (also driven from popup_glossary_export_parity_test.dart inside `flutter test`).

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const popupPath = path.resolve(__dirname, '../../assets/popup/popup.js');
// popup.html loads dict-media.js before popup.js; the export path calls into it
// (normalizeDictMediaPath / rewriteDictionaryMediaPath), so load the real thing
// rather than stubbing the media path rules.
const dictMediaPath = path.resolve(__dirname, '../../assets/popup/dict-media.js');
const source = fs.readFileSync(dictMediaPath, 'utf8') + '\n' +
  fs.readFileSync(popupPath, 'utf8');

function makeElement(tag) {
  return {
    tagName: (tag || 'div').toUpperCase(),
    className: '',
    id: '',
    textContent: '',
    innerHTML: '',
    // Real CSSStyleDeclaration semantics that popup.js relies on: individual
    // property writes plus `cssText +=` accumulation.
    style: {
      cssText: '',
      // gaiji export branch writes width/margin via setProperty(..., 'important').
      setProperty(name, value, priority) {
        this.cssText += name + ':' + value + (priority ? ' !' + priority : '') + ';';
      },
    },
    dataset: {},
    children: [],
    attributes: [],
    classList: {
      _set: new Set(),
      add(name) { this._set.add(name); },
      remove(name) { this._set.delete(name); },
      contains(name) { return this._set.has(name); },
    },
    appendChild(child) { this.children.push(child); return child; },
    append(...nodes) { this.children.push(...nodes); },
    setAttribute() {},
    getAttribute() { return null; },
    hasAttribute() { return false; },
    removeAttribute() {},
    addEventListener() {},
    querySelectorAll() { return []; },
    querySelector() { return null; },
    closest() { return null; },
    get firstChild() { return this.children.length ? this.children[0] : null; },
  };
}

function makeSandbox() {
  const documentObj = {
    documentElement: { style: {}, classList: makeElement().classList },
    head: { appendChild() {} },
    body: makeElement('body'),
    getElementById() { return null; },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(tag) { return makeElement(tag); },
    createTextNode(text) { const n = makeElement('#text'); n.textContent = text; return n; },
    addEventListener() {},
  };

  const windowObj = {
    audioSources: [],
    needsAudio: false,
    lookupEntries: [],
    dictionaryStyles: {},
    hiddenDictionaryNames: [],
    collapsedDictionaryNames: [],
    // Mining payload path: dictionary media is embedded, so exported images are
    // <img src="fushi_dict_N.ext"> and go through applyImageStyles.
    embedMedia: true,
    devicePixelRatio: 2,
    innerWidth: 400,
    flutter_inappwebview: { callHandler() { return Promise.resolve(false); } },
    getSelection() { return { toString() { return ''; } }; },
  };
  documentObj.defaultView = windowObj;

  // Stands in for the popup's media loads: buildMinePayload measures real image
  // sizes through `new Image()` on the same image:// URL the popup displays.
  // Paths listed in `naturalSizes` load with that size; any other path errors.
  const naturalSizes = {};
  class FakeImage {
    constructor() {
      this.naturalWidth = 0;
      this.naturalHeight = 0;
      this.onload = null;
      this.onerror = null;
    }
    set src(url) {
      this._src = url;
      const match = /[?&]path=([^&]*)/.exec(url);
      const size = match ? naturalSizes[decodeURIComponent(match[1])] : undefined;
      setTimeout(() => {
        if (size) {
          this.naturalWidth = size[0];
          this.naturalHeight = size[1];
          if (this.onload) this.onload();
        } else if (this.onerror) {
          this.onerror();
        }
      }, 0);
    }
    get src() { return this._src; }
  }

  const sandbox = {
    Node: { TEXT_NODE: 3, ELEMENT_NODE: 1 },
    Date, Math, URL, JSON, RegExp, Set, Map, Object, Array, console,
    performance: { now() { return 0; } },
    setTimeout, clearTimeout,
    DOMParser: class { parseFromString() { return { body: makeElement('body'), querySelectorAll() { return []; } }; } },
    document: documentObj,
    window: windowObj,
    getComputedStyle() { return {}; },
    Image: FakeImage,
    __naturalSizes: naturalSizes,
  };
  sandbox.globalThis = sandbox;
  return sandbox;
}

function loadPopup(entry) {
  const sandbox = makeSandbox();
  vm.createContext(sandbox);
  const exported = source + `
    ;window.lookupEntries = [${JSON.stringify(entry)}];
    // buildMinePayload normally opens this registry before rendering fields.
    ;currentDictionaryMedia = new Map();
    ;window.__test = {
      multi: function() { return constructGlossaryHtml(0); },
      single: function() { return constructSingleGlossaryHtml(0); },
      image: function(data, exporting) { return createDefinitionImage(data, 'Dict', exporting); },
      structured: function(parent, node, exporting) {
        return renderStructuredContent(parent, node, null, 'Dict', exporting);
      },
      // Runs the real mining payload builder and returns every image node it
      // exported, so the test sees exactly what lands in the Anki field.
      mine: async function() {
        const exported = [];
        const original = createDefinitionImage;
        createDefinitionImage = function(data, dictionary, exporting) {
          const node = original(data, dictionary, exporting);
          if (exporting) exported.push(node);
          return node;
        };
        try {
          await buildMinePayload('x', 'x', [], [], [], 'x', 0, '');
        } finally {
          createDefinitionImage = original;
        }
        return { exported: exported, sizesClosed: currentExportImageSizes === null };
      },
    };
  `;
  vm.runInContext(exported, sandbox, { filename: 'popup.js' });
  return sandbox;
}

function gloss(dictionary, text) {
  return { dictionary: dictionary, content: text, definitionTags: '', termTags: '' };
}

function labelsOf(html) {
  const out = [];
  const re = /<i>([^<]*)<\/i>/g;
  let m;
  while ((m = re.exec(html)) !== null) { out.push(m[1]); }
  return out;
}

// The container span is the first child of the returned .gloss-image-link node.
function containerOf(node) {
  assert.ok(node && node.children.length > 0, 'image node must have a container child');
  return node.children[0];
}

(async function run() {
  const entry = {
    expression: '猫', reading: 'ねこ',
    glossaries: [gloss('JMdict', 'cat'), gloss('JMdict', 'kitty'), gloss('Daijirin', 'ねこ科の動物')],
    frequencies: [], pitches: [],
  };

  // BUG-1061 (1/2): no ordinal anywhere in the {glossary} labels — the first
  // entry of a dictionary carries just the dictionary name, subsequent entries
  // of the same dictionary carry nothing (tags would go here when present).
  {
    const sb = loadPopup(entry);
    const multi = sb.window.__test.multi();
    assert.deepStrictEqual(labelsOf(multi), ['(JMdict)', '', '(Daijirin)'],
      'the {glossary} labels must be Yomitan-shaped and ordinal-free; got ' + multi);
    assert.ok(!/\(\d+[,)]/.test(multi),
      'no "(1," / "(1)" ordinal may appear in the exported glossary; got ' + multi);
  }

  // BUG-1061 (2/2): the two mining payload builders must agree on the label
  // format — they render the same dictionary for the same card.
  {
    const sb = loadPopup(entry);
    const multi = sb.window.__test.multi();
    const single = sb.window.__test.single();
    for (const dict of ['JMdict', 'Daijirin']) {
      const first = labelsOf(single[dict])[0];
      assert.ok(labelsOf(multi).includes(first),
        `{glossary} must use the same label as {glossary-first} for ${dict}; ` +
        `single=${first} multi=${JSON.stringify(labelsOf(multi))}`);
    }
  }

  // BUG-1062 / BUG-2742 (1/3): a non-em image exports exactly like Yomitan's
  // card — `width: {usedWidth}em` in a `font-size:1px` container, i.e. usedWidth
  // px (real Yomitan card: 明鏡 `font-size:1px;width:150em`). BUG-1062 had pinned
  // `font-size:1em` here, which blew such images up to the full card width.
  {
    const sb = loadPopup(entry);
    const node = sb.window.__test.image({ path: 'pic.png', width: 150, height: 100 }, true);
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '150em',
      'exported image container must size in em like Yomitan; got ' + container.style.width);
    assert.ok(/font-size:1px/.test(container.style.cssText) &&
      !/font-size:1em/.test(container.style.cssText),
      'a non-em image must sit in Yomitan\'s font-size:1px container; got ' +
      container.style.cssText);
    assert.ok(/max-width:100%/.test(container.style.cssText),
      'exported image must still be capped at the card width');
    assert.strictEqual(node.dataset.sizeUnits, undefined,
      'a non-em image must not be tagged data-size-units=em');
    const img = container.children.find(c => c.tagName === 'IMG');
    assert.ok(img.width === 150 && img.height === 100,
      'non-em <img> attributes are usedWidth x usedWidth*aspect like Yomitan; got ' +
      img.width + 'x' + img.height);
  }

  // BUG-1062 (2/3): the popup path is unchanged — px there is correct because
  // the popup ships the Yomitan stylesheet.
  {
    const sb = loadPopup(entry);
    const node = sb.window.__test.image({ path: 'pic.png', width: 10, height: 5 }, false);
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '10px',
      'popup image container must keep px sizing; got ' + container.style.width);
  }

  // BUG-1062 (3/3): dictionaries that declare em units are untouched by the fix
  // (they were already em on both paths).
  {
    const sb = loadPopup(entry);
    const node = sb.window.__test.image(
      { path: 'gaiji.svg', width: 2, height: 2, sizeUnits: 'em' }, true);
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '2em',
      'sizeUnits:em images stay em on export; got ' + container.style.width);
    assert.ok(/font-size:1em/.test(container.style.cssText) &&
      !/font-size:1px/.test(container.style.cssText),
      'an em image\'s container must follow the card font size; got ' +
      container.style.cssText);
    assert.strictEqual(node.dataset.sizeUnits, 'em');
  }

  // BUG-1676 (1/3): a dictionary that declares NO size must not be exported at
  // the `width = 100` fallback — that number is neither the image's size nor its
  // aspect ratio, and as `100em` it resolves to ~100 x card-font-size (2000px on
  // a 775px-wide card). The <img> itself becomes the layout box instead.
  {
    const sb = loadPopup(entry);
    const node = sb.window.__test.image({ path: 'pic.png' }, true);
    const container = containerOf(node);
    assert.strictEqual(container.style.width, 'auto',
      'an image with no declared size must be laid out by the <img>; got ' + container.style.width);
    assert.ok(!/100em/.test(container.style.cssText + container.style.width),
      'the 100 fallback must never be exported as 100em (BUG-1676); got ' + container.style.cssText);
    assert.strictEqual(node.dataset.hasAspectRatio, 'false',
      'no declared size means no invented 1:1 aspect ratio; got ' + node.dataset.hasAspectRatio);
    const img = container.children.find(c => c.tagName === 'IMG');
    assert.ok(img, 'exported node must contain an <img>');
    assert.ok(img.width === undefined && img.height === undefined,
      'the 100x100 fallback must not be written as width/height attributes; got ' +
      img.width + 'x' + img.height);
    assert.ok(/position:static/.test(img.style.cssText) && /max-width:100%/.test(img.style.cssText),
      'the natural-size <img> must be in flow and capped at the card width; got ' + img.style.cssText);
    assert.ok(!/position:absolute/.test(img.style.cssText),
      'an absolutely positioned <img> would collapse the auto-width container to 0; got ' +
      img.style.cssText);
  }

  // BUG-1676 (2/3): declared sizes are untouched — the BUG-1062 em semantics
  // still apply, and the aspect-ratio sizer still drives the layout.
  {
    const sb = loadPopup(entry);
    const node = sb.window.__test.image({ path: 'pic.png', width: 10, height: 5 }, true);
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '10em',
      'declared-size images keep Yomitan em sizing; got ' + container.style.width);
    assert.strictEqual(node.dataset.hasAspectRatio, 'true',
      'declared-size images keep their aspect-ratio sizer');
    const img = container.children.find(c => c.tagName === 'IMG');
    assert.ok(/position:absolute/.test(img.style.cssText),
      'declared-size images keep the sizer + absolute <img> layout; got ' + img.style.cssText);
  }

  // BUG-1676 (3/3): exported structured-content tables carry the overflow guard
  // inline. The popup gets it from popup.css; an Anki card has no stylesheet, and
  // `table-layout:auto` ignores percentage max-width on cells — without this the
  // whole card is dragged off the right edge of the screen by one wide table.
  {
    const sb = loadPopup(entry);
    const parent = sb.document.createElement('div');
    sb.window.__test.structured(parent, { tag: 'table', content: 'x' }, true);
    const container = parent.children[0];
    assert.ok(container && container.classList.contains('gloss-sc-table-container'),
      'a structured-content table must be wrapped in .gloss-sc-table-container');
    assert.ok(/overflow-x:auto/.test(container.style.cssText),
      'exported table container must inline the overflow guard (BUG-1676); got ' +
      container.style.cssText);
    assert.ok(/max-width:100%/.test(container.style.cssText),
      'exported table container must be capped at the card width; got ' + container.style.cssText);

    const popupParent = sb.document.createElement('div');
    sb.window.__test.structured(popupParent, { tag: 'table', content: 'x' }, false);
    assert.strictEqual(popupParent.children[0].style.cssText, '',
      'the popup path must stay CSS-driven, not inline-styled');
  }

  // BUG-2190: with no media file to embed (host without embedMedia — the browser
  // extension before this fix, or an image the dictionary cannot serve), the
  // gaiji falls back to its alt text. That text must flow as plain inline text:
  // the image box (gaiji branch: width:auto!important / height:1.2em /
  // line-height:0, plus the Anki-side width:1em!important) was measured on the
  // user's real card to squeeze an 80px-wide ［参考］ into a 24px, zero-line-height
  // inline-block, overflowing onto the following text.
  {
    const sb = loadPopup(entry);
    sb.window.embedMedia = false;
    sb.window.useAnkiConnect = false;
    const gaiji = {
      path: 'gaiji/参考1.svg',
      data: { class: 'gaiji', alt: '［参考］' },
    };
    const node = sb.window.__test.image(gaiji, true);
    assert.strictEqual(node.textContent, '［参考］',
      'alt text must be the exported content when no media file is embedded');
    assert.ok(node.classList.contains('gloss-image-alt'),
      'alt fallback must be its own inline text node class; got ' +
      [...node.classList._set].join(' '));
    assert.ok(!node.classList.contains('gloss-image-link') &&
      node.children.length === 0,
      'alt fallback must not carry the image container geometry (BUG-2190)');
    assert.strictEqual(node.style.cssText, '',
      'alt fallback must not inherit line-height:0 / height:1.2em image styles; got ' +
      node.style.cssText);

    // With media embedded the gaiji still exports as an <img> inside the box.
    const sbImg = loadPopup(entry);
    const withMedia = sbImg.window.__test.image(gaiji, true);
    assert.ok(withMedia.classList.contains('gloss-image-link'),
      'embedded gaiji keeps the image link box');
    const container = withMedia.children[0];
    assert.ok(container.children.some(c => c.tagName === 'IMG'),
      'embedded gaiji exports an <img>');
    // The 1.2em inline gaiji box must track the text size: Yomitan's 1px
    // container rule would squash it to 1.2px.
    assert.ok(/font-size:1em/.test(container.style.cssText) &&
      !/font-size:1px/.test(container.style.cssText),
      'an unsized SVG gaiji must keep a 1em container; got ' + container.style.cssText);
  }

  // ---- BUG-2742: the real image size drives the exported box ----
  const goiEntry = {
    expression: 'コンコン', reading: 'コンコン',
    glossaries: [{
      // Shape of 語彙力・熟語の百科事典 on the user's card: the pictures declare
      // only a height, in em.
      dictionary: '語彙力・熟語の百科事典',
      content: JSON.stringify({
        type: 'structured-content',
        content: [
          { tag: 'div', content: [
            { tag: 'img', path: 'img/kitsune.png', height: 10, sizeUnits: 'em', background: false, collapsible: false },
            { tag: 'img', path: 'img/knock.png', height: 10, sizeUnits: 'em', background: false, collapsible: false },
          ] },
          { tag: 'div', content: [
            { tag: 'img', path: 'img/wide.png', width: 200 },
            { tag: 'img', path: 'img/plain.png' },
            { tag: 'img', path: 'img/missing.png', height: 10, sizeUnits: 'em' },
          ] },
        ],
      }),
      definitionTags: '', termTags: '',
    }],
    frequencies: [], pitches: [],
  };
  const near = (actual, expected) => Math.abs(actual - expected) < 1e-6;
  const sizerOf = (container) => container.children.find(c => c.classList.contains('gloss-image-sizer'));
  const imgOf = (container) => container.children.find(c => c.tagName === 'IMG');

  const sb = loadPopup(goiEntry);
  // 180x210 is the real file behind the user's Yomitan card (its <img> reads
  // 480x560 only because em images are rendered at usedWidth * 14 * 2 * dpr).
  sb.__naturalSizes['img/kitsune.png'] = [180, 210];
  sb.__naturalSizes['img/knock.png'] = [200, 280];
  sb.__naturalSizes['img/wide.png'] = [400, 300];
  sb.__naturalSizes['img/plain.png'] = [320, 240];
  const mined = await sb.window.__test.mine();
  assert.ok(mined.sizesClosed,
    'buildMinePayload must close the measured-size registry like currentDictionaryMedia');
  const byPath = {};
  mined.exported.forEach(node => { (byPath[node.dataset.path] = byPath[node.dataset.path] || []).push(node); });
  for (const p of ['img/kitsune.png', 'img/knock.png', 'img/wide.png', 'img/plain.png', 'img/missing.png']) {
    assert.ok(byPath[p] && byPath[p].length > 0, 'mining must export ' + p);
  }

  // BUG-2742 (1/4): the user's card. Height-only em pictures take their width
  // from the real aspect ratio — Yomitan's `width: 8.57143em` (= 10 / (210/180))
  // and a 116.667% sizer — instead of the `width = 100` fallback that made a
  // 100em × 10em strip with the picture shrunk and centred inside.
  for (const [p, w, h, imgW, imgH] of [
    ['img/kitsune.png', 180, 210, 480, 560],
    ['img/knock.png', 200, 280, 400, 560],
  ]) {
    for (const node of byPath[p]) {
      const container = containerOf(node);
      const usedWidth = 10 / (h / w);
      assert.ok(/em$/.test(container.style.width) && near(parseFloat(container.style.width), usedWidth),
        `${p}: container must be ${usedWidth}em wide like Yomitan; got ${container.style.width}`);
      assert.ok(near(parseFloat(sizerOf(container).style.paddingTop), (h / w) * 100),
        `${p}: sizer must carry the real aspect ratio; got ${sizerOf(container).style.paddingTop}`);
      assert.ok(/font-size:1em/.test(container.style.cssText),
        `${p}: em picture must scale with the card font; got ${container.style.cssText}`);
      assert.strictEqual(node.dataset.sizeUnits, 'em');
      const img = imgOf(container);
      // Yomitan: usedWidth * 14 * 2 * devicePixelRatio (2 here); the user's
      // Yomitan card reads <img width="480" height="560"> for the 180x210 file.
      assert.ok(near(img.width, imgW) && near(img.height, imgH),
        `${p}: <img> attributes must match Yomitan's ${imgW}x${imgH}; got ${img.width}x${img.height}`);
    }
  }

  // BUG-2742 (2/4): width-only non-em image → declared width in px, real aspect.
  for (const node of byPath['img/wide.png']) {
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '200em');
    assert.ok(near(parseFloat(sizerOf(container).style.paddingTop), 75),
      'width-only image must use the real 400x300 aspect; got ' + sizerOf(container).style.paddingTop);
    assert.ok(/font-size:1px/.test(container.style.cssText),
      'non-em image sits in a 1px container; got ' + container.style.cssText);
    const img = imgOf(container);
    assert.ok(img.width === 200 && near(img.height, 150), 'got ' + img.width + 'x' + img.height);
  }

  // BUG-2742 (3/4): an unsized image that could be measured gets Yomitan's box
  // at its real pixel size (320em in a 1px container = 320px).
  for (const node of byPath['img/plain.png']) {
    const container = containerOf(node);
    assert.strictEqual(container.style.width, '320em');
    assert.ok(/font-size:1px/.test(container.style.cssText), 'got ' + container.style.cssText);
    assert.strictEqual(node.dataset.hasAspectRatio, 'true');
    assert.ok(near(parseFloat(sizerOf(container).style.paddingTop), 75));
  }

  // BUG-2742 (4/4): measuring failed (missing file / host too slow). Never fall
  // back to the invented 100em strip: the <img> keeps its own aspect ratio and
  // only the declared dimension is applied to it.
  for (const node of byPath['img/missing.png']) {
    const container = containerOf(node);
    assert.strictEqual(container.style.width, 'auto',
      'unmeasured height-only image must be laid out by the <img>; got ' + container.style.width);
    assert.ok(!/100em/.test(container.style.cssText + container.style.width),
      'the width = 100 fallback must never be exported; got ' + container.style.cssText);
    assert.ok(/font-size:1em/.test(container.style.cssText), 'got ' + container.style.cssText);
    const img = imgOf(container);
    assert.strictEqual(img.style.height, '10em',
      'the declared height must still size the <img>; got ' + img.style.height);
    assert.ok(/position:static/.test(img.style.cssText), 'got ' + img.style.cssText);
  }

  console.log('popup_glossary_export_parity_test.js: all assertions passed');
})().catch(error => {
  console.error(error);
  process.exit(1);
});
