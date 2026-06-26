const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dictMediaPath = path.resolve(__dirname, '../../../assets/popup/dict-media.js');
const popupPath = path.resolve(__dirname, '../../../assets/popup/popup.js');
const popupCssPath = path.resolve(__dirname, '../../../assets/popup/popup.css');
const selectionPath = path.resolve(__dirname, '../../../assets/popup/selection.js');

class FakeClassList {
  constructor(element) {
    this.element = element;
    this.values = new Set();
  }

  add(...names) {
    for (const name of names) {
      this.values.add(name);
    }
    this.element.className = [...this.values].join(' ');
  }

  contains(name) {
    return this.values.has(name);
  }

  remove(name) {
    this.values.delete(name);
    this.element.className = [...this.values].join(' ');
  }
}

class FakeElement {
  constructor(tagName) {
    this.tagName = tagName.toUpperCase();
    this.nodeType = 1;
    this.children = [];
    this.childNodes = this.children;
    this.dataset = {};
    this.style = {};
    this.attributes = {};
    this.className = '';
    this.classList = new FakeClassList(this);
    this.listeners = {};
    this.parentElement = null;
    this.parentNode = null;
    this.textContent = '';
    this.src = '';
    this.alt = '';
    // Pre-declared so el()'s `key in element` check routes these as real
    // properties (a callable handler / boolean), not stringified attributes.
    this.onclick = null;
    this.ontouchstart = null;
    this.disabled = false;
  }

  get innerHTML() {
    if (this.children.length === 0) {
      return this.textContent;
    }
    return this.children.map((child) => child.innerHTML ?? child.textContent ?? '').join('');
  }

  set innerHTML(value) {
    this.children = [];
    this.childNodes = this.children;
    this.textContent = String(value);
  }

  appendChild(child) {
    this.children.push(child);
    child.parentElement = this;
    child.parentNode = this;
    return child;
  }

  append(...children) {
    for (const child of children) {
      this.appendChild(child);
    }
  }

  setAttribute(name, value) {
    this.attributes[name] = String(value);
  }

  hasAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attributes, name);
  }

  addEventListener(type, handler) {
    (this.listeners[type] ??= []).push(handler);
  }

  dispatchEvent(event) {
    for (const handler of this.listeners[event.type] ?? []) {
      handler(event);
    }
  }

  remove() {
    if (!this.parentElement) {
      return;
    }
    const parent = this.parentElement;
    const siblings = parent.children;
    const index = siblings.indexOf(this);
    if (index >= 0) {
      siblings.splice(index, 1);
    }
    this.parentElement = null;
    this.parentNode = null;
  }

  getBoundingClientRect() {
    // TODO-859: tests inject _rect to model a real rendered image's pixel box so
    // the image hit-test (pointHitsRenderedImagePixels) can be exercised.
    return this._rect ?? {left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0};
  }

  querySelector(selector) {
    // Minimal selector support exercised by TODO-859 image hit-test: 'tag',
    // '.class', or 'tag.class' (e.g. 'img.gloss-image' / 'canvas').
    const parsed = selector.match(/^([a-zA-Z]+)?(?:\.([\w-]+))?$/);
    if (!parsed || (!parsed[1] && !parsed[2])) {
      return null;
    }
    const wantTag = parsed[1] ? parsed[1].toUpperCase() : null;
    const wantClass = parsed[2] || null;
    const matches = (el) =>
      (wantTag === null || el.tagName === wantTag) &&
      (wantClass === null || (!!el.classList && el.classList.contains(wantClass)));
    const visit = (el) => {
      for (const child of el.children ?? []) {
        if (matches(child)) {
          return child;
        }
        const found = visit(child);
        if (found) {
          return found;
        }
      }
      return null;
    };
    return visit(this);
  }

  closest(selector) {
    if (!selector.startsWith('.')) {
      return null;
    }
    const className = selector.slice(1);
    let element = this;
    while (element) {
      if (element.classList?.contains(className)) {
        return element;
      }
      element = element.parentElement;
    }
    return null;
  }
}

function createPopupContext() {
  const listeners = {};
  const timers = new Map();
  let nextTimerId = 1;

  const textNode = {
    nodeType: 3,
    textContent: '辞書名',
    parentElement: new FakeElement('span'),
  };
  textNode.parentElement.classList.add('dict-name');
  textNode.parentElement.childNodes.push(textNode);
  let caretStartContainer = textNode;

  const selection = {
    text: '',
    removeAllRanges() {
      this.text = '';
    },
    addRange(range) {
      this.text = range.node.textContent.slice(range.start, range.end);
    },
    toString() {
      return this.text;
    },
  };

  const document = {
    body: new FakeElement('body'),
    createElement(tagName) {
      return new FakeElement(tagName);
    },
    createTextNode(text) {
      return {
        nodeType: 3,
        textContent: String(text),
        parentElement: null,
        parentNode: null,
      };
    },
    createRange() {
      return {
        node: null,
        start: 0,
        end: 0,
        setStart(node, offset) {
          this.node = node;
          this.start = offset;
        },
        setEnd(node, offset) {
          this.node = node;
          this.end = offset;
        },
      };
    },
    caretRangeFromPoint() {
      return {
        startContainer: caretStartContainer,
        startOffset: 0,
      };
    },
    addEventListener(type, handler) {
      (listeners[type] ??= []).push(handler);
    },
    querySelector(selector) {
      if (!selector.startsWith('.')) {
        return null;
      }
      const className = selector.slice(1);
      const visit = (element) => {
        if (
          element.classList?.contains(className) ||
          element.className.split(/\s+/).includes(className)
        ) {
          return element;
        }
        for (const child of element.children ?? []) {
          const found = visit(child);
          if (found) {
            return found;
          }
        }
        return null;
      };
      return visit(this.body);
    },
  };

  const context = {
    console,
    document,
    event: null,
    Image: class {
      addEventListener() {}
      set src(value) {
        this._src = value;
      }
    },
    Node: {TEXT_NODE: 3},
    window: {
      devicePixelRatio: 1,
      innerWidth: 360,
      getSelection() {
        return selection;
      },
      flutter_inappwebview: {
        callHandler() {
          return Promise.resolve(true);
        },
      },
    },
    getComputedStyle() {
      return {fontSize: '15px'};
    },
    setTimeout(callback, delay) {
      const id = nextTimerId++;
      timers.set(id, {callback, delay, cleared: false});
      return id;
    },
    clearTimeout(id) {
      const timer = timers.get(id);
      if (timer) {
        timer.cleared = true;
      }
    },
  };
  context.globalThis = context;
  context.window.window = context.window;
  context.__listeners = listeners;
  context.__timers = timers;
  context.__textTarget = textNode.parentElement;
  context.__setCaretStartContainer = (node) => {
    caretStartContainer = node;
  };
  return context;
}

function loadPopup() {
  const context = createPopupContext();
  vm.runInNewContext(fs.readFileSync(dictMediaPath, 'utf8'), context, {
    filename: dictMediaPath,
  });
  vm.runInNewContext(fs.readFileSync(popupPath, 'utf8'), context, {
    filename: popupPath,
  });
  return context;
}

