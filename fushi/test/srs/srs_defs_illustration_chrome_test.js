// Runs inside headless Chromium against the production defs-page scripts.
// Driven by srs_defs_illustration_chrome_test.dart (BUG-5181).
//
// Lays out exported dictionary illustrations (declared-size and natural-size
// export shapes) inside a "picture | vertical caption" table, with Chromium's
// minimum font size at 8px (Android WebView default), then checks that the
// picture stays inside its box, the box stays inside the column, and a tap on
// the picture or on the box hands the image to the host.
(function () {
  var C = window.__srsTestCase;
  var failures = [];
  var passed = 0;
  var details = [];
  var calls = [];
  window.__srsTestCalls = calls;

  function check(cond, msg) {
    if (cond) { passed++; } else { failures.push(msg); }
  }
  function rect(el) { return el.getBoundingClientRect(); }
  function fmt(r) {
    return Math.round(r.left) + ',' + Math.round(r.top) + ' ' +
      Math.round(r.width) + 'x' + Math.round(r.height);
  }
  function finish() {
    var pre = document.createElement('pre');
    pre.id = 'results';
    pre.textContent = btoa(unescape(encodeURIComponent(JSON.stringify({
      failures: failures, passed: passed, details: details.join(' | ')
    }))));
    document.body.appendChild(pre);
  }
  function click(target) {
    target.dispatchEvent(new MouseEvent('click', {
      bubbles: true, cancelable: true, composed: true, button: 0
    }));
  }

  function run() {
    window.__fushiSrsHostLayout();
    var li = document.querySelector('li[data-dictionary]');
    var lr = rect(li);
    var lcs = getComputedStyle(li);
    var colLeft = lr.left + parseFloat(lcs.paddingLeft);
    var colRight = lr.right - parseFloat(lcs.paddingRight);
    details.push('column ' + Math.round(colLeft) + '..' + Math.round(colRight));
    ['declared', 'natural'].forEach(function (id) {
      var a = document.getElementById(id);
      var box = a.firstElementChild;
      var img = box.querySelector('img');
      var table = a.closest('table');
      var caption = table.querySelector('td[data-sc-caption]');
      var br = rect(box), ir = rect(img), tr = rect(table), cr = rect(caption);
      details.push(id + ' illus=' + a.getAttribute('data-fushi-srs-illus') +
        ' w=' + a.style.getPropertyValue('--fushi-srs-illus-w') +
        ' avail=' + a.style.getPropertyValue('--fushi-srs-illus-avail') +
        ' box=' + fmt(br) + ' img=' + fmt(ir) + ' table=' + fmt(tr) +
        ' caption=' + fmt(cr));
      check(a.getAttribute('data-fushi-srs-illus') === 'color', id + ': marked as a color illustration');
      check(Math.abs(parseFloat(a.style.getPropertyValue('--fushi-srs-illus-w')) - C.w) <= 1,
        id + ': declared width is the laid-out width (' + C.w + 'px), not em x clamped font size');
      check(parseFloat(a.style.getPropertyValue('--fushi-srs-illus-avail')) > 0, id + ': column width measured');
      check(br.width > 0 && br.height > 0, id + ': box has a size');
      check(ir.left >= br.left - 1 && ir.top >= br.top - 1 &&
        ir.right <= br.right + 1 && ir.bottom <= br.bottom + 1, id + ': picture inside its box');
      check(Math.abs(ir.width - br.width) <= 1 && Math.abs(ir.height - br.height) <= 1,
        id + ': picture fills its box');
      check(Math.abs(br.height / br.width - C.h / C.w) < 0.02, id + ': box keeps the picture aspect ratio');
      check(br.left >= colLeft - 1 && tr.right <= colRight + 1 && cr.right <= colRight + 1,
        id + ': picture and caption stay inside the column');
      if (C.size === 'large') {
        // Fills the column next to the caption (the height cap allows more).
        check(br.width > C.w && Math.abs(tr.right - colRight) <= 2,
          id + ': large fills the column width');
      } else {
        check(Math.abs(br.width - Math.max(C.w, C.minWidth)) <= 1,
          id + ': ' + C.size + ' keeps the declared width');
      }
      var before = calls.length;
      click(img);
      check(calls.length === before + 1 && calls[before][0] === 'onSrsImageTap' &&
        calls[before][1] === img.currentSrc, id + ': tapping the picture opens it');
      click(box.firstElementChild);
      check(calls.length === before + 2 && calls[before + 1][0] === 'onSrsImageTap',
        id + ': tapping the box opens the picture');
    });
    check(calls.every(function (c) { return c[0] === 'onSrsImageTap'; }),
      'illustration taps never become lookups: ' + JSON.stringify(calls.map(function (c) { return c[0]; })));
  }

  // A 239x320 picture: white with a black right edge.
  var canvas = document.createElement('canvas');
  canvas.width = C.w;
  canvas.height = C.h;
  var g = canvas.getContext('2d');
  g.fillStyle = '#fff';
  g.fillRect(0, 0, C.w, C.h);
  g.fillStyle = '#000';
  g.fillRect(C.w - 20, 0, 20, C.h);
  var url = canvas.toDataURL('image/png');
  var imgs = [].slice.call(document.querySelectorAll('#fushi-card-root img'));
  var left = imgs.length;
  imgs.forEach(function (img) {
    img.addEventListener('load', function () {
      if (--left > 0) return;
      try { run(); } catch (err) { failures.push('threw: ' + (err && err.stack || err)); }
      finish();
    }, {once: true});
    img.src = url;
  });
})();
