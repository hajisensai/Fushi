import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/app_model_library_host_service.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/sync_asset_package_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-1488：母设备（host）改过名的书，同步到子设备（peer）后仍显示原书名。
///
/// 根因是书的「改名」根本不出境：它不写 `epub_books.title`（那列派生跨端身份
/// `bookKey`），而是写一行 `override_title://` 覆盖偏好，而互联清单 DTO 不带
/// 显示名、备份合并把 preferences 一律当设备设置、备份导出还把它当 app 设置
/// strip 掉。本测试按「只搬显示名、绝不搬身份」这条契约锁住三条通道。
///
/// 变异实测（2026-08-10，逐条破坏 lib 确认转红后**反向替换**还原，零 lib 残留）：
///  - `app_model_library_host_service.dart` 的 `displayTitle: overrideTitles[r.bookKey]`
///    改回 `displayTitle: null` → 「host 清单下发用户改过的书名」转红
///    （expected `'我改的名字'`，actual `'原始书名'`）；
///  - `fushi_library_host_service.dart` 的 wire 键 `'displayTitle'` 改名成
///    `'displayTitleXX'` → 「改过名才写 wire 键」转红（wire map 无该键）；
///  - `backup_service.dart` 的 `_notOverrideTitleSql` 改成 `'1=1'`
///    → 「settings 谓词不再吞掉书名 override」转红（override 行被 DELETE）；
///  - `backup_merge_engine.dart` 的 `_mergeOverrideTitlePrefs` instr 判据改成
///    `< 0`（恒假）→ 「母设备 override 并进子设备」转红（目标库查不到该行）。
void main() {
  /// 该书改名偏好在 `preferences` 表里的**完整落库 key**。
  ///
  /// 这里刻意写字面量而不是调 lib 的拼接函数：它是持久化编码，测试的职责就是把
  /// 它逐字节钉死（三段分别来自 `dbSourcePrefKey` / `kOverrideTitleKeyMarker` /
  /// `ReaderFushiSource.mediaIdentifierFor`）。
  String overridePrefKey(String bookKey) =>
      'src:reader_fushi:override_title://fushi://book/$bookKey';

  EpubBooksCompanion book(String bookKey, String title) =>
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '/fake/$bookKey.epub',
        extractDir: '/fake/$bookKey',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
      );

  Future<FushiDatabase> openDb(String prefix) async {
    final Directory dir = await Directory.systemTemp.createTemp(prefix);
    addTearDown(() => cleanupTempDir(dir));
    final FushiDatabase db = FushiDatabase(dir.path);
    addTearDown(db.close);
    return db;
  }

  AppModelLibraryHostService buildHost(FushiDatabase db) =>
      AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: Directory.systemTemp,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(),
      );

  // ── wire DTO：additive 且只在真改过名时占字节 ──────────────────────────────

  test('改过名才写 wire 键；displayName 恒可用', () {
    const RemoteBookInfo renamed = RemoteBookInfo(
      title: '原始书名',
      hasContent: true,
      displayTitle: '我改的名字',
    );
    expect(renamed.toJson()['displayTitle'], '我改的名字');
    expect(renamed.displayName, '我改的名字');
    // 身份红线：downloadId 仍是 raw title（无 bookKey 时）。
    expect(renamed.downloadId, '原始书名');
  });

  test('没改过名（displayTitle 为 null 或等于 title）不写 wire 键', () {
    const RemoteBookInfo plain =
        RemoteBookInfo(title: '原始书名', hasContent: true);
    expect(plain.toJson().containsKey('displayTitle'), isFalse);
    expect(plain.displayName, '原始书名');

    const RemoteBookInfo same = RemoteBookInfo(
      title: '原始书名',
      hasContent: true,
      displayTitle: '原始书名',
    );
    expect(same.toJson().containsKey('displayTitle'), isFalse);
  });

  test('旧 host 的 JSON 无 displayTitle 键：displayName 回落 raw title', () {
    final RemoteBookInfo decoded = RemoteBookInfo.fromJson(<String, Object?>{
      'title': '原始书名',
      'hasContent': true,
    });
    expect(decoded.displayTitle, isNull);
    expect(decoded.displayName, '原始书名');
  });

  // ── host 清单：把本机 override 下发出去 ───────────────────────────────────

  test('host 清单下发用户改过的书名，身份键仍是 raw title', () async {
    final FushiDatabase db = await openDb('bug1488_host_');
    await db.insertEpubBook(book('原始书名', '原始书名'));
    await db.setPref(
      overridePrefKey('原始书名'),
      PrefCodec.encode('我改的名字'),
    );

    final List<RemoteBookInfo> books = await buildHost(db).listBooks();
    expect(books, hasLength(1));
    expect(books.single.displayTitle, '我改的名字');
    expect(books.single.displayName, '我改的名字');
    // 身份红线：raw title / bookKey / downloadId 一律不动。
    expect(books.single.title, '原始书名');
    expect(books.single.bookKey, '原始书名');
    expect(books.single.downloadId, '原始书名');
  });

  test('没改过名的书：host 清单不带 displayTitle', () async {
    final FushiDatabase db = await openDb('bug1488_host_plain_');
    await db.insertEpubBook(book('原始书名', '原始书名'));

    final List<RemoteBookInfo> books = await buildHost(db).listBooks();
    expect(books.single.displayTitle, isNull);
    expect(books.single.toJson().containsKey('displayTitle'), isFalse);
  });

  // ── 备份导出：改名是内容，不是 app 设置 ──────────────────────────────────

  test('settings 谓词不再吞掉书名 override，普通设置仍被吞', () async {
    final FushiDatabase db = await openDb('bug1488_pred_');
    await db.setPref(overridePrefKey('原始书名'), PrefCodec.encode('新名'));
    await db.setPref('reader_font_size', PrefCodec.encode(18));

    // 「不勾 settings 导出」= 按该谓词删掉 preferences 行。
    await db.customStatement(
      'DELETE FROM preferences WHERE ${BackupService.settingsPrefPredicate}',
    );

    final Map<String, String> rest = await db.getAllPrefs();
    expect(rest.containsKey(overridePrefKey('原始书名')), isTrue,
        reason: '书名 override 是内容，必须活下来');
    expect(rest.containsKey('reader_font_size'), isFalse,
        reason: '普通阅读设置仍归 settings 分类');
  });

  // ── 备份合并导入：母设备的改名并进子设备，且绝不 clobber 本机改名 ──────────

  test('合并导入：母设备 override 并入子设备，子设备自己的改名不被覆盖', () async {
    // 母设备（src）：两本书都改过名。
    final Directory srcDir =
        await Directory.systemTemp.createTemp('bug1488_src_');
    addTearDown(() => cleanupTempDir(srcDir));
    final FushiDatabase src = FushiDatabase(srcDir.path);
    await src.insertEpubBook(book('书甲', '书甲'));
    await src.insertEpubBook(book('书乙', '书乙'));
    await src.setPref(overridePrefKey('书甲'), PrefCodec.encode('母设备起的名'));
    await src.setPref(overridePrefKey('书乙'), PrefCodec.encode('母设备起的名2'));
    await src.close();

    // 子设备（target）：两本书都在，但只给「书乙」起过自己的名字。
    final FushiDatabase target = await openDb('bug1488_dst_');
    await target.insertEpubBook(book('书甲', '书甲'));
    await target.insertEpubBook(book('书乙', '书乙'));
    await target.setPref(
      overridePrefKey('书乙'),
      PrefCodec.encode('子设备自己起的名'),
    );

    final String srcDbPath =
        p.join(srcDir.path, 'fushi.db').replaceAll(r'\', '/');
    await target.customStatement("ATTACH DATABASE '$srcDbPath' AS mergesrc");
    await BackupMergeEngine(target).merge();
    await target.customStatement('DETACH DATABASE mergesrc');

    final Map<String, String> prefs = await target.getAllPrefs();
    expect(
      PrefCodec.decodeUntyped(prefs[overridePrefKey('书甲')]!),
      '母设备起的名',
      reason: '子设备没自己改过名 → 收下母设备的改名（本 bug 的核心）',
    );
    expect(
      PrefCodec.decodeUntyped(prefs[overridePrefKey('书乙')]!),
      '子设备自己起的名',
      reason: 'merge 从不 clobber 本地（与 audiobook_pos_% 同律）',
    );
  });
}