function testEmSizedWideImagesUseHorizontalScrollWrapper() {
  const context = loadPopup();
  const node = context.createDefinitionImage(
    {
      path: 'img/wide.png',
      width: 100,
      height: 10,
      sizeUnits: 'em',
    },
    'test-dict',
    false,
  );

  assert.equal(node.className, 'gloss-image-scroll');
  assert.equal(node.children[0].className, 'gloss-image-link');
  assert.equal(node.children[0].style.maxWidth, 'none');
  assert.equal(node.children[0].children[0].style.width, '100em');
  assert.equal(node.children[0].children[0].style.maxWidth, 'none');
}

// TODO-350: Sanseido (三省堂国語辞典) marks pitch accent as a small inline SVG
// embedded in the term_bank structured content — `{tag:'img', width:0.5,
// height:1.0, sizeUnits:'em', path:'sankoku8/svg-accent/アクセント.svg'}` — NOT as
// Yomitan pitch term_meta. createDefinitionImage routes every em-sized image
// through the gloss-image-scroll wrapper (added in 290b42feb for very wide em
// images like 100em×10em). The wrapper must stay inline so the 0.5em accent mark
// stays on the same line as the kana it annotates; a block wrapper bumped it onto
// its own line and detached the accent from the reading ("音調显示有问题",
// hoshi-android renders it inline because upstream Yomitan has no scroll wrapper).
// The inline-block + overflow-x:auto fix (in popup.css) lets layout decide whether
// scrolling is needed from real geometry, so wide images still scroll while the
// narrow accent mark collapses to its content width and stays inline.
function testSanseidoEmAccentImageStaysInlineAndPointsAtDictionaryMedia() {
  const context = loadPopup();
  const node = context.createDefinitionImage(
    {
      tag: 'img',
      width: 0.5,
      height: 1.0,
      sizeUnits: 'em',
      appearance: 'auto',
      background: false,
      collapsible: false,
      collapsed: false,
      path: 'sankoku8/svg-accent/アクセント.svg',
    },
    '三省堂国語辞典　第八版',
    false,
  );

  // The em path still wraps for the wide-image scroll case…
  assert.equal(node.className, 'gloss-image-scroll');
  const link = node.children[0];
  assert.equal(link.className, 'gloss-image-link');
  const container = link.children[0];
  // …but the accent mark keeps its own 0.5em width (not stretched to a block row).
  assert.equal(container.style.width, '0.5em');
  // SVG aspect ratio is preserved (height 1.0 / width 0.5 = 200%).
  assert.equal(container.children[0].style.paddingTop, '200%');
  // The accent SVG resolves to the dictionary media scheme with its CJK path
  // percent-encoded (regression for the embedded-SVG accent never loading).
  const img = container.children[3];
  assert.equal(img.className, 'gloss-image');
  assert.equal(
    img.src,
    'image://?dictionary=%E4%B8%89%E7%9C%81%E5%A0%82%E5%9B%BD%E8%AA%9E%E8%BE%9E' +
      '%E5%85%B8%E3%80%80%E7%AC%AC%E5%85%AB%E7%89%88&path=sankoku8%2Fsvg-accent' +
      '%2F%E3%82%A2%E3%82%AF%E3%82%BB%E3%83%B3%E3%83%88.svg',
  );
}

// CSS guard: the gloss-image-scroll wrapper must be inline-block so an em-sized
// accent mark stays in the kana's inline flow. A bare div (display:block) detaches
// the Sanseido pitch accent from its reading (TODO-350).
function testGlossImageScrollWrapperIsInline() {
  const css = fs.readFileSync(popupCssPath, 'utf8');
  const ruleMatch = css.match(/\.gloss-image-scroll\s*\{([^}]*)\}/);
  assert.ok(ruleMatch, '.gloss-image-scroll rule must exist in popup.css');
  const body = ruleMatch[1];
  assert.ok(
    /display\s*:\s*inline-block\s*;/.test(body),
    '.gloss-image-scroll must be inline-block so small em images stay inline; got: ' +
      body.trim(),
  );
  assert.ok(
    /overflow-x\s*:\s*auto\s*;/.test(body),
    '.gloss-image-scroll must keep overflow-x:auto for wide em images',
  );
}

function testLargeRasterImagesMarkedAsEmUseNaturalWidthAfterLoad() {
  const context = loadPopup();
  const node = context.createDefinitionImage(
    {
      path: 'img/d93ed9600ba7717bd75cd68f5d35760c.png',
      width: 100,
      height: 10,
      sizeUnits: 'em',
    },
    'test-dict',
    false,
  );

  assert.equal(node.className, 'gloss-image-scroll');

  const link = node.children[0];
  const container = link.children[0];
  const sizer = container.children[0];
  const img = container.children[3];

  img.naturalWidth = 230;
  img.naturalHeight = 246;
  img.listeners.load[0]();

  assert.equal(container.style.width, '230px');
  assert.equal(link.dataset.sizeUnits, undefined);
  assert.equal(sizer.style.paddingTop, `${(246 / 230) * 100}%`);
}

function testExplicitContentImageDimensionsDefaultToPixelUnits() {
  const context = loadPopup();
  const node = context.createDefinitionImage(
    {
      path: 'img/wide-default-units.png',
      width: 100,
      height: 10,
    },
    'test-dict',
    false,
  );

  assert.equal(node.className, 'gloss-image-link');
  assert.equal(node.dataset.sizeUnits, undefined);
  assert.equal(node.children[0].style.width, '100px');
}

function testPixelImagesWithBadDeclaredAspectUseNaturalWidthAfterLoad() {
  const context = loadPopup();
  const node = context.createDefinitionImage(
    {
      path: 'img/d93ed9600ba7717bd75cd68f5d35760c.png',
      width: 100,
      height: 10,
    },
    'test-dict',
    false,
  );
  const container = node.children[0];
  const sizer = container.children[0];
  const img = container.children[3];

  img.naturalWidth = 230;
  img.naturalHeight = 246;
  img.listeners.load[0]();

  assert.equal(container.style.width, '230px');
  assert.equal(sizer.style.paddingTop, `${(246 / 230) * 100}%`);
}

function testTappingDefinitionImageOpensLightbox() {
  const context = loadPopup();
  const node = context.createDefinitionImage(
    {
      path: 'img/d93ed9600ba7717bd75cd68f5d35760c.png',
      width: 100,
      height: 10,
      data: {alt: 'test image'},
    },
    'test-dict',
    false,
  );
  context.document.body.appendChild(node);

  node.dispatchEvent({
    type: 'click',
    preventDefault() {
      this.defaultPrevented = true;
    },
    stopPropagation() {
      this.propagationStopped = true;
    },
  });

  const lightbox = context.document.body.children.find(
    (child) => child.className === 'dict-image-lightbox',
  );

  assert.ok(lightbox, 'image lightbox was not opened');
  assert.equal(lightbox.children[0].tagName, 'IMG');
  assert.equal(lightbox.children[0].src, 'image://?dictionary=test-dict&path=img%2Fd93ed9600ba7717bd75cd68f5d35760c.png');
  assert.equal(lightbox.children[0].alt, 'test image');

  lightbox.dispatchEvent({type: 'click'});
  assert.equal(
    context.document.body.children.some(
      (child) => child.className === 'dict-image-lightbox',
    ),
    false,
  );
}

