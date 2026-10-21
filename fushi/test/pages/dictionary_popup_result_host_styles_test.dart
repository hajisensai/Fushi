// ignore: depend_on_referenced_packages  — 测试桩需直接实现该平台接口（flutter_inappwebview 的传递依赖）
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/fake_inappwebview_platform.dart';
import 'dictionary_popup_push_dedup_test.dart'
    show
        MutableResultPopupWebView,
        PushDedupAppModel,
        RecordingInAppWebViewPlatform,
        RecordingWebViewHarness,
        ResultHolder,
        makeResult,
        wrapPopup;

/// BUG-3612：iPad 看电脑媒体库视频制卡——查词经 `AppModel` 的 remote-first 路径由
/// 电脑完成，弹窗在本机渲染、Glossary 也在本机导出（`popup.js` 读
/// `window.dictionaryStyles`）。宿主没有注入资源源（同一表面下一次可能是本机结果），
/// 弹窗必须按**结果**自带的 host 样式整表替换，换回本机结果时再恢复本机样式。
void main() {
  late RecordingWebViewHarness harness;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    harness = RecordingWebViewHarness();
    InAppWebViewPlatform.instance = RecordingInAppWebViewPlatform(harness);
  });

  tearDownAll(installFakeInAppWebViewPlatform);

  const String hostStylesJs = 'window.dictionaryStyles = {"明鏡":".host{}"};';

  DictionarySearchResult hostResult(String term, Map<String, String> styles) =>
      makeResult(term)..remoteDictionaryStyles = styles;

  testWidgets(
    'a remote result injects its host styles; a local one restores local',
    (WidgetTester tester) async {
      final Map<String, String> hostStyles = Map<String, String>.unmodifiable(
        <String, String>{'明鏡': '.host{}'},
      );
      final ResultHolder holder = ResultHolder(hostResult('語', hostStyles));
      await tester.pumpWidget(
        wrapPopup(
          appModel: PushDedupAppModel(),
          popup: MutableResultPopupWebView(holder: holder),
        ),
      );
      await tester.pump();
      await tester.pump();
      String lastPush() => harness.scripts.lastWhere(
        (String s) => s.contains('window.lookupEntries'),
      );

      // 首推：静态段写入本机样式后，host 样式紧跟着整表覆盖它。
      final String first = lastPush();
      expect(first, contains(hostStylesJs));
      expect(
        first.lastIndexOf('window.dictionaryStyles ='),
        first.indexOf(hostStylesJs),
        reason: 'host 样式必须是最后一次写入 window.dictionaryStyles',
      );
      await harness.firePopupRendered();

      final DictionaryPopupWebViewState state = tester
          .state<DictionaryPopupWebViewState>(
            find.byType(MutableResultPopupWebView),
          );

      // 同一 host、指纹没变：结果带同一个样式实例，不重注入。
      holder.value = hostResult('別', hostStyles);
      expect(state.refreshCurrentResult(), isTrue);
      await tester.pump();
      expect(lastPush(), isNot(contains('window.dictionaryStyles')));
      await harness.firePopupRendered();

      // 换回本机结果：静态段（本机样式）必须重发，把 host 样式换掉。
      holder.value = makeResult('猫');
      expect(state.refreshCurrentResult(), isTrue);
      await tester.pump();
      final String local = lastPush();
      expect(local, contains('window.dictionaryStyles'));
      expect(local, isNot(contains('.host{}')));
    },
  );
}
