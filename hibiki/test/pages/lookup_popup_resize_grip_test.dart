import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// Phase B（查词弹窗尺寸拖拽）测试。分两层：
///
/// 1. 纯函数 [resolveDraggedLookupSize]：方向（右下增大 / 左上减小）、双向 clamp、
///    界面缩放折算（拖动位移在已缩放盒坐标系，回写基准要除 uiScale）、uiScale 兜底。
///    不依赖任何 harness。
/// 2. widget：pump 一个带 resize grip 的 [DictionaryPopupLayer]（result=null → 走
///    「未找到」占位分支，不挂平台 WebView），在 grip 上模拟 pan 拖动，断言拖动后
///    真实 [AppModel]/偏好里的 `popupMaxWidth`/`popupMaxHeight` 按预期方向变化并被
///    clamp——覆盖 grip 手势 → 折算 → 落偏好整条写穿链路。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  group('resolveDraggedLookupSize 纯函数', () {
    test('右下拖动（正 delta）在 uiScale=1 时按位移等量增大', () {
      final LookupSize s = resolveDraggedLookupSize(
        currentBaseWidth: 400,
        currentBaseHeight: 360,
        deltaWidthPx: 200,
        deltaHeightPx: 100,
        uiScale: 1.0,
      );
      expect(s.width, 600);
      expect(s.height, 460);
    });

    test('左上拖动（负 delta）减小', () {
      final LookupSize s = resolveDraggedLookupSize(
        currentBaseWidth: 800,
        currentBaseHeight: 700,
        deltaWidthPx: -150,
        deltaHeightPx: -120,
        uiScale: 1.0,
      );
      expect(s.width, 650);
      expect(s.height, 580);
    });

    test('uiScale=2：盒坐标位移折算回基准要除以缩放', () {
      final LookupSize s = resolveDraggedLookupSize(
        currentBaseWidth: 400,
        currentBaseHeight: 360,
        deltaWidthPx: 200, // 盒里拖 200px，界面 2× → 基准只 +100
        deltaHeightPx: 200,
        uiScale: 2.0,
      );
      expect(s.width, 500);
      expect(s.height, 460);
    });

    test('上界 clamp 到 2000×1600', () {
      final LookupSize s = resolveDraggedLookupSize(
        currentBaseWidth: 1900,
        currentBaseHeight: 1500,
        deltaWidthPx: 5000,
        deltaHeightPx: 5000,
        uiScale: 1.0,
      );
      expect(s.width, kLookupPopupMaxWidth);
      expect(s.height, kLookupPopupMaxHeight);
    });

    test('下界 clamp 到 250×200', () {
      final LookupSize s = resolveDraggedLookupSize(
        currentBaseWidth: 300,
        currentBaseHeight: 300,
        deltaWidthPx: -5000,
        deltaHeightPx: -5000,
        uiScale: 1.0,
      );
      expect(s.width, kLookupPopupMinWidth);
      expect(s.height, kLookupPopupMinHeight);
    });

    test('uiScale<=0 按 1 兜底，不除零/不反向', () {
      final LookupSize s = resolveDraggedLookupSize(
        currentBaseWidth: 400,
        currentBaseHeight: 360,
        deltaWidthPx: 50,
        deltaHeightPx: 40,
        uiScale: 0,
      );
      expect(s.width, 450);
      expect(s.height, 400);
    });
  });

  group('DictionaryPopupLayer resize grip widget', () {
    // AppModel 构造时 DefaultCacheManager 经 path_provider 平台通道，单测 mock 掉。
    late Directory pathProviderDir;
    setUpAll(() {
      pathProviderDir =
          Directory.systemTemp.createTempSync('hibiki_path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async => pathProviderDir.path,
      );
    });
    tearDownAll(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      if (pathProviderDir.existsSync()) {
        pathProviderDir.deleteSync(recursive: true);
      }
    });

    late HibikiDatabase db;
    late PreferencesRepository prefs;
    late AppModel appModel;

    setUp(() async {
      db = HibikiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      appModel = AppModel(testPlatformServices());
      appModel.wireLocalAudioForTesting(
        prefsRepo: prefs,
        databaseDirectory: Directory.systemTemp.createTempSync('resize_grip'),
      );
    });

    tearDown(() async {
      prefs.dispose();
      await db.close();
    });

    Future<void> pumpLayer(WidgetTester tester, {double uiScale = 1.0}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _ResizeTestHost(appModel: appModel, uiScale: uiScale),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('grip 渲染在弹窗层里', (WidgetTester tester) async {
      await pumpLayer(tester);
      expect(find.byKey(DictionaryPopupLayer.resizeGripKey), findsOneWidget);
    });

    testWidgets('向右下拖动放大 → 偏好宽/高都增大', (WidgetTester tester) async {
      await pumpLayer(tester);
      expect(appModel.popupMaxWidth, appModel.defaultPopupMaxWidth); // 400
      expect(appModel.popupMaxHeight, appModel.defaultPopupMaxHeight); // 360

      await tester.drag(
        find.byKey(DictionaryPopupLayer.resizeGripKey),
        const Offset(180, 120),
      );
      await tester.pump();

      expect(appModel.popupMaxWidth, greaterThan(400));
      expect(appModel.popupMaxHeight, greaterThan(360));
      // 不超上界。
      expect(appModel.popupMaxWidth, lessThanOrEqualTo(kLookupPopupMaxWidth));
      expect(appModel.popupMaxHeight, lessThanOrEqualTo(kLookupPopupMaxHeight));
    });

    testWidgets('向右下巨量拖动被 clamp 到上界 2000×1600', (WidgetTester tester) async {
      await pumpLayer(tester);
      await tester.drag(
        find.byKey(DictionaryPopupLayer.resizeGripKey),
        const Offset(5000, 5000),
      );
      await tester.pump();
      expect(appModel.popupMaxWidth, kLookupPopupMaxWidth);
      expect(appModel.popupMaxHeight, kLookupPopupMaxHeight);
    });

    testWidgets('向左上巨量拖动被 clamp 到下界 250×200', (WidgetTester tester) async {
      await pumpLayer(tester);
      await tester.drag(
        find.byKey(DictionaryPopupLayer.resizeGripKey),
        const Offset(-5000, -5000),
      );
      await tester.pump();
      expect(appModel.popupMaxWidth, kLookupPopupMinWidth);
      expect(appModel.popupMaxHeight, kLookupPopupMinHeight);
    });
  });
}