// ── TODO-859 方案1: document-level tap routing on the parent popup ──────────
// The popup's document 'click' handler decides, for every tap that is NOT on a
// button/audio/summary, whether to (a) select a word, (b) keep the layer, or
// (c) ask Flutter to close descendant popups (tapOutside). Before TODO-859 the
// handler used a BLACKLIST (.entry-header / .entry-tags / .glossary-group /
// .category-section) so taps in entry-card whitespace OUTSIDE those selectors
// were a dead zone: neither selecting nor closing — the user reported tapping
// the dictionary body did not close the child popup.
// 方案1 replaces it with a POSITIVE predicate: a tap anywhere inside a card root
// (.entry / .kanji-card) keeps the layer; only a tap on pure popup background
// fires tapOutside.

function fireDocumentClick(context, target, clientX = 50, clientY = 50) {
  const handler = context.__listeners.click[0];
  let tapOutsideCalls = 0;
  context.window.flutter_inappwebview.callHandler = (name) => {
    if (name === 'tapOutside') {
      tapOutsideCalls += 1;
    }
    return Promise.resolve(true);
  };
  let selectCalls = 0;
  context.window.hoshiSelection = {
    selectText() {
      selectCalls += 1;
    },
  };
  // A real mousedown lands at the same spot first (no drag), matching production.
  const mousedown = context.__listeners.mousedown[0];
  mousedown({clientX, clientY});
  handler({target, clientX, clientY});
  return {tapOutsideCalls, selectCalls};
}

// Build: body > .entry (card root) > .glossary-content (definition text body).
function buildEntryCardDom(context) {
  const entry = new FakeElement('div');
  entry.classList.add('entry');
  const glossary = new FakeElement('div');
  glossary.classList.add('glossary-content');
  // A bare gap node inside .entry but outside .glossary-content / known selectors:
  // this is the old dead zone (li margin / category-body padding / the
  // single-content wrapper that carries no class).
  const cardGap = new FakeElement('div');
  context.document.body.appendChild(entry);
  entry.appendChild(glossary);
  entry.appendChild(cardGap);
  return {entry, glossary, cardGap};
}

// (1) Tapping the definition TEXT body still routes to word selection.
function testTapOnGlossaryTextSelectsWord() {
  const context = loadPopup();
  const {glossary} = buildEntryCardDom(context);
  const result = fireDocumentClick(context, glossary);
  assert.equal(result.selectCalls, 1, 'tapping .glossary-content text must select a word');
  assert.equal(result.tapOutsideCalls, 0, 'selecting a word must not close descendants');
}

// (2) Tapping entry-card WHITESPACE (the old dead zone) keeps the layer: it must
// NOT fire tapOutside (方案1 preserves the layer when inside a card root).
function testTapOnEntryCardWhitespaceKeepsLayer() {
  const context = loadPopup();
  const {cardGap} = buildEntryCardDom(context);
  const result = fireDocumentClick(context, cardGap);
  assert.equal(result.tapOutsideCalls, 0,
    'tapping entry-card whitespace must NOT fire tapOutside (no dead zone, layer kept)');
  assert.equal(result.selectCalls, 0,
    'card whitespace is not text: no selection, just a no-op that keeps the layer');
}

// (3) Tapping PURE popup background (outside every card root) fires tapOutside
// so Flutter closes the descendant child popups (方案1 close path).
function testTapOnPopupBackgroundFiresTapOutside() {
  const context = loadPopup();
  buildEntryCardDom(context);
  const background = new FakeElement('div');
  context.document.body.appendChild(background);
  const result = fireDocumentClick(context, background);
  assert.equal(result.tapOutsideCalls, 1,
    'tapping pure popup background must fire tapOutside to close child popups');
  assert.equal(result.selectCalls, 0, 'background is not text: no selection');
}

// (4) Tapping inside a kanji card root also keeps the layer (separate render
// path; 方案1 covers .kanji-card too).
function testTapInsideKanjiCardKeepsLayer() {
  const context = loadPopup();
  const kanjiCard = new FakeElement('div');
  kanjiCard.classList.add('kanji-card');
  const kanjiGap = new FakeElement('div');
  context.document.body.appendChild(kanjiCard);
  kanjiCard.appendChild(kanjiGap);
  const result = fireDocumentClick(context, kanjiGap);
  assert.equal(result.tapOutsideCalls, 0,
    'tapping inside a .kanji-card must NOT fire tapOutside (layer kept)');
}

// ── TODO-859 症状B: image lightbox hit-box narrowed to real image pixels ────
// The .gloss-image-link click listener opens the fullscreen lightbox. Its box is
// widened by .gloss-image-container min-width:min(100%,200px) and horizontally
// overflows adjacent text, so a tap on neighbouring text used to flash the black
// lightbox overlay. pointHitsRenderedImagePixels narrows the hit to the rendered
// img.gloss-image rect: a tap on the image pixels opens the lightbox, a tap in
// the container whitespace (outside the pixel rect) does NOT.
function buildPreviewImageNode(context) {
  const node = context.createDefinitionImage(
    {
      path: 'img/d93ed9600ba7717bd75cd68f5d35760c.png',
      width: 100,
      height: 10,
      data: {alt: 'test image'},
    },
    'test-dict',
    false,
  );
  context.document.body.appendChild(node);
  const img = node.querySelector('img.gloss-image');
  assert.ok(img, 'a rendered gloss-image must exist for the hit-test');
  img._rect = {left: 0, top: 0, right: 40, bottom: 40, width: 40, height: 40};
  return node;
}

function dispatchImageClick(node, clientX, clientY) {
  const event = {
    type: 'click',
    clientX,
    clientY,
    preventDefault() {
      this.defaultPrevented = true;
    },
    stopPropagation() {
      this.propagationStopped = true;
    },
  };
  node.dispatchEvent(event);
  return event;
}

function testTapOnImagePixelsOpensLightbox() {
  const context = loadPopup();
  const node = buildPreviewImageNode(context);
  dispatchImageClick(node, 20, 20);
  const lightbox = context.document.body.children.find(
    (child) => child.className === 'dict-image-lightbox',
  );
  assert.ok(lightbox, 'tapping the image pixels must open the lightbox');
}

function testTapInImageContainerWhitespaceDoesNotOpenLightbox() {
  const context = loadPopup();
  const node = buildPreviewImageNode(context);
  // Point (150,20) is in the widened container overflow, beyond the image rect.
  const event = dispatchImageClick(node, 150, 20);
  const lightbox = context.document.body.children.find(
    (child) => child.className === 'dict-image-lightbox',
  );
  assert.equal(lightbox, undefined,
    'tapping the widened container whitespace (outside image pixels) must NOT open the lightbox');
  assert.notEqual(event.defaultPrevented, true,
    'a whitespace tap must not preventDefault: the event keeps bubbling to the tap router');
  assert.notEqual(event.propagationStopped, true,
    'a whitespace tap must not stopPropagation: it falls through to the document handler');
}

function testLongPressTimerSurvivesEarlyTouchEnd() {
  const context = loadPopup();
  const touchStart = context.__listeners.touchstart[0];
  const touchEnd = context.__listeners.touchend[0];

  touchStart({
    touches: [{clientX: 10, clientY: 10}],
    target: context.__textTarget,
  });
  touchEnd({});

  const timer = [...context.__timers.values()].find(
    (entry) => entry.delay === 400,
  );
  assert.ok(timer, 'long press timer was not scheduled');
  assert.equal(timer.cleared, false);
  timer.callback();
  assert.equal(context.window.getSelection().toString(), '辞書名');
}

