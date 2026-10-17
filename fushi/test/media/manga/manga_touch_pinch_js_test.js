// Runs inside the real generated manga window document (headless Chromium),
// against the production gesture script. Driven by manga_touch_pinch_js_test.dart.
//
// Input is synthesized as real DOM PointerEvents dispatched on the element under
// the finger -- the same event path a WebView uses. The "lost finger" scenario
// dispatches the release on a node that was detached mid-gesture: that event's
// propagation path no longer contains `document`, which is exactly how a touch
// whose target was removed (OCR layer replaced, cover layer torn down) ends
// without the document-level gesture machine ever hearing about it.
(function () {
  var failures = [];
  var passed = 0;
  var calls = [];
  window.__mangaTestCalls = calls;
  var IS_WEBTOON_DOC = document.documentElement.getAttribute('data-test-mode') === 'webtoon';

  function check(cond, msg) {
    if (cond) { passed++; } else { failures.push(msg); }
  }
  function zoom() {
    var canvas = document.getElementById('manga-canvas');
    var m = /scale\(([^)]+)\)/.exec((canvas && canvas.style.transform) || '');
    return m ? Number(m[1]) : 1;
  }
  function panX() {
    var canvas = document.getElementById('manga-canvas');
    var m = /translate\(([-0-9.e]+)px/.exec((canvas && canvas.style.transform) || '');
    return m ? Number(m[1]) : 0;
  }
  function turns() {
    return calls.filter(function (c) { return c[0] === 'onMangaTurn'; }).length;
  }
  function fire(type, target, id, x, y, primary) {
    var down = type === 'pointerdown' || type === 'pointermove';
    target.dispatchEvent(new PointerEvent(type, {
      pointerId: id, pointerType: 'touch', isPrimary: primary,
      clientX: x, clientY: y, button: type === 'pointermove' ? -1 : 0,
      buttons: down ? 1 : 0, bubbles: true, cancelable: true, composed: true
    }));
  }
  function at(x, y) { return document.elementFromPoint(x, y) || document.body; }
  // One finger: down, `steps` moves to (x1, y1), up.
  function drag(id, x0, y0, x1, y1, steps) {
    var t = at(x0, y0);
    fire('pointerdown', t, id, x0, y0, true);
    for (var i = 1; i <= steps; i++) {
      fire('pointermove', t, id, x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps, true);
    }
    fire('pointerup', t, id, x1, y1, true);
  }
  // Two fingers on a horizontal line around (cx, cy): half-distance d0 -> d1.
  function pinch(idA, idB, cx, cy, d0, d1, steps) {
    var ta = at(cx - d0, cy), tb = at(cx + d0, cy);
    fire('pointerdown', ta, idA, cx - d0, cy, true);
    fire('pointerdown', tb, idB, cx + d0, cy, false);
    for (var i = 1; i <= steps; i++) {
      var d = d0 + (d1 - d0) * i / steps;
      fire('pointermove', ta, idA, cx - d, cy, true);
      fire('pointermove', tb, idB, cx + d, cy, false);
    }
    fire('pointerup', tb, idB, cx + d1, cy, false);
    fire('pointerup', ta, idA, cx - d1, cy, true);
  }
  // A finger whose release is never heard by `document`: it lands on a node
  // that is removed before the finger lifts.
  function lostFinger(id, x, y, primary) {
    var ghost = document.createElement('div');
    ghost.style.cssText = 'position:fixed;left:' + (x - 20) + 'px;top:' + (y - 20) +
        'px;width:40px;height:40px;z-index:50;';
    document.body.appendChild(ghost);
    fire('pointerdown', ghost, id, x, y, primary);
    ghost.remove();
    fire('pointerup', ghost, id, x, y, primary);
  }

  var cx = 206, cy = 430;
  var nextId = 10;

  // 1. Two-finger pinch out really zooms, and does not turn the page.
  var z0 = zoom();
  var t0 = turns();
  pinch(nextId++, nextId++, cx, cy, 40, 140, 12);
  var zIn = zoom();
  check(zIn > z0 * 1.5, 'pinch out must zoom in: ' + z0 + ' -> ' + zIn);
  check(turns() === t0, 'pinch must not turn the page');

  // 2. While zoomed, a single finger pans the canvas and keeps the zoom.
  var px0 = panX();
  drag(nextId++, cx, cy, cx + 60, cy, 8);
  check(Math.abs(zoom() - zIn) < 1e-6, 'one-finger pan must not change zoom: ' + zIn + ' -> ' + zoom());
  check(Math.abs(panX() - px0) > 30, 'one-finger drag must pan while zoomed: ' + px0 + ' -> ' + panX());

  // 3. Two-finger pinch in zooms back out.
  pinch(nextId++, nextId++, cx, cy, 140, 30, 12);
  var zOut = zoom();
  check(zOut < zIn - 0.3, 'pinch in must zoom out: ' + zIn + ' -> ' + zOut);

  // Reset to exactly 100% for the remaining cases.
  window.__mangaSetZoom(100);
  check(Math.abs(zoom() - 1) < 1e-6, 'reset to 100%');

  // 4. A finger whose release was lost, then a big one-finger swipe: the swipe
  //    must not zoom (the lost finger is not still on the glass) and must still
  //    act as a swipe (paged: turns the page).
  lostFinger(nextId++, 230, 420, true);
  var t4 = turns();
  drag(nextId++, 236, 420, 20, 420, 16);
  check(Math.abs(zoom() - 1) < 1e-6, 'big swipe after a lost finger must not zoom, got ' + zoom());
  if (!IS_WEBTOON_DOC) {
    check(turns() === t4 + 1, 'big swipe after a lost finger must still turn the page');
  }

  // 5. ... and the reader is not stuck: the next swipe works too, and a real
  //    pinch still zooms from the true two-finger geometry.
  var t5 = turns();
  drag(nextId++, 300, 420, 40, 420, 16);
  check(Math.abs(zoom() - 1) < 1e-6, 'second swipe must not zoom');
  if (!IS_WEBTOON_DOC) check(turns() === t5 + 1, 'second swipe must turn the page (not stuck)');
  pinch(nextId++, nextId++, cx, cy, 50, 100, 10);
  var zr = zoom();
  check(zr > 1.6 && zr < 2.4, 'pinch after a lost finger must follow the two real fingers (~2x), got ' + zr);
  window.__mangaSetZoom(100);

  // 6. A second finger lost *inside* a pinch must not leave the reader stuck
  //    once every real finger has lifted and a new gesture starts.
  var a = nextId++;
  var ta = at(150, cy);
  fire('pointerdown', ta, a, 150, cy, true);
  lostFinger(nextId++, 260, cy, false);
  fire('pointerup', ta, a, 150, cy, true);
  var t6 = turns();
  drag(nextId++, 300, 420, 40, 420, 16);
  check(Math.abs(zoom() - 1) < 1e-6, 'swipe after a pinch with a lost finger must not zoom, got ' + zoom());
  if (!IS_WEBTOON_DOC) check(turns() === t6 + 1, 'swipe after a pinch with a lost finger must turn the page');

  // 7. Third finger during a pinch, then one lifts: no zoom jump.
  window.__mangaSetZoom(100);
  var f1 = nextId++, f2 = nextId++, f3 = nextId++;
  var e1 = at(150, cy), e2 = at(260, cy), e3 = at(206, 600);
  fire('pointerdown', e1, f1, 150, cy, true);
  fire('pointerdown', e2, f2, 260, cy, false);
  fire('pointerdown', e3, f3, 206, 600, false);
  fire('pointerup', e1, f1, 150, cy, true);
  var zBefore = zoom();
  fire('pointermove', e2, f2, 261, cy, false);
  check(Math.abs(zoom() - zBefore) < 0.05,
      'changing the pinch pair must rebase, not jump: ' + zBefore + ' -> ' + zoom());
  fire('pointerup', e2, f2, 261, cy, false);
  fire('pointerup', e3, f3, 206, 600, false);

  var out = document.createElement('pre');
  out.id = 'results';
  out.textContent = btoa(JSON.stringify({passed: passed, failures: failures}));
  document.body.appendChild(out);
})();
