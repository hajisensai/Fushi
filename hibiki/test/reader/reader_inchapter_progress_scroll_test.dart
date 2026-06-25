import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show parseReaderStableProgressDetails, readerScrollProgressRefreshAllowed;

import '../pages/reader_hibiki_page_source_corpus.dart';

/// BUG-213：章内原生滚动进度不更新（用户：「章内滚动进度不会动，只有到下一章了
/// 进度才会更新一次」）。
///
/// 根因：章内进度 UI 字段只在 `_refreshProgress()` 里写，而原生滚动（连续模式 window
/// 滚动 / 分页模式触摸·trackpad·键盘箭头落 body 的原生滚动）此前没有任何刷新通道，要
/// 等 10s 轮询或翻章才更新一次。修复给两模式共享的 setup 脚本挂一条统一 scroll → Dart
/// 通道（`onReaderScroll`）；BUG-380 后改为 rAF 节流（边滑边回传）+ 尾沿补一发，
/// Dart 侧经纯函数门控走 `_refreshProgressFromScroll()` 的 coalesce 守卫调
/// `_refreshProgress()`，进度边滑边实时更新而不是只在滑停后跳一下。
///
/// reader_hibiki_page.dart 太重（WebView + DB + provider）不便整页 mount，门控逻辑
/// 抽成 [readerScrollProgressRefreshAllowed] 纯函数在此锁定真值表；JS 通道与 Dart
/// 接线由源码扫描守卫锁定，防回归。
void main() {
  group('readerScrollProgressRefreshAllowed（章内滚动刷新门控真值表）', () {
    test('全部就绪：正常章内滚动触发进度刷新', () {
      expect(
        readerScrollProgressRefreshAllowed(
          readerContentReady: true,
          restoreInFlight: false,
          lyricsMode: false,
          controllerAvailable: true,
        ),
        isTrue,
      );
    });

    test('恢复期（restoreInFlight）一律抑制——程序化恢复滚动不误触发', () {
      expect(
        readerScrollProgressRefreshAllowed(
          readerContentReady: true,
          restoreInFlight: true,
          lyricsMode: false,
          controllerAvailable: true,
        ),
        isFalse,
        reason: '章节恢复/重载期 WebView 正被程序化滚动到锚点，不应当章内滚动刷新进度',
      );
    });

    test('内容未就绪（!readerContentReady）抑制', () {
      expect(
        readerScrollProgressRefreshAllowed(
          readerContentReady: false,
          restoreInFlight: false,
          lyricsMode: false,
          controllerAvailable: true,
        ),
        isFalse,
        reason: '内容未就绪时 hoshiProgressDetails 可能算不出总数',
      );
    });

    test('歌词模式（lyricsMode）抑制——非正文阅读无章内进度语义', () {
      expect(
        readerScrollProgressRefreshAllowed(
          readerContentReady: true,
          restoreInFlight: false,
          lyricsMode: true,
          controllerAvailable: true,
        ),
        isFalse,
      );
    });

    test('控制器已释放（!controllerAvailable）抑制——dispose 竞态', () {
      expect(
        readerScrollProgressRefreshAllowed(
          readerContentReady: true,
          restoreInFlight: false,
          lyricsMode: false,
          controllerAvailable: false,
        ),
        isFalse,
      );
    });

    test('多守卫同时不满足时仍抑制', () {
      expect(
        readerScrollProgressRefreshAllowed(
          readerContentReady: false,
          restoreInFlight: true,
          lyricsMode: true,
          controllerAvailable: false,
        ),
        isFalse,
      );
    });
  });

  group('parseReaderStableProgressDetails（stable 进度结果解析）', () {
    test('解析稳定进度和精确 charOffset', () {
      final snapshot = parseReaderStableProgressDetails('"250,1000,345"');

      expect(snapshot, isNotNull);
      expect(snapshot!.progress, 0.25);
      expect(snapshot.charOffset, 345);
    });

    test('稳定章首 0 是合法用户位置，不被一刀切禁掉', () {
      final snapshot = parseReaderStableProgressDetails('0,1000,0');

      expect(snapshot, isNotNull);
      expect(snapshot!.progress, 0.0);
      expect(snapshot.charOffset, 0);
    });

    test('未 settle / 空结果不生成可保存快照', () {
      expect(parseReaderStableProgressDetails(null), isNull);
      expect(parseReaderStableProgressDetails(''), isNull);
      expect(parseReaderStableProgressDetails('0,0,0'), isNull);
      expect(parseReaderStableProgressDetails('not-progress'), isNull);
    });
  });

  group('源码守卫：章内滚动进度回传通道存在（防回归）', () {
    late String src;

    setUpAll(() {
      src = readReaderPageSource();
    });

    test('setup 脚本注册 window+document scroll 监听并回传 onReaderScroll', () {
      // 通道必须挂在两模式共享的 setup 脚本里（_buildReaderSetupScript），且对 window
      // 与 document 都监听（覆盖连续模式 window 滚动 + 分页模式 body 内部滚动）。
      // TODO-718：第二参传 isUserDriven（最近真实用户输入驱动），故匹配前缀不含闭括号。
      expect(src.contains("callHandler('onReaderScroll'"), isTrue,
          reason: 'scroll reporter 必须经 callHandler 把进度回传 Dart');
      expect(
        src.contains("window.addEventListener('scroll', _onReaderScrollEvent"),
        isTrue,
        reason: '必须监听 window scroll（连续模式 window 原生滚动）',
      );
      expect(
        src.contains(
            "document.addEventListener('scroll', _onReaderScrollEvent"),
        isTrue,
        reason: '必须监听 document scroll capture（分页模式 body 内部滚动）',
      );
    });

    test('BUG-380：回传通道是 rAF 节流（边滑边回传）+ 尾沿补一发，且抑制重锚瞬态', () {
      expect(src.contains('requestAnimationFrame'), isTrue);
      // rAF 节流：滑动中每个动画帧最多回传一次（合并同帧多次 scroll 事件），进度边滑
      // 边实时跟随。锁住「rAF 在飞时不再排新 rAF」这个节流不变量——若回退成纯尾沿
      // 去抖（每次都 clearTimeout 推后定时器、滑动期间不回传），下面的断言会转红。
      final int idx = src.indexOf('function _onReaderScrollEvent()');
      expect(idx, greaterThan(0), reason: '_onReaderScrollEvent 必须存在');
      final String handler = src.substring(idx, idx + 700);
      expect(handler.contains('if (!_progressScrollRaf) {'), isTrue,
          reason: 'rAF 节流：在飞期不再排新 rAF，滑动中按帧回传（不是纯尾沿去抖）');
      expect(handler.contains('_reportReaderScroll();'), isTrue,
          reason: 'rAF 回调里必须直接回传，让进度边滑边更新');
      // 尾沿补一发：滑停后短延时再回传一次最终位置（rAF 节流不保证捕捉到静止帧）。
      expect(handler.contains('_progressScrollTimer'), isTrue,
          reason: '尾沿补发必须有 timer 变量');
      expect(handler.contains('}, 120);'), isTrue,
          reason: '尾沿补发延时（120ms）回传最终静止位置');
      expect(handler.contains('clearTimeout(_progressScrollTimer)'), isTrue,
          reason: '新滚动须重置尾沿补发 timer');
      // 防回归：滑动期间不得只靠尾沿（旧 bug 是 rAF 内再套 setTimeout 200ms 纯去抖）。
      expect(handler.contains('}, 200);'), isFalse,
          reason: 'BUG-380：不得回退成「rAF 内套 200ms 纯尾沿去抖」(滑动中不回传)');
      expect(src.contains('r._reanchorPending === true) return'), isTrue,
          reason: '程序化重锚期（_reanchorPending）必须跳过回传，避免恢复/重排瞬态误触发');
    });

    test('Dart 注册 onReaderScroll handler 并走纯函数门控后 coalesce 刷新', () {
      expect(src.contains("handlerName: 'onReaderScroll'"), isTrue,
          reason: '必须注册 onReaderScroll JS handler');
      // TODO-718：callback 现按 isUserDriven 传 _handleReaderScroll(bool)，签名加参。
      expect(src.contains('_handleReaderScroll('), isTrue);
      final int idx = src.indexOf('void _handleReaderScroll()');
      expect(idx, greaterThan(0), reason: '_handleReaderScroll 必须存在');
      // 窗口放宽到 2700：TODO-151/164(BUG-225) 诊断块 + TODO-736 B-3 settle 块 + TODO-718
      // 顶部解武装块，函数体持续加长（旧窗口会切断在分发前漏掉末尾误转红）。
      final String body = src.substring(idx, idx + 2700);
      expect(body.contains('readerScrollProgressRefreshAllowed('), isTrue,
          reason: '门控必须走纯函数 readerScrollProgressRefreshAllowed');
      // BUG-380：门控通过后走 coalesce 守卫（高频滚动不堆积 evaluateJavascript），
      // 而不是裸调 _refreshProgress()。
      expect(body.contains('_refreshProgressFromScroll();'), isTrue,
          reason: '滚动路径门控通过后必须走 _refreshProgressFromScroll coalesce 守卫');
    });

    test('BUG-380/卡死：_refreshProgressFromScroll 是 coalesce 守卫 + 50ms 节流', () {
      final int idx = src.indexOf('void _refreshProgressFromScroll()');
      expect(idx, greaterThan(0), reason: '_refreshProgressFromScroll 必须存在');
      // 窗口放宽到 1400：卡死修复在此函数内插入了时间节流块，函数体加长。
      final String body = src.substring(idx, idx + 1400);
      // 在飞时再来的滚动只置 pending，不并发跑第二次 evaluateJavascript。
      expect(body.contains('if (_scrollProgressInFlight) {'), isTrue,
          reason: '在飞期必须只置 pending，避免 hoshiProgressDetails 调用堆积');
      expect(body.contains('_scrollProgressPending = true;'), isTrue);
      // 飞完后若有 pending 补跑一次，保证最终静止位置一定被刷到。
      expect(body.contains('whenComplete('), isTrue,
          reason: '必须在刷新完成后清在飞标记并按 pending 补跑（coalesce）');
      expect(body.contains('_refreshProgress()'), isTrue,
          reason: 'coalesce 守卫最终仍调既有 _refreshProgress 重算进度');
      // 卡死修复：时间节流（对齐 hoshi 安卓 CONTINUOUS_PROGRESS_THROTTLE_MS=50ms）。原本只有
      // coalesce、一完成就背靠背补跑 calculateProgress 全文重算 → 鼠标拖动/连续滚动把 WebView
      // JS 线程占满卡死。节流后滑动中最多每 50ms 一次 + 尾沿补发最终位置。
      expect(body.contains('throttleMs'), isTrue,
          reason: '滚动进度重算必须时间节流，否则背靠背全文重算 → JS 卡死（对齐 hoshi 安卓 50ms）');
      expect(body.contains('_scrollProgressThrottleTimer'), isTrue,
          reason: '节流尾沿 timer 必须存在（保证停止后最终位置被刷到）');
    });

    test('刷新进度必须走 stableProgressInvocation，避免恢复/重锚瞬态 0 落库', () {
      final int idx = src.indexOf('Future<void> _refreshProgress() async');
      expect(idx, greaterThan(0), reason: '_refreshProgress 必须存在');
      final String body = src.substring(idx, idx + 3200);
      expect(
        body.contains('ReaderPaginationScripts.stableProgressInvocation()'),
        isTrue,
        reason: '恢复完成和滚动回传复用 _refreshProgress；这里必须走 stable '
            'gate，_reanchorPending 时返回 null，不能直接读瞬态 progress=0',
      );
      expect(
        body.contains("source: 'window.hoshiProgressDetails()'"),
        isFalse,
        reason: '裸 hoshiProgressDetails 会绕过 _reanchorPending/settled gate',
      );
    });
  });
}