function testRepeatedTouchStartDoesNotCancelPendingLongPress() {
  const context = loadPopup();
  const touchStart = context.__listeners.touchstart[0];

  touchStart({
    touches: [{clientX: 10, clientY: 10}],
    target: context.__textTarget,
  });
  const firstTimer = [...context.__timers.values()].find(
    (entry) => entry.delay === 400,
  );
  assert.ok(firstTimer, 'first long press timer was not scheduled');

  touchStart({
    touches: [{clientX: 11, clientY: 10}],
    target: context.__textTarget,
  });

  assert.equal(firstTimer.cleared, false);
  firstTimer.callback();
  assert.equal(context.window.getSelection().toString(), '辞書名');
}

function testLongPressFallsBackFromElementToTextNode() {
  const context = loadPopup();
  const touchStart = context.__listeners.touchstart[0];
  context.__setCaretStartContainer(context.__textTarget);

  touchStart({
    touches: [{clientX: 10, clientY: 10}],
    target: context.__textTarget,
  });

  const timer = [...context.__timers.values()].find(
    (entry) => entry.delay === 400,
  );
  assert.ok(timer, 'long press timer was not scheduled');
  timer.callback();
  assert.equal(context.window.getSelection().toString(), '辞書名');
}

function testFrequencyAndPitchSectionsDoNotRenderCrowdedTitles() {
  const context = loadPopup();

  const freq = context.createFrequencySection([
    {dictionary: 'freq-dict', frequencies: [{value: '1'}]},
  ]);
  const pitch = context.createPitchSection([
    {dictionary: 'pitch-dict', pitchPositions: [0]},
  ], 'かな');

  assert.ok(freq, 'frequency section was not rendered');
  assert.ok(pitch, 'pitch section was not rendered');
  assert.equal(freq.children.some((child) => child.className === 'category-title'), false);
  assert.equal(pitch.children.some((child) => child.className === 'category-title'), false);
}

function testStructuredContentTablesUseHorizontalScrollContainer() {
  const context = loadPopup();
  const parent = context.document.createElement('div');

  context.renderStructuredContent(parent, {
    tag: 'table',
    content: [
      {
        tag: 'tr',
        content: [
          {tag: 'td', content: 'left'},
          {tag: 'td', content: 'right'},
        ],
      },
    ],
  }, null, 'test-dict', false);

  assert.equal(parent.children.length, 1);
  assert.equal(parent.children[0].className, 'gloss-sc-table-container');
  assert.equal(parent.children[0].children[0].tagName, 'TABLE');
  assert.equal(parent.children[0].children[0].className, 'gloss-sc-table');
}

// BUG-057: wty-ja-en non-lemma "alt-of" glossaries arrive as an array of
// [term, [tag, ...]] pairs. The generic array path used to flatten each pair
// into bare adjacent text nodes with no spacing, rendering as mojibake
// ("时Hyōgai时alt-of时alternative时kanji"). renderStructuredContent must instead
// emit one structured list item per pair (term + its tag chips).
function testFormOfGlossaryArrayRendersSeparatedTermAndTags() {
  const context = loadPopup();
  const parent = context.document.createElement('div');

  context.renderStructuredContent(
    parent,
    [
      ['时', ['Hyōgai']],
      ['时', ['alt-of']],
      ['时', ['alternative']],
      ['时', ['kanji']],
    ],
    null,
    'wty-ja-en',
    false,
  );

  assert.equal(parent.children.length, 1, 'expected a single wrapping list');
  const list = parent.children[0];
  assert.equal(list.className, 'form-of-list');
  assert.equal(list.children.length, 4, 'expected one item per term/tag pair');

  const first = list.children[0];
  const term = first.children[0];
  assert.equal(term.className, 'form-of-term');
  assert.equal(term.textContent, '时');

  const tagRow = first.children[1];
  assert.ok(
    tagRow.className.split(/\s+/).includes('glossary-tags'),
    'tags should render in a glossary-tags row',
  );
  assert.equal(tagRow.children[0].className, 'glossary-tag');
  assert.equal(tagRow.children[0].textContent, 'Hyōgai');

  // The remaining pairs keep their own term + tag, not a flattened run.
  assert.equal(list.children[1].children[1].children[0].textContent, 'alt-of');
  assert.equal(list.children[3].children[1].children[0].textContent, 'kanji');
}

function testSelectionHighlightReturnsBoundsForPopupPositioning() {
  const source = fs.readFileSync(selectionPath, 'utf8');

  assert.ok(
    source.includes('if (!this.selection?.ranges.length) return null;'),
    'highlightSelection should return null when no ranges exist',
  );
  assert.ok(
    source.includes('bounds.left'),
    'highlightSelection should aggregate range bounds',
  );
  assert.ok(
    source.includes('width: bounds.right - bounds.left'),
    'highlightSelection should return a width from aggregated bounds',
  );
  assert.ok(
    source.includes('height: bounds.bottom - bounds.top'),
    'highlightSelection should return a height from aggregated bounds',
  );
}

async function testMineEntryDoesNotReuseAudioFromPreviousExpression() {
  const context = loadPopup();
  const resolved = [];
  const mined = [];
  context.window.audioSources = ['https://audio.example/?term={term}'];
  context.window.needsAudio = true;
  context.window.lookupEntries = [
    {
      expression: '猫',
      reading: 'ねこ',
      glossaries: [
        {
          dictionary: 'dict',
          content: {tag: 'span', content: 'cat'},
          definitionTags: '',
          termTags: '',
        },
      ],
    },
  ];
  context.window.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'resolveWordAudio') {
      resolved.push(payload);
      return Promise.resolve(`audio://${payload.expression}`);
    }
    if (name === 'mineEntry') {
      mined.push(payload);
      return Promise.resolve(true);
    }
    return Promise.resolve(true);
  };

  await context.mineEntry('猫', 'ねこ', [], [], [], '猫', 0, '猫');
  context.window.lookupEntries = [
    {
      expression: '犬',
      reading: 'いぬ',
      glossaries: [
        {
          dictionary: 'dict',
          content: {tag: 'span', content: 'dog'},
          definitionTags: '',
          termTags: '',
        },
      ],
    },
  ];
  await context.mineEntry('犬', 'いぬ', [], [], [], '犬', 0, '犬');

  assert.deepEqual(
    resolved.map((entry) => entry.expression),
    ['猫', '犬'],
    'a new expression at the same popup index must resolve its own audio',
  );
  assert.deepEqual(
    mined.map((entry) => entry.audio),
    ['audio://猫', 'audio://犬'],
  );
}

