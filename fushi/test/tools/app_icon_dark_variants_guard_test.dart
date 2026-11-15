import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

/// 反馈 HsUdOMa5eq：应用图标各平台的深色 / 着色 / 主题变体守卫。
///
/// 资源由 `tool/app_icon/gen_app_icon_variants.py` 生成；这里只扫描已提交的
/// 资源与工程引用，防止有人用 Xcode「All Sizes」或 flutter_launcher_icons 重生成
/// 图标时把外观变体静默冲掉。
void main() {
  String read(String relative) {
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
    return f.readAsStringSync();
  }

  /// PNG IHDR：宽、高、color type（0 灰度 / 2 RGB / 3 调色板 / 4 灰度+alpha / 6 RGBA）。
  ({int width, int height, int colorType}) pngHeader(String relative) {
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
    final Uint8List bytes = f.readAsBytesSync();
    const List<int> sig = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    expect(bytes.length, greaterThan(33), reason: '$relative 不是 PNG');
    expect(bytes.sublist(0, 8), sig, reason: '$relative 不是 PNG');
    final ByteData data = ByteData.sublistView(bytes);
    return (
      width: data.getUint32(16),
      height: data.getUint32(20),
      colorType: bytes[25],
    );
  }

  const String iosSet = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';

  test('iOS AppIcon 为 Single Size 并带 dark / tinted 外观变体', () {
    final Map<String, dynamic> contents =
        jsonDecode(read('$iosSet/Contents.json')) as Map<String, dynamic>;
    final List<Map<String, dynamic>> images =
        (contents['images'] as List<dynamic>).cast<Map<String, dynamic>>();

    String? appearanceOf(Map<String, dynamic> image) {
      final List<dynamic>? appearances = image['appearances'] as List<dynamic>?;
      if (appearances == null) return null;
      for (final dynamic a in appearances) {
        final Map<String, dynamic> m = a as Map<String, dynamic>;
        if (m['appearance'] == 'luminosity') return m['value'] as String;
      }
      return null;
    }

    final Map<String?, Map<String, dynamic>> byAppearance =
        <String?, Map<String, dynamic>>{};
    for (final Map<String, dynamic> image in images) {
      // 外观变体只在 Single Size（universal / ios / 1024）下生效；混进
      // 逐尺寸 iphone / ipad 条目会让 Xcode 回到 All Sizes，dark/tinted 失效。
      expect(image['idiom'], 'universal', reason: '非 universal 条目: $image');
      expect(image['platform'], 'ios', reason: '非 ios 平台条目: $image');
      expect(image['size'], '1024x1024', reason: '非 1024 条目: $image');
      final String? appearance = appearanceOf(image);
      expect(
        byAppearance.containsKey(appearance),
        isFalse,
        reason: '外观 $appearance 重复',
      );
      byAppearance[appearance] = image;
    }
    expect(byAppearance.keys.toSet(), <String?>{
      null,
      'dark',
      'tinted',
    }, reason: 'AppIcon 应恰好有 Any / Dark / Tinted 三张');

    final ({int width, int height, int colorType}) any = pngHeader(
      '$iosSet/${byAppearance[null]!['filename']}',
    );
    final ({int width, int height, int colorType}) dark = pngHeader(
      '$iosSet/${byAppearance['dark']!['filename']}',
    );
    final ({int width, int height, int colorType}) tinted = pngHeader(
      '$iosSet/${byAppearance['tinted']!['filename']}',
    );
    for (final ({int width, int height, int colorType}) h
        in <({int width, int height, int colorType})>[any, dark, tinted]) {
      expect(h.width, 1024);
      expect(h.height, 1024);
    }
    // App Store 主图标不得带 alpha。
    expect(<int>[0, 2], contains(any.colorType), reason: 'Any 图标不得带 alpha');
    // 深色变体要透明底，系统才能铺自己的深色底。
    expect(<int>[4, 6], contains(dark.colorType), reason: 'Dark 图标应带 alpha');
    // 着色变体：不透明灰度。
    expect(tinted.colorType, 0, reason: 'Tinted 图标应为不透明灰度');

    // Single Size 下不再引用的逐尺寸 PNG 不得残留（actool 会报 unassigned child）。
    final Set<String> referenced = images
        .map((Map<String, dynamic> i) => i['filename'] as String)
        .toSet();
    for (final FileSystemEntity e in Directory(iosSet).listSync()) {
      final String name = e.uri.pathSegments.last;
      if (name.endsWith('.png')) {
        expect(referenced, contains(name), reason: '$name 未被 Contents.json 引用');
      }
    }
  });

  test('macOS 26+ 用 Icon Composer AppIcon.icon 提供深色外观，旧系统仍有 appiconset', () {
    const String iconDir = 'macos/Runner/AppIcon.icon';
    final Map<String, dynamic> icon =
        jsonDecode(read('$iconDir/icon.json')) as Map<String, dynamic>;
    final List<Map<String, dynamic>> fills =
        (icon['fill-specializations'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
    expect(
      fills.any((Map<String, dynamic> f) => f['appearance'] == 'dark'),
      isTrue,
      reason: 'icon.json 缺深色外观填充',
    );
    expect(
      fills.any((Map<String, dynamic> f) => !f.containsKey('appearance')),
      isTrue,
      reason: 'icon.json 缺默认（浅色）填充',
    );
    int layerCount = 0;
    for (final dynamic g in icon['groups'] as List<dynamic>) {
      for (final dynamic l
          in (g as Map<String, dynamic>)['layers'] as List<dynamic>) {
        final String imageName =
            (l as Map<String, dynamic>)['image-name'] as String;
        expect(
          File('$iconDir/Assets/$imageName').existsSync(),
          isTrue,
          reason: 'icon.json 引用的图层 $imageName 不存在',
        );
        layerCount++;
      }
    }
    expect(layerCount, greaterThan(0));

    final String pbxproj = read('macos/Runner.xcodeproj/project.pbxproj');
    expect(
      RegExp(
        r'/\* AppIcon\.icon \*/ = \{isa = PBXFileReference; '
        r'lastKnownFileType = folder\.iconcomposer\.icon;[^}]*'
        r'path = Runner/AppIcon\.icon;',
      ).hasMatch(pbxproj),
      isTrue,
      reason: 'macOS 工程缺 AppIcon.icon 文件引用',
    );
    // 必须进 Runner 主 target 的 Resources（与 Assets.xcassets 同一个 phase）。
    final RegExp runnerResources = RegExp(
      r'isa = PBXResourcesBuildPhase;[^}]*?files = \(([^)]*)\)',
    );
    final bool inRunnerResources = runnerResources
        .allMatches(pbxproj)
        .map((RegExpMatch m) => m.group(1)!)
        .any(
          (String files) =>
              files.contains('Assets.xcassets in Resources') &&
              files.contains('AppIcon.icon in Resources'),
        );
    expect(
      inRunnerResources,
      isTrue,
      reason: 'AppIcon.icon 未加入 Runner target 的 Resources build phase',
    );
    // 26 以前的 macOS 仍取 appiconset。
    expect(
      File(
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png',
      ).existsSync(),
      isTrue,
    );
  });

  test('Android 自适应图标带主题图标单色层与深色模式背景', () {
    final Directory adaptiveDir = Directory(
      'android/app/src/main/res/mipmap-anydpi-v26',
    );
    final List<File> iconXmls = adaptiveDir
        .listSync()
        .whereType<File>()
        .where(
          (File f) =>
              f.uri.pathSegments.last.startsWith('launcher_icon') &&
              f.path.endsWith('.xml'),
        )
        .toList();
    expect(iconXmls, isNotEmpty);

    final String mono = read(
      'android/app/src/main/res/drawable/ic_launcher_monochrome.xml',
    );
    expect(mono, contains('android:viewportWidth="108"'));
    expect(mono, contains('android:viewportHeight="108"'));
    expect(mono, contains('android:pathData="M'));

    final String nightColors = read(
      'android/app/src/main/res/values-night/colors.xml',
    );
    final Map<String, String> nightByName = <String, String>{};
    for (final RegExpMatch m in RegExp(
      r'<color\s+name="([^"]+)"\s*>\s*#([0-9A-Fa-f]{6,8})\s*</color>',
    ).allMatches(nightColors)) {
      nightByName[m.group(1)!] = m.group(2)!;
    }

    final RegExp bgRefRe = RegExp(
      r'<background\s+android:drawable="@color/([^"]+)"',
    );
    for (final File f in iconXmls) {
      final String name = f.uri.pathSegments.last;
      final String xml = f.readAsStringSync();
      expect(
        xml,
        contains(
          '<monochrome android:drawable="@drawable/ic_launcher_monochrome"/>',
        ),
        reason: '$name 缺 Android 13+ 主题图标 monochrome 层',
      );
      final RegExpMatch? bg = bgRefRe.firstMatch(xml);
      if (bg == null) continue;
      final String colorName = bg.group(1)!;
      final String? hex = nightByName[colorName];
      expect(
        hex,
        isNotNull,
        reason: '$name 的背景 @color/$colorName 在 values-night 未定义深色值',
      );
      // 深色背景同样必须不透明（TODO-1269）且确实是深色。
      expect(hex!.length, 6, reason: '深色背景须为不透明 #RRGGBB');
      final int r = int.parse(hex.substring(0, 2), radix: 16);
      final int g = int.parse(hex.substring(2, 4), radix: 16);
      final int b = int.parse(hex.substring(4, 6), radix: 16);
      final double luma = (299 * r + 587 * g + 114 * b) / 1000;
      expect(luma, lessThan(96), reason: '$colorName 深色值 #$hex 不够深');
      expect(r + g + b, greaterThan(0), reason: '纯黑背景会与 TODO-1269 症状混淆');
    }
  });
}
