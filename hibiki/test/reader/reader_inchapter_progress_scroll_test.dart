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
/// 通道（`onReaderScroll`），rAF + 200ms debounce 后回传，Dart 侧经纯函数门控调
/// `_refreshProgress()`。
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
      expect(src.contains("callHandler('onReaderScroll')"), isTrue,
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

    test('回传通道带 rAF + debounce 去抖，且抑制重锚瞬态', () {
      expect(src.contains('requestAnimationFrame'), isTrue);
      // debounce：用 200ms setTimeout 抑制高频滚动抖动（不绑死精确空白，避免 format
      // 重排折行误伤；只锁住「有 timer 变量 + 200ms + clearTimeout」这三个不变量）。
      expect(src.contains('_progressScrollTimer'), isTrue,
          reason: 'scroll 回传必须有 debounce timer 变量');
      expect(src.contains('}, 200);'), isTrue,
          reason: 'scroll 回传必须 200ms debounce，避免每帧 setState');
      expect(src.contains('clearTimeout(_progressScrollTimer)'), isTrue,
          reason: '新滚动须取消上一次未触发的 debounce timer');
      expect(src.contains('r._reanchorPending === true) return'), isTrue,
          reason: '程序化重锚期（_reanchorPending）必须跳过回传，避免恢复/重排瞬态误触发');
    });

    test('Dart 注册 onReaderScroll handler 并走纯函数门控后 _refreshProgress', () {
      expect(src.contains("handlerName: 'onReaderScroll'"), isTrue,
          reason: '必须注册 onReaderScroll JS handler');
      expect(src.contains('=> _handleReaderScroll()'), isTrue);
      final int idx = src.indexOf('void _handleReaderScroll()');
      expect(idx, greaterThan(0), reason: '_handleReaderScroll 必须存在');
      // 窗口放宽到 1100：TODO-151/164(BUG-225) 在该函数内插入了诊断日志块，函数体加长，
      // 600 字符窗口会切断在诊断块中间漏掉末尾 _refreshProgress();（旧窗口会误转红）。
      final String body = src.substring(idx, idx + 1100);
      expect(body.contains('readerScrollProgressRefreshAllowed('), isTrue,
          reason: '门控必须走纯函数 readerScrollProgressRefreshAllowed');
      expect(body.contains('_refreshProgress();'), isTrue,
          reason: '门控通过后必须调 _refreshProgress 刷新章内进度');
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
