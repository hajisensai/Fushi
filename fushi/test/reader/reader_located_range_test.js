// BUG-4103：跳转落点标记 window.__fushiMarkLocatedRange 在真实 DOM Range / CSS Highlight 上的行为。
// 由 reader_located_range_test.dart 拼进真 Chrome 页面执行，结果写进 <pre id="results">。
(() => {
  const failures = [];
  let passed = 0;
  function test(name, action) {
    try { action(); passed++; }
    catch (error) { failures.push(name + ': ' + error.stack); }
  }
  function equal(actual, expected) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw Error(JSON.stringify({actual, expected}));
    }
  }
  function isFurigana(node) {
    const el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('rt, rp'));
  }
  // 分页 / 连续 shell 的同名协作者（createWalker 拒 rt/rp、countChars = 学习单位），
  // 与 reader_pagination_scripts.dart 的 _sharedJs 同口径。
  function chapterReader(root) {
    return {
      createWalker: () => document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode: n => isFurigana(n) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
      }),
      countChars: text => window.fushiStudyUnits.count(text),
    };
  }
  // VN shell：createWalker 只走当前屏，章内起点查 buildNodeOffsets 建的 nodeStartOffsets。
  function screenReader(root, screenStart) {
    const reader = chapterReader(root);
    const offsets = new WeakMap();
    let count = screenStart;
    const walker = reader.createWalker();
    let node;
    while ((node = walker.nextNode())) {
      offsets.set(node, count);
      count += reader.countChars(node.textContent);
    }
    reader.rangeMap = {};
    reader.nodeStartOffsets = offsets;
    return reader;
  }
  // 高亮覆盖的正文（不含注音）。
  function markedText() {
    const highlight = CSS.highlights.get('fushi-search');
    if (!highlight) return null;
    return Array.from(highlight).map(range => {
      const box = document.createElement('div');
      box.appendChild(range.cloneContents());
      box.querySelectorAll('rt, rp').forEach(el => el.remove());
      return box.textContent;
    }).join('|');
  }
  function fixture(html) {
    CSS.highlights.clear();
    document.body.innerHTML = '<div id="chapter">' + html + '</div>';
    return document.getElementById('chapter');
  }
  function mark(start, end) {
    return window.__fushiMarkLocatedRange(start, end);
  }

  window.__fushiCssHighlightsSupported = true;

  test('paged/continuous: sentence across inline elements and ruby', () => {
    window.fushiReader = chapterReader(fixture(
      '<p>前文。<b>選択</b>した<ruby>文<rt>ぶん</rt></ruby>章です。後の文。</p>'));
    // 前文 = 0..1；選択した文章です = 2..9（句末「。」不是学习单位）。
    equal(mark(2, 10), true);
    equal(markedText(), '選択した文章です');
  });
  test('paged/continuous: offsets in later paragraphs count the whole chapter', () => {
    window.fushiReader = chapterReader(fixture(
      '<p>一段目の文。</p><p>二段目、ここが目標の文。</p>'));
    // 一段目の文 = 0..4；二段目 = 5..7；ここが目標の文 = 8..14。
    equal(mark(8, 15), true);
    equal(markedText(), 'ここが目標の文');
  });
  test('paged/continuous: space-separated words are one unit each', () => {
    window.fushiReader = chapterReader(fixture('<p>Hello brave new world.</p>'));
    equal(mark(1, 3), true);
    equal(markedText(), 'brave new');
  });
  test('paged/continuous: sentence end exactly at a node boundary', () => {
    window.fushiReader = chapterReader(fixture('<p><span>目標</span><span>次</span></p>'));
    equal(mark(0, 2), true);
    equal(markedText(), '目標');
  });
  test('offset outside the chapter paints nothing', () => {
    window.fushiReader = chapterReader(fixture('<p>短い章。</p>'));
    equal(mark(50, 60), false);
    equal(markedText(), null);
  });
  test('empty or inverted span paints nothing', () => {
    window.fushiReader = chapterReader(fixture('<p>短い章。</p>'));
    equal(mark(2, 2), false);
    equal(mark(3, 1), false);
    equal(markedText(), null);
  });
  test('engines without CSS Custom Highlight paint nothing', () => {
    window.fushiReader = chapterReader(fixture('<p>短い章。</p>'));
    window.__fushiCssHighlightsSupported = false;
    try {
      equal(mark(0, 2), false);
      equal(markedText(), null);
    } finally {
      window.__fushiCssHighlightsSupported = true;
    }
  });
  test('vn: screen clone maps chapter offsets via nodeStartOffsets', () => {
    // 屏从章内第 100 个单位开始：画面の文章 = 100..104，次の文 = 105..107。
    window.fushiReader = screenReader(fixture('<p>画面の文章。<b>次の文</b>。</p>'), 100);
    equal(mark(105, 108), true);
    equal(markedText(), '次の文');
  });
  test('vn: sentence that began on the previous screen is marked from screen start', () => {
    window.fushiReader = screenReader(fixture('<p>画面の文章。</p>'), 100);
    equal(mark(98, 102), true);
    equal(markedText(), '画面');
  });
  test('vn: sentence continuing on the next screen is marked to screen end', () => {
    window.fushiReader = screenReader(fixture('<p>画面の文章</p>'), 100);
    equal(mark(103, 120), true);
    equal(markedText(), '文章');
  });
  test('vn: span entirely on another screen paints nothing', () => {
    window.fushiReader = screenReader(fixture('<p>画面の文章。</p>'), 100);
    equal(mark(10, 20), false);
    equal(markedText(), null);
  });
  test('re-marking replaces the previous mark', () => {
    window.fushiReader = chapterReader(fixture('<p>一つ目。二つ目。</p>'));
    equal(mark(0, 3), true);
    equal(mark(3, 6), true);
    equal(markedText(), '二つ目');
  });

  document.body.innerHTML = '<pre id="results"></pre>';
  document.querySelector('#results').textContent = btoa(unescape(encodeURIComponent(JSON.stringify({passed, failures}))));
})();
