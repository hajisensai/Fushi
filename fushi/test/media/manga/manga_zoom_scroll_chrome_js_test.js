// Runs inside the real generated manga window document (headless Chromium),
// against the production gesture script. Driven by
// manga_zoom_scroll_chrome_js_test.dart.
//
// Webtoon zoom keeps the content under the finger in place by rewriting
// window.scrollY (_zoomAbout -> scrollTo). That scroll is a re-anchor, not the
// reader scrolling the strip -- it must not be reported as "user scrolled"
// (onMangaReaderHide), otherwise a double-tap zoom out pops the reader UI back
// in and a zoom in hides it. A real one-finger drag must still report.
(function () {
  var failures = [];
  var passed = 0;
  var calls = [];
  window.__mangaTestCalls = calls;

  function check(cond, msg) {
    if (cond) { passed++; } else { failures.push(msg); }
  }
  function zoom() {
    var canvas = document.getElementById('manga-canvas');
    var m = /scale\(([^)]+)\)/.exec((canvas && canvas.style.transform) || '');
    return m ? Number(m[1]) : 1;
  }
  function hides() {
    return calls.filter(function (c) { return c[0] === 'onMangaReaderHide'; });
  }
  function fire(type, target, id, x, y) {
    var down = type === 'pointerdown' || type === 'pointermove';
    target.dispatchEvent(new PointerEvent(type, {
      pointerId: id, pointerType: 'touch', isPrimary: true,
      clientX: x, clientY: y, button: type === 'pointermove' ? -1 : 0,
      buttons: down ? 1 : 0, bubbles: true, cancelable: true, composed: true
    }));
  }
  function at(x, y) { return document.elementFromPoint(x, y) || document.body; }
  function tap(id, x, y) {
    var t = at(x, y);
    fire('pointerdown', t, id, x, y);
    fire('pointerup', t, id, x, y);
  }
  function scrolled() {
    // The browser coalesces scrolls into one `scroll` event per frame. Fire it
    // synchronously at the point a frame would, so the run is deterministic.
    window.dispatchEvent(new Event('scroll'));
  }

  var id = 100;
  // Start in the middle of the strip so zoom can move scrollY both ways.
  // Programmatic, no recent input: never reported.
  window.scrollTo(0, 600);
  scrolled();
  calls.length = 0;
  var y0 = window.scrollY;
  check(y0 > 0, 'strip must be scrollable for this test, scrollY=' + y0);

  // Double tap in the lower half: zoom in, scrollY grows (re-anchor).
  tap(id++, 206, 700);
  tap(id++, 206, 700);
  scrolled();
  check(zoom() > 1.5, 'double tap must zoom in, got ' + zoom());
  check(window.scrollY > y0,
      'zoom in must re-anchor scrollY downwards: ' + y0 + ' -> ' + window.scrollY);
  check(hides().length === 0,
      'zoom-in re-anchor scroll must not toggle the reader UI: ' + JSON.stringify(hides()));

  // Double tap again: back to 100%, scrollY shrinks (re-anchor).
  var y1 = window.scrollY;
  tap(id++, 206, 700);
  tap(id++, 206, 700);
  scrolled();
  check(Math.abs(zoom() - 1) < 0.01, 'second double tap must zoom back out, got ' + zoom());
  check(window.scrollY < y1,
      'zoom out must re-anchor scrollY upwards: ' + y1 + ' -> ' + window.scrollY);
  check(hides().length === 0,
      'zoom-out re-anchor scroll must not toggle the reader UI: ' + JSON.stringify(hides()));

  // Control: the reader really scrolling the strip still reports.
  var y2 = window.scrollY;
  var t = at(206, 700);
  fire('pointerdown', t, id, 206, 700);
  for (var i = 1; i <= 12; i++) {
    fire('pointermove', t, id, 206, 700 - 400 * i / 12);
    scrolled();
  }
  fire('pointerup', t, id, 206, 300);
  id++;
  check(window.scrollY > y2, 'drag up must scroll the strip down: ' + y2 + ' -> ' + window.scrollY);
  var h = hides();
  check(h.length > 0 && h[h.length - 1][1] === true,
      'a real upward drag (scrolling down) must still hide the UI: ' + JSON.stringify(h));

  var out = document.createElement('pre');
  out.id = 'results';
  out.textContent = btoa(JSON.stringify({passed: passed, failures: failures}));
  document.body.appendChild(out);
})();
