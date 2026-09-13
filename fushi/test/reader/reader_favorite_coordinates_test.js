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
  function fixture(html) {
    window.getSelection().removeAllRanges();
    document.body.innerHTML = html;
  }
  function select(start, startOffset, end, endOffset) {
    const range = document.createRange();
    range.setStart(start, startOffset);
    range.setEnd(end, endOffset);
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(range);
    return window.fushiSelection.nativeSelectionSentenceRange();
  }
  function paint(text, offset, css) {
    window.__fushiCssHighlightsSupported = css;
    window.__fushiApplyHighlights([{id: 'favorite', text, offset, length: 1, color: 'yellow'}]);
    return css
      ? Array.from(CSS.highlights.get('fushi-hl-yellow') || []).map(r => r.toString()).join('')
      : Array.from(document.querySelectorAll('[data-highlight-id="favorite"]')).map(n => n.textContent).join('');
  }
  for (const css of [true, false]) {
    const mode = css ? 'CSS Highlight' : 'fallback span';
    for (const [name, html, needle, hint] of [
      ['Latin and digits before selection', '<p>ABC 123日本語選択した文章です。</p>', '選択した文章', 5],
      ['Japanese only', '<p>これは選択した文章です。</p>', '選択した文章', 3],
      ['middle of Latin word', '<p>before alphabet after</p>', 'phab', 1],
      ['punctuation', '<p>前文。選択、した！文章。</p>', '選択、した！', 2],
      ['non BMP and other scripts', '<p>before 𠮷🙂 café Ελληνικά العربية after</p>', '𠮷🙂 café Ελληνικά العربية', 1],
      ['cross-node whitespace', '<p>前文。<b>選択 </b><i>した文章</i>です。</p>', '選択 した文章', 2],
    ]) {
      test(mode + ': ' + name, () => {
        fixture(html);
        const painted = paint(needle, hint, css);
        // Layout whitespace at a node boundary has no glyph to paint.
        equal(painted.replace(/\s/g, ''), needle.replace(/\s/g, ''));
      });
    }
    test(mode + ': repeated text uses study hint', () => {
      fixture('<p>ABC 同文。後。同文。</p>');
      equal(paint('同文', 4, css), '同文');
      if (css) equal(window.__fushiHighlightRangeMap.favorite.ranges[0].startOffset, 9);
      else equal(document.querySelector('[data-highlight-id]').previousSibling.textContent, 'ABC 同文。後。');
    });
    test(mode + ': ambiguous repeat stays unpainted', () => {
      fixture('<p>同文。同文。</p>');
      equal(paint('同文', 1, css), '');
    });
    test(mode + ': missing text cannot paint stale offset', () => {
      fixture('<p>別の文章。</p>');
      equal(paint('保存時の文章', 0, css), '');
    });
  }
  test('native drag keeps substring independent of expanded sentence', () => {
    fixture('<p>ABC 123日本語選択した文章です。</p>');
    const node = document.querySelector('p').firstChild;
    const data = select(node, 10, node, 17);
    equal(data.text, '選択した文章で');
    equal(data.normalizedOffset, 5);
    equal(data.matchableOffset, 9);
    equal(window.__fushiGetSelectionNormRange().text, data.text);
    equal(paint(data.text, data.normalizedOffset, true), data.text);
  });
  test('native range element child indexes exclude adjacent text', () => {
    fixture('<p><span>前</span><b>選択</b><i>文章</i><span>後</span></p>');
    const p = document.querySelector('p');
    const data = select(p, 1, p, 3);
    equal(data.text, '選択文章');
    equal(data.normalizedOffset, 1);
    equal(data.normalizedLength, 4);
  });
  test('native ruby range excludes pronunciation and respects cross-node ends', () => {
    fixture('<p>前<ruby>漢<rt>かん</rt></ruby><b>字と文章</b>後</p>');
    const p = document.querySelector('p');
    const b = document.querySelector('b').firstChild;
    const data = select(p, 1, b, 2);
    equal(data.text, '漢字と');
    equal(data.normalizedOffset, 1);
    equal(data.normalizedLength, 3);
  });
  document.body.innerHTML = '<pre id="results"></pre>';
  document.querySelector('#results').textContent = btoa(unescape(encodeURIComponent(JSON.stringify({passed, failures}))));
})();
