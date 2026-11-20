import 'dart:io';

import 'package:test/test.dart';

/// 守卫：漫画导入对话框问载体身份必须**走记忆**，不得裸调分类函数。
///
/// 与 `book_import_carrier_memo_guard_test.dart` 同款。`.zip` / `.epub` 的定性要
/// `isImageArchive` 真开包；漫画框此前在 initState 预填、`_adoptPath`、
/// `_handleDialogDrop` 的循环里各裸调一次 `classifyImportCarrier`，一次拖入 = 同一
/// 个包开两三次，然后 `importArchive` 再开一次。记忆层的行为正确性在
/// `import_carrier_test.dart` 的 `ImportCarrierResolver` 组里验；这里只钉接线。
void main() {
  late String src;

  setUpAll(() {
    final File f = File('lib/src/media/manga/manga_import_dialog.dart');
    expect(f.existsSync(), isTrue, reason: '守卫目标文件应存在');
    src = f.readAsStringSync();
  });

  test('对话框不得裸调 classifyImportCarrier（必须经 ImportCarrierResolver）', () {
    expect(
      src.contains('classifyImportCarrier('),
      isFalse,
      reason: '裸调会绕过记忆 → 同一路径重复开包；改用 _classify → resolver',
    );
  });

  test('对话框持有且只持有一个 ImportCarrierResolver', () {
    expect(
      'ImportCarrierResolver('.allMatches(src).length,
      1,
      reason: '多个 resolver = 各自一份记忆 = 还是会重复开包',
    );
  });

  test('_classify 走 resolver 的异步判定，且判据仍是真开包判据', () {
    // manga-3（BUG-5022）：同步 resolve 会在 UI isolate 上开包（选中几百 MB 的
    // 文字 EPUB 界面停住），漫画框只许走 resolveAsync + 后台判据。
    expect(src.contains('_carrierResolver.resolveAsync('), isTrue);
    expect(src.contains('_carrierResolver.resolve('), isFalse);
    expect(
      src.contains('MangaModule.probeImageArchive(widget.db, pth)'),
      isTrue,
      reason: '换成按扩展名的桩会让 Yomitan 词典 zip 被当漫画导入',
    );
    expect(
      src.contains('isImageArchive:'),
      isFalse,
      reason: '给了同步判据就可能被同步 resolve 用上，回到 UI isolate 开包',
    );
  });
}
