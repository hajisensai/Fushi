// BUG-4808 behavior test: the paged shell's deferred "land once more" callbacks
// re-derive the landing from the registered SEMANTIC anchor instead of writing
// back a pixel position captured before the deferral.
//
// Two deferred writers existed:
//   · `_settleAndNotify(context, pos)` — every restore entry (restoreProgress /
//     restoreToCharOffset / jumpToFragment) read the page position right after
//     landing and a 16 ms timer wrote that captured `pos` back;
//   · `_alignRangeToPage` — after a reveal landed, the next animation frame wrote
//     the captured `targetScroll` again.
// Neither checked whether the position had been legitimately changed in between.
// A lazy image that finished loading inside the window re-anchored the viewport
// to the right page (reapplyImageLateAnchor) and the timer then put the stale
// page back — with no further image load nothing corrected it, and the following
// progress report persisted the wrong position. A user page turn inside the frame
// after a reveal was pulled back to the reveal target the same way.
//
// This harness instantiates the real paged shell object (extracted from
// reader_pagination_scripts.dart via the Dart driver) with controllable timers /
// animation frames and a fake layout whose geometry the test moves the way a
// late image load does, and asserts:
//   A. settle: a late-image re-anchor inside the 16 ms window survives the timer
//      (char / progress / fragment anchors), and the snap baseline is the live
//      position;
//   B. settle keeps its original job: a reflow that zeroed the scroll is re-landed;
//      an untouched landing is neither re-derived (no second walk of the chapter
//      before Dart is notified) nor rewritten;
//   C. settle: a user page turn / a replacing reveal inside the window is not
//      overwritten;
//   D. reveal frame: a user page turn inside the frame is not pulled back; an
//      unchanged target is re-landed (reflow) and a moved target is followed;
//   E. audio-follow fade branch: same generation rule, without ending the fade;
//   F. reveal frame during a page-curl preview (the preview does not bump the
//      anchor generation): no write on the previewed page; reverting the curl
//      re-lands the still-registered target, committing it drops the pending work.
//
// Driven from paged_settle_semantic_anchor_behavior_test.dart inside `flutter test`;
// the payload (production script sources as JSON) arrives on stdin.

const assert = require('node:assert');
const {
  readPayload, shellObjectLiteral, compileScript, scrolledRect, scrolledRange,
} = require('./paged_shell_behavior_support.js');

const data = readPayload();

const PAGE = 1000;

function instantiate() {
  // `anchorDoc`: document coordinate of the restore anchor's character (char /
  // progress restores land on its page). Geometry is in document coordinates;
  // client rects are derived from the live scroll, like the engine sees them.
  const state = { scroll: 3000, anchorDoc: 5200 };
  const calls = { setPage: [], setPageNow: [], snap: [], notify: 0, finishTurn: 0, rederive: 0 };
  const timers = [];
  const frames = [];
  const elements = {};
  const style = { writingMode: 'horizontal-tb', getPropertyValue() { return ''; } };
  const getComputedStyle = () => style;
  const window = {
    innerWidth: 1000, innerHeight: 800, CSS: {}, Highlight: function() {},
    getComputedStyle,
  };
  const document = {
    documentElement: { style: {}, clientHeight: 800, clientWidth: 1000 },
    scrollingElement: null,
    body: { clientWidth: 1000, clientHeight: 800 },
    fonts: { ready: Promise.resolve() },
    caretRangeFromPoint: () => null,
    getElementById: (id) => elements[id] || null,
    getElementsByName: () => [],
  };
  const Node = { TEXT_NODE: 3 };
  compileScript(['window'], data.studyUnits, 'reader_study_unit_script.js')(window);
  const C = { perfTraceEnabled: false };
  const factory = compileScript(
    ['window', 'document', 'C', 'global', 'CSS', 'Highlight', 'getComputedStyle', 'Node',
      'requestAnimationFrame', 'setTimeout'],
    'window.fushiReader = ' + shellObjectLiteral(data.paged) + '; return window.fushiReader;',
    'paged_shell.js'
  );
  const reader = factory(window, document, C, {}, window.CSS, window.Highlight,
    getComputedStyle, Node,
    (fn) => { frames.push(fn); },
    (fn, ms) => { timers.push({ fn, ms }); });

  const context = {
    vertical: false, pageSize: PAGE, contentStart: 0, columnGap: 0, physicalMaxScroll: 1e9,
  };
  reader.getScrollContext = () => context;
  reader.getPagePosition = () => state.scroll;
  reader.setPagePosition = (ctx, position) => {
    calls.setPage.push(position);
    state.scroll = position;
    return position;
  };
  reader._setPagePositionNow = (ctx, position) => {
    calls.setPageNow.push(position);
    state.scroll = position;
    return position;
  };
  // Landing by semantic anchor = the page that holds the anchor's character in
  // the CURRENT layout.
  const landOnAnchor = () => {
    calls.rederive++;
    reader.setPagePosition(context, Math.floor(state.anchorDoc / PAGE) * PAGE);
  };
  reader.charOffsetInRange = () => true;
  reader.scrollToCharOffset = landOnAnchor;
  reader.scrollToProgressPaged = landOnAnchor;
  reader.registerSnapScroll = (pos) => { calls.snap.push(pos); };
  reader.notifyRestoreComplete = () => { calls.notify++; };
  // User page turn through the production paginate (it is what retires the anchor).
  reader.adjacentPageStep = () => ({ context, target: state.scroll + PAGE });
  reader.turnPageAnimated = (ctx, target) => { state.scroll = target; };
  reader.pageTurnEffect = () => 'none';
  reader.whenPageTurnApplied = (fn) => { fn(); };
  return { reader, state, calls, timers, frames, elements, context };
}

