import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：锁定「视频长按弹菜单 + 视频纳入共享标签系统」的修复，防止回归到
/// 「长按 == 打开（无菜单）」「视频卡无标签」的旧行为。
///
/// 用源码扫描而非整页 widget pump，因为两处视频表面（视频 tab [HomeVideoPage] /
/// 书架 [reader_hibiki_history_page]）都依赖完整 AppModel + DB，整页启动成本高且
/// 脆弱；这里的不变式（onLongPress 不指向打开、存在标签/封面/删除菜单项、卡片渲染
/// 标签 provider）正是用户报的 bug 的精确反面，源码扫描足以守住。
String _read(String relative) {
  final File f = File(relative);
  if (!f.existsSync()) {
    throw StateError(
        'missing source: $relative (cwd=${Directory.current.path})');
  }
  return f.readAsStringSync();
}

String _methodBody(String source, String signature) {
  final int start = source.indexOf(signature);
  if (start < 0) {
    throw StateError('missing method signature: $signature');
  }
  final int bodyStart = source.indexOf('{', start);
  if (bodyStart < 0) {
    throw StateError('missing method body: $signature');
  }
  int depth = 0;
  for (int i = bodyStart; i < source.length; i++) {
    final String ch = source[i];
    if (ch == '{') depth++;
    if (ch == '}') {
      depth--;
      if (depth == 0) return source.substring(start, i + 1);
    }
  }
  throw StateError('unterminated method body: $signature');
}

