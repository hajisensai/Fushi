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

/// 假平台视图背后的那一只「原生」控制器：记下所有执行过的 JS。
class _RecordingController extends PlatformInAppWebViewController {
  _RecordingController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 1),
      );

  final List<String> evaluated = <String>[];

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    evaluated.add(source);
    return null;
  }

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) {}

  @override
  Future<void> loadData({
    required String data,
    String mimeType = 'text/html',
    String encoding = 'utf8',
    WebUri? baseUrl,
    @Deprecated('Use historyUrl instead') Uri? androidHistoryUrl,
    WebUri? historyUrl,
    @Deprecated('Use allowingReadAccessTo instead')
    Uri? iosAllowingReadAccessTo,
    WebUri? allowingReadAccessTo,
  }) async {}
}

final _RecordingController _native = _RecordingController();

/// 与真插件同形：每次回调都经 `controllerFromPlatform` 给同一平台控制器**新包一只**
/// app 侧 controller（onWebViewCreated 与 onLoadStop 拿到的不是同一个对象）。
class _WrappingPlatform extends InAppWebViewPlatform {
  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => _WrappingWebViewWidget(params);
}

class _WrappingWebViewWidget extends PlatformInAppWebViewWidget {
  _WrappingWebViewWidget(PlatformInAppWebViewWidgetCreationParams params)
    : super.implementation(params);

  @override
  Widget build(BuildContext context) => _LifecycleProbe(params: params);

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;

  @override
  void dispose() {}
}

class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe({required this.params});

  final PlatformInAppWebViewWidgetCreationParams params;

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

class _LifecycleProbeState extends State<_LifecycleProbe> {
  @override
  void initState() {
    super.initState();
    final PlatformInAppWebViewWidgetCreationParams p = widget.params;
    Future<void>.microtask(() {
      p.onWebViewCreated?.call(p.controllerFromPlatform!(_native));
      p.onLoadStop?.call(p.controllerFromPlatform!(_native), null);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  setUp(() {
    _native.evaluated.clear();
    InAppWebViewPlatform.instance = _WrappingPlatform();
  });
  tearDown(installFakeInAppWebViewPlatform);

  // iOS 用户报：导入的 Anki 牌组（JLPT N1 / Eggrolls / 蓝宝书，整面 WebView 卡面）点词
  // 不查词、点空白唤不出悬浮顶栏。页内取词脚本先看门控 `window.__fushiSrsLookup`，
  // 门控从没下发：onLoadStop 的参数与 onWebViewCreated 存下的 controller 是两只包装，
  // `_installLookup` 的 identical 判断恒假、装完脚本就返回。
  testWidgets('外壳加载完后下发取词门控（插件每次回调新包 controller）', (WidgetTester tester) async {
    final SrsCardLookupController lookup = SrsCardLookupController(
      settings: () => (tap: true, hoverAuto: false),
    );
    addTearDown(lookup.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          srsCardAppearanceProvider.overrideWithValue(
            const SrsCardAppearance(),
          ),
          srsCardFontsProvider.overrideWithValue(
            const <Map<String, dynamic>>[],
          ),
          srsCardFontRootProvider.overrideWithValue(null),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SrsCardLookupScope(
                controller: lookup,
                child: SrsWebCardFace(
                  face: SrsCardFace(
                    cardId: 'c1',
                    showingAnswer: false,
                    bodyHtml: '<p>諸問題</p>',
                    css: '',
                    languageCode: 'ja',
                    onBridgeKey: (String _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      _native.evaluated.any(
        (String s) => s.contains('window.__fushiSrsLookupInstalled'),
      ),
      isTrue,
      reason: 'lookup script must be installed',
    );
    expect(
      _native.evaluated.any(
        (String s) => s.startsWith('window.__fushiSrsLookup = {tap: true'),
      ),
      isTrue,
      reason:
          'without the gate the page script drops every tap '
          '(no lookup, no onTapEmpty)',
    );
  });
}