function runTimer(f) {
  assert.strictEqual(f.timers.length, 1, 'settle schedules exactly one timer');
  assert.strictEqual(f.timers[0].ms, 16, 'settle waits one frame (16 ms)');
  f.timers.shift().fn();
}

// The image `load` listener of _sharedInitImages: metrics invalidated, then the
// late anchor re-applied.
function lateImageLoad(f, mutate) {
  mutate();
  f.reader.paginationMetrics = null;
  f.reader.reapplyImageLateAnchor();
}

// ── A. settle vs. a late image inside the 16 ms window ────────────────────
async function settleSurvivesLateImage() {
  for (const [label, restore] of [
    ['char anchor', (f) => f.reader.restoreToCharOffset(5700)],
    ['progress anchor', (f) => f.reader.restoreProgress(0.5)],
  ]) {
    const f = instantiate();
    await restore(f);
    assert.strictEqual(f.state.scroll, 5000, label + ': restore lands on the anchor page');
    assert.strictEqual(f.calls.notify, 0, label + ': Dart is not notified before the settle');
    // A block image before the anchor finishes loading and pushes it one page on.
    lateImageLoad(f, () => { f.state.anchorDoc = 6200; });
    assert.strictEqual(f.state.scroll, 6000, label + ': the late image re-anchors to the anchor\'s new page');
    runTimer(f);
    assert.strictEqual(f.state.scroll, 6000,
      label + ': the settle timer must not write back the pixel position captured before the image loaded');
    assert.deepStrictEqual(f.calls.snap, [6000], label + ': snap baseline = the live position');
    assert.strictEqual(f.calls.notify, 1, label + ': restore completion notified once');
  }
  {
    const label = 'fragment anchor';
    const f = instantiate();
    const geom = { doc: 5200, size: 40 };
    f.elements.note = { getClientRects: () => [scrolledRect(f.state, geom)], getBoundingClientRect: () => scrolledRect(f.state, geom) };
    assert.strictEqual(await f.reader.jumpToFragment('note'), true);
    assert.strictEqual(f.state.scroll, 5000, label + ': jump lands on the target page');
    lateImageLoad(f, () => { geom.doc = 6200; });
    assert.strictEqual(f.state.scroll, 6000);
    runTimer(f);
    assert.strictEqual(f.state.scroll, 6000,
      label + ': the settle timer must not write back the stale page');
    assert.deepStrictEqual(f.calls.snap, [6000]);
    assert.strictEqual(f.calls.notify, 1);
  }
  {
    // The image loads inside the window but its load event is still queued when
    // the timer fires: the position is untouched, so the settle writes nothing
    // (no stale pixel either) and the load listener, when its turn comes,
    // re-anchors as for any image that loads after the restore.
    const f = instantiate();
    await f.reader.restoreToCharOffset(5700);
    f.state.anchorDoc = 6200;
    const writes = f.calls.setPage.length;
    runTimer(f);
    assert.strictEqual(f.calls.setPage.length, writes, 'an untouched position is not rewritten by the settle');
    assert.strictEqual(f.calls.notify, 1);
    lateImageLoad(f, () => {});
    assert.strictEqual(f.state.scroll, 6000, 'the queued load event re-anchors by the semantic anchor');
  }

}

