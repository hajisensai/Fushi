import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_book_font_aliases.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

/// 反馈 KFtRi4FjnO：電書協书的章标题（`.gfont`，`font-family: sans-serif-ja, sans-serif`）在
/// 换了主题字体的小米手机上竖排叠字。根因是阅读器没定义規范别名 `sans-serif-ja`，标题落进
/// Android 可被 OEM 主题替换的 generic `sans-serif`。修法见 [ReaderBookFontAliases]。
///
/// 这里钉 CSS 生成层。「`local()` 在 Android Blink 上能命中 Noto Sans CJK JP、标题实际字体从
/// `MiSans VF` 变成 Noto」的证据只能在 Android 真机取（CI 的桌面 Chrome 没有这些系统字体）。
void main() {
  Future<ReaderSettings> settingsFor({
    required String writingMode,
    required String viewMode,
  }) async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    await settings.setWritingMode(writingMode);
    await settings.setViewMode(viewMode);
    return settings;
  }

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  const String localSrc =
      'src: local("Noto Sans CJK JP Regular"), '
      'local("NotoSansCJKjp-Regular"), local("NotoSansCJKJP-Regular");';

  for (final String writingMode in <String>['vertical-rl', 'horizontal-tb']) {
    for (final String viewMode in <String>['paginated', 'continuous', 'vn']) {
      test(
        'Android $writingMode $viewMode：两个黑体别名都声明为系统 Noto 的 local()',
        () async {
          final ReaderSettings settings = await settingsFor(
            writingMode: writingMode,
            viewMode: viewMode,
          );
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          for (final String css in <String>[
            ReaderContentStyles.css(settings: settings),
            ReaderContentStyles.css(
              settings: settings,
              fontFaces: '@font-face { font-family: "UserFont"; }',
              fontFamily: '"UserFont"',
            ),
          ]) {
            for (final String family in <String>[
              'sans-serif-ja',
              'sans-serif-ja-v',
            ]) {
              expect(
                css,
                contains('@font-face { font-family: "$family"; $localSrc }'),
              );
            }
            // 用户自定义字体的 @font-face 仍在，别名只是追加。
            if (css.contains('UserFont')) {
              expect(css, contains('@font-face { font-family: "UserFont"; }'));
            }
          }
        },
      );
    }
  }

  test(
    '别名 face 不带 font-weight：AOSP 无 Noto Sans CJK Bold，挂 700 face 会让粗体整族落空',
    () {
      final String faces = ReaderBookFontAliases.fontFaces(
        TargetPlatform.android,
      );
      expect(faces, isNot(contains('font-weight')));
      expect(faces, isNot(contains('Bold')));
    },
  );

  test('不定义明朝体别名：Noto Serif CJK 只是 serif 的 fallback，local() 不命中', () {
    final String faces = ReaderBookFontAliases.fontFaces(
      TargetPlatform.android,
    );
    expect(faces, isNot(contains('"serif-ja')));
  });

  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.iOS,
    TargetPlatform.linux,
  ]) {
    test('${platform.name}：不注入（generic 黑体就是系统日文黑体）', () async {
      final ReaderSettings settings = await settingsFor(
        writingMode: 'vertical-rl',
        viewMode: 'paginated',
      );
      debugDefaultTargetPlatformOverride = platform;
      expect(ReaderBookFontAliases.fontFaces(platform), isEmpty);
      expect(
        ReaderContentStyles.css(settings: settings),
        isNot(contains('sans-serif-ja')),
      );
    });
  }
}