/// 复刻 reader/video 宿主的 resize 接线：持预览态、松手落偏好。uiScale 直接注入
/// （单测 harness 未初始化 themeNotifier，故不读 appModel.appUiScale），其余逻辑与
/// [BaseSourcePageState] / [DictionaryPageMixin] 的处理器一致。
class _ResizeTestHost extends StatefulWidget {
  const _ResizeTestHost({required this.appModel, required this.uiScale});

  final AppModel appModel;
  final double uiScale;

  @override
  State<_ResizeTestHost> createState() => _ResizeTestHostState();
}

class _ResizeTestHostState extends State<_ResizeTestHost> {
  LookupSize? _preview;

  double get _boxWidth =>
      (_preview?.width ?? widget.appModel.popupMaxWidth) * widget.uiScale;
  double get _boxHeight =>
      (_preview?.height ?? widget.appModel.popupMaxHeight) * widget.uiScale;

  LookupSize get _currentBase =>
      LookupSize(widget.appModel.popupMaxWidth, widget.appModel.popupMaxHeight);

  void _start() => setState(() => _preview = _currentBase);

  void _update(Offset deltaPx) {
    final LookupSize base = _preview ?? _currentBase;
    setState(() {
      _preview = resolveDraggedLookupSize(
        currentBaseWidth: base.width,
        currentBaseHeight: base.height,
        deltaWidthPx: deltaPx.dx,
        deltaHeightPx: deltaPx.dy,
        uiScale: widget.uiScale,
      );
    });
  }

  void _end() {
    final LookupSize? committed = _preview;
    setState(() => _preview = null);
    if (committed != null) {
      widget.appModel.setPopupMaxWidth(committed.width);
      widget.appModel.setPopupMaxHeight(committed.height);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: _boxWidth,
        height: _boxHeight,
        child: DictionaryPopupLayer(
          result: null,
          webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
          onDismiss: () {},
          onTextSelected: (String text, Rect localRect) {},
          onLinkClick: (String query, Rect localRect) {},
          onMineEntry: (Map<String, String> fields) async =>
              const MinePopupResult(),
          onDuplicateCheck: (String expression, String reading) async => false,
          enableSwipeToClose: false,
          showResizeGrip: true,
          onResizeStart: _start,
          onResizeUpdate: _update,
          onResizeEnd: _end,
        ),
      ),
    );
  }
}