// ── B. settle still re-lands after a reflow zeroed the scroll ─────────────
async function settleKeepsRelandingAfterReflow() {
  {
    const f = instantiate();
    await f.reader.restoreToCharOffset(5700);
    f.state.scroll = 0; // restore-induced reflow reset the scroller
    runTimer(f);
    assert.strictEqual(f.state.scroll, 5000, 'settle re-lands the anchor after a reflow reset');
    assert.deepStrictEqual(f.calls.snap, [5000]);
    assert.strictEqual(f.calls.notify, 1);
    assert.strictEqual(f.calls.rederive, 2, 'a displaced position is re-derived once by the settle');
  }
  for (const [label, restore] of [
    ['char anchor', (f) => f.reader.restoreToCharOffset(5700)],
    ['progress anchor', (f) => f.reader.restoreProgress(0.5)],
  ]) {
    // Nothing moved the position inside the window: the settle must not walk
    // the chapter again before notifying Dart (the walk to the anchor is as
    // expensive as the restore itself on a long chapter).
    const f = instantiate();
    await restore(f);
    assert.strictEqual(f.calls.rederive, 1);
    const writes = f.calls.setPage.length;
    runTimer(f);
    assert.strictEqual(f.calls.rederive, 1, label + ': an untouched landing is not re-derived by the settle');
    assert.strictEqual(f.calls.setPage.length, writes, label + ': and nothing is written');
    assert.strictEqual(f.state.scroll, 5000);
    assert.deepStrictEqual(f.calls.snap, [5000]);
    assert.strictEqual(f.calls.notify, 1);
  }

}

// ── C. the position was handed to someone else inside the window ──────────
async function settleYieldsToNewOwner() {
  {
    const f = instantiate();
    await f.reader.restoreToCharOffset(5700);
    assert.strictEqual(f.reader.paginate('forward'), 'scrolled');
    assert.strictEqual(f.state.scroll, 6000, 'user turned the page inside the settle window');
    const writes = f.calls.setPage.length;
    runTimer(f);
    assert.strictEqual(f.state.scroll, 6000, 'settle must not pull a user page turn back to the restore page');
    assert.strictEqual(f.calls.setPage.length, writes, 'a retired anchor means settle writes no position');
    assert.deepStrictEqual(f.calls.snap, [6000], 'snap baseline = the page the user turned to');
    assert.strictEqual(f.calls.notify, 1, 'restore completion is still notified');
  }
  {
    // A programmatic reveal (audiobook follow) replaced the anchor.
    const f = instantiate();
    await f.reader.restoreToCharOffset(5700);
    assert.strictEqual(f.reader.scrollToRange(scrolledRange(f.state, { doc: 7200, size: 40 })), true);
    assert.strictEqual(f.state.scroll, 7000);
    runTimer(f);
    assert.strictEqual(f.state.scroll, 7000, 'settle follows the replacing reveal target, not the restore page');
    assert.deepStrictEqual(f.calls.snap, [7000]);
  }
  {
    // A failed fragment jump has no anchor: it registers snap + notifies at once.
    const f = instantiate();
    assert.strictEqual(await f.reader.jumpToFragment('missing'), false);
    assert.strictEqual(f.timers.length, 0);
    assert.deepStrictEqual(f.calls.snap, [3000]);
    assert.strictEqual(f.calls.notify, 1);
  }

}

// ── D. the frame after a reveal ───────────────────────────────────────────
function revealFrameFollowsAnchor() {
  {
    const f = instantiate();
    assert.strictEqual(f.reader.scrollToRange(scrolledRange(f.state, { doc: 5200, size: 40 })), true);
    assert.strictEqual(f.state.scroll, 5000);
    assert.strictEqual(f.frames.length, 1, 'the reveal schedules one follow-up frame');
    f.reader.paginate('forward');
    assert.strictEqual(f.state.scroll, 6000);
    const writes = f.calls.setPage.length;
    f.frames.shift()();
    assert.strictEqual(f.state.scroll, 6000, 'the reveal frame must not pull a user page turn back to the reveal target');
    assert.strictEqual(f.calls.setPage.length, writes, 'a retired reveal target writes no position');
  }
  {
    const f = instantiate();
    f.reader.scrollToRange(scrolledRange(f.state, { doc: 5200, size: 40 }));
    f.state.scroll = 0; // reflow reset inside the frame
    f.frames.shift()();
    assert.strictEqual(f.state.scroll, 5000, 'an unchanged reveal target is re-landed after a reflow reset');
  }
  {
    const f = instantiate();
    const cue = { doc: 5200, size: 40 };
    f.reader.scrollToRange(scrolledRange(f.state, cue));
    cue.doc = 6200; // a late image moved the revealed cue inside the frame
    f.frames.shift()();
    assert.strictEqual(f.state.scroll, 6000, 'the reveal frame follows the target to its new page');
  }
  {
    // A newer reveal owns the position; the older frame is stale.
    const f = instantiate();
    const first = { doc: 5200, size: 40 };
    f.reader.scrollToRange(scrolledRange(f.state, first));
    f.reader.scrollToRange(scrolledRange(f.state, { doc: 8200, size: 40 }));
    assert.strictEqual(f.state.scroll, 8000);
    assert.strictEqual(f.frames.length, 2);
    f.frames.shift()();
    assert.strictEqual(f.state.scroll, 8000, 'the superseded reveal frame must not write its own target');
    f.frames.shift()();
    assert.strictEqual(f.state.scroll, 8000);
  }

}

