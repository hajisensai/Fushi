import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

String _code(String source) => maskCommentsAndStrings(source);

bool _containsCode(String source, String needle) =>
    containsCodeLine(_code(source), needle);

/// 下载页的「设置」顶部段。
///
/// PR#820 把下载页门头从 `AppBar + TabBar` 换成与库页同构的
/// `FushiPageHeader.customTitle` + `FushiSegmentedStrip`，承载形态从
/// `Tab(text: …)` 变成 `ButtonSegment(value: …, label: Text(…))`。守卫要守的
/// **行为**没变（设置是常驻的第四个顶部段，不是临时齿轮模式），锚点跟着搬到
/// 新形态即可——别因为形态换了就把断言删掉。
bool _hasSettingsSegment(String source) => RegExp(
      r'\bButtonSegment<int>\s*\(\s*value:\s*3\s*,\s*'
      r'label:\s*Text\s*\(\s*t\.settings\s*\)\s*\)',
    ).hasMatch(_code(source));

bool _hasFullWidthTorrentSettings(String source) => RegExp(
      r'\bTorrentSettingsSection\s*\(\s*constrainWidth:\s*false\s*\)',
    ).hasMatch(_code(source));

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('设置页签判据忽略注释注入', () {
    const String commentsOnly = '''
// kind: MediaLibraryViewKind.settings
/* value: GameSection.settings
value: VideoLibrarySection.settings
ButtonSegment<int>(value: 3, label: Text(t.settings))
TorrentSettingsSection(constrainWidth: false)
*/
''';
    expect(
      _containsCode(
        commentsOnly,
        'kind: MediaLibraryViewKind.settings',
      ),
      isFalse,
    );
    expect(
      _containsCode(commentsOnly, 'value: GameSection.settings'),
      isFalse,
    );
    expect(
      _containsCode(commentsOnly, 'value: VideoLibrarySection.settings'),
      isFalse,
    );
    expect(_hasSettingsSegment(commentsOnly), isFalse);
    expect(_hasFullWidthTorrentSettings(commentsOnly), isFalse);
  });

  test('设置页签判据忽略字符串注入', () {
    const String stringsOnly = r"""
const String decoy = '''
kind: MediaLibraryViewKind.settings
value: GameSection.settings
value: VideoLibrarySection.settings
ButtonSegment<int>(value: 3, label: Text(t.settings))
TorrentSettingsSection(constrainWidth: false)
''';
""";
    expect(
      _containsCode(stringsOnly, 'kind: MediaLibraryViewKind.settings'),
      isFalse,
    );
    expect(
      _containsCode(stringsOnly, 'value: GameSection.settings'),
      isFalse,
    );
    expect(
      _containsCode(stringsOnly, 'value: VideoLibrarySection.settings'),
      isFalse,
    );
    expect(_hasSettingsSegment(stringsOnly), isFalse);
    expect(_hasFullWidthTorrentSettings(stringsOnly), isFalse);
  });

  test('书架、漫画、视频和游戏顶部导航都提供设置页', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/home_reader_page.dart',
      'lib/src/media/manga/manga_library_page.dart',
    ]) {
      expect(
        _containsCode(source(path), 'kind: MediaLibraryViewKind.settings'),
        isTrue,
        reason: '$path 顶部导航缺少设置页',
      );
    }

    // #792 起视频模块从 home_page 的 MediaLibraryShell 换成独立
    // VideoLibraryShell,设置段随之搬家——守卫针跟着扎到新位置。
    final String video = source(
      'lib/src/pages/implementations/video_library_shell.dart',
    );
    expect(
      _containsCode(video, 'value: VideoLibrarySection.settings'),
      isTrue,
      reason: '视频顶部导航缺少设置页',
    );

    final String game = source(
      'lib/src/pages/implementations/game_shared.dart',
    );
    expect(_containsCode(game, 'value: GameSection.settings'), isTrue);
    expect(_containsCode(game, 'value: GameSection.diagnostics'), isFalse,
        reason: '兼容性诊断不能继续占用游戏顶部高频 tab');
  });

  test('下载把设置作为第四个顶部 tab，而不是临时齿轮模式', () {
    final String downloads = source(
      'lib/src/pages/implementations/downloads_page.dart',
    );
    expect(_hasSettingsSegment(downloads), isTrue);
    expect(_hasFullWidthTorrentSettings(downloads), isTrue);
    expect(containsIdentifier(downloads, '_showSettings'), isFalse);

    final String downloadsCode = _code(downloads);
    final int subscriptions = downloadsCode.indexOf(
      'Text(t.download_subscriptions_tab)',
    );
    final Match? settings = RegExp(
      r'label:\s*Text\s*\(\s*t\.settings\s*\)',
    ).firstMatch(downloadsCode);
    expect(subscriptions, greaterThanOrEqualTo(0));
    expect(settings, isNotNull);
    expect(settings!.start, greaterThan(subscriptions));
  });

  test('模块设置和诊断详情都保留返回模块导航的真实入口', () {
    final String moduleSettings = source(
      'lib/src/pages/implementations/module_settings_view.dart',
    );
    expect(
      _containsCode(
        moduleSettings,
        'FushiPageHeader.customTitle(title: widget.navigation)',
      ),
      isTrue,
      reason: '隐藏 Cupertino 外观也不能删掉模块分段导航',
    );

    final String diagnostics = source(
      'lib/src/pages/implementations/game_diagnostics_page.dart',
    );
    expect(
      _containsCode(
        diagnostics,
        'icon: Icons.arrow_back',
      ),
      isTrue,
      reason: '诊断页高亮设置段时，重选当前段不会回调，必须另有显式返回入口',
    );
    expect(
      RegExp(
        r'gameSectionNotifier\.value\s*=\s*GameSection\.settings',
      ).hasMatch(_code(diagnostics)),
      isTrue,
    );
  });
}