// TODO-766: mining must do a FRESH audio resolve even when the playback cache
// already holds this exact word. A remote host signs the audio URL with a
// short-lived token (5 min); the playback path resolves+plays immediately (token
// fresh) and CACHES the URL. If mining later reuses that cached URL the token
// has expired and Anki downloads a 404 → empty [sound:]. So buildMinePayload must
// re-call resolveWordAudio (re-signing a new token) rather than returning the
// cached playback URL. Reverting the fix (mining reuses the cache) makes the
// second resolveWordAudio call disappear → this test turns red.
async function testMiningResolvesFreshAudioEvenWhenCacheHoldsSameWord() {
  const context = loadPopup();
  const resolved = [];
  const mined = [];
  let signCounter = 0;
  context.window.audioSources = ['https://audio.example/?term={term}'];
  context.window.needsAudio = true;
  context.window.lookupEntries = [
    {
      expression: '猫',
      reading: 'ねこ',
      glossaries: [
        {
          dictionary: 'dict',
          content: {tag: 'span', content: 'cat'},
          definitionTags: '',
          termTags: '',
        },
      ],
    },
  ];
  context.window.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'resolveWordAudio') {
      resolved.push(payload);
      // Each resolve hands back a DISTINCT token-signed URL, mimicking the host.
      signCounter += 1;
      return Promise.resolve(`audio://${payload.expression}?token=${signCounter}`);
    }
    if (name === 'playWordAudio') {
      return Promise.resolve(true);
    }
    if (name === 'mineEntry') {
      mined.push(payload);
      return Promise.resolve(true);
    }
    return Promise.resolve(true);
  };

  // 1) Play the word — this resolves+caches the playback URL (token #1).
  const playedUrl = await context.resolveCachedAudioUrl('猫', 'ねこ', 0);
  assert.equal(playedUrl, 'audio://猫?token=1',
    'playback resolves and caches the first token-signed URL');
  assert.equal(resolved.length, 1, 'playback issued exactly one resolve');

  // 2) Mine the SAME word — must NOT reuse the cached token-1 URL; it must do a
  //    fresh resolve (token #2) so Anki gets a non-expired URL.
  await context.mineEntry('猫', 'ねこ', [], [], [], '猫', 0, '猫');

  assert.equal(resolved.length, 2,
    'mining the same word must trigger a SECOND fresh resolveWordAudio (no cache reuse)');
  assert.equal(mined.length, 1, 'exactly one mine occurred');
  assert.equal(mined[0].audio, 'audio://猫?token=2',
    'the mined card carries the freshly-signed URL, not the stale cached one');
}

// ── TODO-084/087: mine button state is DETECTED AT LOOKUP TIME ─────────────
// Builds an entry header, finds its mine button, and drives the duplicateCheck
// handler. The button's 已制卡 ✓ / 可制卡 + state is the real Anki status
// detected when the popup renders the word (the initial duplicateCheck), NOT a
// purely-visual always-clickable indicator. Re-looking-up the word rebuilds the
// DOM and re-detects (TODO-084); a click on a ✓ re-verifies as an edge-case
// fallback for same-popup external deletion (TODO-087).

function buildMineHeader(context) {
  // reading === expression skips buildFuriganaEl (the fake DOM cannot append the
  // bare text nodes that furigana rendering produces); the mine button is built
  // either way and that is all these tests exercise.
  const entry = {
    expression: '刀',
    reading: '刀',
    matched: '刀',
    frequencies: [],
    pitches: [],
    rules: [],
  };
  const header = context.createEntryHeader(entry, 0);
  const hasClass = (node, name) =>
    (node.className || '').split(/\s+/).includes(name) ||
    (node.classList && node.classList.contains(name));
  const findMine = (node) => {
    if (hasClass(node, 'mine-button')) return node;
    for (const child of node.children ?? []) {
      const found = findMine(child);
      if (found) return found;
    }
    return null;
  };
  const mineButton = findMine(header);
  assert.ok(mineButton, 'mine button was not created');
  return mineButton;
}

async function flush() {
  // Drain microtasks (the in-flight duplicateCheck/mineEntry promises).
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

// LOOKUP-TIME DETECTION (primary mechanism): when the popup renders a word the
// initial duplicateCheck queries Anki and sets the ACCURATE button state.
// Card present -> 已制卡 ✓ + data-mined='1'. Card absent -> 可制卡 + + no
// data-mined. The ✓ is a real detected state, not decoration.
async function testLookupTimeDetectionSetsAccurateStateForExistingCard() {
  const context = loadPopup();
  context.window.allowDupes = false;
  context.window.flutter_inappwebview.callHandler = (name) => {
    if (name === 'duplicateCheck') return Promise.resolve(true); // card in Anki
    return Promise.resolve(true);
  };
  const mineButton = buildMineHeader(context);
  await flush(); // initial lookup-time duplicateCheck resolves
  assert.equal(mineButton.textContent, '✓', 'existing card detected at lookup time shows 已制卡 ✓');
  assert.equal(mineButton.dataset.mined, '1', 'lookup-time detection records a real mined state');
  assert.ok(mineButton.classList.contains('duplicate'), '✓ carries the duplicate class');
}

async function testLookupTimeDetectionSetsMineableStateForAbsentCard() {
  const context = loadPopup();
  context.window.allowDupes = false;
  context.window.flutter_inappwebview.callHandler = (name) => {
    if (name === 'duplicateCheck') return Promise.resolve(false); // not in Anki
    return Promise.resolve(true);
  };
  const mineButton = buildMineHeader(context);
  await flush();
  assert.equal(mineButton.textContent, '+', 'absent card detected at lookup time shows 可制卡 +');
  assert.notEqual(mineButton.dataset.mined, '1', 'an absent card is not a mined state');
}

// TODO-084 (primary): re-looking-up the word after deleting its card in Anki
// rebuilds the DOM (a fresh createEntryHeader) and re-detects at lookup time, so
// the new button shows 可制卡 + and can re-mine. Simulated by building a second
// header after the card was deleted.
async function testRelookupAfterDeletionDetectsMineableAndReMines() {
  const context = loadPopup();
  context.window.allowDupes = false;
  const mined = [];
  let cardExists = true; // first lookup: card is in Anki
  context.window.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'duplicateCheck') return Promise.resolve(cardExists);
    if (name === 'mineEntry') {
      mined.push(payload);
      cardExists = true;
      return Promise.resolve(true);
    }
    return Promise.resolve(true);
  };

  // First lookup detects the existing card.
  const firstButton = buildMineHeader(context);
  await flush();
  assert.equal(firstButton.dataset.mined, '1', 'first lookup detects the card -> 已制卡');

  // User deletes the card in Anki, then RE-LOOKS-UP the word (new header).
  cardExists = false;
  const secondButton = buildMineHeader(context);
  await flush();
  assert.notEqual(secondButton.dataset.mined, '1', 're-lookup detects deletion -> 可制卡');
  assert.equal(secondButton.textContent, '+', 're-lookup button is mineable again');

  // Clicking it re-mines the (now absent) card.
  await secondButton.onclick();
  await flush();
  assert.equal(mined.length, 1, 're-looked-up word can be mined again after deletion');
}

