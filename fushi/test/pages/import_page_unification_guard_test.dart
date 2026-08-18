import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// TODO-2930 导入页统一（2026-08-18 用户反馈）源码守卫：
///
/// 1. 四个模块导入页的**页头不再有「添加来源」**——添加入口收敛到「常驻来源」
///    区头（Cupertino 布局不渲染页头，收敛后 iOS 才第一次有了这个入口）；
/// 2. 快速导入区统一为「导入单件 + 导入文件夹」（游戏无扫描根概念，只有单件
///    入口，见 `home_game_page.dart` 的 `_buildImport` 文档）；
/// 3. 「本地扫描根」与「常驻来源」两个叫法统一为「常驻来源」
///    （`media_source_section_title`），`media_source_local_roots` key 已删除。
///
/// 为什么用源码扫描：`MediaSourcesPage` / `MangaSourcesPage` 都从 `appProvider`
/// 拿整个 `AppModel`，widget 测试测的是环境不是接线；这里要守的恰恰是接线与
/// 入口位置本身。读源码并**掩掉注释**（共享 [maskComments]，等长掩码不打乱
/// 下标），防止「实现删光、注释里留字面量」的假绿。
String _read(String path) => maskComments(File(path).readAsStringSync());

/// 从 [signature] 起，到下一个同缩进 `Widget ` 成员声明为止的方法切片。
String _methodSlice(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: '找不到 $signature');
  final int end = source.indexOf('\n  Widget ', start + signature.length);
  return end < 0 ? source.substring(start) : source.substring(start, end);
}

void main() {
  final String page =
      _read('lib/src/pages/implementations/media_sources_page.dart');
  final String view =
      _read('lib/src/pages/implementations/media_sources_view.dart');
  final String manga = _read('lib/src/media/manga/manga_sources_page.dart');
  final String game =
      _read('lib/src/pages/implementations/home_game_page.dart');

  group('页头不再有「添加来源」，入口在常驻来源区头', () {
    test('书 / 视频导入页', () {
      expect(
        _methodSlice(page, 'Widget _buildHeader()'),
        isNot(contains('t.media_source_add')),
        reason: '页头只留视频的全部刮削 / 后台任务',
      );
      expect(
        _methodSlice(page, 'Widget _buildSourcesSectionHeader()'),
        contains('tooltip: t.media_source_add'),
        reason: '区块内必须有等价的添加入口，能力不丢',
      );
    });

    test('漫画导入页', () {
      expect(
        _methodSlice(manga, 'Widget _buildHeader()'),
        isNot(contains('t.media_source_add')),
      );
      // 区头行：标题 + 添加按钮挂同一个 Row（build 里唯一一处 media_source_add）。
      expect(manga, contains('tooltip: t.media_source_add'));
      expect(
        manga.indexOf('tooltip: t.media_source_add'),
        greaterThan(manga.indexOf('t.media_source_section_title')),
        reason: '添加按钮必须在「常驻来源」区头，不在页头',
      );
    });
  });

  group('快速导入区统一为「导入单件 + 导入文件夹」', () {
    test('书 / 视频两域都有导入文件夹入口', () {
      // book 与 video 两个 case 各接一次共享 _importFolder。
      expect(
        RegExp('onTap: _importFolder').allMatches(page).length,
        2,
        reason: 'book / video 各一个「导入文件夹」按钮',
      );
      final int videoCase = page.indexOf("'video' => <QuickImportAction>[");
      expect(videoCase, isNonNegative);
      expect(
        page.indexOf('onTap: _importFolder', videoCase),
        greaterThan(videoCase),
        reason: '视频不再只有「导入视频」一个按钮（TODO-2930）',
      );
    });

    test('漫画接同一个共享 importFolder 流程', () {
      expect(manga, contains('.importFolder()'));
    });

    test('游戏保留单件入口（无扫描根概念，无文件夹管线）', () {
      expect(game, contains('label: t.game_add'));
      expect(game, contains('addGameViaFilePicker'));
    });

    test('共享 importFolder 按域出「设为常驻来源」提示语', () {
      expect(view, contains('Future<void> importFolder()'));
      expect(view, contains('t.video_import_folder_as_source_hint'));
      expect(view, contains('t.manga_import_folder_as_source_hint'));
      expect(view, contains('t.book_import_folder_as_source_hint'));
    });
  });

  group('术语统一：「本地扫描根」并入「常驻来源」', () {
    test('漫画区头改用 media_source_section_title，旧 key 全灭', () {
      expect(manga, contains('t.media_source_section_title'));
      expect(manga, isNot(contains('media_source_local_roots')));
    });

    test('i18n 里 media_source_local_roots key 已删除', () {
      final String zh =
          File('lib/i18n/strings_zh-CN.i18n.json').readAsStringSync();
      final String en = File('lib/i18n/strings.i18n.json').readAsStringSync();
      expect(zh, isNot(contains('media_source_local_roots')));
      expect(en, isNot(contains('media_source_local_roots')));
      expect(zh, isNot(contains('本地扫描根')));
    });
  });
}
