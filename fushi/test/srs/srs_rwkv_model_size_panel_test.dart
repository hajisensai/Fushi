// 牌组设置 › RWKV 的模型档位（Small sm98 / Tiny sm101）：读 `<support>/srs_rwkv/model_size` 显示当前档位与
// 对应说明；选另一档立即写回同一个设置文件（无头服务端读的也是它），权重库 provider 跟着换成新档位的权重。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_rwkv_panel.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_engine/srs/srs_rwkv_attach.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late Directory support;

  setUp(() {
    support = Directory.systemTemp.createTempSync('srs_rwkv_model_size');
  });

  tearDown(() {
    try {
      support.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  // 说明文字在紧凑行模式下收进信息提示，不一定是可见的 Text：直接读行的属性。
  AdaptiveSettingsSegmentedRow<SrsRwkvModelSize> row(WidgetTester tester) =>
      tester.widget<AdaptiveSettingsSegmentedRow<SrsRwkvModelSize>>(
        find.byKey(const ValueKey<String>('srs-settings-rwkv-model-size')),
      );

  /// 权重库 provider 的当前值（没人 watch 它：先 listen 让它建起来，在假时钟里 pump 到出值）。
  Future<SrsRwkvModels> models(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    final ProviderSubscription<AsyncValue<SrsRwkvModels>> sub = container
        .listen(srsRwkvModelsProvider, (_, _) {});
    addTearDown(sub.close);
    for (int i = 0; i < 20 && sub.read().valueOrNull == null; i++) {
      await tester.pump();
    }
    return sub.read().requireValue;
  }

  Future<ProviderContainer> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          srsSupportRootProvider.overrideWithValue(() async => support),
          // 不起真服务（会去下载权重）；这里只测档位设置。
          srsRwkvServiceProvider.overrideWith((Ref ref) async => null),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: buildFushiThemeData(
              scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
              textTheme: Typography.material2021().black,
              designSystem: FushiDesignSystem.material,
              glass: FushiGlassMaterial.off,
              glassDesign: false,
            ),
            builder: (BuildContext context, Widget? child) =>
                FushiGlassScope(child: child!),
            home: const Scaffold(
              body: SingleChildScrollView(child: SrsRwkvPanel()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(SrsRwkvPanel)));
  }

  testWidgets('设置文件是 Tiny：显示 Tiny 的说明；选 Small 写回设置文件、权重库换成 sm98', (
    WidgetTester tester,
  ) async {
    srsRwkvModelSizeFile(support)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('tiny');
    final ProviderContainer container = await pumpPanel(tester);

    expect(
      find.byKey(const ValueKey<String>('srs-settings-rwkv-model-size')),
      findsOneWidget,
    );
    expect(row(tester).selected, SrsRwkvModelSize.tiny);
    expect(row(tester).subtitle, t.srs_settings_rwkv_model_size_tiny_hint);
    final SrsRwkvModels tinyModels = await models(tester, container);
    expect(tinyModels.model.fileName, kSrsRwkvTinyWeightsName);

    // 分段条的段标签不一定是可点的独立 Text（自适应分段组件自己画），直接走行的回调：测的是选了之后的接线。
    row(tester).onChanged(SrsRwkvModelSize.small);
    // 写设置文件是真 IO：假时钟里 pump 推进 Dart 侧，runAsync 让出真实事件循环给文件写入，交替直到写完。
    for (
      int i = 0;
      i < 200 && readSrsRwkvModelSize(support) != SrsRwkvModelSize.small;
      i++
    ) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }
    await tester.pumpAndSettle();

    expect(srsRwkvModelSizeFile(support).readAsStringSync(), 'small');
    expect(row(tester).selected, SrsRwkvModelSize.small);
    expect(row(tester).subtitle, t.srs_settings_rwkv_model_size_small_hint);
    final SrsRwkvModels smallModels = await models(tester, container);
    expect(smallModels.size, SrsRwkvModelSize.small);
    expect(smallModels.model.fileName, kSrsRwkvSmallWeightsName);
  });

  testWidgets('没有设置文件：默认 Small', (WidgetTester tester) async {
    await pumpPanel(tester);
    expect(row(tester).selected, SrsRwkvModelSize.small);
    expect(row(tester).subtitle, t.srs_settings_rwkv_model_size_small_hint);
    expect(srsRwkvModelSizeFile(support).existsSync(), isFalse);
  });
}
