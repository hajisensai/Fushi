import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-4712：`.fushiplug` 插件包拖进插件管理类页面毫无反应。
///
/// 根因有两层：分类层没有任何类别认 `.fushiplug`（落 unknown，静默），而安装流程
/// 和文件选择器焊死在 `pickAndInstallMusicPlugin` 里，拖放根本没有入口可接。这里
/// 钉住两件事：分类层认得出插件包；插件管理落点拖入后走的是和「安装」按钮同一条
/// 校验 → 确认 → 安装流程。
MusicPluginPackageInfo _info() => const MusicPluginPackageInfo(
  manifest: MusicPluginManifest(
    id: 'one.asmr.test',
    name: 'ASMR Test',
    version: '1.0.0',
    api: 1,
    capabilities: <String>['search', 'stream', 'login'],
    searchTypes: <String>['track'],
    permissions: <String>['network'],
    networkDomains: <String>['example.com'],
  ),
  digest: 'digest-1',
  signer: null,
  files: <String>[],
);

class _FakeManager extends MusicPluginManager {
  _FakeManager()
    : super(
        rootDir: Directory('${Directory.systemTemp.path}/fushi-plug-drop-none'),
        httpClientFactory: HttpClient.new,
        log: (_, _, _) {},
      );

  final List<Uint8List> inspected = <Uint8List>[];
  final List<String> installedDigests = <String>[];

  @override
  Future<MusicPluginPackageInfo> inspect(Uint8List zip) async {
    inspected.add(zip);
    return _info();
  }

  @override
  Future<bool> signerChanged(MusicPluginPackageInfo info) async => false;

  @override
  Future<MusicPluginPackageInfo> install(Uint8List zip, String digest) async {
    installedDigests.add(digest);
    return _info();
  }
}

/// 拖放处理里有真实文件 IO：在 fake zone 里只有 runAsync 才推得动。
Future<void> _settleIo(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

void main() {
  group('分类层', () {
    test('.fushiplug 归插件包，不再落 unknown', () {
      final DroppedFiles files = classifyDroppedFiles(<String>[
        r'C:\dl\asmr-one.fushiplug',
        '/home/u/OTHER.FUSHIPLUG',
      ]);
      expect(files.plugins, <String>[
        r'C:\dl\asmr-one.fushiplug',
        '/home/u/OTHER.FUSHIPLUG',
      ]);
      expect(files.unknown, isEmpty);
      expect(files.hasAny, isTrue);
    });

    test('插件管理落点认的扩展名与文件选择器一致（.fushiplug + .zip）', () {
      expect(kPluginPackageExtensions, <String>{'fushiplug', 'zip'});
      expect(
        pluginPackagePathsOf(<String>[
          '/a.fushiplug',
          '/b.ZIP',
          '/c.epub',
          'https://example.com/x.fushiplug',
        ]),
        <String>['/a.fushiplug', '/b.ZIP'],
      );
    });
  });

  group('音乐插件落点', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi-plug-drop-');
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Future<_FakeManager> pump(WidgetTester tester) async {
      LocaleSettings.setLocale(AppLocale.en);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 1200);
      addTearDown(tester.view.reset);
      final _FakeManager manager = _FakeManager();
      // 装 navigator key，让 FushiToast 走自绘 overlay，测试里才能 find 到提示文字。
      final GlobalKey<NavigatorState> navigatorKey =
          GlobalKey<NavigatorState>();
      FushiToast.navigatorKey = navigatorKey;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: MusicPluginDropTarget(
                manager: manager,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      return manager;
    }

    FushiFileDropTarget target(WidgetTester tester) =>
        tester.widget<FushiFileDropTarget>(find.byType(FushiFileDropTarget));

    testWidgets('拖入 .fushiplug：读包 → 校验 → 弹安装确认 → 确认后安装', (
      WidgetTester tester,
    ) async {
      final _FakeManager manager = await pump(tester);
      final File pkg = File('${tmp.path}/asmr-one.fushiplug');
      final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      await tester.runAsync(() => pkg.writeAsBytes(bytes));

      unawaited(target(tester).runDrop(<String>[pkg.path], Offset.zero));
      await _settleIo(tester);

      expect(manager.inspected.single, bytes);
      expect(find.text(t.music_plugins_install_title), findsOneWidget);
      expect(manager.installedDigests, isEmpty, reason: '确认之前不安装');

      await tester.tap(find.text(t.music_plugins_install_action));
      await _settleIo(tester);

      expect(manager.installedDigests, <String>['digest-1']);

      // 安装成功会弹 toast：等停留期满、退场播完，不留挂起的 Timer。
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });

    testWidgets('拖入的不是插件包：不碰安装流程', (WidgetTester tester) async {
      final _FakeManager manager = await pump(tester);

      unawaited(
        target(tester).runDrop(<String>['${tmp.path}/song.mp3'], Offset.zero),
      );
      await _settleIo(tester);

      expect(manager.inspected, isEmpty);
      expect(find.text(t.music_plugins_install_title), findsNothing);
      // 不许静默：落在插件页的非插件文件要给「本页不支持」提示。
      expect(find.text(t.drag_drop_unsupported_on_plugins), findsOneWidget);

      // 等提示停留期满、退场播完，不留挂起的 Timer。
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    });
  });
}
