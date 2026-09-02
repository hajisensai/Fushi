import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 「材料改名」四类入口的结构守卫。
///
/// 改名这件事在本仓库有两种落法，选错了就是数据损坏：
///
///  * **身份不是名字** 的（视频 `video_books.bookUid` / 扫描根 `media_sources.id`
///    / 合集 `media_collections.id`）→ 直接改那一列。
///  * **名字就是身份** 的（书 `epub_books.bookKey` = sanitize(title)、词典
///    `dictionary_metadata.name` = 主键 + 磁盘目录名 + 引擎装载路径）→ 只能写
///    覆盖层，真名冻结。改真名等于换身份：书是十来张子表连坐重键，词典是用户
///    样式失效 + 图音 404 + 制卡字段对不上，且**全都不抛错**。
///
/// 所以这里钉的是「哪条路走哪个 API」，外加一条弹窗收敛（别再复制第五份壳）。
String _read(String path) {
  final File file = File(path);
  expect(file.existsSync(), isTrue, reason: '找不到 $path');
  return maskCommentsAndStrings(file.readAsStringSync());
}

/// i18n key 在源码里是 `t.xxx` 这种属性访问（代码，不是字符串），掩掉字符串也
/// 还在——正好避开「把 key 写进注释就骗绿」。
///
/// 判「后面不再跟标识符字符」而不是裸 `contains`：`t.book_rename` 会被
/// `t.book_rename_label` 整段命中，于是「只加了标签 key、没加菜单项」也能骗绿
/// （同前缀假阳性是这个仓库反复踩过的形状）。
void _expectUsesKey(String code, String key, {required String reason}) {
  final String needle = 't.$key';
  final RegExp identifierChar = RegExp(r'[A-Za-z0-9_]');
  bool found = false;
  int at = code.indexOf(needle);
  while (at >= 0) {
    final int after = at + needle.length;
    final String next = after < code.length ? code[after] : ' ';
    if (!identifierChar.hasMatch(next)) {
      found = true;
      break;
    }
    at = code.indexOf(needle, at + 1);
  }
  expect(found, isTrue, reason: reason);
}

