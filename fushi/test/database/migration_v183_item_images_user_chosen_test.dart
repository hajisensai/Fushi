import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:test/test.dart';

/// v183：`item_images.user_chosen`——附加图来源锁（用户在「横幅…」里选的横幅之后的
/// 刮削不覆盖）。纯加列，存量 0 = 刮削来源；按列存在性守卫，重跑幂等。
void main() {
  bool hasColumn(sqlite.Database raw, String table, String column) => raw
      .select('PRAGMA table_info($table)')
      .any((sqlite.Row row) => row['name'] == column);

  test('v182 → v183：加列、存量行原样且记为刮削来源；重跑幂等', () async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'item_images_user_chosen_v183',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final String path = '${directory.path}/test.db';
    final FushiDatabase original = FushiDatabase.atFile(
      path,
      isMainProcess: false,
    );
    await original.customSelect('SELECT 1').get();
    await original.close();

    // 退回 v182 的样子：没有 user_chosen 列，有一行存量横版背景。
    final sqlite.Database raw = sqlite.sqlite3.open(path);
    raw.execute('ALTER TABLE item_images DROP COLUMN user_chosen');
    raw.execute(
      'INSERT INTO item_images '
      '(media_type, entry_key, kind, position, path, source_url) '
      "VALUES ('epub', 'b1', 'backdrop', 0, '/old.jpg', 'https://x/old.jpg')",
    );
    raw.execute('PRAGMA user_version = 182');
    expect(hasColumn(raw, 'item_images', 'user_chosen'), isFalse);
    raw.dispose();

    FushiDatabase migrated = FushiDatabase.atFile(path, isMainProcess: false);
    expect(migrated.schemaVersion, kFushiDbSchemaVersion);
    ItemImageRow row = (await migrated.getItemImages(
      MediaKind.epub,
      'b1',
    )).single;
    expect(row.path, '/old.jpg');
    expect(row.sourceUrl, 'https://x/old.jpg');
    expect(row.userChosen, isFalse);
    expect(
      await migrated.hasUserChosenItemImage(
        MediaKind.epub,
        'b1',
        MediaImageKind.backdrop,
      ),
      isFalse,
    );
    await migrated.close();

    final sqlite.Database again = sqlite.sqlite3.open(path);
    expect(hasColumn(again, 'item_images', 'user_chosen'), isTrue);
    again.execute(
      "UPDATE item_images SET user_chosen = 1 WHERE entry_key = 'b1'",
    );
    again.execute('PRAGMA user_version = 182');
    again.dispose();

    migrated = FushiDatabase.atFile(path, isMainProcess: false);
    row = (await migrated.getItemImages(MediaKind.epub, 'b1')).single;
    expect(row.userChosen, isTrue, reason: '列已在时跳过，已有的锁不丢');
    await migrated.close();
  });
}
