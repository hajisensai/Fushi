const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

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
  vm.runInNewContext(fs.readFileSync(scriptPath, 'utf8'), context, {
    filename: scriptPath,
  });
  return context;
}

function testPopupHtmlImagesUseDictionaryMediaScheme() {
  const context = loadScript(popupPath);
  const html = '<div><img src="img/example.png"><link href="styles.css"></div>';
  const rewritten = context.rewriteDictLinks(html, '故事ことわざの辞典');

  assert.ok(
    rewritten.includes(
      'src="image://?dictionary=%E6%95%85%E4%BA%8B%E3%81%93%E3%81%A8%E3%82%8F%E3%81%96%E3%81%AE%E8%BE%9E%E5%85%B8&path=img%2Fexample.png"',
    ),
    rewritten,
  );
  assert.ok(
    rewritten.includes(
      'href="dictmedia://styles.css?dictionary=%E6%95%85%E4%BA%8B%E3%81%93%E3%81%A8%E3%82%8F%E3%81%96%E3%81%AE%E8%BE%9E%E5%85%B8"',
    ),
    rewritten,
  );
}

function testDefinitionHtmlImagesUseDictionaryMediaScheme() {
  const context = loadScript(definitionPath);
  const html = '<p><img src="/media/figure.svg"></p>';
  const rewritten = context.rewriteDictLinks(html, '故事ことわざの辞典');

  assert.ok(
    rewritten.includes(
      'src="image://?dictionary=%E6%95%85%E4%BA%8B%E3%81%93%E3%81%A8%E3%82%8F%E3%81%96%E3%81%AE%E8%BE%9E%E5%85%B8&path=media%2Ffigure.svg"',
    ),
    rewritten,
  );
}

function testExternalHtmlImagesRemainExternal() {
  const context = loadScript(popupPath);
  const html = '<img src="https://example.com/example.png"><img src="data:image/png;base64,abc">';
  const rewritten = context.rewriteDictLinks(html, 'dict');

  assert.equal(rewritten, html);
}

testPopupHtmlImagesUseDictionaryMediaScheme();
testDefinitionHtmlImagesUseDictionaryMediaScheme();
testExternalHtmlImagesRemainExternal();
