import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/game_shared.dart';

import '../helpers/source_guard.dart';

String _code(String source) => maskCommentsAndStrings(source);

bool _containsCode(String source, String needle) =>
    containsCodeLine(_code(source), needle);

/// 下载页的「设置」顶部段。
///
/// 承载形态换过三次：`Tab(text: …)` → PR#820 与库页同构的
/// `ButtonSegment(value: …, label: Text(…))` → 2026-08-24 库页顶栏改走 MD3 tabs 后的
/// `LibrarySectionTab(value: …, label: …)`。守卫要守的**行为**三次都没变（设置是常驻的
/// 第四个顶部段，不是临时齿轮模式），锚点跟着搬到新形态即可——别因为形态换了就把断言
/// 删掉。
bool _hasSettingsSegment(String source) => RegExp(
      r'\bLibrarySectionTab<int>\s*\(\s*value:\s*3\s*,\s*'
      r'label:\s*t\.settings\s*\)',
    ).hasMatch(_code(source));

/// BUG-1858 起 `constrainWidth` 参数已删：全宽不再是调用点的一个选项，而是
/// [TorrentSettingsSection] 唯一的形态。守的**行为**没变（下载页的设置面是全宽的），
/// 锚点跟着搬到无参调用。
bool _hasFullWidthTorrentSettings(String source) => RegExp(
      r'\bTorrentSettingsSection\s*\(\s*\)',
    ).hasMatch(_code(source));

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('设置页签判据忽略注释注入', () {
    const String commentsOnly = '''
// kind: MediaLibraryViewKind.settings
/* value: GameSection.settings
value: VideoLibrarySection.settings
LibrarySectionTab<int>(value: 3, label: t.settings)
TorrentSettingsSection()
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
LibrarySectionTab<int>(value: 3, label: t.settings)
TorrentSettingsSection()
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

  // 2026-10-09 用户拍板：书架 / 漫画 / 视频 / 游戏四个模块库页里的「设置」子页签
  // 全部移除——它们只是全局「设置 › 阅读 / 漫画 / 视频 / 游戏」分类的投影
  // （[ModuleSettingsView] 读的就是全局 schema），与全局设置、阅读时的设置面板
  // 重复。守卫反转为「不得再出现」，防止有人把投影页签加回来。
  test('书架、漫画、视频和游戏顶部导航不再提供模块内设置页', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/home_reader_page.dart',
      'lib/src/media/manga/manga_library_page.dart',
      'lib/src/pages/implementations/video_library_shell.dart',
      'lib/src/pages/implementations/home_game_page.dart',
    ]) {
      final String code = source(path);
      expect(
        containsIdentifier(code, 'ModuleSettingsView'),
        isFalse,
        reason: '$path 不得再内嵌模块设置页（设置一律走全局设置）',
      );
      expect(
        _containsCode(code, 'kind: MediaLibraryViewKind.settings'),
        isFalse,
      );
    }
    final String video = source(
      'lib/src/pages/implementations/video_library_shell.dart',
    );
    expect(
      _containsCode(video, 'value: VideoLibrarySection.settings'),
      isFalse,
      reason: '视频顶部导航不得再有设置页',
    );

    // 游戏页签由 [kGameSectionTabOrder] 循环生成（序的唯一真相）。
    final String game = source(
      'lib/src/pages/implementations/game_shared.dart',
    );
    expect(
      _containsCode(
        game,
        'for (final GameSection section in kGameSectionTabOrder)',
      ),
      isTrue,
      reason: '游戏页签必须由 kGameSectionTabOrder 循环生成（序的唯一真相）',
    );
    expect(
      GameSection.values.map((GameSection s) => s.name),
      isNot(contains('settings')),
      reason: '游戏模块不得再有设置子区',
    );
    expect(kGameSectionTabOrder.contains(GameSection.diagnostics), isFalse,
        reason: '兼容性诊断不能继续占用游戏顶部高频 tab');
    expect(kGameSectionTabOrder.last, GameSection.importGames,
        reason: '导入恒排末位，与书 / 漫画 / 视频库页同构');
  });

  // 2026-09-27 起「下载」模块改名「浏览」（Mihon Browse 形态）：顶部页签变成
  // 来源 / 扩展 / 发现 / 下载，下载设置不再占顶部页签，而是「下载」页签页头齿轮
  // push 的独立页 BrowseDownloadSettingsPage。守的行为是「设置有一个稳定入口、
  // 是全宽整页」，不是「设置原地替换正文的临时模式」（_showSettings 仍禁止）。
  test('浏览页的下载设置是页头齿轮 push 的独立页，而不是临时模式', () {
    final String downloads = source(
      'lib/src/pages/implementations/browse_page.dart',
    );
    expect(
      _hasSettingsSegment(downloads),
      isFalse,
      reason: '下载设置不再占顶部页签（页签用 BrowseTab 枚举）',
    );
    expect(_hasFullWidthTorrentSettings(downloads), isTrue);
    expect(containsIdentifier(downloads, '_showSettings'), isFalse);

    final String downloadsCode = _code(downloads);
    expect(
      containsCodeLine(
        downloadsCode,
        'class BrowseDownloadSettingsPage extends ConsumerWidget {',
      ),
      isTrue,
    );
    expect(
      RegExp(
        r'builder:\s*\(BuildContext context\)\s*=>\s*'
        r'const BrowseDownloadSettingsPage\(\)',
      ).hasMatch(downloadsCode),
      isTrue,
      reason: '齿轮必须 push 设置独立页',
    );
    expect(
      containsIdentifier(downloads, '_openDownloadSettings'),
      isTrue,
    );
    expect(
      RegExp(
        r'enum BrowseTab \{ discover, sources, extensions, downloads \}',
      ).hasMatch(downloadsCode),
      isTrue,
      reason: '顶部页签里不得再有 settings',
    );
  });

  test('独立设置页与诊断详情都保留真实返回入口', () {
    final String moduleSettings = source(
      'lib/src/pages/implementations/module_settings_view.dart',
    );
    expect(
      _containsCode(
        moduleSettings,
        'FushiPageHeader.route(title: title)',
      ),
      isTrue,
      reason: '推出来的独立设置页必须有带返回键的页头',
    );

    final String diagnostics = source(
      'lib/src/pages/implementations/game_diagnostics_page.dart',
    );
    expect(
      _containsCode(
        diagnostics,
        'icon: FushiIcons.back',
      ),
      isTrue,
      reason: '诊断页高亮捕获工作台段时，重选当前段不会回调，必须另有显式返回入口',
    );
    expect(
      RegExp(r'onTap:\s*widget\.onShowCapture').hasMatch(_code(diagnostics)),
      isTrue,
      reason: '诊断返回键回到捕获工作台（模块内设置页已移除）',
    );
  });
}
