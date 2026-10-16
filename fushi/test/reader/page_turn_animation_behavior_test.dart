import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';

/// 小说阅读器翻页动画（reader_page_turn_script.dart）的**生产 JS 行为测试**。
///
/// 把生产分页 shell 里的 `window.fushiReader` 对象字面量原样抠出来，在 node 里配一套
/// 最小假 DOM（computed style / scroll 容器 / `document.startViewTransition`）真跑：
/// 相邻翻页走 View Transition、无 API / 墨水屏 / 效果为无时直接赋值、瞬时定位与搜索
/// 揭示不走动画、有声书跟读相邻页固定淡入、连按 skipTransition、跟手提交 / 回弹阈值、
/// 竖排前进方向标记。
void main() {
  test('JS 侧不另立兜底时长：没有 Dart 下发的时长就不播动画', () {
    final String source = ReaderPaginationScripts.paginatedShellSource();
    expect(source, contains('return ms > 0 ? ms : 0;'));
    expect(source, contains('if (!(this.pageTurnDurationMs() > 0)) return'));
    expect(source, contains('var(--fushi-pt-duration,0ms)'));
  });

  test('只有分页 shell 带翻页动画片段', () {
    expect(
      ReaderPaginationScripts.paginatedShellSource(),
      contains('turnPageAnimated: function'),
    );
    expect(
      ReaderPaginationScripts.continuousShellSource(),
      isNot(contains('turnPageAnimated: function')),
    );
  });

  test('stableProgressInvocation 在翻页在途 / 跟手中返 null', () {
    expect(
      ReaderPaginationScripts.stableProgressInvocation(),
      contains('pageTurnBusy'),
    );
  });

  test('production paginated shell page-turn behavior (node)', () {
    final String payload = jsonEncode(<String, String>{
      'paged': ReaderPaginationScripts.paginatedShellSource(),
    });
    final Directory temp = Directory.systemTemp.createTempSync(
      'fushi-page-turn-js-',
    );
    final File payloadFile = File('${temp.path}/payload.json')
      ..writeAsStringSync(payload);
    late final ProcessResult result;
    try {
      result = Process.runSync(
        'node',
        <String>['-e', _runner, payloadFile.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } finally {
      temp.deleteSync(recursive: true);
    }
    expect(
      result.exitCode,
      0,
      reason:
          'page turn runner failed:\n'
          'stdout=${result.stdout}\nstderr=${result.stderr}',
    );
    expect(result.stdout.toString().trim(), 'OK');
  });
}

const String _runner = r'''
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}
function objectLiteral(source) {
  const marker = 'window.fushiReader = {';
  const start = source.indexOf(marker);
  if (start < 0) throw new Error('fushiReader object missing');
  const brace = source.indexOf('{', start);
  const end = source.indexOf('\n};', brace);
  if (end < 0) throw new Error('fushiReader object terminator missing');
  return source.slice(brace, end + 2);
}

function makeEnv(opts) {
  opts = opts || {};
  const attrs = {};
  const rootProps = {};
  const appended = {};
  const body = {
    scrollLeft: 0, scrollTop: 0,
    scrollWidth: 4000, scrollHeight: 4000, clientWidth: 400, clientHeight: 400,
    style: {},
    getBoundingClientRect() { return { width: 400, height: 400 }; }
  };
  const root = {
    scrollTop: 0, scrollLeft: 0,
    setAttribute(k, v) { attrs[k] = String(v); },
    removeAttribute(k) { delete attrs[k]; },
    getAttribute(k) { return k in attrs ? attrs[k] : null; },
    appendChild(el) { appended[el.id] = el; return el; },
    style: {
      setProperty(k, v) { rootProps[k] = v; },
      removeProperty(k) { delete rootProps[k]; },
      getPropertyValue(k) { return rootProps[k] || ''; }
    }
  };
  const transitions = [];
  const document = {
    documentElement: root,
    body,
    head: { appendChild(el) { appended[el.id] = el; return el; } },
    getElementById(id) { return appended[id] || null; },
    createElement() { return { id: '', textContent: '' }; }
  };
  if (opts.viewTransitions !== false) {
    document.startViewTransition = function(update) {
      const t = {
        update, skipped: 0, ran: false,
        skipTransition() { this.skipped++; },
        ready: Promise.resolve(),
        updateCallbackDone: Promise.resolve(),
        finished: new Promise(() => {}),
        run() { if (!this.ran) { this.ran = true; update(); } }
      };
      transitions.push(t);
      return t;
    };
  }
  const style = {
    writingMode: opts.writingMode || 'horizontal-tb',
    direction: 'ltr',
    columnWidth: '380px', columnGap: '20px', columnCount: '1',
    paddingTop: '10px', paddingBottom: '10px', paddingLeft: '10px', paddingRight: '10px',
    fontSize: '16px', backgroundColor: 'rgb(250, 240, 220)',
    eink: opts.eink ? '1' : ''
  };
  function getComputedStyle(el) {
    return Object.assign({}, style, {
      getPropertyValue(k) { return k === '--fushi-reader-eink-mode' ? style.eink : ''; }
    });
  }
  const handlers = [];
  const frames = [];
  let fakeNow = 0;
  const window = {
    scrollX: 0, scrollY: 0,
    innerWidth: 400, innerHeight: 400,
    scrollTo() {},
    getComputedStyle,
    flutter_inappwebview: { callHandler(...args) { handlers.push(args); } },
    performance: { now: () => fakeNow }
  };
  const C = Object.assign({
    perfTraceEnabled: false,
    pageTurnAnimation: 'fade',
    pageTurnDurationMs: 240,
    pageTurnFollowDrag: true,
    swipeLeftIsForward: true
  }, opts.C || {});
  function requestAnimationFrame(fn) { frames.push(fn); return frames.length; }
  const factory = new Function(
    'window', 'document', 'C', 'getComputedStyle', 'requestAnimationFrame', 'performance',
    'CSS', 'Highlight',
    'window.fushiReader = ' + objectLiteral(data.paged) + '; return window.fushiReader;'
  );
  const reader = factory(window, document, C, getComputedStyle, requestAnimationFrame,
    window.performance, {}, function() {});
  reader._clearSelectionOnViewportChange = function() {};
  reader.paginationMetrics = { minScroll: 0, maxScroll: 3600, totalChars: 100, progressStops: [] };
  function flushFrames(limit) {
    let n = 0;
    while (frames.length && n++ < (limit || 200)) {
      const fn = frames.shift();
      fakeNow += 16;
      fn();
    }
  }
  return { reader, document, body, attrs, rootProps, transitions, handlers, C, style, frames, flushFrames };
}

// ① 相邻翻页走 View Transition：旧位置在回调前不动，回调里写死新页并广播滚动。
{
  const env = makeEnv();
  const r = env.reader;
  assert(r.paginate('forward') === 'scrolled', 'forward should scroll');
  assert(env.transitions.length === 1, 'adjacent page turn must call startViewTransition');
  assert(env.body.scrollLeft === 0, 'position must not change before the old snapshot');
  assert(env.attrs['data-fushi-pt'] === 'fade', 'effect attribute missing: ' + JSON.stringify(env.attrs));
  assert(env.attrs['data-fushi-pt-move'] === 'left', 'LTR forward must move content left');
  assert(r.pageTurnBusy() === true && r.pendingPageTurnTarget() === 400, 'pending target');
  env.transitions[0].run();
  assert(env.body.scrollLeft === 400, 'update callback must land on the next page');
  assert(r.pageTurnBusy() === false, 'busy cleared after the update callback');
  assert(env.handlers.some(h => h[0] === 'onReaderScroll'), 'progress must be broadcast at animation start');
  assert(env.rootProps['--fushi-pt-duration'] === '240ms', 'duration var');
  assert(env.document.getElementById('fushi-page-turn-style'), 'page turn stylesheet injected');
  const css = env.document.getElementById('fushi-page-turn-style').textContent;
  // 快照对象是根（视口）而不是滚动容器 body：WebKit 对竖排 scrollTop 滚过的 body
  // 截出的新页快照是空白（Mac WKWebView 实测），根快照与滚动轴无关。
  assert(css.indexOf('view-transition-name') < 0, 'no element-level view-transition-name');
  assert(css.indexOf('::view-transition-old(root)') >= 0, 'animates the root old snapshot');
  assert(css.indexOf('::view-transition-new(root)') >= 0, 'animates the root new snapshot');
  assert(css.indexOf('display:none') < 0, 'root snapshots are not hidden');
}

// ② 回调还没跑就有人读几何：同步落位并 skip（读方绝不看到旧页）。
{
  const env = makeEnv();
  const r = env.reader;
  r.paginate('forward');
  const ctx = r.getScrollContext();
  assert(env.body.scrollLeft === 400, 'geometry read must flush the pending page turn');
  assert(env.transitions[0].skipped === 1, 'flushed transition must be skipped');
  assert(r.getPagePosition(ctx) === 400, 'readers see the new page');
  env.transitions[0].run();
  assert(env.body.scrollLeft === 400, 'late update callback is a no-op');
}

// ③ 连按：在途 / 播放中的上一个动画 skipTransition 后立即起下一次。
{
  const env = makeEnv();
  const r = env.reader;
  r.paginate('forward');
  r.paginate('forward');
  assert(env.transitions.length === 2, 'second turn starts its own transition');
  assert(env.transitions[0].skipped >= 1, 'first transition skipped on rapid turn');
  env.transitions[1].run();
  assert(env.body.scrollLeft === 800, 'two rapid turns land two pages later, got ' + env.body.scrollLeft);
  r.paginate('backward');
  assert(env.transitions.length === 3, 'third transition');
  r.paginate('backward');
  assert(env.transitions[2].skipped >= 1, 'running animation skipped by the next turn');
  env.transitions[3].run();
  assert(env.body.scrollLeft === 0, 'back to the first page, got ' + env.body.scrollLeft);
  assert(env.attrs['data-fushi-pt-move'] === 'right', 'LTR backward moves content right');
}

// ④ 无 startViewTransition / 墨水屏 / 效果为无：与原来一样瞬时赋值。
for (const variant of [{ viewTransitions: false }, { eink: true }, { C: { pageTurnAnimation: 'none' } }]) {
  const env = makeEnv(variant);
  const r = env.reader;
  assert(r.paginate('forward') === 'scrolled', 'scrolled ' + JSON.stringify(variant));
  assert(env.body.scrollLeft === 400, 'instant assignment ' + JSON.stringify(variant));
  assert(env.transitions.length === 0, 'no view transition ' + JSON.stringify(variant));
  assert(!('data-fushi-pt' in env.attrs), 'no animation attributes ' + JSON.stringify(variant));
}

// ⑤ 恢复 / 跳转 / 重锚（setPagePosition）与搜索揭示不走动画，并结束正在播的动画。
{
  const env = makeEnv({ C: { pageTurnAnimation: 'slide' } });
  const r = env.reader;
  r.paginate('forward');
  env.transitions[0].run();
  r.setPagePosition(r.getScrollContext(), 2000);
  assert(env.body.scrollLeft === 2000, 'jump is instant');
  assert(env.transitions.length === 1, 'jump must not start a transition');
  assert(env.transitions[0].skipped === 1, 'jump ends the running animation');
  // 搜索命中（非跟读）落相邻页：瞬时。
  r.getRect = () => ({ left: 410, top: 0, width: 10, height: 10 });
  assert(r._alignRangeToPage({}) === true, 'search reveal turns page');
  assert(env.transitions.length === 1, 'search reveal must not animate');
  assert(env.body.scrollLeft === 2400, 'search reveal instant, got ' + env.body.scrollLeft);
}

// ⑥ 有声书跟读：相邻页固定淡入（即使所选是平移）；跨多页瞬时。
{
  const env = makeEnv({ C: { pageTurnAnimation: 'slide' } });
  const r = env.reader;
  r.getRect = () => ({ left: 410, top: 0, width: 10, height: 10 });
  r._audioRevealPageTurn = true;
  assert(r._alignRangeToPage({}) === true, 'audio reveal turns page');
  assert(env.transitions.length === 1, 'adjacent audio reveal animates');
  assert(env.attrs['data-fushi-pt'] === 'fade', 'audio follow always fades');
  env.transitions[0].run();
  assert(env.body.scrollLeft === 400, 'audio reveal lands next page');
  r.getRect = () => ({ left: 1210, top: 0, width: 10, height: 10 });
  r._alignRangeToPage({});
  assert(env.transitions.length === 1, 'multi-page audio reveal is instant');
  assert(env.body.scrollLeft === 1600, 'multi-page audio reveal lands, got ' + env.body.scrollLeft);
  r._audioRevealPageTurn = false;
}

// ⑦ 方向按阅读方向：竖排 vertical-rl 前进 = 内容向右移、新页从左进入。
{
  const env = makeEnv({ writingMode: 'vertical-rl', C: { pageTurnAnimation: 'slide' } });
  const r = env.reader;
  assert(r.pageTurnMoveDirection(true) === 'right', 'vertical-rl forward moves right');
  assert(r.pageTurnMoveDirection(false) === 'left', 'vertical-rl backward moves left');
  r.paginate('forward');
  assert(env.attrs['data-fushi-pt-move'] === 'right', 'vertical forward attribute');
  assert(env.rootProps['--fushi-pt-new-from'] === '-400px', 'new page enters from the left: ' + env.rootProps['--fushi-pt-new-from']);
  assert(env.rootProps['--fushi-pt-old-to'] === '400px', 'old page leaves to the right');
  env.transitions[0].run();
  assert(env.body.scrollTop === 400, 'vertical pagination still scrolls the column axis');
  const ltr = makeEnv().reader;
  assert(ltr.pageTurnMoveDirection(true) === 'left', 'horizontal forward moves left');
}

// ⑧ 覆盖：前进旧页在上移走、新页静止；后退新页在上盖回。
{
  const r = makeEnv().reader;
  const fwd = r.pageTurnPlan('cover', -1, 400, 0, 0, true, false);
  assert(fwd.old === 'move' && fwd.next === 'still' && fwd.top === 'old' && fwd.oldTo === -400, 'cover forward plan');
  const back = r.pageTurnPlan('cover', 1, 400, 0, 0, false, false);
  assert(back.old === 'still' && back.next === 'move' && back.top === 'new' && back.newFrom === -400, 'cover backward plan');
  const fade = r.pageTurnPlan('fade', 1, 400, 0, 0, true, false);
  assert(fade.old === 'still' && fade.next === 'fade', 'fade plan');
}

// ⑨ 跟手（横排滚正文）：不到 1/4 宽且慢 = 回弹；超过 = 提交并从当前偏移接力、时长按比例缩短。
{
  const env = makeEnv({ C: { pageTurnAnimation: 'slide' } });
  const r = env.reader;
  assert(r.followDragEnabled() === true, 'follow drag enabled for slide');
  r.followDragUpdate(-50);
  assert(env.body.scrollLeft === 50, 'horizontal follow scrolls with the finger');
  assert(r.pageTurnBusy() === true, 'busy while dragging');
  assert(r.followDragEnd(-50, -0.1) === null, 'short slow drag springs back');
  env.flushFrames();
  assert(env.body.scrollLeft === 0, 'spring back to base, got ' + env.body.scrollLeft);
  assert(r.pageTurnBusy() === false, 'idle after spring back');
  r.followDragUpdate(-30);
  assert(r.followDragEnd(-30, -0.8) === 'left', 'fling commits');
  r._reboundFollowDrag();
  env.flushFrames();
  r.followDragUpdate(-150);
  assert(r.followDragEnd(-150, 0) === 'left', 'past a quarter commits');
  assert(env.body.scrollLeft === 150, 'committed drag keeps its offset until the turn arrives');
  r.paginate('forward');
  const t = env.transitions[env.transitions.length - 1];
  assert(env.rootProps['--fushi-pt-duration'] === '150ms', 'remaining duration scaled: ' + env.rootProps['--fushi-pt-duration']);
  assert(env.rootProps['--fushi-pt-old-to'] === '-250px', 'old continues from the drag offset');
  assert(env.rootProps['--fushi-pt-new-from'] === '250px', 'new is adjacent to the old snapshot');
  t.run();
  assert(env.body.scrollLeft === 400, 'drag commit lands next page, got ' + env.body.scrollLeft);
}

// ⑩ 跟手（竖排只平移当前页）+ 章首阻尼；淡入 / 关开关时不跟手。
{
  const env = makeEnv({ writingMode: 'vertical-rl', C: { pageTurnAnimation: 'cover', swipeLeftIsForward: false } });
  const r = env.reader;
  r.followDragUpdate(80);
  assert(env.body.style.transform === 'translateX(80px)', 'vertical follow shifts the current page: ' + env.body.style.transform);
  assert(env.body.scrollTop === 0, 'vertical follow does not scroll');
  r.followDragCancel();
  env.flushFrames();
  assert(env.body.style.transform === '', 'spring back clears the shift');
  // 章首往回拖：阻尼 0.3×；提交仍回传方向让 Dart 跨章。
  r.followDragUpdate(-200);
  assert(env.body.style.transform === 'translateX(-60px)', 'chapter start damping: ' + env.body.style.transform);
  assert(r.followDragEnd(-200, 0) === 'left', 'limit drag still reports the swipe for chapter crossing');
  env.flushFrames();
  assert(env.body.style.transform === '', 'limit drag springs back');
  assert(makeEnv({ C: { pageTurnAnimation: 'fade' } }).reader.followDragEnabled() === false, 'fade has no follow');
  assert(makeEnv({ C: { pageTurnAnimation: 'slide', pageTurnFollowDrag: false } }).reader.followDragEnabled() === false, 'switch off');
  assert(makeEnv({ viewTransitions: false, C: { pageTurnAnimation: 'slide' } }).reader.followDragEnabled() === false, 'no API no follow');
}

process.stdout.write('OK');
process.exit(0);
''';
