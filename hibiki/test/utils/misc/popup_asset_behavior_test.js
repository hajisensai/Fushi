const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dictMediaPath = path.resolve(__dirname, '../../../assets/popup/dict-media.js');
const popupPath = path.resolve(__dirname, '../../../assets/popup/popup.js');

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

  addEventListener(type, handler) {
    (this.listeners[type] ??= []).push(handler);
  }

  getBoundingClientRect() {
    return {width: 0, height: 0};
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

function testPixelImagesUseNaturalAspectRatioAfterLoad() {
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

  assert.equal(container.style.width, '100px');
  assert.equal(sizer.style.paddingTop, `${(246 / 230) * 100}%`);
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

testEmSizedWideImagesUseHorizontalScrollWrapper();
testExplicitContentImageDimensionsDefaultToPixelUnits();
testPixelImagesUseNaturalAspectRatioAfterLoad();
