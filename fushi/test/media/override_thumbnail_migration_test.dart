import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/override_thumbnail_migration.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// W2-3：override 封面 hash 文件名的 hoshi://→fushi:// 前缀换代清扫。
/// 文件名按与生产同一条 key 派生式现算（`<key>.hashCode`），造旧形态文件走
/// 清扫断言归位到新规范名。
void main() {
  late Directory thumbs;
  late FushiDatabase db;

  setUp(() {
    thumbs = Directory.systemTemp.createTempSync('fushi_thumb_mig_test');
    db = FushiDatabase.forTesting(NativeDatabase.memory(
      setup: (raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ));
  });

  tearDown(() async {
    await db.close();
    if (thumbs.existsSync()) thumbs.deleteSync(recursive: true);
  });

  Future<void> seedItem(String identifier) => db.customStatement(
        'INSERT INTO media_items '
        '(media_identifier, title, media_type_identifier, '
        'media_source_identifier, unique_key, position, duration, '
        'can_delete, can_edit) '
        "VALUES ('$identifier', 'T', 'reader', 'reader_fushi', "
        "'reader_fushi/$identifier', 0, 0, 1, 1)",
      );

  File fileFor(String name) => File(p.join(thumbs.path, name));

  test('old-canonical and legacy source-burned names move to new canonical',
      () async {
    await seedItem('fushi://book/A');
    await seedItem('fushi://srtbook/S');
    // A：旧规范形态（BUG-1317 后、W2-3 前写的）。
    final String oldCanonicalA =
        'hoshi://book/A/override_thumbnail'.hashCode.toString();
    fileFor(oldCanonicalA).writeAsStringSync('jpgA');
    // S：legacy 烧源键形态（BUG-1317 前写的）。
    final String legacyS =
        'hoshi://srtbook/S/reader_ttu/override_thumbnail'.hashCode.toString();
    fileFor(legacyS).writeAsStringSync('jpgS');

    final bool clean = await migrateOverrideThumbnailPrefixes(
        db: db, thumbnailsDirectory: thumbs);

    expect(clean, isTrue);
    expect(
        fileFor(canonicalOverrideThumbnailName('fushi://book/A'))
            .readAsStringSync(),
        'jpgA');
    expect(
        fileFor(canonicalOverrideThumbnailName('fushi://srtbook/S'))
            .readAsStringSync(),
        'jpgS');
    expect(fileFor(oldCanonicalA).existsSync(), isFalse);
    expect(fileFor(legacyS).existsSync(), isFalse);
  });

  test('existing new-canonical file wins; idempotent second run', () async {
    await seedItem('fushi://book/B');
    final String newName = canonicalOverrideThumbnailName('fushi://book/B');
    fileFor(newName).writeAsStringSync('new');
    final String oldName =
        'hoshi://book/B/override_thumbnail'.hashCode.toString();
    fileFor(oldName).writeAsStringSync('old');

    expect(
        await migrateOverrideThumbnailPrefixes(
            db: db, thumbnailsDirectory: thumbs),
        isTrue);
    expect(fileFor(newName).readAsStringSync(), 'new', reason: '新规范名已存在时绝不覆盖');
    expect(fileFor(oldName).existsSync(), isTrue, reason: '旧文件原样保留（永不再读，无害残影）');

    // 幂等：再跑一遍零变化。
    expect(
        await migrateOverrideThumbnailPrefixes(
            db: db, thumbnailsDirectory: thumbs),
        isTrue);
    expect(fileFor(newName).readAsStringSync(), 'new');
  });

  test('no thumbnails dir / no book items -> clean no-op', () async {
    final Directory gone = Directory(p.join(thumbs.path, 'nope'));
    expect(
        await migrateOverrideThumbnailPrefixes(
            db: db, thumbnailsDirectory: gone),
        isTrue);
    expect(
        await migrateOverrideThumbnailPrefixes(
            db: db, thumbnailsDirectory: thumbs),
        isTrue);
  });
}
