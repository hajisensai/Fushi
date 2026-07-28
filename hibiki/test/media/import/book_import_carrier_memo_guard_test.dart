import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫：书籍导入对话框问载体身份必须**走记忆**，不得裸调分类函数。
///
/// `.zip` / `.epub` 的定性要 `isImageArchive` 真开包（全量同步解压），是这个对话框里
/// 唯一一处重量级同步 IO。而同一个路径在一次导入里会被问三次——选中时的漫画闸门、
/// `_doImport` 的兜底闸门、`_importEpubOnly` 的分派。裸调 `classifyImportCarrier` 就是
/// 解压三次；有声书对齐路径（EPUB+字幕）更亏：它根本不进 `_importEpubOnly`，前面那
/// 几次开包纯属白开，而分家之前这条路一次都不开包。
///
/// 记忆层的行为正确性（同路径只算一次、换路径必须重算、不改判定结果）在
/// `import_carrier_test.dart` 的 `ImportCarrierResolver` 组里用计数假回调验；这里只钉
/// 接线——防止有人日后在对话框里再插一句裸调，把重复解压悄悄放回来。
void main() {
  late String src;

  setUpAll(() {
    final File f = File('lib/src/media/audiobook/book_import_dialog.dart');
    expect(f.existsSync(), isTrue, reason: '守卫目标文件应存在');
    src = f.readAsStringSync();
  });

  test('对话框不得裸调 classifyImportCarrier（必须经 ImportCarrierResolver）', () {
    expect(src.contains('classifyImportCarrier('), isFalse,
        reason: '裸调会绕过记忆 → 同一路径重复全量解压；改用 _classifyCarrier');
  });

  test('对话框持有且只持有一个 ImportCarrierResolver', () {
    expect('ImportCarrierResolver('.allMatches(src).length, 1,
        reason: '多个 resolver = 各自一份记忆 = 还是会重复开包');
  });

  test('_classifyCarrier 是唯一入口且委托给 resolver', () {
    expect(src.contains('_carrierResolver.resolve('), isTrue,
        reason: '_classifyCarrier 必须委托给 resolver，而不是自己再拼一次判据');
    // 真实注入的判据不能被换成简化桩，否则词典包一票否决就失效了
    // （那条判据活在 MangaArchiveImporter.looksLikeImageArchive 里）。
    expect(src.contains('isImageArchive: MangaModule.isImageArchive'), isTrue,
        reason: '必须注入真判据；换成按扩展名的桩会让 Yomitan 词典 zip 被当漫画导入');
  });
}
