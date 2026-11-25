import 'dart:io';
import 'dart:ui' show Brightness, Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:image/image.dart' as img;

/// 防回归守卫：进程起来之前由系统画的启动窗口（Android 的 `LaunchTheme` /
/// Android 12+ 的系统 splash、iOS 的 `LaunchScreen`）必须和 app 默认主题同底色。
///
/// 这段时间 Dart 还没跑，颜色只能写死在原生资源里；它和首帧（首页，或首帧前的
/// 加载 / 错误页——都用 [buildFushiFallbackTheme] 的 surface）不同色，冷启动就先
/// 闪一下别的颜色。改默认主题的种子色 / 中性阶梯时这条会红：把报出来的新值填回
/// 原生资源即可。
void main() {
  String hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  String defaultSurface(Brightness brightness) =>
      hex(buildFushiFallbackTheme(brightness).colorScheme.surface);

  String read(String relative) {
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
    return f.readAsStringSync();
  }

  const String res = 'android/app/src/main/res';

  test('Android：launch_background 浅色 / 深色各等于默认主题 surface', () {
    final RegExp color = RegExp(
      r'<color name="launch_background">(#[0-9A-Fa-f]{6})</color>',
    );
    for (final (String dir, Brightness brightness) in <(String, Brightness)>[
      ('values', Brightness.light),
      ('values-night', Brightness.dark),
    ]) {
      final RegExpMatch? m = color.firstMatch(read('$res/$dir/colors.xml'));
      expect(m, isNotNull, reason: '$dir/colors.xml 缺 launch_background');
      expect(
        m!.group(1)!.toUpperCase(),
        defaultSurface(brightness),
        reason: '$dir/colors.xml 的 launch_background 要等于默认主题 surface',
      );
    }
  });

  test('Android：启动 / 常驻窗口主题的底色都引用 launch_background', () {
    final RegExp style = RegExp(
      r'<style name="(LaunchTheme|NormalTheme)"[^>]*>(.*?)</style>',
      dotAll: true,
    );
    final RegExp background = RegExp(
      r'<item name="android:(windowBackground|windowSplashScreenBackground)">'
      r'(.*?)</item>',
    );
    for (final String dir in <String>[
      'values',
      'values-night',
      'values-v31',
      'values-night-v31',
    ]) {
      final Map<String, String> bodies = <String, String>{
        for (final RegExpMatch m in style.allMatches(
          read('$res/$dir/styles.xml'),
        ))
          m.group(1)!: m.group(2)!,
      };
      expect(bodies.keys, containsAll(<String>['LaunchTheme', 'NormalTheme']));
      for (final MapEntry<String, String> e in bodies.entries) {
        final Map<String, String> items = <String, String>{
          for (final RegExpMatch m in background.allMatches(e.value))
            m.group(1)!: m.group(2)!,
        };
        expect(
          items['windowBackground'],
          '@color/launch_background',
          reason: '$dir/styles.xml ${e.key} 的 windowBackground',
        );
        // Android 12+ 的系统 splash 不看 windowBackground，另有自己的底色项。
        if (dir.endsWith('v31') && e.key == 'LaunchTheme') {
          expect(
            items['windowSplashScreenBackground'],
            '@color/launch_background',
            reason: '$dir/styles.xml 的 windowSplashScreenBackground',
          );
        }
      }
    }
  });

  test('Android 12+：系统启动画面在首帧到达时直接撤掉，不做退出淡出', () {
    // 启动画面与首帧同底色，默认的约 200 ms 淡出只会让首页晚一点看清。
    expect(
      read('android/app/src/main/java/app/fushi/reader/MainActivity.java'),
      contains(
        'getSplashScreen().setOnExitAnimationListener(SplashScreenView::remove)',
      ),
    );
  });

  test('iOS：LaunchBackground 浅色 / 深色两张图各等于默认主题 surface', () {
    const String set = 'ios/Runner/Assets.xcassets/LaunchBackground.imageset';
    final String contents = read('$set/Contents.json');
    expect(contents, contains('"filename" : "background.png"'));
    expect(contents, contains('"filename" : "darkbackground.png"'));
    for (final (String file, Brightness brightness) in <(String, Brightness)>[
      ('background.png', Brightness.light),
      ('darkbackground.png', Brightness.dark),
    ]) {
      final img.Image? decoded = img.decodePng(
        File('$set/$file').readAsBytesSync(),
      );
      expect(decoded, isNotNull, reason: '$file 无法解码为 PNG');
      final img.Pixel p = decoded!.getPixel(0, 0);
      expect(
        hex(Color.fromARGB(255, p.r.toInt(), p.g.toInt(), p.b.toInt())),
        defaultSurface(brightness),
        reason: '$set/$file 要等于默认主题 surface',
      );
    }
    // 整屏由 LaunchBackground 图铺满（四边约束贴齐根视图）。
    expect(
      read('ios/Runner/Base.lproj/LaunchScreen.storyboard'),
      contains('image="LaunchBackground"'),
    );
  });
}
