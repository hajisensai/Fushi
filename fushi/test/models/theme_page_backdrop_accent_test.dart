import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/page_backdrop_style.dart';
import 'package:fushi/src/utils/misc/app_icon_preferences.dart';
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

  // ── 主题选择与取色覆盖：点色卡要真的换主题 ──────────────────────────────

  test('取色生效时报告覆盖来源；在主题选择里点色卡：关掉取色、显示所选主题、背景图保留', () async {
    notifier = build();
    final Color blue = ThemeNotifier.buildPresetColorScheme(
      ThemeNotifier.themePresets['m3-blue']!,
      Brightness.light,
    ).primary;
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);
    expect(
      notifier.activeAccentOverrideSource,
      ThemeAccentOverrideSource.pageBackdrop,
    );

    await notifier.pickAppThemeKey('m3-blue');

    expect(notifier.appThemeKey, 'm3-blue');
    expect(notifier.followPageBackdropAccent, isFalse);
    expect(notifier.pageBackdropAccentSeed, isNull);
    expect(notifier.activeAccentOverrideSource, isNull);
    expect(primary(), blue);
    expect(
      pageBackdropSettings.value.hasCustomImage,
      isTrue,
      reason: '只关取色，不动背景图',
    );
  });

  test('没有取色覆盖时点色卡：不碰「从图片取色」开关', () async {
    notifier = build();
    await notifier.pickAppThemeKey('m3-blue');
    expect(notifier.appThemeKey, 'm3-blue');
    expect(notifier.activeAccentOverrideSource, isNull);
    expect(notifier.followPageBackdropAccent, isTrue);
  });

  test('setAppThemeKey 只换键（删除自定义主题后的回落等非用户选择）：不关取色', () async {
    notifier = build();
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);
    await notifier.setAppThemeKey('m3-blue');
    expect(notifier.followPageBackdropAccent, isTrue);
    expect(notifier.pageBackdropAccentSeed, const Color(green));
  });

  test('点色卡：关取色与换主题同一次通知、监听者从不看到「取色已关、主题未换」的中间态', () async {
    notifier = build();
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);
    final Color blue = ThemeNotifier.buildPresetColorScheme(
      ThemeNotifier.themePresets['m3-blue']!,
      Brightness.light,
    ).primary;
    final List<Color> seen = <Color>[];
    void listener() => seen.add(primary());
    notifier.addListener(listener);

    await notifier.pickAppThemeKey('m3-blue');
    notifier.removeListener(listener);

    expect(seen, <Color>[blue]);
  });

  test('背景图取色与图标取色同时生效：点色卡两个都关，不会落到图标取色上', () async {
    final Future<int?> Function(String) originalIconExtractor =
        ThemeNotifier.appIconSeedExtractor;
    addTearDown(() {
      ThemeNotifier.appIconSeedExtractor = originalIconExtractor;
      currentAppIconSelection.value = const AppIconSelection(
        presetKey: 'default',
      );
    });
    final File icon = source('icon.png');
    ThemeNotifier.appIconSeedExtractor = (String _) async => red;
    currentAppIconSelection.value = AppIconSelection(
      presetKey: customIconKey,
      customPath: icon.path,
    );
    notifier = build();
    await notifier.setFollowAppIconAccent(true);
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);
    expect(notifier.appIconAccentSeed, const Color(red));
    expect(
      notifier.activeAccentOverrideSource,
      ThemeAccentOverrideSource.pageBackdrop,
    );

    await notifier.pickAppThemeKey('m3-blue');

    expect(notifier.followPageBackdropAccent, isFalse);
    expect(notifier.followAppIconAccent, isFalse);
    expect(notifier.activeAccentOverrideSource, isNull);
    expect(
      primary(),
      ThemeNotifier.buildPresetColorScheme(
        ThemeNotifier.themePresets['m3-blue']!,
        Brightness.light,
      ).primary,
    );
  });

  test('点色卡落库：开关与主题键同一批写进偏好库，重载后仍是所选主题', () async {
    notifier = build();
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);
    await notifier.pickAppThemeKey('m3-blue');

    final Map<String, String> stored = await database.getAllPrefs();
    expect(stored['app_theme_key'], PrefCodec.encode('m3-blue'));
    expect(
      stored[kPageBackdropFollowImageAccentPrefKey],
      PrefCodec.encode(false),
    );
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

  test('背景图按配置记：旧图还被别的配置用着就不删，没人用了才删', () async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    Future<int> profile(String name) => database.insertProfile(
      ProfilesCompanion.insert(name: name, createdAt: now, updatedAt: now),
    );
    final int a = await profile('A');
    final int b = await profile('B');
    final String uidA = await database.profileUidOf(a);
    final String uidB = await database.profileUidOf(b);
    const String parkedPrefix = 'page_backdrop_image_landscape::';

    /// 与 ProfileRepository 切配置时同一结果：live 值停放到 [fromUid] 名下，[restore] 换回 live。
    Future<void> switchProfile(String fromUid, int to, String? restore) async {
      final String? live = await database.getPref(
        kPageBackdropLandscapeImagePrefKey,
      );
      await database.setPref('$parkedPrefix$fromUid', live ?? '');
      await database.setPref(kActiveProfileIdPrefKey, '$to');
      if (restore != null) {
        await database.setPref(kPageBackdropLandscapeImagePrefKey, restore);
      }
      await notifier.refreshFromDb();
    }

    await database.setPref(kActiveProfileIdPrefKey, '$a');
    notifier = build();
    await notifier.importPageBackdropImage(source('x.png'), portrait: false);
    final String x = pageBackdropSettings.value.landscapeImagePath!;

    // 切到 B（没停放过，沿用 x），B 换成 y：x 还是 A 的图，不能删。
    await switchProfile(uidA, b, null);
    expect(pageBackdropSettings.value.landscapeImagePath, x);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await notifier.importPageBackdropImage(source('y.png'), portrait: false);
    final String y = pageBackdropSettings.value.landscapeImagePath!;
    expect(File(x).existsSync(), isTrue, reason: 'A 还停放着 x');

    // 切回 A：拿回 x。A 换成 z：x 只剩 A 自己的旧停放值指着，删；y 是 B 的，留。
    await switchProfile(uidB, a, PrefCodec.encode(x));
    expect(pageBackdropSettings.value.landscapeImagePath, x);
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await notifier.importPageBackdropImage(source('z.png'), portrait: false);
    final String z = pageBackdropSettings.value.landscapeImagePath!;
    expect(File(x).existsSync(), isFalse);
    expect(File(y).existsSync(), isTrue, reason: 'B 还停放着 y');
    expect(File(z).existsSync(), isTrue);

    // B 被删掉（停放键随之清掉）：y 成了孤儿，下一次换图时收掉。
    await database.deletePref('$parkedPrefix$uidB');
    await notifier.importPageBackdropImage(source('p.png'), portrait: true);
    expect(File(y).existsSync(), isFalse);
    expect(File(z).existsSync(), isTrue);
  });

  test('并发换图排队执行：后一次刚复制的文件不会被前一次的清扫删掉', () async {
    notifier = build();
    await Future.wait(<Future<void>>[
      notifier.importPageBackdropImage(source('l.png'), portrait: false),
      notifier.importPageBackdropImage(source('p.png'), portrait: true),
      notifier.importPageBackdropModuleImage(
        HomeTab.video,
        source('v.png'),
        portrait: false,
      ),
    ]);
    final PageBackdropSettings settings = pageBackdropSettings.value;
    expect(File(settings.landscapeImagePath!).existsSync(), isTrue);
    expect(File(settings.portraitImagePath!).existsSync(), isTrue);
    expect(
      File(
        pageBackdropModuleOverrides.value[HomeTab.video]!.landscapeImagePath!,
      ).existsSync(),
      isTrue,
    );
    expect(store.listSync().whereType<File>(), hasLength(3));
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

  test('非激活配置的只读视图按它自己停放的图与取色缓存取色，不借激活配置那张图', () async {
    notifier = build();
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);
    expect(notifier.pageBackdropAccentSeed, const Color(green));

    // 另一份配置停放的是自己的图与取色缓存（loadSettingsView 把停放值换进视图偏好）。
    final String other = '${scratch.path}/other-profile.png';
    final ThemeNotifier view =
        ThemeNotifier.profileView(notifier, <String, String>{
          'design_system': PrefCodec.encode('material'),
          'app_theme_key': PrefCodec.encode('m3-baseline'),
          kPageBackdropPresetPrefKey: PrefCodec.encode('custom'),
          kPageBackdropLandscapeImagePrefKey: PrefCodec.encode(other),
          kPageBackdropSeedCachePrefKey: PrefCodec.encode('$other|1:1|$red'),
        });
    expect(view.pageBackdropAccentSeed, const Color(red));
    view.dispose();

    // 那份配置没选自定义图片：激活配置的图再怎么取色，视图也不被覆盖。
    final ThemeNotifier plain =
        ThemeNotifier.profileView(notifier, <String, String>{
          'design_system': PrefCodec.encode('material'),
          'app_theme_key': PrefCodec.encode('m3-baseline'),
        });
    expect(plain.pageBackdropAccentSeed, isNull);
    plain.dispose();

    // 与激活配置同一张图：沿用 live 已取到的颜色。
    final ThemeNotifier same =
        ThemeNotifier.profileView(notifier, <String, String>{
          'design_system': PrefCodec.encode('material'),
          'app_theme_key': PrefCodec.encode('m3-baseline'),
          kPageBackdropPresetPrefKey: PrefCodec.encode('custom'),
          kPageBackdropLandscapeImagePrefKey: PrefCodec.encode(
            pageBackdropSettings.value.landscapeImagePath!,
          ),
        });
    expect(same.pageBackdropAccentSeed, const Color(green));
    same.dispose();
  });

  test('偏好里的图在这台设备上不存在：回落默认样式、不取色', () async {
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
    expect(pageBackdropSettings.value.effectivePreset, PageBackdropPreset.mesh);
    expect(notifier.pageBackdropAccentSeed, isNull);
  });

  // ── BUG-5370：iOS 更新换容器 UUID / 换数据根后背景图不能丢 ─────────────

  test('导入只存文件名：背景图目录整体换了根，重启后图照样解析到新位置', () async {
    notifier = build();
    await notifier.importPageBackdropImage(source('a.png'), portrait: false);
    await notifier.importPageBackdropImage(source('b.png'), portrait: true);
    await notifier.importPageBackdropModuleImage(
      HomeTab.books,
      source('c.png'),
      portrait: false,
    );
    final String landscapeName = pageBackdropImageFileName(
      pageBackdropSettings.value.landscapeImagePath!,
    );
    final Map<String, String> stored = await database.getAllPrefs();
    expect(
      PrefCodec.decodeUntyped(stored[kPageBackdropLandscapeImagePrefKey]!),
      landscapeName,
      reason: '偏好只存文件名，不烧进容器根',
    );
    expect(
      PrefCodec.decodeUntyped(stored[kPageBackdropPortraitImagePrefKey]!),
      isNot(contains(store.path)),
    );
    expect(
      PrefCodec.decodeUntyped(stored[kPageBackdropModuleImagesPrefKey]!),
      isNot(contains(store.path)),
    );
    await notifier.pageBackdropImagesSettled;
    notifier.dispose();

    // iOS 装新构建：容器 UUID 变了，support 根连同 page_backdrop 目录一起到了新位置。
    final Directory moved = Directory('${scratch.path}/new-container/store');
    moved.parent.createSync(recursive: true);
    store.renameSync(moved.path);
    ThemeNotifier.pageBackdropImageDirectory = () async => moved;
    pageBackdropSettings.value = const PageBackdropSettings();
    notifier = build(await database.getAllPrefs());
    await notifier.pageBackdropImagesSettled;

    final PageBackdropSettings after = pageBackdropSettings.value;
    expect(after.hasCustomImage, isTrue);
    expect(after.landscapeImagePath, startsWith(moved.path));
    expect(File(after.landscapeImagePath!).existsSync(), isTrue);
    expect(File(after.portraitImagePath!).existsSync(), isTrue);
    final String books =
        pageBackdropModuleOverrides.value[HomeTab.books]!.landscapeImagePath!;
    expect(books, startsWith(moved.path));
    expect(File(books).existsSync(), isTrue);
    expect(notifier.pageBackdropAccentSeed, const Color(green));
  });

  test('存量绝对路径（旧容器根）：载入时按文件名改写 live、模块与各配置停放的值', () async {
    store.createSync(recursive: true);
    for (final String name in <String>[
      'landscape-1.jpg',
      'portrait-2.jpg',
      'module-books-landscape-3.jpg',
      'landscape-4.jpg',
      'module-video-landscape-5.jpg',
    ]) {
      File('${store.path}/$name').writeAsBytesSync(<int>[1, 2, 3]);
    }
    // 旧容器里的路径：文件已随目录搬到 [store]，这些绝对路径本身全悬空。
    String old(String name) =>
        '${scratch.path}/OLD-CONTAINER-UUID/Library/page_backdrop/$name';
    final String gone = old('landscape-0-not-here.jpg');
    final Map<String, String> prefs = <String, String>{
      kPageBackdropPresetPrefKey: PrefCodec.encode('custom'),
      kPageBackdropLandscapeImagePrefKey: PrefCodec.encode(
        old('landscape-1.jpg'),
      ),
      kPageBackdropPortraitImagePrefKey: PrefCodec.encode(
        old('portrait-2.jpg'),
      ),
      kPageBackdropModulePresetsPrefKey: PrefCodec.encode(
        jsonEncode(<String, String>{'books': 'custom'}),
      ),
      kPageBackdropModuleImagesPrefKey: PrefCodec.encode(
        jsonEncode(<String, Object>{
          'books': <String, String>{
            'landscape': old('module-books-landscape-3.jpg'),
          },
        }),
      ),
      'page_backdrop_image_landscape::uid-other': PrefCodec.encode(
        old('landscape-4.jpg'),
      ),
      'page_backdrop_image_portrait::uid-other': PrefCodec.encode(gone),
      'page_backdrop_module_images::uid-other': PrefCodec.encode(
        jsonEncode(<String, Object>{
          'video': <String, String>{
            'landscape': old('module-video-landscape-5.jpg'),
          },
        }),
      ),
    };
    for (final MapEntry<String, String> e in prefs.entries) {
      await database.setPref(e.key, e.value);
    }

    notifier = build(prefs);
    await notifier.pageBackdropImagesSettled;

    final PageBackdropSettings settings = pageBackdropSettings.value;
    expect(settings.hasCustomImage, isTrue);
    expect(
      settings.landscapeImagePath,
      resolvePageBackdropImagePath('landscape-1.jpg', directory: store.path),
    );
    expect(File(settings.portraitImagePath!).existsSync(), isTrue);
    expect(
      File(
        pageBackdropModuleOverrides.value[HomeTab.books]!.landscapeImagePath!,
      ).existsSync(),
      isTrue,
    );

    Object? read(Map<String, String> all, String key) =>
        PrefCodec.decodeUntyped(all[key]!);
    final Map<String, String> all = await database.getAllPrefs();
    expect(read(all, kPageBackdropLandscapeImagePrefKey), 'landscape-1.jpg');
    expect(read(all, kPageBackdropPortraitImagePrefKey), 'portrait-2.jpg');
    expect(
      decodePageBackdropModuleImages(
        read(all, kPageBackdropModuleImagesPrefKey),
      )[HomeTab.books]!.landscape,
      'module-books-landscape-3.jpg',
    );
    expect(
      read(all, 'page_backdrop_image_landscape::uid-other'),
      'landscape-4.jpg',
    );
    expect(
      decodePageBackdropModuleImages(
        read(all, 'page_backdrop_module_images::uid-other'),
      )[HomeTab.video]!.landscape,
      'module-video-landscape-5.jpg',
    );
    expect(
      read(all, 'page_backdrop_image_portrait::uid-other'),
      gone,
      reason: '目录里没有的文件不改写，照旧按不存在处理',
    );

    // 换一张图触发清扫：停放配置引用的文件（按文件名比）一个都不能被当孤儿删。
    await notifier.importPageBackdropImage(source('new.png'), portrait: false);
    expect(File('${store.path}/landscape-1.jpg').existsSync(), isFalse);
    for (final String kept in <String>[
      'portrait-2.jpg',
      'module-books-landscape-3.jpg',
      'landscape-4.jpg',
      'module-video-landscape-5.jpg',
    ]) {
      expect(File('${store.path}/$kept').existsSync(), isTrue, reason: kept);
    }
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
      PageBackdropPreset.mesh,
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

  test('没存过背景样式（新装 / 恢复默认删键）默认柔光晕染', () {
    notifier = build();
    expect(notifier.pageBackdropPreset, PageBackdropPreset.mesh);
    expect(pageBackdropSettings.value.preset, PageBackdropPreset.mesh);
  });

  test('存量「角落形状」偏好（全局与按模块）读成柔光晕染，不改写持久化值', () {
    notifier = build(<String, String>{
      kPageBackdropPresetPrefKey: PrefCodec.encode('corner'),
      kPageBackdropModulePresetsPrefKey: PrefCodec.encode('{"video":"corner"}'),
    });
    expect(notifier.pageBackdropPreset, PageBackdropPreset.mesh);
    expect(pageBackdropSettings.value.preset, PageBackdropPreset.mesh);
    expect(
      pageBackdropModuleOverrides.value[HomeTab.video]?.preset,
      PageBackdropPreset.mesh,
    );
  });
}