// TODO-087 (edge-case fallback): same popup, card deleted in Anki WITHOUT a
// re-lookup. The button still shows 已制卡 ✓ (stale). Clicking it re-verifies
// against Anki, finds the card gone, and re-mines.
async function testMineButtonReMinesAfterCardDeletedWithoutReopening() {
  const context = loadPopup();
  context.window.allowDupes = false;
  const mined = [];
  let cardExists = true; // card already in Anki at lookup time
  context.window.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'duplicateCheck') return Promise.resolve(cardExists);
    if (name === 'mineEntry') {
      mined.push(payload);
      cardExists = true; // mining recreates the card
      return Promise.resolve(true); // isAnkiConnect -> synchronous re-check
    }
    return Promise.resolve(true);
  };

  const mineButton = buildMineHeader(context);
  await flush(); // lookup-time detection -> 已制卡 ✓
  assert.equal(mineButton.dataset.mined, '1', 'lookup-time detection marks the existing card as mined');
  assert.equal(typeof mineButton.onclick, 'function', 'onclick must be a real handler');

  // User deletes the card in Anki, popup still open, NO re-lookup / re-open.
  cardExists = false;

  // Edge-case fallback: clicking the stale ✓ re-verifies, finds no card, re-mines.
  await mineButton.onclick();
  await flush();
  assert.equal(mined.length, 1, 'clicking a stale ✓ after in-Anki deletion must re-mine');
  assert.equal(mineButton.textContent, '✓', 'after re-mining the state is 已制卡 ✓ again');
  assert.equal(mineButton.disabled, false, 'button stays clickable, never a dead lock');
}

// TODO-087 fallback, no-deletion case: clicking a 已制卡 ✓ whose card is still
// genuinely in Anki (dupes off) must re-verify and add NOTHING.
async function testMineButtonDoesNotDuplicateWhenCardStillExists() {
  const context = loadPopup();
  context.window.allowDupes = false;
  const mined = [];
  let cardExists = true; // card really is still in Anki
  context.window.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'duplicateCheck') return Promise.resolve(cardExists);
    if (name === 'mineEntry') {
      mined.push(payload);
      return Promise.resolve(true);
    }
    return Promise.resolve(true);
  };

  const mineButton = buildMineHeader(context);
  await flush(); // initial lookup-time detection paints 已制卡 ✓
  assert.equal(mineButton.textContent, '✓', 'lookup-time detection shows 已制卡 ✓ for an existing card');
  assert.equal(mineButton.dataset.mined, '1', 'mined state is recorded');

  await mineButton.onclick();
  await flush();
  assert.equal(mined.length, 0, 'must not duplicate a card that still exists in Anki');
  assert.equal(mineButton.textContent, '✓', 'indicator stays 已制卡 ✓');
  assert.equal(mineButton.disabled, false, 'button is still clickable, never locked');
}

// TODO-448: a failed or uncertain mineEntry result must not schedule a delayed
// duplicateCheck that later flips the button to ✓. That was the visible "first
// failed, then succeeded" experience when addNote reached Anki but the response
// connection was lost.
async function testFailedMineDoesNotRefreshIntoSuccessAfterDuplicateCheck() {
  const context = loadPopup();
  context.window.allowDupes = false;
  let duplicateChecks = 0;
  let cardExists = false;
  context.window.flutter_inappwebview.callHandler = (name) => {
    if (name === 'duplicateCheck') {
      duplicateChecks += 1;
      return Promise.resolve(cardExists);
    }
    if (name === 'mineEntry') {
      cardExists = true;
      return Promise.resolve({ ankiConnect: false, noteId: null });
    }
    return Promise.resolve(true);
  };

  const mineButton = buildMineHeader(context);
  await flush();
  assert.equal(mineButton.textContent, '+', 'initial state is mineable');
  assert.equal(duplicateChecks, 1, 'initial lookup-time duplicateCheck ran');

  await mineButton.onclick();
  await flush();

  assert.equal(duplicateChecks, 1,
    'failed/uncertain mine results must not run a delayed duplicateCheck');
  assert.equal(context.__timers.size, 0,
    'failed/uncertain mine results must not schedule delayed refresh timers');
  assert.equal(mineButton.textContent, '+',
    'a failed/uncertain mine must not later paint itself as success');
}

// ── TODO-270 D: tri-state mine button (overwrite the latest mined card) ─────
// After a successful mine that returns a real note id (AnkiConnect only) the
// button becomes a GREEN "latest editable" ✓↩: clicking it overwrites THAT note
// (updateEntry) instead of re-mining. Mining a different word supersedes it back
// to a plain ✓ (only the most-recently-mined card stays editable). AnkiDroid
// returns no id -> never enters the third state (graceful degrade).

function buildMineHeaderFor(context, expression) {
  // reading === expression skips buildFuriganaEl (the fake DOM cannot append the
  // bare text nodes furigana rendering produces). The mine button — all these
  // tests exercise — is built either way, and the entry key still differs per
  // expression so supersession across distinct words is exercised correctly.
  const entry = {
    expression,
    reading: expression,
    matched: expression,
    frequencies: [],
    pitches: [],
    rules: [],
  };
  const header = context.createEntryHeader(entry, 0);
  const hasClass = (node, name) =>
    (node.className || '').split(/\s+/).includes(name) ||
    (node.classList && node.classList.contains(name));
  const findMine = (node) => {
    if (hasClass(node, 'mine-button')) return node;
    for (const child of node.children ?? []) {
      const found = findMine(child);
      if (found) return found;
    }
    return null;
  };
  const mineButton = findMine(header);
  assert.ok(mineButton, 'mine button was not created');
  return mineButton;
}

// Mining a word whose backend returns a note id makes the button the editable
// latest (green ✓↩); clicking it again calls updateEntry with that note id and
// the new fields — NOT a second mineEntry.
async function testLatestMinedCardCanBeOverwrittenInPlace() {
  const context = loadPopup();
  context.window.allowDupes = true; // skip the re-verify branch noise
  const mined = [];
  const updated = [];
  context.window.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'duplicateCheck') return Promise.resolve(true);
    if (name === 'mineEntry') {
      mined.push(payload);
      // AnkiConnect-style structured reply with a real note id.
      return Promise.resolve({ ankiConnect: true, noteId: 555 });
    }
    if (name === 'updateEntry') {
      updated.push(payload);
      return Promise.resolve({ ankiConnect: true, noteId: payload.noteId });
    }
    return Promise.resolve(true);
  };

  const mineButton = buildMineHeaderFor(context, '猫');
  await flush(); // lookup-time detection (card present here)

  // First click mines and the note id makes it the editable latest.
  await mineButton.onclick();
  await flush();
  assert.equal(mined.length, 1, 'first click mines a new card');
  assert.equal(mineButton.dataset.latest, '1', 'a mined card with a note id is the editable latest');
  assert.equal(mineButton.textContent, '✓↩', 'latest editable shows the ✓ + undo glyph');
  assert.ok(mineButton.classList.contains('latest'), 'latest carries the .latest class');

  // Second click OVERWRITES the same note instead of mining again.
  await mineButton.onclick();
  await flush();
  assert.equal(mined.length, 1, 'overwriting must NOT create a second card');
  assert.equal(updated.length, 1, 'clicking the green ✓↩ calls updateEntry');
  assert.equal(updated[0].noteId, 555, 'updateEntry targets the latest note id');
  assert.ok(updated[0].fields && updated[0].fields.expression === '猫',
    'updateEntry carries the freshly-built fields');
  assert.equal(mineButton.dataset.latest, '1', 'a successful update stays the editable latest');
  assert.equal(mineButton.disabled, false, 'button never sticks disabled');
}

