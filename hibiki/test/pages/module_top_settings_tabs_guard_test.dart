import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('书架、漫画、视频和游戏顶部导航都提供设置页', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/home_reader_page.dart',
      'lib/src/media/manga/manga_library_page.dart',
      'lib/src/pages/implementations/home_page.dart',
    ]) {
      expect(
        source(path).contains('kind: MediaLibraryViewKind.settings'),
        isTrue,
        reason: '$path 顶部导航缺少设置页',
      );
    }

    final String game = source(
      'lib/src/pages/implementations/game_shared.dart',
    );
    expect(game.contains('value: GameSection.settings'), isTrue);
    expect(game.contains('value: GameSection.diagnostics'), isFalse,
        reason: '兼容性诊断不能继续占用游戏顶部高频 tab');
  });

  test('下载把设置作为第四个顶部 tab，而不是临时齿轮模式', () {
    final String downloads = source(
      'lib/src/pages/implementations/downloads_page.dart',
    );
    expect(downloads.contains('length: 4'), isTrue);
    expect(downloads.contains('Tab(text: t.settings)'), isTrue);
    expect(downloads.contains('child: const TorrentSettingsSection()'), isTrue);
    expect(downloads.contains('_showSettings'), isFalse);
  });
}