// ── E. audio-follow fade branch ───────────────────────────────────────────
function audioFollowFadeFrame() {
  for (const scenario of ['intact', 'reset', 'user-turn']) {
    const f = instantiate();
    f.reader.pageTurnEffect = () => 'fade';
    f.reader._audioRevealPageTurn = true;
    f.state.scroll = 4000;
    assert.strictEqual(f.reader.scrollToRange(scrolledRange(f.state, { doc: 5200, size: 40 })), true);
    assert.strictEqual(f.state.scroll, 5000, 'adjacent audio reveal lands through the animated turn');
    assert.strictEqual(f.frames.length, 1);
    if (scenario === 'reset') f.state.scroll = 0;
    if (scenario === 'user-turn') f.reader.paginate('forward');
    const before = f.state.scroll;
    f.frames.shift()();
    assert.deepStrictEqual(f.calls.setPage, [], scenario + ': the fade branch never ends the animation via setPagePosition');
    if (scenario === 'intact') {
      assert.deepStrictEqual(f.calls.setPageNow, [], 'intact: nothing to rewrite');
      assert.strictEqual(f.state.scroll, 5000);
    } else if (scenario === 'reset') {
      assert.deepStrictEqual(f.calls.setPageNow, [5000], 'reset: re-landed without ending the fade');
    } else {
      assert.strictEqual(f.state.scroll, before, 'user-turn: the fade frame must not pull the page back');
      assert.deepStrictEqual(f.calls.setPageNow, []);
    }
  }

}

// ── F. the reveal frame fires while a page-curl preview is showing ────────
function revealFrameUnderCurlPreview() {
  for (const scenario of ['revert', 'revert-moved', 'commit']) {
    for (const fade of [false, true]) {
      const label = scenario + (fade ? ' (fade)' : '');
      const f = instantiate();
      // The preview / revert write the scroller directly (no bookkeeping).
      f.reader.assignPagePosition = (ctx, position) => { f.state.scroll = position; };
      f.reader.finishPageTurnAnimation = () => {};
      f.reader._resetFollowDragVisual = () => {};
      if (fade) {
        f.reader.pageTurnEffect = () => 'fade';
        f.reader._audioRevealPageTurn = true;
      }
      f.state.scroll = 4000;
      const cue = { doc: 5200, size: 40 };
      assert.strictEqual(f.reader.scrollToRange(scrolledRange(f.state, cue)), true);
      assert.strictEqual(f.state.scroll, 5000);
      assert.strictEqual(f.frames.length, 1);
      assert.strictEqual(f.reader.curlPreview('forward'), 'ok');
      assert.strictEqual(f.state.scroll, 6000, label + ': the body shows the previewed page');
      const writes = f.calls.setPage.length;
      f.frames.shift()();
      assert.strictEqual(f.state.scroll, 6000,
        label + ': the reveal frame must not write the body back under the curl preview');
      assert.strictEqual(f.calls.setPage.length, writes, label + ': no setPagePosition during the preview');
      assert.deepStrictEqual(f.calls.setPageNow, [], label + ': no direct write during the preview');
      assert.strictEqual(f.reader._curl.base, 5000, label + ': the preview state is intact');
      if (scenario === 'commit') {
        assert.strictEqual(f.reader.paginate('forward'), 'scrolled');
        assert.strictEqual(f.state.scroll, 6000, label + ': the committed turn stays');
        assert.strictEqual(f.reader._curlLateAnchorPending, false, label + ': commit drops the pending re-land');
        while (f.frames.length) f.frames.shift()();
        assert.strictEqual(f.state.scroll, 6000, label + ': nothing pulls the committed turn back');
      } else {
        if (scenario === 'revert-moved') cue.doc = 6200; // a late image moved the cue meanwhile
        f.reader.curlRevert();
        assert.strictEqual(f.reader._curl, null);
        assert.strictEqual(f.state.scroll, scenario === 'revert-moved' ? 6000 : 5000,
          label + ': reverting the curl re-lands the still-registered reveal target');
        assert.strictEqual(f.reader._curlLateAnchorPending, false);
      }
    }
  }
}

async function main() {
  await settleSurvivesLateImage();
  await settleKeepsRelandingAfterReflow();
  await settleYieldsToNewOwner();
  revealFrameFollowsAnchor();
  audioFollowFadeFrame();
  revealFrameUnderCurlPreview();
  console.log('all assertions passed');
}

main().catch((error) => {
  console.error(error?.stack ?? error);
  process.exit(1);
});