// Mining a SECOND word supersedes the first: the first word is no longer the
// latest, so clicking its (now stale) button does NOT call updateEntry — it
// falls back to the ordinary mined path.
async function testMiningNextCardDowngradesPreviousFromEditable() {
  const context = loadPopup();
  context.window.allowDupes = true;
  const mined = [];
  const updated = [];
  context.window.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'duplicateCheck') return Promise.resolve(true);
    if (name === 'mineEntry') {
      mined.push(payload.expression);
      return Promise.resolve({ ankiConnect: true, noteId: mined.length });
    }
    if (name === 'updateEntry') {
      updated.push(payload.noteId);
      return Promise.resolve({ ankiConnect: true, noteId: payload.noteId });
    }
    return Promise.resolve(true);
  };

  // Mine word A -> it is the editable latest.
  const buttonA = buildMineHeaderFor(context, '猫');
  await flush();
  await buttonA.onclick();
  await flush();
  assert.equal(buttonA.dataset.latest, '1', 'A is editable right after mining');

  // Mine word B (a different popup entry) -> B becomes the latest, superseding A.
  const buttonB = buildMineHeaderFor(context, '犬');
  await flush();
  await buttonB.onclick();
  await flush();
  assert.equal(buttonB.dataset.latest, '1', 'B is now the editable latest');

  // Clicking A's stale button must NOT overwrite — A is no longer the latest.
  await buttonA.onclick();
  await flush();
  assert.equal(updated.length, 0,
    'a superseded earlier card must not be overwritten in place');
  // A re-mines through the ordinary path instead (allowDupes -> a new mine).
  assert.ok(mined.includes('猫'), 'the earlier word goes through the normal mine path');
}

// AnkiDroid graceful degrade: a mine that returns no note id (bare true / no id)
// never becomes the editable latest — it stays an ordinary ✓.
async function testNoNoteIdNeverBecomesEditableLatest() {
  const context = loadPopup();
  context.window.allowDupes = true;
  const updated = [];
  context.window.flutter_inappwebview.callHandler = (name) => {
    if (name === 'duplicateCheck') return Promise.resolve(true);
    if (name === 'mineEntry') return Promise.resolve(true); // AnkiDroid: bare bool, no id
    if (name === 'updateEntry') { updated.push(1); return Promise.resolve(true); }
    return Promise.resolve(true);
  };

  const mineButton = buildMineHeaderFor(context, '本');
  await flush();
  await mineButton.onclick();
  await flush();
  assert.notEqual(mineButton.dataset.latest, '1',
    'no note id -> never the editable latest (AnkiDroid degrade)');
  assert.equal(mineButton.textContent, '✓', 'shows an ordinary ✓, not the ✓↩ glyph');

  // Clicking again must not attempt an in-place overwrite.
  await mineButton.onclick();
  await flush();
  assert.equal(updated.length, 0, 'without a note id, clicks never call updateEntry');
}

// ── TODO-614: overwrite-scope = all promotes an EARLIER card to ✓↩ ─────────
// "现在只能覆写最近制的卡，我想给再之前的也能覆写。" With overwriteScope=all the
// host's overwriteTargetNoteId handler returns a real note id for an already-mined
// word the user never touched this session. The lookup-time render must promote
// that button to the green ✓↩ (editable latest) so clicking it overwrites the
// earlier card in place — WITHOUT the user having mined it in this popup session.
async function testOverwriteScopeAllPromotesEarlierCardToEditable() {
  const context = loadPopup();
  context.window.allowDupes = false;
  const updated = [];
  context.window.flutter_inappwebview.callHandler = (name, payload) => {
    if (name === 'duplicateCheck') return Promise.resolve(true); // card in Anki
    // scope=all: the host reaches into Anki and hands back the earlier card's id.
    if (name === 'overwriteTargetNoteId') return Promise.resolve(777);
    if (name === 'updateEntry') {
      updated.push(payload);
      return Promise.resolve({ ankiConnect: true, noteId: payload.noteId });
    }
    return Promise.resolve(true);
  };

  // The word was NEVER mined in this session — only the host's scope=all lookup
  // makes it editable.
  const mineButton = buildMineHeaderFor(context, '昨日');
  await flush(); // lookup-time duplicateCheck + overwriteTargetNoteId resolve

  assert.equal(mineButton.dataset.mined, '1', 'an existing card is detected as mined');
  assert.equal(mineButton.dataset.latest, '1',
    'scope=all promotes an earlier (never-this-session) card to the editable latest');
  assert.equal(mineButton.textContent, '✓↩',
    'a promoted earlier card shows the ✓ + undo glyph');

  // Clicking it overwrites the earlier note in place (updateEntry, NOT a re-mine).
  await mineButton.onclick();
  await flush();
  assert.equal(updated.length, 1, 'clicking ✓↩ overwrites the earlier card via updateEntry');
  assert.equal(updated[0].noteId, 777, 'updateEntry targets the earlier card note id');
}

// scope=latest (default) / AnkiDroid (no id): overwriteTargetNoteId returns null,
// so an earlier card stays an ordinary ✓ — the old two-state behaviour is intact
// (Never break userspace). A click just re-verifies, never an in-place overwrite.
async function testOverwriteScopeLatestKeepsEarlierCardOrdinary() {
  const context = loadPopup();
  context.window.allowDupes = false;
  const updated = [];
  context.window.flutter_inappwebview.callHandler = (name) => {
    if (name === 'duplicateCheck') return Promise.resolve(true);
    if (name === 'overwriteTargetNoteId') return Promise.resolve(null); // latest scope
    if (name === 'updateEntry') { updated.push(1); return Promise.resolve(true); }
    return Promise.resolve(true);
  };

  const mineButton = buildMineHeaderFor(context, '今日');
  await flush();

  assert.equal(mineButton.dataset.mined, '1', 'the existing card is still detected as mined');
  assert.notEqual(mineButton.dataset.latest, '1',
    'scope=latest must not promote an earlier card (old behaviour preserved)');
  assert.equal(mineButton.textContent, '✓', 'an earlier card stays an ordinary ✓');
}

// ── TODO-094 S5: kanji dictionary card ─────────────────────────────────────
// A single-character lookup carries per-character kanji-dictionary results
// (onyomi / kunyomi / radical / strokes / meanings) on window.kanjiResults,
// injected alongside window.lookupEntries by dictionary_popup_webview.dart.
// buildKanjiCards() renders a card per character; an empty / missing array
// renders nothing (so multi-char / kana / latin lookups are untouched).
//
// SCOPE NOTE: these tests exercise ONLY the render logic for a GIVEN kanji
// payload — they do NOT assert the FFI actually returns kanji. On-device,
// queryKanji is still empty until the hoshidicts native libs are rebuilt with
// the S3 kanji exports across all 5 platforms; until then this card never
// appears on a real lookup. End-to-end is therefore pending that rebuild +
// device verification; this S5 work makes the render pipeline ready + testable.

function findByClass(node, className) {
  if (!node) return null;
  const has = (node.className || '').split(/\s+/).includes(className) ||
    (node.classList && node.classList.contains(className));
  if (has) return node;
  for (const child of node.children ?? []) {
    const found = findByClass(child, className);
    if (found) return found;
  }
  return null;
}

function collectText(node) {
  if (!node) return '';
  if (node.children && node.children.length) {
    return node.children.map(collectText).join('');
  }
  return node.textContent || '';
}

