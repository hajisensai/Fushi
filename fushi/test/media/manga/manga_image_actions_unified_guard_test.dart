import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_reader_settings_sheet.dart';

import '../../helpers/source_guard.dart';

/// 漫画阅读器的「保存 / 分享 / 复制图片」与小说正文、插图册、缩放看图共用
/// 一套动作本体（`reader/image_actions_sheet.dart` 的 `runImageAction`；保存 =
/// 手机写系统相册、桌面另存为）。旧实现把页图复制进 app 自己的
/// `<书目录>/saved/...` 并受「保存目录」设置控制——用户 2026-10-25 拍板统一，
/// 这里钉住不许长回第二份保存实现。
void main() {
  String read(String path) =>
      maskComments(File(path).readAsStringSync().replaceAll('\r\n', '\n'));

  String slice(String source, String start, String end) {
    final int s = source.indexOf(start);
    expect(s, isNonNegative, reason: '找不到起始标记：$start');
    final int e = source.indexOf(end, s + start.length);
    expect(e, isNonNegative, reason: '找不到结束标记：$end');
    return source.substring(s, e);
  }

  test('漫画右键菜单的图片动作走全局图片动作实现', () {
    final String source = read(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    );

    final String runner = slice(
      source,
      'Future<void> _runCurrentMangaPageImageAction(ImageAction action)',
      'Future<void> _setCurrentMangaPageAsCover()',
    );
    expect(runner, contains('await runImageAction(action, file);'));
    expect(runner, isNot(contains('.copy(')), reason: '不得自己复制文件落盘');

    final String menu = slice(
      source,
      'Future<void> _showReaderContextMenu(String payloadJson)',
      'Widget build(BuildContext context)',
    );
    expect(
      menu,
      contains(
        'imageActionsFor(\n              defaultTargetPlatformForImageSave(),',
      ),
      reason: '图片项按平台列，与长按面板同一判据',
    );
    expect(menu, contains('imageActionLabel(imageAction)'));
    expect(
      menu,
      contains('_runCurrentMangaPageImageAction(action.imageAction!)'),
    );
    expect(menu, isNot(contains('shareImageFile(')));
    expect(menu, isNot(contains('copyImageFileToClipboard(')));

    // 旧保存实现与它读的「保存目录」设置都已删除。
    expect(source, isNot(contains('_saveCurrentMangaPage')));
    expect(source, isNot(contains('_saveDirectory')));
    expect(source, isNot(contains("'saved'")));
  });

  test('「保存目录」设置不再出现在漫画阅读设置里', () {
    final Set<String> keys = <String>{
      for (final MangaReaderPreferenceDescriptor d
          in mangaReaderPreferenceDescriptors(<String>{}))
        d.key,
    };
    expect(keys, isNot(contains('saveDirectory')));
    expect(
      const MangaReaderPreferences().toJson().containsKey('saveDirectory'),
      isFalse,
    );
    // 旧存档里的冻结键只是不再读取：带着它解析不报错，也不会被当成覆盖项留下。
    expect(
      MangaReaderPreferences.normalizedOverride(<String, Object?>{
        'saveDirectory': 'flat',
      }),
      isEmpty,
    );
  });
}
