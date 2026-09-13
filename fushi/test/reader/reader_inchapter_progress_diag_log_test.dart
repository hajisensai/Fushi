import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// TODO-151 / TODO-164 / BUG-225：章内滚动进度链路三点诊断日志。
///
/// 背景：BUG-213 已把章内原生滚动接进 `onReaderScroll → _handleReaderScroll →
/// _refreshProgress` 刷新章内进度。用户仍报「还是没修好」，可能是用分页模式（章内
/// 自由滚动被 snapScroll 列对齐回去、无净滚动，回传链是 no-op）、用旧版，或连续模式
/// 某一链断。为便于下次真机 run 定位是哪一链断，在链路三点加诊断日志：
///   ① JS `_reportReaderScroll`：console.log 输出 reanchorPending / hasBridge；
///   ② Dart `_handleReaderScroll`：记四个门控条件各自真值 + 是否实际调 _refreshProgress；
///   ③ Dart `_refreshProgress`：记重算后 _progressCurrentChars / _progressTotalChars。
///
/// 三点诊断默认 off：Dart 侧 `DebugLogService.instance.enabled` 门控（ship off，
/// 用户在调试日志页打开后才进环形缓冲）；JS 侧由 Dart 把同一布尔插值进脚本门控
/// console.log（onConsoleMessage → debugPrint → DebugLogService）。本守卫只锁「三点
/// 接入存在且受 enabled 门控」，撤掉任一点 → 对应用例转红。不验运行时（needsDevice）。
void main() {
  group('TODO-151/164 章内进度三点诊断日志接入（防回归）', () {
    late String src;

    setUpAll(() {
      src = readReaderPageSource();
    });

    test('文件 import 了 DebugLogService', () {
      expect(
        src.contains(
          "import 'package:fushi/src/utils/misc/debug_log_service.dart'",
        ),
        isTrue,
        reason: '三点诊断都经 DebugLogService.instance.enabled 门控，须 import',
      );
    });

    test('① JS _reportReaderScroll 受门控输出 reanchorPending / hasBridge', () {
      final int idx = src.indexOf('function _reportReaderScroll()');
      expect(idx, greaterThan(0), reason: 'JS _reportReaderScroll 必须存在');
      // TODO-718 在体内加了 userDriven 计算 + 注释，窗口放宽到 1300。
      final String body = src.substring(idx, idx + 1300);
      // JS 门控用 Dart 插值的 DebugLogService.instance.enabled 渲染成字面 true/false。
      expect(
        body.contains('if (C.debugLogging)'),
        isTrue,
        reason: 'JS 诊断 console.log 须由 DebugLogService.enabled 门控（默认 off）',
      );
      expect(
        body.contains('console.log'),
        isTrue,
        reason: 'JS 端诊断走 console.log（经 onConsoleMessage 转 debugPrint）',
      );
      expect(
        body.contains('reanchorPending='),
        isTrue,
        reason: '须输出 reanchorPending（true 时早返回不回传）',
      );
      expect(
        body.contains('hasBridge='),
        isTrue,
        reason: '须输出 hasBridge（false 时 callHandler 不可用）',
      );
      // 不破坏 151 现有早返回逻辑。
      expect(
        body.contains('r._reanchorPending === true) return'),
        isTrue,
        reason: '诊断不得移除原 _reanchorPending 早返回',
      );
    });

    test('② Dart _handleReaderScroll 受门控记四门控真值 + 是否刷新', () {
      // 窗口由花括号配对给出（methodBody），不再是定长字符窗口：2026-09-06 tall 格式
      // 迁移把 `debugPrint('[ReaderDiag] …'` 拆成两行、函数体也随 B-3 / ReadUnitLedger
      // 改动伸缩，定长窗口 + 单行字面量两条假设同时塌掉（本组曾因此在 develop 上
      // 静默转红）。字面量只钉诊断串本身，与 formatter 断行无关。
      final String body = methodBody(src, 'void _handleReaderScroll()');
      expect(
        body.contains('if (DebugLogService.instance.enabled)'),
        isTrue,
        reason: 'Dart 诊断须由 DebugLogService.instance.enabled 门控（默认 off）',
      );
      expect(body.contains('debugPrint('), isTrue);
      expect(body.contains("'[ReaderDiag] _handleReaderScroll"), isTrue);
      // 四个门控条件各自真值都要落进诊断。
      expect(body.contains(r'readerContentReady=$_readerContentReady'), isTrue);
      expect(body.contains(r'restoreInFlight=$_restoreInFlight'), isTrue);
      expect(body.contains(r'lyricsMode=$_lyricsMode'), isTrue);
      expect(body.contains('controllerAvailable='), isTrue);
      // 是否实际调 _refreshProgress。
      expect(body.contains(r'allowed=$allowed'), isTrue);
      expect(body.contains('refresh='), isTrue);
    });

    test('③ Dart _refreshProgress 受门控记 progressCurrentChars / Total', () {
      // 同 ②：花括号配对窗口 + 只钉诊断串本身（原定长 6000 窗口在函数体伸缩后
      // 尾部诊断块漂出窗外，转红与实现无关）。
      final String body = methodBody(
        src,
        'Future<void> _refreshProgress() async',
      );
      expect(
        body.contains('if (DebugLogService.instance.enabled)'),
        isTrue,
        reason: 'Dart 诊断须由 DebugLogService.instance.enabled 门控（默认 off）',
      );
      expect(body.contains('debugPrint('), isTrue);
      expect(body.contains("'[ReaderDiag] _refreshProgress"), isTrue);
      expect(
        body.contains(r'progressCurrentChars=$_progressCurrentChars'),
        isTrue,
        reason: '须记重算后 _progressCurrentChars',
      );
      expect(
        body.contains(r'progressTotalChars=$_progressTotalChars'),
        isTrue,
        reason: '须记重算后 _progressTotalChars',
      );
    });
  });
}