void main() {
  group('书（EPUB / 漫画 / PDF / SRT 有声书）', () {
    test('两类书卡菜单都有一级「重命名」', () {
      final String shelf =
          _read('lib/src/pages/implementations/reader_fushi_history_page.dart');
      _expectUsesKey(
        shelf,
        'book_rename',
        reason: 'EPUB 书卡菜单缺「重命名」——改名又只剩「编辑信息」里那两层',
      );
      final String srt =
          _read('lib/src/pages/implementations/reader_history/books.part.dart');
      _expectUsesKey(
        srt,
        'book_rename',
        reason: 'SRT / 有声书卡菜单缺「重命名」',
      );
    });

    test('落的是显示名覆盖层，绝不写 title 列', () {
      final String shelf =
          _read('lib/src/pages/implementations/reader_fushi_history_page.dart');
      final String body = methodBody(shelf, 'Future<void> _renameBook(');

      expect(
        body.contains('setOverrideTitleFromMediaItem('),
        isTrue,
        reason: '书改名必须走 override_title 覆盖层',
      );
      // bookKey = sanitizeTtuFilename(title)，是跨端身份。任何形态的「改标题列」
      // 都会换掉主键，十来张子表连坐。
      for (final String forbidden in <String>[
        'updateEpubBookTitle(',
        'updateSrtBookTitle(',
      ]) {
        expect(
          shelf.contains(forbidden),
          isFalse,
          reason: '$forbidden 会改主键 bookKey，等于换身份——改名只能走覆盖层',
        );
      }
    });

    test('改名后让书架重读，而不是只 refreshTab', () {
      final String shelf =
          _read('lib/src/pages/implementations/reader_fushi_history_page.dart');
      final String body = methodBody(shelf, 'Future<void> _renameBook(');
      // BUG-1018 同款：书架的响应式源按 key 集合去重，纯覆盖层写入不会重发，
      // 只 refreshTab 会拿旧缓存 MediaItem 重绘 → 看着像「没保存」。
      expect(
        body.contains('invalidate('),
        isTrue,
        reason: '改完名必须 invalidate 书籍 provider，否则列表显示旧名',
      );
    });

    test('初值取当前显示名，不是原始 title', () {
      final String shelf =
          _read('lib/src/pages/implementations/reader_fushi_history_page.dart');
      final String body = methodBody(shelf, 'Future<void> _renameBook(');
      // 取 item.title 的话，改过一次名的书再开改名框会闪回原名，用户以为改名丢了。
      expect(
        body.contains('displayTitleForBook('),
        isTrue,
        reason: '改名框初值必须是当前显示名（走显示名门面）',
      );
    });
  });

  group('扫描根 / 媒体源库', () {
    test('有改名入口，且落 label 列', () {
      final String view =
          _read('lib/src/pages/implementations/media_sources_view.dart');
      _expectUsesKey(view, 'media_source_rename', reason: '扫描根行缺改名按钮');

      final String body = methodBody(view, 'Future<void> _rename(');
      expect(
        body.contains('updateMediaSourceLabel('),
        isTrue,
        reason: '扫描根改名走 label 列——身份是自增 id，改名不牵动扫描/凭据/归属',
      );
      expect(
        body.contains('_load()'),
        isTrue,
        reason: '改完要重载列表，否则还显示旧名',
      );
    });
  });

  group('词典', () {
    test('有改名入口，且落 display_name 覆盖列', () {
      final String page =
          _read('lib/src/pages/implementations/dictionary_dialog_page.dart');
      _expectUsesKey(page, 'dict_rename', reason: '词典行缺改名按钮');

      final String body = methodBody(page, 'Future<void> _renameDictionary(');
      expect(
        body.contains('setDictionaryDisplayName('),
        isTrue,
        reason: '词典改名只能写覆盖列；真名是主键+目录名+引擎装载路径',
      );
    });

    test('列表显示走 effectiveDisplayName', () {
      final String page =
          _read('lib/src/pages/implementations/dictionary_dialog_page.dart');
      expect(
        page.contains('dictionary.effectiveDisplayName'),
        isTrue,
        reason: '词典列表标题必须显示用户改的名字',
      );
    });

    test('重导 / 在线更新继承显示名', () {
      final String importer =
          _read('lib/src/models/dictionary_import_manager.dart');
      // 两条导入路径（目录导入 / 文件导入+强制覆盖）各有一处 persistDictionary，
      // 少继承一处就是「在线更新一次名字打回原形」。
      expect(
        'preservedSettings?.displayName'.allMatches(importer).length,
        greaterThanOrEqualTo(2),
        reason: '两条导入路径都要继承显示名，否则重导后改名丢失',
      );
    });

    test('存储占用：翻译 label 但 id 保持真名', () {
      final String service = _read('lib/src/storage/storage_usage_service.dart');
      // id 是删除路由主键（settings_schema_storage 按它找磁盘目录），翻译了会
      // 删不掉 / 删错目录。
      expect(
        service.contains('id: dictionaryNames[i]'),
        isTrue,
        reason: '存储占用条目 id 必须是真名——删除按它找目录',
      );
      expect(
        service.contains('dictionaryDisplayNames[dictionaryNames[i]]'),
        isTrue,
        reason: 'label 该显示用户改的名字',
      );
    });
  });

  group('弹窗收敛', () {
    test('四个域的改名都走同一个共享原语', () {
      // 收敛前这里是四份复制品：合集 / 游戏 / 视频（裸 AlertDialog，还过早
      // dispose 了 controller）/ Profile。再加书、扫描根、词典就是七份。
      for (final (String what, String path) in <(String, String)>[
        ('合集', 'lib/src/pages/implementations/collection_name_dialog.dart'),
        ('视频', 'lib/src/pages/implementations/home_video_page.dart'),
        ('书', 'lib/src/pages/implementations/reader_fushi_history_page.dart'),
        ('扫描根', 'lib/src/pages/implementations/media_sources_view.dart'),
        ('词典', 'lib/src/pages/implementations/dictionary_dialog_page.dart'),
      ]) {
        expect(
          containsIdentifierCall(_read(path), 'showNameInputDialog'),
          isTrue,
          reason: '$what 的改名弹窗没走共享原语（$path）',
        );
      }
    });

    test('原语自己管 trim / 空名 / controller 生命周期', () {
      final String dialog =
          _read('lib/src/pages/implementations/name_input_dialog.dart');
      final String submit = methodBody(dialog, 'void _submit()');
      expect(submit.contains('.trim()'), isTrue, reason: '必须裁空白');
      expect(
        submit.contains('isEmpty'),
        isTrue,
        reason: '空名不提交——调用方因此不必各自判空',
      );
      // 视频那份旧实现在 `await showDialog` 返回后立刻 dispose，那时弹窗还没拆完
      // （游戏改名踩过同一个坑并留了注释）。原语把 controller 交给 State 持有。
      expect(
        methodBody(dialog, 'void dispose()').contains('_controller.dispose()'),
        isTrue,
        reason: 'controller 必须由 State 在 dispose 里释放',
      );
    });

    test('视频改名不再是裸 AlertDialog', () {
      final String video =
          _read('lib/src/pages/implementations/home_video_page.dart');
      final String body = methodBody(video, 'Future<void> _renameVideo(');
      expect(
        body.contains('AlertDialog'),
        isFalse,
        reason: '改名弹窗统一走设计系统，不再手搓 AlertDialog',
      );
      expect(
        body.contains('TextEditingController('),
        isFalse,
        reason: 'controller 由原语持有，调用方不再自己造（会过早 dispose）',
      );
    });
  });
}
