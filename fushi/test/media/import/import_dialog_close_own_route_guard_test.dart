import 'dart:io';

import 'package:test/test.dart';

/// 导入框（长耗时、await 结束后才关自己）一律用 `closeOwnRoute` 关掉自己的路由，不许用
/// 带结果的裸 `Navigator.pop(context, …)`：导入期间用户可能从悬浮反馈球 / 全局快捷键把
/// 别的页面推到导入框上面，裸 `pop` 会关掉那一页并把导入结果当成它的返回值（反馈
/// zorhfwRcz- 分诊，manga_import_dialog.dart 导入完成处）。
///
/// 不带结果的 `Navigator.pop(context)` 只出现在「取消」按钮里——用户点的是框上的按钮，框
/// 必然在最顶层，不在本守卫范围。
const List<String> _importDialogs = <String>[
  'lib/src/media/manga/manga_import_dialog.dart',
  'lib/src/media/audiobook/book_import_dialog.dart',
  'lib/src/media/audiobook/audiobook_import_dialog.dart',
  'lib/src/media/audiobook/srt_book_reimport_dialog.dart',
  'lib/src/media/import/pasted_text_book_dialog.dart',
  'lib/src/media/import/book_archive_import_dialog.dart',
  'lib/src/media/video/video_import_dialog.dart',
  'lib/src/media/video/iptv_playlist_import_dialog.dart',
  'lib/src/media/audio_cd/audio_cd_import.dart',
];

void main() {
  final RegExp barePopWithResult = RegExp(r'Navigator\.pop\(\s*context\s*,');

  for (final String path in _importDialogs) {
    test('$path closes itself via closeOwnRoute', () {
      final String src = File(path).readAsStringSync();
      final List<String> offenders = <String>[
        for (final RegExpMatch m in barePopWithResult.allMatches(src))
          'line ${'\n'.allMatches(src.substring(0, m.start)).length + 1}',
      ];
      expect(
        offenders,
        isEmpty,
        reason: '$path: use closeOwnRoute(context, result)',
      );
      expect(src.contains('closeOwnRoute'), isTrue);
    });
  }
}
