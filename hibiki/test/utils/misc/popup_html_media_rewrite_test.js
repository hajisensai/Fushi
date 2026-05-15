const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const dictMediaPath = path.resolve(__dirname, '../../../assets/popup/dict-media.js');
const popupPath = path.resolve(__dirname, '../../../assets/popup/popup.js');
const definitionPath = path.resolve(__dirname, '../../../assets/popup/definition.js');

function loadScript(scriptPath) {
  const context = {
    console,
    document: {
      addEventListener() {},
    },
    window: {
      flutter_inappwebview: {
        callHandler() {
          return Promise.resolve(null);
        },
      },
    },
  };
  context.globalThis = context;
  vm.runInNewContext(fs.readFileSync(dictMediaPath, 'utf8'), context, {
    filename: dictMediaPath,
  });
  vm.runInNewContext(fs.readFileSync(scriptPath, 'utf8'), context, {
    filename: scriptPath,
  });
  return context;
}

const DICT = '故事ことわざの辞典';
const DICT_ENC = encodeURIComponent(DICT);

function testPopupHtmlImagesUseDictionaryMediaScheme() {
  const context = loadScript(popupPath);
  const html = '<div><img src="img/example.png"><link href="styles.css"></div>';
  const rewritten = context.rewriteDictLinks(html, DICT);

  assert.ok(
    rewritten.includes(
      `src="image://?dictionary=${DICT_ENC}&path=img%2Fexample.png"`,
    ),
    'img src not rewritten: ' + rewritten,
  );
  assert.ok(
    rewritten.includes(
      `href="dictmedia://styles.css?dictionary=${DICT_ENC}"`,
    ),
    'link href not rewritten: ' + rewritten,
  );
}

function testDefinitionHtmlImagesUseDictionaryMediaScheme() {
  const context = loadScript(definitionPath);
  const html = '<p><img src="/media/figure.svg"></p>';
  const rewritten = context.rewriteDictLinks(html, DICT);

  assert.ok(
    rewritten.includes(
      `src="image://?dictionary=${DICT_ENC}&path=media%2Ffigure.svg"`,
    ),
    'img src not rewritten: ' + rewritten,
  );
}

function testStructuredImagesNormalizeDictionaryMediaPath() {
  const context = loadScript(popupPath);
  const rewritten = context.rewriteDictionaryMediaPath('.\\media\\figure.svg', DICT);

  assert.strictEqual(
    rewritten,
    `image://?dictionary=${DICT_ENC}&path=media%2Ffigure.svg`,
  );
}

function testExternalHtmlImagesRemainExternal() {
  const context = loadScript(popupPath);
  const html = '<img src="https://example.com/example.png"><img src="data:image/png;base64,abc">';
  const rewritten = context.rewriteDictLinks(html, 'dict');

  assert.equal(rewritten, html);
}

function testLinkHrefNormalized() {
  const context = loadScript(popupPath);
  const html = '<link href="./styles\\main.css">';
  const rewritten = context.rewriteDictLinks(html, DICT);

  assert.ok(
    rewritten.includes(
      `href="dictmedia://styles%2Fmain.css?dictionary=${DICT_ENC}"`,
    ),
    'link href with ./ prefix and backslash not normalized: ' + rewritten,
  );
  assert.ok(
    !rewritten.includes('.%2F'),
    'link href still contains ./ prefix: ' + rewritten,
  );
  assert.ok(
    !rewritten.includes('%5C'),
    'link href still contains backslash: ' + rewritten,
  );
}

function testDictMediaLoadedOnce() {
  const context = loadScript(popupPath);
  assert.strictEqual(typeof context.rewriteDictLinks, 'function');
  assert.strictEqual(typeof context.rewriteDictionaryMediaPath, 'function');
  assert.strictEqual(typeof context.constructDictCss, 'function');
}

testPopupHtmlImagesUseDictionaryMediaScheme();
testDefinitionHtmlImagesUseDictionaryMediaScheme();
testStructuredImagesNormalizeDictionaryMediaPath();
testExternalHtmlImagesRemainExternal();
testLinkHrefNormalized();
testDictMediaLoadedOnce();
