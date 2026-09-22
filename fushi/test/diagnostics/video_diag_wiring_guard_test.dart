import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 视频 / 查词诊断日志的接线守卫（2026-09-22）。
///
/// 这套日志的价值全在「每个埋点都还在」：任何一处被后续重构顺手删掉，导出的流水
/// 就会缺一段，而**缺失本身是静默的**——日志照样生成、照样能导出，只是永远答不出
/// 那一段为什么慢。这些接线点又都在真播放器 / 真 WebView 背后，widget 层探不到，
/// 只能靠源码守卫咬住。
///
/// 注释先掩码再匹配（等长掩码，下标与原文一致），避免注释里的同名字面量把断言
/// 变成恒真。
void main() {
  String code(String path) => maskComments(File(path).readAsStringSync());

  group('libmpv 侧（video_player_controller.dart）', () {
    late String src;
    setUpAll(
      () => src = code('lib/src/media/video/video_player_controller.dart'),
    );

    test('诊断开启时给 libmpv 下发它自己的 log-file + verbose msg-level', () {
      // 「跟 mpv 一样」的落地点：产出的是 libmpv 自己写的日志，不是仿格式的自研
      // 日志。少了这一条，hwdec 协商 / VO 交换链 / 解码器选择全部不可见。
      expect(src, contains('VideoDiagLog.instance.mpvLogFilePath'));
      expect(src, contains("'log-file': mpvLogFile"));
      expect(src, contains("'msg-level': 'all=v'"));
    });

    test('mpv 日志流有独立于 Lua 归因的诊断订阅', () {
      expect(
        src,
        contains(
          '_diagLogSub = player.stream.log.listen(_onMpvLogForDiagnostics);',
        ),
        reason: '统一时间轴需要 mpv 行才对得上帧耗时与查词阶段',
      );
      // Lua 那条订阅必须原样保留（它被 video_lua_script_wiring_guard 逐字钉住）。
      expect(
        src,
        contains(
          '_luaLogSub = player.stream.log.listen(_onMpvLogForLuaScripts);',
        ),
      );
    });

    test('诊断订阅与 Lua 订阅在同一处收口取消（Player 作用域）', () {
      final int idx = src.indexOf('void _resetLuaScriptState() {');
      expect(idx, greaterThan(0));
      // 收在方法末尾的 `\n  }`——裸 `}` 会先命中体内的 `const <String, String?>{}`，
      // 把切片截成一行、让断言变成恒假。
      final String body = src.substring(idx, src.indexOf('\n  }', idx));
      expect(body, contains('_luaLogSub?.cancel()'));
      expect(
        body,
        contains('_diagLogSub?.cancel()'),
        reason: '漏摘会让旧 Player 的迟到日志串到新 Player 的时间轴上',
      );
    });

    test('周期采样在两个消费者都不需要时短路（默认路径零开销）', () {
      final int idx = src.indexOf('void _maybeSampleBlackFlicker(');
      expect(idx, greaterThan(0));
      final String body = src.substring(idx, src.indexOf('\n  }', idx));
      expect(
        body,
        contains('if (!wantFlicker && !wantDiag) return;'),
        reason: '诊断关闭且无黑闪判据时，一个 mpv 属性都不该读',
      );
      expect(body, contains('videoDiagEnabledFor('));
    });

    test('采样读的是共享的属性清单，不另写一份字符串', () {
      expect(src, contains('VideoMpvStatsSnapshot.properties'));
      expect(src, contains('VideoMpvStatsSnapshot.fromProperties(raw)'));
    });

    test('每个 await 之后仍用 _isCurrentLoad 双判据重校验（防原生 UAF）', () {
      final int idx = src.indexOf('Future<void> _sampleBlackFlicker(');
      expect(idx, greaterThan(0));
      // 方法体的结束要从 `async {` 之后再找 `\n  }`——命名参数块自己就以
      // `\n  }) async {` 收尾，直接找会把切片停在参数表末尾。
      final int bodyStart = src.indexOf('async {', idx);
      expect(bodyStart, greaterThan(idx));
      final String body = src.substring(idx, src.indexOf('\n  }', bodyStart));
      expect(
        'if (!_isCurrentLoad(player, loadToken)) return;'
            .allMatches(body)
            .length,
        greaterThanOrEqualTo(2),
        reason: '向已释放的 NativePlayer 读属性是访问违例，不是可以吞掉的异常',
      );
    });
  });

  group('视频页（video_fushi_page.dart）', () {
    late String src;
    setUpAll(
      () => src = code('lib/src/pages/implementations/video_fushi_page.dart'),
    );

    test('帧耗时探针随页面生命周期起停', () {
      expect(src, contains('_frameProbe.start();'));
      expect(src, contains('_frameProbe.stop();'));
    });

    test('dispose 里先停探针再拆页（保住最后一窗证据）', () {
      final int stopIdx = src.indexOf('_frameProbe.stop();');
      final int disposeIdx = src.lastIndexOf('void dispose() {', stopIdx);
      expect(disposeIdx, greaterThan(0));
      expect(
        stopIdx - disposeIdx,
        lessThan(200),
        reason: '停探针要排在 dispose 开头，卡死/黑闪就发生在退出之前的那一秒',
      );
    });

    test('热槽 seed 的结果进日志（小内存分叉点）', () {
      final int idx = src.indexOf('void _seedWarmPopup() {');
      expect(idx, greaterThan(0));
      final String body = src.substring(idx, src.indexOf('\n  }', idx));
      expect(body, contains('VideoDiagCategory.warmSlot'));
      expect(body, contains('low-memory='));
    });
  });

  group('查词链路', () {
    test('pushNestedPopup 起计时，并在 search / fill / 放弃三处落阶段', () {
      final String src = code(
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      );
      final int idx = src.indexOf('Future<int> pushNestedPopup({');
      expect(idx, greaterThan(0));
      final String body = src.substring(
        idx,
        src.indexOf('\n  Future<void> loadMoreForEntry(', idx),
      );
      expect(body, contains('LookupPerfTrace.begin('));
      // 只钉阶段名，不钉排版——dart format 会随上下文改换行，守卫不该跟着碎。
      expect(body, contains('trace?.mark('));
      expect(body, contains("'search'"));
      expect(body, contains("trace?.mark('fill'"));
      expect(
        body,
        contains("trace?.finish('empty')"),
        reason: '空结果直显不经 WebView，不收尾会让游标悬着串到下一次查词',
      );
      expect(body, contains("trace?.finish('abandoned')"));
    });

    test('控制器在 beginTop 记录热槽命中 / 冷建 / 接管停驻 realm 三态', () {
      final String src = code(
        'lib/src/pages/implementations/dictionary_popup_controller.dart',
      );
      expect(src, contains("warmMode = 'hit';"));
      expect(src, contains("LookupPerfTrace.current?.mark('warm'"));
      // 三态判定必须排在 `_takeRealmKey()` **之前那一刻**：replaceStack 路径会先把
      // 当前层的键停驻进池、随后又接管回来，在方法开头按池空与否判会把这种「先存后
      // 取」误报成 cold-create。会撒谎的诊断比没有诊断更糟，故钉住相对顺序。
      final int decideIdx = src.indexOf(
        "warmMode = _parkedRealms.isEmpty ? 'cold-create'",
      );
      expect(decideIdx, greaterThan(0));
      final int takeIdx = src.indexOf('webViewKey: _takeRealmKey()', decideIdx);
      expect(takeIdx, greaterThan(decideIdx), reason: '判定要早于取键，且中间不得再有 retire');
      final int retireIdx = src.indexOf('_retireEntries(_entries);');
      expect(
        retireIdx,
        lessThan(decideIdx),
        reason: 'replaceStack 的 retire 必须发生在判定之前，判定才看得到停驻池的真实状态',
      );
    });

    test('兜底强制翻可见（用户看到的「闪」）记 warn 并收尾', () {
      final String src = code(
        'lib/src/pages/implementations/dictionary_popup_controller.dart',
      );
      final int idx = src.indexOf('void markPendingReveal(');
      expect(idx, greaterThan(0));
      final String body = src.substring(
        idx,
        src.indexOf('void _cancelRevealTimer(', idx),
      );
      expect(
        body,
        contains('VideoDiagLevel.warn'),
        reason: '强制翻可见是可感知的闪，必须在流水里显眼',
      );
      expect(
        body,
        contains("LookupPerfTrace.current?.finish('forced-reveal')"),
      );
    });

    test('正常渲染翻可见记 reveal 并收尾成 revealed', () {
      final String src = code(
        'lib/src/pages/implementations/dictionary_popup_controller.dart',
      );
      final int idx = src.indexOf('bool revealRendered(');
      expect(idx, greaterThan(0));
      final String body = src.substring(idx, src.indexOf('\n  }', idx));
      expect(body, contains("mark('reveal')"));
      expect(body, contains("finish('revealed')"));
    });

    test('WebView 侧记 loadStop（仅冷建才有）、注入量与 renderPopup 完成', () {
      final String src = code(
        'lib/src/pages/implementations/dictionary_popup_webview.dart',
      );
      expect(src, contains("LookupPerfTrace.current?.mark('loadStop')"));
      expect(src, contains('LookupPerfTrace.current?.mark('));
      expect(src, contains("'push',"));
      expect(src, contains("LookupPerfTrace.current?.mark('rendered')"));
      // 注入量是冷建 vs 热槽的直接证据（冷建时静态段恒重发）。
      expect(src, contains(r"'static=${staticSettingsJs.length}B"));
    });
  });

  group('内存策略（app_model.dart）', () {
    test('小内存模式的实际预算进日志', () {
      final String src = code('lib/src/models/app_model.dart');
      final int idx = src.indexOf('void _applyMemoryPolicy() {');
      expect(idx, greaterThan(0));
      final String body = src.substring(idx, src.indexOf('\n  }', idx));
      expect(body, contains('VideoDiagCategory.memory'));
      expect(body, contains('imageCache='));
      expect(body, contains('warm-slot='));
    });
  });

  group('设置入口', () {
    late String src;
    setUpAll(() => src = code('lib/src/settings/settings_schema_system.dart'));

    test('诊断 section 里既有开关也有导出', () {
      expect(src, contains("id: 'diagnostics.video_diag_log_enabled'"));
      expect(src, contains("id: 'diagnostics.video_diag_export'"));
      expect(src, contains('VideoDiagLog.instance.setEnabled(value)'));
      expect(src, contains('buildVideoDiagExportFromDisk('));
    });

    test('导出不被开关状态挡住（复现完先关再导出是常见顺序）', () {
      final int idx = src.indexOf("id: 'diagnostics.video_diag_export'");
      expect(idx, greaterThan(0));
      final String item = src.substring(idx, src.indexOf('),', idx));
      expect(
        item.contains('visible:'),
        isFalse,
        reason: '导出项加可见性门控会让「关掉后导不出来」这种反直觉行为复活',
      );
    });
  });

  group('启动接线（main.dart）', () {
    test('诊断日志在启动时 init 一次', () {
      final String src = code('lib/main.dart');
      expect(src, contains('VideoDiagLog.instance.init()'));
    });
  });
}
