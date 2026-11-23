import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/advanced_mining_handoff.dart';
import 'package:fushi/src/lookup/captured_context_sentences.dart';
import 'package:fushi/src/lookup/global_lookup_stack.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';

import '../helpers/source_guard.dart';

/// 拍板台 rf--UcsGta-overlay（方案 b 转交主窗）：应用外查词覆盖窗卡片上的「高级制卡」
/// 把词条 + 抓到的上下文经覆盖窗通道交给主窗查词页，主窗查完后打开完整的高级制卡
/// 对话框。这里钉住：桥参数 → 转交内容 → 主窗出口排队的整条往返，以及各环接线。
void main() {
  const CapturedSentenceContext captured = CapturedSentenceContext(
    before: <String>['昨日は雨だった。'],
    current: '今日は晴れた。',
    after: <String>['明日も晴れるらしい。'],
  );

  GlobalLookupStack stackOf(List<String> queries) =>
      GlobalLookupStack(<GlobalLookupFrame>[
        for (int i = 0; i < queries.length; i++)
          GlobalLookupFrame(
            id: i == 0 ? 'root' : 'f$i',
            query: queries[i],
            parentIndex: i - 1,
          ),
      ]);

  group('AdvancedMiningHandoff.fromBridgeArgs', () {
    test('解析 popup.js openAdvancedMining 的对象参数（不认下标）', () {
      final AdvancedMiningHandoff? handoff =
          AdvancedMiningHandoff.fromBridgeArgs(<Object?>[
            <String, Object?>{
              'entryIndex': 3,
              'matched': '晴れた',
              'expression': '晴れる',
              'reading': 'はれる',
            },
          ]);
      expect(
        handoff,
        const AdvancedMiningHandoff(
          expression: '晴れる',
          reading: 'はれる',
          matched: '晴れた',
        ),
      );
    });

    test('缺表记 / 参数不是对象（BUG-1326 的字符串形态）→ 不转交', () {
      expect(
        AdvancedMiningHandoff.fromBridgeArgs(<Object?>[
          <String, Object?>{'matched': '晴れた', 'expression': '  '},
        ]),
        isNull,
      );
      expect(
        AdvancedMiningHandoff.fromBridgeArgs(<Object?>['{"expression":"晴れる"}']),
        isNull,
      );
      expect(AdvancedMiningHandoff.fromBridgeArgs(null), isNull);
      expect(AdvancedMiningHandoff.fromBridgeArgs(<Object?>[]), isNull);
    });

    test('读音缺省为空串', () {
      final AdvancedMiningHandoff? handoff =
          AdvancedMiningHandoff.fromBridgeArgs(<Object?>[
            <String, Object?>{'matched': '雨', 'expression': '雨'},
          ]);
      expect(handoff?.reading, '');
      expect(handoff?.matched, '雨');
    });
  });

  group('resolveOverlayHandoffSource', () {
    test('根卡：根查询串 + 切好的前后句', () {
      final OverlayHandoffSource? source = resolveOverlayHandoffSource(
        stack: stackOf(<String>['今日は晴れた']),
        frameId: 'root',
        captured: captured,
        sentence: '今日は晴れた。',
      );
      expect(source?.text, '今日は晴れた');
      expect(identical(source?.capturedContext, captured), isTrue);
    });

    test('根卡只有一句（悬浮字幕 / 歌词行）→ 包成没有前后句的上下文', () {
      final OverlayHandoffSource? source = resolveOverlayHandoffSource(
        stack: stackOf(<String>['晴れ']),
        frameId: null,
        captured: null,
        sentence: ' 今日は晴れた。 ',
      );
      expect(source?.text, '晴れ');
      expect(source?.capturedContext?.current, '今日は晴れた。');
      expect(source?.capturedContext?.hasNeighbours, isFalse);
    });

    test('根卡没有任何句子 → 不带上下文', () {
      final OverlayHandoffSource? source = resolveOverlayHandoffSource(
        stack: stackOf(<String>['晴れ']),
        frameId: 'root',
        captured: null,
        sentence: '',
      );
      expect(source?.text, '晴れ');
      expect(source?.capturedContext, isNull);
    });

    test('嵌套卡：该层查询串，不带根词的语境', () {
      final OverlayHandoffSource? source = resolveOverlayHandoffSource(
        stack: stackOf(<String>['今日は晴れた', '天気']),
        frameId: 'f1',
        captured: captured,
        sentence: '今日は晴れた。',
      );
      expect(source?.text, '天気');
      expect(source?.capturedContext, isNull);
    });

    test('发起的卡层已不在栈里 / 栈为空 → 不转交', () {
      expect(
        resolveOverlayHandoffSource(
          stack: stackOf(<String>['今日は晴れた']),
          frameId: 'f9',
          captured: captured,
          sentence: '',
        ),
        isNull,
      );
      expect(
        resolveOverlayHandoffSource(
          stack: GlobalLookupStack.empty,
          frameId: null,
          captured: captured,
          sentence: '',
        ),
        isNull,
      );
    });
  });

  group('覆盖窗通道 → 主窗出口往返', () {
    setUp(DesktopLookupService.instance.debugReset);
    tearDown(DesktopLookupService.instance.debugReset);

    test('桥参数解析出的词条与上下文原样排进主窗查词请求', () {
      final AdvancedMiningHandoff handoff =
          AdvancedMiningHandoff.fromBridgeArgs(<Object?>[
            <String, Object?>{
              'entryIndex': 0,
              'matched': '晴れた',
              'expression': '晴れる',
              'reading': 'はれる',
            },
          ])!;
      final OverlayHandoffSource source = resolveOverlayHandoffSource(
        stack: stackOf(<String>['今日は晴れた']),
        frameId: 'root',
        captured: captured,
        sentence: captured.current,
      )!;
      final bool queued = DesktopLookupService.instance.triggerLookup(
        source.text,
        capturedContext: source.capturedContext,
        advancedMining: handoff,
      );
      expect(queued, isTrue);
      final DesktopLookupRequest? request =
          DesktopLookupService.instance.pendingRequest;
      expect(request?.text, '今日は晴れた');
      expect(identical(request?.capturedContext, captured), isTrue);
      expect(request?.advancedMining, handoff);
    });

    test('普通主窗查词（深链 / 扩展）不带转交', () {
      DesktopLookupService.instance.triggerLookup('辞書');
      expect(
        DesktopLookupService.instance.pendingRequest?.advancedMining,
        null,
      );
    });
  });

  group('接线守卫', () {
    // flutter test 的 cwd 是 fushi 包根。
    String read(String path) => compactCode(File(path).readAsStringSync());
    final String controller = read(
      'lib/src/lookup/global_lookup_controller.dart',
    );
    final String render = read('lib/src/lookup/global_lookup_render.dart');
    final String injection = read(
      'lib/src/pages/implementations/popup_settings_injection.dart',
    );
    final String appModel = read('lib/src/models/app_model.dart');
    final String home = read(
      'lib/src/pages/implementations/home_dictionary_page.dart',
    );

    test('覆盖窗处理 openAdvancedMining：收卡并交给主窗出口', () {
      expect(controller, contains("if(handler=='openAdvancedMining'){"));
      expect(controller, contains('_handOffAdvancedMining(message);'));
      expect(
        controller,
        contains(
          'model.queueExternalLookup(source.text,capturedContext:source.capturedContext,advancedMining:handoff,);',
        ),
      );
      // 热键根查词把切好的前后句记下来，转交时带走。
      expect(controller, contains('capturedContext:sentences,'));
      expect(controller, contains('_currentCapturedContext=capturedContext;'));
      expect(
        appModel,
        contains(
          'triggerLookup(text,capturedContext:capturedContext,advancedMining:advancedMining,)',
        ),
      );
    });

    test('入口只给默认制卡路径的卡，门控在 renderPopup 之前写', () {
      expect(
        controller,
        contains("route.source!='galCard'&&_currentMiningHandler==null;"),
      );
      expect(
        controller,
        contains(
          'advancedMiningHandoff:_advancedMiningHandoffAvailable(route),',
        ),
      );
      final int flag = render.indexOf(
        r'window.advancedMiningEnabled=$advancedMiningHandoff;',
      );
      expect(flag, greaterThan(0));
      expect(
        render.indexOf('window.renderPopup&&window.renderPopup();'),
        greaterThan(flag),
      );
      expect(injection, contains('t.popup_advanced_mining_open_in_app'));
    });

    test('主窗查词页画完这次结果后按词条身份定位并打开对话框', () {
      expect(home, contains('_pendingAdvancedMining=request.advancedMining;'));
      expect(home, contains('onRendered:_onResultRendered,'));
      expect(home, contains('!webView.hasRenderedResult(result)'));
      expect(home, contains('webView.entryDomIndexFor('));
      expect(
        home,
        contains(
          'sentenceSection:_capturedSentenceSection,)?.call(index,handoff.matched,handoff.expression,handoff.reading);',
        ),
      );
    });
  });
}