function sampleKanji() {
  return {
    character: '水',
    onyomi: 'スイ',
    kunyomi: 'みず',
    radical: '水',
    strokes: 4,
    meanings: ['water', 'liquid'],
    dictName: 'KANJIDIC',
  };
}

function testKanjiCardRendersAllFields() {
  const context = loadPopup();
  context.window.kanjiResults = [sampleKanji()];

  const section = context.buildKanjiCards();
  assert.ok(section, 'kanji section should render for a non-empty payload');
  assert.equal(section.className, 'kanji-card-section');

  const card = findByClass(section, 'kanji-card');
  assert.ok(card, 'a kanji card should be produced');

  const charEl = findByClass(card, 'kanji-card-char');
  assert.ok(charEl, 'the big character should render');
  assert.equal(charEl.textContent, '水');

  const meanings = findByClass(card, 'kanji-card-meanings');
  assert.ok(meanings, 'meanings should render');
  assert.equal(meanings.textContent, 'water, liquid');

  // On / Kun / Radical / Strokes rows: assert the values are present somewhere
  // in the card text (label text is an English fallback; value is what matters).
  const cardText = collectText(card);
  assert.ok(cardText.includes('スイ'), 'onyomi value must be rendered');
  assert.ok(cardText.includes('みず'), 'kunyomi value must be rendered');
  assert.ok(cardText.includes('水'), 'radical value must be rendered');
  assert.ok(cardText.includes('4'), 'stroke count must be rendered');
  assert.ok(cardText.includes('KANJIDIC'), 'source dict name must be rendered');
}

function testKanjiCardEmptyPayloadRendersNothing() {
  const context = loadPopup();

  context.window.kanjiResults = [];
  assert.equal(context.buildKanjiCards(), null,
    'an empty kanji array must render no card (multi-char / kana / latin lookups)');

  delete context.window.kanjiResults;
  assert.equal(context.buildKanjiCards(), null,
    'a missing kanji array must render no card');
}

function testKanjiCardOmitsAbsentFields() {
  const context = loadPopup();
  // A kanji dictionary that only carries meanings (no readings / radical /
  // strokes) must not emit empty reading rows or a 0-stroke row.
  context.window.kanjiResults = [{
    character: '々',
    onyomi: '',
    kunyomi: '',
    radical: '',
    strokes: 0,
    meanings: ['repetition mark'],
    dictName: 'KanjiDict',
  }];

  const section = context.buildKanjiCards();
  const card = findByClass(section, 'kanji-card');
  assert.ok(card, 'card still renders when only meanings are present');
  assert.equal(findByClass(card, 'kanji-card-meanings').textContent, 'repetition mark');
  // No reading rows for empty on/kun, no row for 0 strokes.
  assert.equal(card.children.some((c) => c.className === 'kanji-card-row'), false,
    'absent readings/radical/strokes must not produce empty rows');
}

function stubRenderPopupRuntime(context, container) {
  // renderPopup touches a few DOM/runtime members the shared fake DOM does not
  // implement; stub exactly what its kanji-only / no-results branches reach.
  context.document.getElementById = (id) =>
    id === 'entries-container' ? container : null;
  context.document.querySelectorAll = () => [];
  context.document.body.scrollHeight = 0;
  context.performance = { now: () => 0 };
  // applyCustomCSS appends <style> nodes via document.querySelectorAll; it is
  // not under test here, so neutralize it on the vm-global the script calls.
  context.applyCustomCSS = () => {};
}

function testRenderPopupShowsKanjiCardWithNoTermEntries() {
  const context = loadPopup();
  // A kanji-only result (character only in a kanji dictionary, no term headword)
  // must still render the kanji card instead of "No results".
  const container = new FakeElement('div');
  stubRenderPopupRuntime(context, container);

  context.window.lookupEntries = [];
  context.window.kanjiResults = [sampleKanji()];

  context.window.renderPopup();

  assert.ok(findByClass(container, 'kanji-card'),
    'a kanji-only lookup must render the kanji card');
  assert.equal(findByClass(container, 'no-results'), null,
    'a kanji-only lookup must NOT fall through to the no-results state');
}

function testRenderPopupNoKanjiNoEntriesShowsNoResults() {
  const context = loadPopup();
  const container = new FakeElement('div');
  stubRenderPopupRuntime(context, container);

  context.window.lookupEntries = [];
  context.window.kanjiResults = [];

  context.window.renderPopup();

  // No kanji + no entries keeps the original no-results behaviour: the
  // container's innerHTML is set to the no-results placeholder markup.
  assert.ok((container.textContent || '').includes('No results') ||
    (container.textContent || '').includes('no-results'),
    'empty everything must still show the no-results placeholder');
}

testEmSizedWideImagesUseHorizontalScrollWrapper();
testSanseidoEmAccentImageStaysInlineAndPointsAtDictionaryMedia();
testGlossImageScrollWrapperIsInline();
testLargeRasterImagesMarkedAsEmUseNaturalWidthAfterLoad();
testExplicitContentImageDimensionsDefaultToPixelUnits();
testPixelImagesWithBadDeclaredAspectUseNaturalWidthAfterLoad();
testTappingDefinitionImageOpensLightbox();
testTapOnGlossaryTextSelectsWord();
testTapOnEntryCardWhitespaceKeepsLayer();
testTapOnPopupBackgroundFiresTapOutside();
testTapInsideKanjiCardKeepsLayer();
testTapOnImagePixelsOpensLightbox();
testTapInImageContainerWhitespaceDoesNotOpenLightbox();
testFrequencyAndPitchSectionsDoNotRenderCrowdedTitles();
testStructuredContentTablesUseHorizontalScrollContainer();
testFormOfGlossaryArrayRendersSeparatedTermAndTags();
testKanjiCardRendersAllFields();
testKanjiCardEmptyPayloadRendersNothing();
testKanjiCardOmitsAbsentFields();
testRenderPopupShowsKanjiCardWithNoTermEntries();
testRenderPopupNoKanjiNoEntriesShowsNoResults();
testSelectionHighlightReturnsBoundsForPopupPositioning();
// TODO: testLongPress* tests access document.__listeners.touchstart but popup.js
// registers touchstart on per-entry summary elements. Rewrite tests to create a
// dictionary entry, then fire touchstart on the summary element's own listener.
// testLongPressTimerSurvivesEarlyTouchEnd();
// testRepeatedTouchStartDoesNotCancelPendingLongPress();
// testLongPressFallsBackFromElementToTextNode();

testMineEntryDoesNotReuseAudioFromPreviousExpression().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testMiningResolvesFreshAudioEvenWhenCacheHoldsSameWord().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testLookupTimeDetectionSetsAccurateStateForExistingCard().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testLookupTimeDetectionSetsMineableStateForAbsentCard().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testRelookupAfterDeletionDetectsMineableAndReMines().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testMineButtonReMinesAfterCardDeletedWithoutReopening().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testMineButtonDoesNotDuplicateWhenCardStillExists().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testFailedMineDoesNotRefreshIntoSuccessAfterDuplicateCheck().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testLatestMinedCardCanBeOverwrittenInPlace().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testMiningNextCardDowngradesPreviousFromEditable().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testNoNoteIdNeverBecomesEditableLatest().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testOverwriteScopeAllPromotesEarlierCardToEditable().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

testOverwriteScopeLatestKeepsEarlierCardOrdinary().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
