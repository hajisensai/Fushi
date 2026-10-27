import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages  — 测试桩需直接实现该平台接口（flutter_inappwebview 的传递依赖）
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/srs/srs_card_appearance.dart';
import 'package:fushi/src/srs/srs_providers.dart';

import '../helpers/fake_inappwebview_platform.dart';

/// 每建一次「平台视图」（假 WebView 的 State）+1。
int _platformViewsCreated = 0;

class _CountingPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _CountingWebViewWidget(params);
}

class _CountingWebViewWidget extends PlatformInAppWebViewWidget {
  _CountingWebViewWidget(PlatformInAppWebViewWidgetCreationParams params)
    : super.implementation(params);

  @override
  Widget build(BuildContext context) => const _PlatformViewProbe();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      throw UnimplementedError();

  @override
  void dispose() {}
}

class _PlatformViewProbe extends StatefulWidget {
  const _PlatformViewProbe();

  @override
  State<_PlatformViewProbe> createState() => _PlatformViewProbeState();
}

class _PlatformViewProbeState extends State<_PlatformViewProbe> {
  @override
  void initState() {
    super.initState();
    _platformViewsCreated++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

SrsCardFace _face(String id, {required bool answer}) => SrsCardFace(
  cardId: id,
  showingAnswer: answer,
  bodyHtml: '<p>$id</p>',
  css: '',
  languageCode: 'ja',
  onBridgeKey: (String _) {},
);

void main() {
  setUp(() {
    _platformViewsCreated = 0;
    InAppWebViewPlatform.instance = _CountingPlatform();
  });
  tearDown(installFakeInAppWebViewPlatform);

  // O1yqRPUyut：原生 Fushi 卡面的释义 WebView 正面在 Offstage 里预热（无查词作用域），
  // 翻面后进入有作用域的位置。以前 macOS 上作用域一变，卡面根 widget 就在「裸 WebView」与
  // 「Listener 包 WebView」之间换类型，平台视图每张卡销毁重建两次。
  testWidgets('查词作用域在 null 与非 null 间切换时平台视图不重建', (WidgetTester tester) async {
    final SrsCardLookupController lookup = SrsCardLookupController();
    addTearDown(lookup.dispose);

    Widget host({
      required bool scoped,
      required SrsCardFace face,
    }) => ProviderScope(
      overrides: <Override>[
        srsCardAppearanceProvider.overrideWithValue(const SrsCardAppearance()),
        srsCardFontsProvider.overrideWithValue(const <Map<String, dynamic>>[]),
        srsCardFontRootProvider.overrideWithValue(null),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SrsCardLookupScope(
              controller: scoped ? lookup : null,
              child: SrsWebCardFace(
                key: const ValueKey<String>('face'),
                face: face,
              ),
            ),
          ),
        ),
      ),
    );

    // 正面预热（无作用域）→ 翻面（有作用域）→ 下一张正面（无作用域）→ 翻面。
    await tester.pumpWidget(
      host(scoped: false, face: _face('a', answer: true)),
    );
    expect(_platformViewsCreated, 1);
    await tester.pumpWidget(host(scoped: true, face: _face('a', answer: true)));
    await tester.pumpWidget(
      host(scoped: false, face: _face('b', answer: true)),
    );
    await tester.pumpWidget(host(scoped: true, face: _face('b', answer: true)));
    expect(
      _platformViewsCreated,
      1,
      reason: 'the card face must keep one platform view across flips / cards',
    );
  });
}
