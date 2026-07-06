import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/global_lookup_controller.dart';

/// TODO-872 — 桌面悬浮歌词点词必须优先走 867 app 外全局查词覆盖窗。
///
/// 用户复诉「电脑上还是 app 内弹窗」：主窗最小化/被遮挡着听书时，点悬浮字幕上
/// 的词弹进主窗（in-app 弹窗 / 切词典 tab）等于看不见。本卷钉三件事：
///
///  1. [GlobalLookupController.lookupText]（程序化入口）的回落契约：覆盖窗接不
///     了（未 start / 空词）必须返回 false 且不抛，调用方据此回落 in-app 路由，
///     点词永不静默丢失。
///  2. 两条桌面路由（reader 在场 lyrics.part.dart / app 级 AppModel 默认
///     handler）都先经 [tryFloatingLyricGlobalLookup]，且各自的原回落路由
///     （切词典 tab / FloatingLyricLookupNotifier in-app 宿主）保留——移动端与
///     覆盖窗不可用时行为不变（Never break userspace）。
///  3. 分词单一真相源：适配器必须用 [floatingLyricSearchTerm]（与旧路由同一
///     把），防两处分词漂移。
///
/// 覆盖窗真实弹出（NOACTIVATE、光标锚定、Esc/点外关闭）依赖 native WebView2
/// 窗口，headless 测不了——真机验收见 TODO-872 看板项。
void main() {
  String read(String p) => File(p).readAsStringSync().replaceAll('\r\n', '\n');

  group('GlobalLookupController.lookupText fallback contract', () {
    test('controller 未 start 时返回 false 且不抛（调用方回落 in-app 路由）', () async {
      // 测试进程从不调 start()（需要真 native channel），_started=false 是
      // 本测试的稳定前提；无论测试跑在哪个平台都必须干净返回 false。
      expect(
        await GlobalLookupController.instance.lookupText('言葉'),
        isFalse,
        reason: '未 start 的控制器必须拒接并让调用方回落，而不是半开覆盖窗',
      );
    });

    test('空白词返回 false（no-op，不发起查词）', () async {
      expect(
        await GlobalLookupController.instance.lookupText('   '),
        isFalse,
      );
    });
  });

  group('controller wiring (source scan)', () {
    late String controller;
    setUpAll(() =>
        controller = read('lib/src/lookup/global_lookup_controller.dart'));

    test('公开 lookupText 程序化入口存在且带 _started 门', () {
      expect(
        controller.contains(
            "Future<bool> lookupText(String text, {String sentence = ''})"),
        isTrue,
        reason: '867 覆盖窗必须暴露程序化文本查词入口（TODO-872）',
      );
      final int at = controller.indexOf('Future<bool> lookupText(');
      final String fn =
          controller.substring(at, controller.indexOf('return true;', at));
      expect(fn.contains('_started'), isTrue,
          reason: 'lookupText 必须在控制器未 start 时拒接（返回 false）');
      expect(fn.contains('isSupported'), isTrue,
          reason: 'lookupText 必须门控平台支持（Windows-only）');
    });

    test('热键与 lookupText 共用同一条查词链（_lookupExternal，无复制粘贴）', () {
      expect(controller.contains('_lookupExternal('), isTrue,
          reason: '查词链必须抽成共享方法');
      // searchDictionary 在控制器里只允许出现在共享链 + 嵌套查词两处调用。
      final int calls = 'searchDictionary('.allMatches(controller).length;
      expect(calls, 2,
          reason: '根查词只能活在 _lookupExternal（另一处是 _lookupNested）；'
              '出现第三处说明热键/programmatic 链又分叉了');
    });
  });

  group('desktop floating-lyric routes are overlay-first (source scan)', () {
    test('reader 路由（lyrics.part.dart）：覆盖窗优先，切 tab 回落保留', () {
      final String src =
          read('lib/src/pages/implementations/reader_hibiki/lyrics.part.dart');
      final int fnAt = src.indexOf('Future<void> _lookupFromFloatingLyric(');
      expect(fnAt, greaterThan(-1));
      final String fn = src.substring(fnAt);
      final int overlayAt = fn.indexOf('tryFloatingLyricGlobalLookup(');
      final int tabAt = fn.indexOf('requestHomeDictionaryTab()');
      expect(overlayAt, greaterThan(-1),
          reason: 'reader 在场的悬浮歌词点词必须先试 app 外覆盖窗');
      expect(tabAt, greaterThan(overlayAt),
          reason: '原「切主窗词典 tab」路由必须保留为回落（覆盖窗不可用时）');
    });

    test('app 级路由（app_model.dart）：覆盖窗优先，in-app 宿主回落保留', () {
      final String src = read('lib/src/models/app_model.dart');
      final int at =
          src.indexOf('onFloatingLyricLookup: (String text, int index)');
      expect(at, greaterThan(-1));
      // handler 闭包体（到下一个顶层参数 controlStreams 为止）。
      final int end = src.indexOf('controlStreams:', at);
      expect(end, greaterThan(at));
      final String handler = src.substring(at, end);
      final int overlayAt = handler.indexOf('tryFloatingLyricGlobalLookup(');
      final int hostAt = handler
          .indexOf('FloatingLyricLookupNotifier.instance.requestLookup(');
      expect(overlayAt, greaterThan(-1),
          reason: '无 reader 的悬浮歌词点词必须先试 app 外覆盖窗');
      expect(hostAt, greaterThan(overlayAt),
          reason: '原 in-app 查词宿主必须保留为回落（覆盖窗不可用/移动端）');
    });

    test('适配器：分词单一真相源 + 平台门控 + 整行作句子上下文', () {
      final String src =
          read('lib/src/media/audiobook/floating_lyric_lookup_routing.dart');
      expect(src.contains('GlobalLookupController.isSupported'), isTrue,
          reason: '适配器必须先门控平台（非 Windows 直接回落，零开销）');
      expect(src.contains('floatingLyricSearchTerm('), isTrue,
          reason: '分词必须走与旧路由同一把 floatingLyricSearchTerm，防漂移');
      expect(src.contains('sentence: text.trim()'), isTrue,
          reason: '整行字幕必须作为句子横幅/制卡 sentence 字段传给覆盖窗');
    });
  });
}
