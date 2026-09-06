import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 防回归守卫：默认图标=文字、Windows 运行时切换通道存在、设置页跨平台。
/// 这些是无法用 widget 测试覆盖的「跨语言契约 / 资源引用」，用源码扫描兜底。
void main() {
  String read(String relative) {
    // 测试在 fushi/ 下运行；相对路径即相对该目录。
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
    return f.readAsStringSync();
  }

  test('Android 默认启动器图标引用不透明白 squircle 资源（TODO-1241）', () {
    final String manifest = read('android/app/src/main/AndroidManifest.xml');
    // <application> 默认图标应指向 squircle（不透明白，任意壁纸可见）。
    final RegExp appIcon = RegExp(
      r'android:name="\$\{applicationName\}"[\s\S]*?android:icon="@mipmap/launcher_icon_squircle"',
    );
    expect(appIcon.hasMatch(manifest), isTrue,
        reason: '<application> 默认图标应引用 launcher_icon_squircle');
    // 默认 alias 也应引用 squircle。
    final RegExp defaultAlias = RegExp(
      r'MainActivityDefault[\s\S]*?android:icon="@mipmap/launcher_icon_squircle"',
    );
    expect(defaultAlias.hasMatch(manifest), isTrue,
        reason: '.MainActivityDefault 应引用 launcher_icon_squircle');
    // squircle mipmap 资源（自适应 xml + 至少一档 legacy png）必须存在。
    expect(
        File('android/app/src/main/res/mipmap-anydpi-v26/launcher_icon_squircle.xml')
            .existsSync(),
        isTrue,
        reason: '缺失 launcher_icon_squircle 自适应图标 xml');
    expect(
        File('android/app/src/main/res/mipmap-xxxhdpi/launcher_icon_squircle.png')
            .existsSync(),
        isTrue,
        reason: '缺失 launcher_icon_squircle legacy png');
  });

  test('退役档（立绘 / 透明 wordmark）资源已删且 manifest 无悬空引用', () {
    final String manifest = read('android/app/src/main/AndroidManifest.xml');
    // 三个退役 alias 的图标必须改指向存活的 squircle：资源已删，留着旧引用会让
    // aapt 打包直接失败。
    for (final String alias in <String>[
      'MainActivityFushiFull',
      'MainActivityFushiTransparent',
      'MainActivityFushiMinimal',
    ]) {
      final RegExp ref = RegExp(
        '$alias' r'[\s\S]{0,400}?android:icon="@mipmap/([a-z_0-9]+)"',
      );
      final RegExpMatch? m = ref.firstMatch(manifest);
      expect(m, isNotNull, reason: '$alias 应仍声明并带 android:icon');
      expect(m!.group(1), 'launcher_icon_squircle',
          reason: '$alias 的图标必须指向存活的 launcher_icon_squircle，'
              '旧的 launcher_icon_full / launcher_icon_minimal 资源已删除');
    }
    // 整个 res 树不得再引用已删资源。
    expect(manifest.contains('launcher_icon_full'), isFalse);
    expect(manifest.contains('launcher_icon_minimal'), isFalse);

    // 被删的资源确实不在磁盘上（否则「已删除」这一前提本身就是假的）。
    for (final String rel in <String>[
      'android/app/src/main/res/mipmap-anydpi-v26/launcher_icon_full.xml',
      'android/app/src/main/res/mipmap-anydpi-v26/launcher_icon_minimal.xml',
      'android/app/src/main/res/mipmap-xxxhdpi/launcher_icon_full.png',
      'android/app/src/main/res/mipmap-xxxhdpi/launcher_icon_minimal.png',
      'android/app/src/main/res/drawable-xxxhdpi/ic_launcher_full_foreground.png',
      'android/app/src/main/res/drawable-xxxhdpi/ic_launcher_minimal_foreground.png',
      'assets/meta/launcher_icon_full.png',
      'assets/meta/launcher_icon_minimal.png',
    ]) {
      expect(File(rel).existsSync(), isFalse, reason: '$rel 应已随预设下线删除');
    }
  });

  test('Windows runner 暴露 setWindowIcon 通道方法', () {
    final String cpp = read('windows/runner/flutter_window.cpp');
    expect(cpp.contains('"setWindowIcon"'), isTrue);
    expect(cpp.contains('ApplyWindowIcon'), isTrue);
    expect(cpp.contains('WM_SETICON'), isTrue);
  });

  test('Dart 侧有 setWindowIcon 封装', () {
    final String dart = read('lib/src/utils/window_caption_channel.dart');
    expect(dart.contains('setWindowIcon'), isTrue);
  });

  test('设置页图标网格对 Windows 可见', () {
    final String page =
        read('lib/src/pages/implementations/miscellaneous_settings_page.dart');
    expect(page.contains('Platform.isWindows'), isTrue);
    final String schema =
        read('lib/src/settings/settings_schema_appearance.dart');
    expect(schema.contains('Platform.isWindows'), isTrue);
  });

  test('BUG-1920：设置、启动恢复与宽屏 rail 共用可监听的当前图标真值', () {
    final String prefs = read('lib/src/utils/misc/app_icon_preferences.dart');
    final String page =
        read('lib/src/pages/implementations/miscellaneous_settings_page.dart');
    final String home = read('lib/src/pages/implementations/home_page.dart');
    final String main = read('lib/main.dart');
    final String component =
        read('lib/src/utils/components/current_app_icon.dart');

    expect(prefs.contains('currentAppIconSelection'), isTrue);
    expect(prefs.contains('appIconDecodePixelWidth = 256'), isTrue,
        reason: '侧栏不得按原尺寸解码用户选择的相机/8K 图片');
    expect(
        prefs.contains('await appIconImageProvider(resolved).evict()'), isTrue,
        reason: '固定自定义路径覆盖内容后必须清掉旧 ResizeImage cache');
    expect(page.contains('saveAppIconSelection('), isTrue,
        reason: '预设与自定义成功路径必须在持久化后发布运行时选择');
    expect(page.contains('_persistAppliedIcon('), isTrue,
        reason: '原生切换成功后即使偏好写入失败，rail 也必须同步本次运行态');
    expect(page.contains('saveIconPresetKey('), isFalse);
    expect(page.contains('saveCustomIconPath('), isFalse);
    // rail 的品牌位已从 home_page 的私有方法抽成 NavRailBrandButton（它同时是
    // 官网入口，需要独立可测）：home_page 只剩「rail 确实挂了品牌位」，图标真值
    // 判据跟着实现搬进该组件。
    final String brand =
        read('lib/src/utils/components/nav_rail_brand_button.dart');
    expect(home.contains('leading: const NavRailBrandButton()'), isTrue,
        reason: 'rail 必须挂品牌位，否则下面两条判据会在一个没人用的文件上空转');
    expect(brand.contains('child: const CurrentAppIcon()'), isTrue,
        reason: 'rail 不得再读取 AppModel 中固定的 assets/meta/icon.png');
    expect(brand.contains('child: DecoratedBox('), isFalse,
        reason: 'rail 应直接显示应用图标，不得再套卡片底色和描边');
    expect(
        component.contains('ValueListenableBuilder<AppIconSelection>'), isTrue);
    expect(
        main.contains('startupAppIcon = await loadAppIconSelection()'), isTrue,
        reason: 'runApp 前必须恢复选择，避免第一帧画旧图标');
    expect(main.contains("'getCurrentIcon'"), isTrue,
        reason: 'Android 冷启动必须以 launcher alias 为当前图标真值');
    expect(main.contains('appIconImageProvider(startupAppIcon)'), isTrue,
        reason: '启动预缓存必须与 rail 共用同一个 provider 映射');
    expect(main.contains("AssetImage('assets/meta/icon.png')"), isFalse,
        reason: '启动路径不得再固定预缓存旧品牌图');
  });

  test('Windows app icon 用已提交的 app_icon.ico wordmark', () {
    // TODO-879（f9f5bb380）删除了 flutter_launcher_icons 配置块（generator 会
    // 覆盖手调 adaptive 图标），Windows 改用已提交的 app_icon.ico。
    // 守卫真实不变量：已提交的 ico 存在且非空 + Runner.rc 引用它。
    final File ico = File('windows/runner/resources/app_icon.ico');
    expect(ico.existsSync(), isTrue,
        reason: '缺失已提交的 Windows 图标: windows/runner/resources/app_icon.ico');
    expect(ico.lengthSync() > 0, isTrue,
        reason: 'app_icon.ico 不应为空（应是文字 wordmark 图标）');

    final String rc = read('windows/runner/Runner.rc');
    // .rc 里路径用双反斜杠转义：resources\app_icon.ico。
    final RegExp iconRef = RegExp(
      r'IDI_APP_ICON\s+ICON\s+"resources\\\\app_icon\.ico"',
    );
    expect(iconRef.hasMatch(rc), isTrue,
        reason: 'Runner.rc 应以 IDI_APP_ICON 引用 resources\\\\app_icon.ico');
  });

  test('Android 12+ 系统 splash 图标用专用 splash wordmark 前景（TODO-886）', () {
    // TODO-886：splash 前景改用专用 ic_splash_minimal_foreground（内容窄于
    // 自适应安全区），避免启动器前景 wordmark 太宽被圆遮罩裁切。
    // 几何断言详见 test/android/splash_icon_guard_test.dart。
    for (final String rel in <String>[
      'android/app/src/main/res/values-v31/styles.xml',
      'android/app/src/main/res/values-night-v31/styles.xml',
    ]) {
      final String styles = read(rel);
      expect(
        styles.contains('android:windowSplashScreenAnimatedIcon') &&
            styles.contains('@drawable/ic_splash_minimal_foreground'),
        isTrue,
        reason: '$rel 的 Android 12+ splash 应显示专用 splash wordmark 前景',
      );
    }
  });

  test('预设只剩 default 一档（立绘 / 透明 wordmark 已下线）', () {
    final String prefs = read('lib/src/utils/misc/app_icon_preferences.dart');
    // 数 presetIconAssets 里真实的条目数，而不是「包含某字符串」——后者在
    // map 里多塞一档时不会红。
    final int mapStart =
        prefs.indexOf('const Map<String, String> presetIconAssets');
    expect(mapStart, greaterThanOrEqualTo(0),
        reason: '找不到 presetIconAssets 定义');
    final int mapEnd = prefs.indexOf('};', mapStart);
    final String body = prefs.substring(mapStart, mapEnd);
    final List<String> keys = RegExp(r"'([a-z_0-9]+)':")
        .allMatches(body)
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
    expect(keys, <String>['default'],
        reason: 'presetIconAssets 应只保留 default 一档，实际: $keys');
    expect(body.contains('assets/meta/launcher_icon_squircle.png'), isTrue,
        reason: 'default 预设预览应指向 squircle 资源');

    // 设置页只渲染 default 一个预设 tile。
    final String page =
        read('lib/src/pages/implementations/miscellaneous_settings_page.dart');
    final List<String> tileKeys = RegExp(r"key: '([a-z_0-9]+)',")
        .allMatches(page)
        .map((RegExpMatch m) => m.group(1)!)
        .where((String k) => k != 'custom')
        .toList();
    expect(tileKeys, <String>['default'],
        reason: '设置页应只渲染 default 预设 tile，实际: $tileKeys');
    for (final String gone in <String>[
      't.icon_minimal',
      't.icon_transparent',
      't.icon_full',
    ]) {
      expect(page.contains(gone), isFalse, reason: '设置页不应再引用已删除的 $gone');
    }
  });

  test('Android 老用户安全：退役 alias 仍声明 + IconSwitchHelper 迁移回 default', () {
    // manifest 保留全部退役 alias 声明：老用户若当前启动器指向其中之一，删掉声明
    // 会让升级后 launcher 图标直接消失（zero-LAUNCHER）。
    final String manifest = read('android/app/src/main/AndroidManifest.xml');
    for (final String alias in <String>[
      '.MainActivityFushiMinimal',
      '.MainActivityFushiTransparent',
      '.MainActivityFushiFull',
    ]) {
      expect(manifest.contains(alias), isTrue,
          reason: '退役 alias $alias 必须保留声明（老用户 launcher 安全）');
    }

    final String helper = read(
        'android/app/src/main/java/app/fushi/reader/IconSwitchHelper.java');
    // ALIAS_KEYS 只剩 default：数真实条目，不用「不包含某串」这种反向断言。
    final int keysStart = helper.indexOf('ALIAS_KEYS = Arrays.asList(');
    expect(keysStart, greaterThanOrEqualTo(0));
    final String keysBody =
        helper.substring(keysStart, helper.indexOf(');', keysStart));
    final List<String> keys = RegExp(r'"([a-z_0-9]+)"')
        .allMatches(keysBody)
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
    expect(keys, <String>['default'],
        reason: 'IconSwitchHelper 可选档应只剩 default，实际: $keys');

    // 迁移逻辑覆盖全部三个退役 alias。
    expect(helper.contains('migrateRetiredAliasesIfEnabled'), isTrue,
        reason: '必须提供老用户迁移逻辑，把启用的退役 alias 迁回 default');
    final int retiredStart = helper.indexOf('RETIRED_ALIASES = Arrays.asList(');
    expect(retiredStart, greaterThanOrEqualTo(0));
    final String retiredBody =
        helper.substring(retiredStart, helper.indexOf(');', retiredStart));
    for (final String alias in <String>[
      '.MainActivityFushiMinimal',
      '.MainActivityFushiTransparent',
      '.MainActivityFushiFull',
    ]) {
      expect(retiredBody.contains(alias), isTrue,
          reason: 'RETIRED_ALIASES 必须覆盖 $alias，否则该档老用户迁不回 default');
    }
  });
  test('TODO-1269 回归守卫：所有启动器自适应图标背景必须不透明且非纯黑（纯透明会被渲染成黑）', () {
    // 根因：TODO-1241 把 ic_launcher_minimal_background 从 #FFFFFF 改成纯透明
    // #00000000，adaptive-icon 背景层不能透明——Android 合成到不透明底层、多数
    // 启动器渲染成纯黑，导致老用户（经 IconSwitchHelper 迁到 minimal wordmark）
    // 升级后图标背景全黑。此守卫扫描所有 mipmap-anydpi-v26/launcher_icon*.xml，
    // 解析其 <background> 引用的 @color，再从 values/colors.xml 解析真实色值，
    // 断言：alpha == 0xFF（不透明）且 RGB 非纯黑 (0,0,0)。
    final String colorsXml = read('android/app/src/main/res/values/colors.xml');
    // 解析 colors.xml：name -> #RRGGBB / #AARRGGBB。
    final Map<String, String> colorByName = <String, String>{};
    final RegExp colorRe = RegExp(
      r'<color\s+name="([^"]+)"\s*>\s*(#[0-9A-Fa-f]{6,8})\s*</color>',
    );
    for (final RegExpMatch m in colorRe.allMatches(colorsXml)) {
      colorByName[m.group(1)!] = m.group(2)!;
    }

    // (alpha, r, g, b) 解析：#RRGGBB -> alpha 0xFF；#AARRGGBB -> 显式 alpha。
    List<int> parseArgb(String hex) {
      final String h = hex.substring(1);
      if (h.length == 6) {
        return <int>[
          0xFF,
          int.parse(h.substring(0, 2), radix: 16),
          int.parse(h.substring(2, 4), radix: 16),
          int.parse(h.substring(4, 6), radix: 16),
        ];
      }
      return <int>[
        int.parse(h.substring(0, 2), radix: 16),
        int.parse(h.substring(2, 4), radix: 16),
        int.parse(h.substring(4, 6), radix: 16),
        int.parse(h.substring(6, 8), radix: 16),
      ];
    }

    final Directory adaptiveDir =
        Directory('android/app/src/main/res/mipmap-anydpi-v26');
    expect(adaptiveDir.existsSync(), isTrue,
        reason: '缺失自适应图标目录 mipmap-anydpi-v26');

    final List<FileSystemEntity> iconXmls = adaptiveDir
        .listSync()
        .where((FileSystemEntity e) =>
            e is File &&
            e.uri.pathSegments.last.startsWith('launcher_icon') &&
            e.path.endsWith('.xml'))
        .toList();
    expect(iconXmls, isNotEmpty, reason: '未发现任何 launcher_icon*.xml 自适应图标');

    final RegExp bgRefRe = RegExp(
      r'<background\s+android:drawable="@color/([^"]+)"',
    );
    for (final FileSystemEntity e in iconXmls) {
      final String name = e.uri.pathSegments.last;
      final String xml = (e as File).readAsStringSync();
      final RegExpMatch? bg = bgRefRe.firstMatch(xml);
      // 有的图标背景直接是 png drawable（非 @color），跳过——只校验 @color 背景。
      if (bg == null) continue;
      final String colorName = bg.group(1)!;
      final String? hex = colorByName[colorName];
      expect(hex, isNotNull,
          reason: '$name 引用的 @color/$colorName 在 colors.xml 中未定义');
      final List<int> argb = parseArgb(hex!);
      expect(argb[0], 0xFF,
          reason: '$name 背景 @color/$colorName = $hex 不是不透明（alpha != 0xFF）；'
              '自适应图标背景纯/半透明会被渲染成黑（TODO-1269）');
      final bool isPureBlack = argb[1] == 0 && argb[2] == 0 && argb[3] == 0;
      expect(isPureBlack, isFalse,
          reason: '$name 背景 @color/$colorName = $hex 是纯黑，图标会背景全黑（TODO-1269）');
    }
  });
}
