import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:material_ui/material_ui.dart';

/// 页面背景：自定义图片导入、候选取色与「从图片取色」覆盖主题配色。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory scratch;
  late Directory store;
  late FushiDatabase database;
  late ThemeNotifier notifier;
  late Map<String, List<int>> seedsByPath;
  final Future<List<int>> Function(String) originalExtractor =
      ThemeNotifier.pageBackdropSeedExtractor;
  final Future<Directory> Function() originalDirectory =
      ThemeNotifier.pageBackdropImageDirectory;

  const int green = 0xFF2E7D32;
  const int red = 0xFFC62828;

  ThemeNotifier build([Map<String, String> prefs = const <String, String>{}]) =>
      ThemeNotifier(database, () => const TextTheme())
        ..loadFromPrefsSnapshot(<String, String>{
          'design_system': PrefCodec.encode('material'),
          'app_theme_key': PrefCodec.encode('m3-baseline'),
          'brightness_mode': PrefCodec.encode('light'),
          ...prefs,
        });

  double hueOf(Color c) => Hct.fromInt(c.toARGB32()).hue;

  double hueDistance(double a, double b) {
    final double d = (a - b).abs() % 360;
    return d > 180 ? 360 - d : d;
  }

  Color primary() => notifier.buildColorScheme(Brightness.light).primary;

  /// 导入后的文件路径 → 候选色：导入写的是新文件名，按「目录里唯一那张横屏图」认。
  void seedImported(List<int> seeds) {
    ThemeNotifier.pageBackdropSeedExtractor = (String path) async =>
        seedsByPath[path] ?? seeds;
  }

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('fushi-backdrop-accent-');
    store = Directory('${scratch.path}/store');
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    seedsByPath = <String, List<int>>{};
    ThemeNotifier.pageBackdropImageDirectory = () async => store;
    seedImported(const <int>[green, red]);
  });

  tearDown(() async {
    notifier.dispose();
    ThemeNotifier.pageBackdropSeedExtractor = originalExtractor;
    ThemeNotifier.pageBackdropImageDirectory = originalDirectory;
    pageBackdropSettings.value = const PageBackdropSettings();
    pageBackdropModuleOverrides.value =
        const <HomeTab, PageBackdropModuleOverride>{};
    await database.close();
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  File source(String name) =>
      File('${scratch.path}/$name')..writeAsBytesSync(<int>[1, 2, 3, 4]);

  test('导入横屏图：复制进数据目录、切到自定义预设、取色覆盖主题', () async {
    notifier = build();
    final Color baseline = primary();
    final File original = source('photo.jpg');

    await notifier.importPageBackdropImage(original, portrait: false);

    final String? stored = pageBackdropSettings.value.landscapeImagePath;
    expect(stored, isNotNull);
    expect(stored, startsWith(store.path));
    expect(stored, endsWith('.jpg'));
    expect(original.existsSync(), isTrue, reason: '用户原图不能动');
    expect(notifier.pageBackdropPreset, PageBackdropPreset.custom);
    expect(pageBackdropSettings.value.hasCustomImage, isTrue);
    expect(notifier.pageBackdropSeedCandidates, const <Color>[
      Color(green),
      Color(red),
    ]);
    expect(notifier.pageBackdropAccentSeed, const Color(green));
    expect(primary(), isNot(baseline));
    expect(
      hueDistance(hueOf(primary()), hueOf(const Color(green))),
      lessThan(30),
    );
  });

  test('选第二个候选色；关掉取色回到原主题', () async {
    notifier = build();
    final Color baseline = primary();
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);

    await notifier.setPageBackdropAccentIndex(1);
    expect(notifier.pageBackdropAccentSeed, const Color(red));
    expect(
      hueDistance(hueOf(primary()), hueOf(const Color(red))),
      lessThan(30),
    );

    await notifier.setFollowPageBackdropAccent(false);
    expect(notifier.pageBackdropAccentSeed, isNull);
    expect(primary(), baseline);
  });

  test('切回形状预设：取色不再生效，换回自定义又恢复', () async {
    notifier = build();
    final Color baseline = primary();
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);

    await notifier.setPageBackdropPreset(PageBackdropPreset.wave);
    expect(notifier.pageBackdropAccentSeed, isNull);
    expect(primary(), baseline);

    await notifier.setPageBackdropPreset(PageBackdropPreset.custom);
    expect(notifier.pageBackdropAccentSeed, const Color(green));
  });

  test('换图删掉自己复制的旧文件；竖屏图可单独设、可清掉', () async {
    notifier = build();
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);
    final String first = pageBackdropSettings.value.landscapeImagePath!;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await notifier.importPageBackdropImage(source('b.png'), portrait: false);
    final String second = pageBackdropSettings.value.landscapeImagePath!;
    expect(second, isNot(first));
    expect(File(first).existsSync(), isFalse);
    expect(File(second).existsSync(), isTrue);

    await notifier.importPageBackdropImage(source('p.png'), portrait: true);
    final String? portrait = pageBackdropSettings.value.portraitImagePath;
    expect(portrait, isNotNull);
    expect(pageBackdropSettings.value.imagePathFor(portrait: true), portrait);
    expect(pageBackdropSettings.value.imagePathFor(portrait: false), second);

    await notifier.clearPageBackdropPortraitImage();
    expect(pageBackdropSettings.value.portraitImagePath, isNull);
    expect(File(portrait!).existsSync(), isFalse);
    expect(pageBackdropSettings.value.imagePathFor(portrait: true), second);
  });

  test('冷启动先用取色缓存，文件没变不重取', () async {
    final File image = File('${scratch.path}/kept.png')
      ..writeAsBytesSync(<int>[9, 9, 9]);
    final FileStat stat = image.statSync();
    final String stamp = '${stat.modified.millisecondsSinceEpoch}:${stat.size}';
    int extractions = 0;
    ThemeNotifier.pageBackdropSeedExtractor = (String path) async {
      extractions++;
      return const <int>[green];
    };
    notifier = build(<String, String>{
      kPageBackdropPresetPrefKey: PrefCodec.encode('custom'),
      kPageBackdropLandscapeImagePrefKey: PrefCodec.encode(image.path),
      kPageBackdropSeedCachePrefKey: PrefCodec.encode(
        '${image.path}|$stamp|$red',
      ),
    });
    // 同步首帧就是缓存里的颜色，不先闪一下原主题。
    expect(notifier.pageBackdropAccentSeed, const Color(red));
    await notifier.refreshPageBackdropSeeds();
    expect(extractions, 0);
    expect(notifier.pageBackdropAccentSeed, const Color(red));
  });

  test('偏好里的图在这台设备上不存在：回落角落形状、不取色', () async {
    notifier = build(<String, String>{
      kPageBackdropPresetPrefKey: PrefCodec.encode('custom'),
      kPageBackdropLandscapeImagePrefKey: PrefCodec.encode(
        '${scratch.path}/other-device.png',
      ),
    });
    // 发布快照不做同步文件 IO：没核对过的路径先按存在发布……
    expect(pageBackdropSettings.value.hasCustomImage, isTrue);
    // ……异步核对出不存在后重发布。
    await notifier.refreshPageBackdropSeeds();
    expect(pageBackdropSettings.value.hasCustomImage, isFalse);
    expect(
      pageBackdropSettings.value.effectivePreset,
      PageBackdropPreset.corner,
    );
    expect(notifier.pageBackdropAccentSeed, isNull);
  });

  // ── 按模块单独设置（反馈 DYI1IOZxSM）────────────────────────────────

  test('模块单独导入图片：只改这个模块，全局与应用配色不动', () async {
    final List<String> extracted = <String>[];
    ThemeNotifier.pageBackdropSeedExtractor = (String path) async {
      extracted.add(path);
      return const <int>[green, red];
    };
    notifier = build();
    await notifier.importPageBackdropImage(
      source('global.png'),
      portrait: false,
    );
    final PageBackdropSettings global = pageBackdropSettings.value;
    final Color accent = primary();
    expect(notifier.pageBackdropAccentSeed, const Color(green));
    extracted.clear();

    // 模块图取出来会是红色——但配色必须仍是全局图的绿色。
    ThemeNotifier.pageBackdropSeedExtractor = (String path) async {
      extracted.add(path);
      return const <int>[red];
    };
    await notifier.importPageBackdropModuleImage(
      HomeTab.books,
      source('books.png'),
      portrait: false,
    );

    final PageBackdropModuleOverride? books =
        pageBackdropModuleOverrides.value[HomeTab.books];
    expect(books, isNotNull);
    expect(books!.preset, PageBackdropPreset.custom);
    expect(books.landscapeImagePath, startsWith(store.path));
    expect(File(books.landscapeImagePath!).existsSync(), isTrue);
    expect(pageBackdropSettings.value, global, reason: '全局背景不受影响');
    expect(
      pageBackdropSettingsFor(HomeTab.books).landscapeImagePath,
      books.landscapeImagePath,
    );
    expect(pageBackdropSettingsFor(HomeTab.video), global);
    expect(extracted, isEmpty, reason: '模块图片不取色');
    expect(notifier.pageBackdropAccentSeed, const Color(green));
    expect(primary(), accent);
  });

  test('模块单独设形状预设；恢复跟随全局连同模块图片一起删', () async {
    notifier = build();
    await notifier.setPageBackdropModulePreset(
      HomeTab.video,
      PageBackdropPreset.mesh,
    );
    expect(
      pageBackdropSettingsFor(HomeTab.video).preset,
      PageBackdropPreset.mesh,
    );
    expect(
      pageBackdropSettingsFor(HomeTab.books).preset,
      PageBackdropPreset.corner,
    );

    await notifier.importPageBackdropModuleImage(
      HomeTab.video,
      source('v.png'),
      portrait: false,
    );
    await notifier.importPageBackdropModuleImage(
      HomeTab.video,
      source('vp.png'),
      portrait: true,
    );
    final PageBackdropModuleOverride video =
        pageBackdropModuleOverrides.value[HomeTab.video]!;
    expect(video.portraitImagePath, isNotNull);

    await notifier.clearPageBackdropModulePortraitImage(HomeTab.video);
    expect(
      pageBackdropModuleOverrides.value[HomeTab.video]!.portraitImagePath,
      isNull,
    );
    expect(File(video.portraitImagePath!).existsSync(), isFalse);

    await notifier.setPageBackdropModulePreset(HomeTab.video, null);
    expect(pageBackdropModuleOverrides.value, isEmpty);
    expect(File(video.landscapeImagePath!).existsSync(), isFalse);
    expect(pageBackdropSettingsFor(HomeTab.video), pageBackdropSettings.value);
  });

  test('模块设置随偏好加载发布；模块图在这台设备上不在时退回全局', () async {
    notifier = build(<String, String>{
      kPageBackdropPresetPrefKey: PrefCodec.encode('wave'),
      kPageBackdropModulePresetsPrefKey: PrefCodec.encode(
        '{"books":"custom","music":"arc"}',
      ),
      kPageBackdropModuleImagesPrefKey: PrefCodec.encode(
        jsonEncode(<String, Object>{
          'books': <String, String>{'landscape': '${scratch.path}/gone.png'},
        }),
      ),
    });
    expect(
      pageBackdropSettingsFor(HomeTab.music).preset,
      PageBackdropPreset.arc,
    );
    expect(pageBackdropSettingsFor(HomeTab.books).hasCustomImage, isTrue);

    await notifier.refreshPageBackdropSeeds();
    expect(
      pageBackdropModuleOverrides.value[HomeTab.books]!.landscapeImagePath,
      isNull,
    );
    expect(pageBackdropSettingsFor(HomeTab.books), pageBackdropSettings.value);
    expect(
      pageBackdropSettingsFor(HomeTab.books).preset,
      PageBackdropPreset.wave,
    );
  });
}
