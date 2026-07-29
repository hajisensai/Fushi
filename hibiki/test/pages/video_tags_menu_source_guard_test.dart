import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码守卫：锁定「视频长按弹菜单 + 视频纳入共享标签系统」的修复，防止回归到
/// 「长按 == 打开（无菜单）」「视频卡无标签」的旧行为。
///
/// 用源码扫描而非整页 widget pump，因为视频表面（视频 tab [HomeVideoPage]）依赖
/// 完整 AppModel + DB，整页启动成本高且脆弱；这里的不变式（onLongPress 不指向打开、
/// 存在标签/封面/删除菜单项、卡片渲染标签 provider）正是用户报的 bug 的精确反面，
/// 源码扫描足以守住。
///
/// 注：书架侧视频卡/长按面板已随「书架视频分区」死路径清理一并删除（视频归视频
/// tab 独占），故原「书架」分组已移除，只留视频 tab 分组。
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

  group('视频 tab（HomeVideoPage）长按菜单 + 标签', () {
    final String src = homeVideoSrc;

    test('视频卡 onLongPress 走菜单，不再等于打开播放页', () {
      // TODO-063 起选择态禁用卡片长按，让祖先扫选接管；未进入选择态时所有平台
      // 都必须继续走 _showVideoMenu。
      expect(src.contains('_showVideoMenu(book)'), isTrue, reason: '长按必须弹菜单');
      // 旧 bug：onLongPress 与 onTap 一样调 _open。
      expect(src.contains('onLongPress: () => _open(book)'), isFalse,
          reason: '长按不能再只是打开视频（无菜单）');
    });

    test('选择态长按禁用、点击改切换勾选（批量选择，TODO-063）', () {
      // 折掉换行/缩进后比对，免得 dart format 的换行位置成为守卫的隐形前提。
      final String flat = src.replaceAll(RegExp(r'\s+'), ' ');
      expect(
          flat.contains(
              'onLongPress: _selectionMode ? null : () => _showVideoMenu(book)'),
          isTrue,
          reason: '未进选择态时触屏/桌面长按都弹菜单，选择态才禁用');
      expect(flat.contains('touchLongPressSelects'), isFalse,
          reason: '不得再按触屏平台把未进入选择态的长按改判成多选');
      expect(src.contains('_toggleSelection(book.bookUid)'), isTrue,
          reason: '选择态点卡片切换勾选');
    });

    test('未进选择态的长按不按平台改判，也不再叠加临时 ⋮ 按钮', () {
      final String flat = src.replaceAll(RegExp(r'\s+'), ' ');
      expect(flat.contains('isTouchSelectionPlatform'), isFalse);
      expect(flat.contains('ShelfCardMenuButton'), isFalse,
          reason: '恢复长按菜单后不需要在封面上永久叠加替代入口');
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

    test('字幕动作文案不展示格式限定词，但 picker 仍保留白名单', () {
      final String menuBody = _methodBody(
        src,
        'void _showVideoMenu(VideoBookRow book)',
      );
      final String pickerBody = _methodBody(
        src,
        'Future<void> _pickSubtitle(VideoBookRow book)',
      );
      final String i18n = _read('lib/i18n/strings.i18n.json');

      expect(menuBody.contains('label: t.video_import_pick_subtitle'), isTrue);
      expect(
        pickerBody.contains(
            "allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa']"),
        isTrue,
        reason: 'label polish must not relax the actual subtitle file picker',
      );
      expect(i18n.contains('"video_import_pick_subtitle": "Pick subtitle"'),
          isTrue);
      expect(i18n.contains('Pick subtitle (srt/vtt/ass)'), isFalse);
    });

    test('编辑标签进入共享 TagPickerPage（video MediaRef 分支）', () {
      // 命名统一 Phase 3.3：TagPickerPage 收口为单 MediaRef 目标参数。
      expect(
        src.contains(
            'media: MediaRef(kind: MediaKind.video, entryKey: book.bookUid)'),
        isTrue,
      );
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
}
