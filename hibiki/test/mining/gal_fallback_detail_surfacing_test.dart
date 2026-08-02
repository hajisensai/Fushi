import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/gal_hook_failure_text.dart';
import 'package:hibiki/src/mining/galgame_audio_source.dart';

import '../helpers/source_guard.dart';

/// BUG-1446：降级会话卡把 `injectorDetail` 整个丢掉，native 一手证据永远到不了用户。
///
/// 现场是用户在 1.3.1+1171 上看到「捕获组件与本体版本不一致。…先彻底关掉游戏再重开
/// 一次…」——照做也不会好，因为**真正漂开的是哪一侧、差了几个版本**根本没显示。
///
/// 证据本来是齐的：native `ProtocolMismatchDetail`（`voice_hook_reader.cpp`）逐字段
/// 生成 `shm=12/want 13` 这样的双方版本对照 → `flutter_window.cpp` 以 `detail` 回传 →
/// `_activateLoopback(detail: galHookDiagnosticsDetail(...))` 存进
/// [GalHookSessionState.injectorDetail]。BUG-1216 立下的「有原因时也要给证据」只落在
/// 一次性 toast（[galHookLaunchOutcomeMessage]）上，常驻会话卡是另一条渲染路径、
/// 各写各的，于是最后一米把唯一能一次确诊的事实抹掉了。
void main() {
  group('降级结论三级取值 (BUG-1100 行为不变)', () {
    test('有可执行处置时优先给处置', () {
      expect(
        galHookFallbackHeadline(
          failure: GalHookInjectorFailure.protocolMismatch,
          fallbackReason: 'engine_attach_failed',
        ),
        galHookFailureLabel(GalHookInjectorFailure.protocolMismatch),
      );
    });

    test('注入链本来就通（failure=none）时退到降级原因的人话', () {
      expect(
        galHookFallbackHeadline(
          failure: GalHookInjectorFailure.none,
          fallbackReason: 'engine_pcm_unavailable',
        ),
        galHookFallbackLabel('engine_pcm_unavailable'),
      );
    });

    test('两张表都没有才回退内部代码，绝不编造原因', () {
      expect(
        galHookFallbackHeadline(
          failure: GalHookInjectorFailure.none,
          fallbackReason: 'some_unmapped_reason',
        ),
        'some_unmapped_reason',
      );
    });
  });

  group('会话卡必须把 native 证据显示出来 (BUG-1446)', () {
    // 私有 widget（`_SessionOverviewCard`）没法从外部构造，widget 测试够不着；
    // 源码扫描是这条回归目前最强的可落地层。
    late String card;

    setUpAll(() {
      final File file = File(
        'lib/src/pages/implementations/texthooker_page.dart',
      );
      expect(
        file.existsSync(),
        isTrue,
        reason: '会话卡源文件不在了？守卫失去锚点，先修路径再谈断言',
      );
      final String src = file.readAsStringSync();
      final int start =
          maskCommentsAndStrings(src).indexOf('class _SessionOverviewCard');
      expect(
        start,
        greaterThanOrEqualTo(0),
        reason: '_SessionOverviewCard 改名了：守卫锚点必须跟着改，不能静默失效',
      );
      card = balancedBlockFrom(src, start, what: '_SessionOverviewCard');
    });

    test('渲染了 state.injectorDetail —— 丢掉它等于把确诊依据藏起来', () {
      expect(
        containsCodeLine(card, 'state.injectorDetail'),
        isTrue,
        reason: '降级卡只说处置、不给 native 证据，正是 BUG-1446 的原始症状',
      );
    });

    test('证据是独立的一行，不缀在八十多字的处置文案尾部', () {
      // 处置那行有 maxLines（compact 只有 2 行）+ ellipsis。把证据拼进同一个 Text
      // 会被省略号整段吃掉——改了跟没改一样，所以这条必须钉死。
      expect(
        namedArgumentValues(card, 'maxLines')
            .any((String v) => v.trim() == '1'),
        isTrue,
        reason: '证据行应自己占一行（maxLines: 1），与处置文案的 2/3 行分开',
      );
      // headline 只接收 failure + fallbackReason；证据一旦被塞进它的实参，
      // 就又回到了「缀在长文案尾部、被 ellipsis 吃掉」的老路。
      final EnclosingCall headline = enclosingCallOf(
        card,
        'galHookFallbackHeadline(',
      );
      expect(
        headline.text.contains('injectorDetail'),
        isFalse,
        reason: 'injectorDetail 不该出现在 galHookFallbackHeadline 的实参里',
      );
    });
  });
}
