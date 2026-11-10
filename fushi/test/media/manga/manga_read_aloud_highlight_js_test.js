// Runs inside the real generated manga window document (headless Chromium),
// against the production overlay script. Driven by
// manga_read_aloud_highlight_js_test.dart, which defines window.__testBoxes
// (the OCR layer HTML of page 0) and window.__testGroup (the sentence group
// to highlight) before this file runs.
//
// Manga read-aloud highlights the sentence being read: __mangaSetSpeaking marks
// only the boxes of that sentence group, survives the OCR layer being replaced
// (__mangaReplaceOcr), and a negative group clears it.
(function () {
  var failures = [];
  var passed = 0;

  function check(cond, msg) {
    if (cond) { passed++; } else { failures.push(msg); }
  }
  function speaking() {
    return document.querySelectorAll('.ocr-box.manga-speaking');
  }
  function groupBoxes(page, group) {
    return document.querySelectorAll('.manga-page[data-page="' + page +
        '"] .ocr-box[data-manga-sentence-group="' + group + '"]');
  }

  var group = window.__testGroup;
  window.__mangaReplaceOcr(0, window.__testBoxes);
  var total = document.querySelectorAll('.manga-page[data-page="0"] .ocr-box').length;
  var target = groupBoxes(0, group).length;
  check(total > target && target > 0,
      'fixture must have boxes inside and outside the group: total=' + total +
      ' target=' + target);
  check(speaking().length === 0, 'nothing highlighted before reading');

  window.__mangaSetSpeaking(0, group);
  var lit = speaking();
  check(lit.length === target,
      'only the read sentence group is highlighted: ' + lit.length + ' vs ' + target);
  var allInGroup = true;
  for (var i = 0; i < lit.length; i++) {
    if (lit[i].getAttribute('data-manga-sentence-group') !== String(group)) {
      allInGroup = false;
    }
  }
  check(allInGroup, 'highlighted boxes all belong to the read group');

  // Background OCR replaces the page's text layer: the highlight comes back.
  window.__mangaReplaceOcr(0, window.__testBoxes);
  check(speaking().length === target,
      'highlight is re-applied after __mangaReplaceOcr: ' + speaking().length);

  // Page without an OCR layer in the window: no throw, nothing lit.
  window.__mangaSetSpeaking(1, group);
  check(speaking().length === 0, 'switching to a page without boxes clears page 0');

  window.__mangaSetSpeaking(0, group);
  window.__mangaSetSpeaking(0, -1);
  check(speaking().length === 0, 'group -1 clears the highlight');
  check(window.__mangaSpeaking === null, 'cleared state is null');

  var out = document.createElement('pre');
  out.id = 'results';
  out.textContent = btoa(JSON.stringify({passed: passed, failures: failures}));
  document.body.appendChild(out);
})();