void main() {
  final String homeVideoSrc =
      _read('lib/src/pages/implementations/home_video_page.dart');
  final String shelfSrc =
      _read('lib/src/pages/implementations/reader_hibiki_history_page.dart');

  group('视频 tab（HomeVideoPage）长按菜单 + 标签', () {
    final String src = homeVideoSrc;

    test('视频卡 onLongPress 走菜单，不再等于打开播放页', () {
      // TODO-063 起 onLongPress 是三元（选择态禁用长按、非选择态弹菜单），故不再锁
      // 死 `onLongPress: () => _showVideoMenu(book)` 字面量前缀，只断言长按指向
      // _showVideoMenu（弹菜单）这条不变式。
      expect(src.contains('_showVideoMenu(book)'), isTrue, reason: '长按必须弹菜单');
      // 旧 bug：onLongPress 与 onTap 一样调 _open。
      expect(src.contains('onLongPress: () => _open(book)'), isFalse,
          reason: '长按不能再只是打开视频（无菜单）');
    });

    test('选择态长按禁用、点击改切换勾选（批量选择，TODO-063）', () {
      // 选择态下长按必须禁用（避免与勾选冲突），点击切换勾选而非打开播放页。
      expect(
          src.contains(
              'onLongPress: _selectionMode ? null : () => _showVideoMenu(book)'),
          isTrue,
          reason: '选择态长按禁用，非选择态才弹菜单');
      expect(src.contains('_toggleSelection(book.bookUid)'), isTrue,
          reason: '选择态点卡片切换勾选');
    });

    test('长按面板复用封面背景 frame，不再用 bottom sheet', () {
      final String menuBody = _methodBody(
        src,
        'void _showVideoMenu(VideoBookRow book)',
      );

      expect(menuBody.contains('showModalBottomSheet'), isFalse,
          reason: '_showVideoMenu 不得再弹旧底部小栏');
      expect(menuBody.contains('showAppDialog'), isTrue);
      expect(menuBody.contains('MediaItemDialogFrame'), isTrue,
          reason: '视频 tab 长按必须复用 TODO-455 的共享封面背景 frame');
    });

    test('长按面板含五项管理动作且不含播放动作', () {
      final String menuBody = _methodBody(
        src,
        'void _showVideoMenu(VideoBookRow book)',
      );

      expect(menuBody.contains('_editTags(book)'), isTrue);
      expect(menuBody.contains('_renameVideo(book)'), isTrue);
      expect(menuBody.contains('_pickCover(book)'), isTrue);
      expect(menuBody.contains('_pickSubtitle(book)'), isTrue);
      expect(menuBody.contains('_confirmDelete(book)'), isTrue);
      expect(menuBody.contains('_open(book)'), isFalse,
          reason: '播放仍由卡片点击负责，长按面板不放播放按钮');
      expect(menuBody.contains('dialog_read'), isFalse);
    });

    test('编辑标签进入共享 TagPickerPage（videoBookUid 分支）', () {
      expect(src.contains('TagPickerPage(videoBookUid: book.bookUid)'), isTrue);
    });

    test('卡片渲染所挂标签 + 顶部标签筛选栏', () {
      expect(src.contains('videoBookTagMapProvider'), isTrue,
          reason: '卡片标签来自共享 provider');
      expect(src.contains('_buildTagFilterBar'), isTrue, reason: '顶部要有标签筛选栏');
      expect(src.contains('filteredVideoBookUidsProvider'), isTrue,
          reason: '网格按标签筛选');
    });

    test('视频拖拽加标签成功提示使用视频文案', () {
      final String addVideoTagBody = _methodBody(
        src,
        'Future<void> _addTagToVideoBook(String bookUid, BookTagRow tag)',
      );

      expect(addVideoTagBody.contains('tag_added_to_video'), isTrue);
      expect(addVideoTagBody.contains('tag_added_to_book'), isFalse,
          reason: '视频加标签成功不能复用“书籍”文案');
    });
  });

  group('书架（reader_hibiki_history_page）视频卡长按菜单 + 标签', () {
    final String src = shelfSrc;

    test('视频卡 onLongPress 走菜单，不再等于打开播放页', () {
      expect(src.contains('onLongPress: () => _showVideoBookDialog(book)'),
          isTrue);
      expect(src.contains('onLongPress: () => _openVideoBook(book)'), isFalse,
          reason: '书架视频卡长按不能再只是打开（无菜单）');
    });

    test('视频卡渲染标签 + 可拖标签到卡 + 面板五项管理动作', () {
      expect(src.contains('_buildVideoBookTagLabels(book.bookUid)'), isTrue);
      expect(src.contains('onTagDropped: (tag) => _addTagToVideoBook'), isTrue);
      final String dialogBody = _methodBody(
        src,
        'void _showVideoBookDialog(VideoBookRow book)',
      );

      expect(dialogBody.contains('showModalBottomSheet'), isFalse,
          reason: '_showVideoBookDialog 不得再弹旧底部小栏');
      expect(dialogBody.contains('showAppDialog'), isTrue);
      expect(dialogBody.contains('MediaItemDialogFrame'), isTrue,
          reason: '书架视频长按必须复用 TODO-455 的共享封面背景 frame');
      expect(dialogBody.contains('_openVideoTagPicker(book.bookUid)'), isTrue);
      expect(dialogBody.contains('_renameVideoBook(book)'), isTrue);
      expect(dialogBody.contains('_pickVideoCover(book)'), isTrue);
      expect(dialogBody.contains('_pickVideoSubtitle(book)'), isTrue);
      expect(dialogBody.contains('_confirmDeleteVideoBook(book)'), isTrue);
      expect(dialogBody.contains('_openVideoBook(book)'), isFalse,
          reason: '播放仍由卡片点击负责，长按面板不放播放按钮');
      expect(dialogBody.contains('dialog_read'), isFalse);
    });

    test('视频筛选改为按命中 bookUid 过滤（不再整组隐藏）', () {
      expect(src.contains('filteredVideoBookUidsProvider'), isTrue);
      // 旧实现：hasActiveFilter 时把 videoBooks 直接置空隐藏。
      expect(
        src.contains('(hasActiveFilter || appModel.experimentalVideoEnabled)'),
        isFalse,
        reason: '不应再用 hasActiveFilter 整组隐藏视频',
      );
    });

    test('视频拖拽加标签成功提示使用视频文案，书籍入口保留书籍文案', () {
      final String addVideoTagBody = _methodBody(
        src,
        'Future<void> _addTagToVideoBook(String bookUid, BookTagRow tag)',
      );
      final String addBookTagBody = _methodBody(
        src,
        'Future<void> _addTagToBook(String bookKey, BookTagRow tag)',
      );

      expect(addVideoTagBody.contains('tag_added_to_video'), isTrue);
      expect(addVideoTagBody.contains('tag_added_to_book'), isFalse,
          reason: '书架视频加标签成功不能复用“书籍”文案');
      expect(addBookTagBody.contains('tag_added_to_book'), isTrue,
          reason: '普通书籍加标签成功仍然使用书籍文案');
      expect(addBookTagBody.contains('tag_added_to_video'), isFalse);
    });
  });
}
