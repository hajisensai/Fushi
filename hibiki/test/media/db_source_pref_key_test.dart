import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/media_source.dart';

/// [dbSourcePrefKey] 是 MediaSource 偏好命名空间 key（`src:<source>:<key>`）的单一
/// 真相编码器。此前 media_source 与 profile_repository 各自硬编码该格式（后者还钉死
/// 历史名 reader_ttu）。本测试：①逐字节冻结格式（持久化红线，变了即丢用户偏好）；
/// ②backup_service 的冻结 reader_ttu const key 与编码器输出一致（防漂移又不破 const）；
/// ③media_source / profile_repository 都经编码器、不再硬编码格式。
void main() {
  group('dbSourcePrefKey 偏好 key 编码单一真相', () {
    test('格式逐字节冻结 src:<source>:<key>（持久化红线）', () {
      expect(dbSourcePrefKey('reader_ttu', 'font_catalog'),
          'src:reader_ttu:font_catalog');
      expect(dbSourcePrefKey('reader_ttu', ''), 'src:reader_ttu:');
      expect(dbSourcePrefKey('reader_ttu', 'x'), 'src:reader_ttu:x');
      expect(dbSourcePrefKey('video_hibiki', 'k'), 'src:video_hibiki:k');
    });

    test('backup_service 的冻结 reader_ttu const key 与编码器输出一致（防漂移）', () {
      final String backup =
          File('lib/src/sync/backup_service.dart').readAsStringSync();
      for (final String key in <String>[
        dbSourcePrefKey('reader_ttu', 'font_catalog'),
        dbSourcePrefKey('reader_ttu', 'custom_fonts'),
        dbSourcePrefKey('reader_ttu', 'app_ui_fonts'),
        dbSourcePrefKey('reader_ttu', 'dict_fonts'),
      ]) {
        expect(backup, contains("'$key'"),
            reason: 'backup_service 的 $key 必须与 dbSourcePrefKey 输出逐字节一致');
      }
    });

    test('media_source / profile_repository 经 dbSourcePrefKey 编码，不再硬编码格式', () {
      final String ms =
          File('lib/src/media/media_source.dart').readAsStringSync();
      final String pr =
          File('lib/src/profile/profile_repository.dart').readAsStringSync();
      expect(ms, contains('dbSourcePrefKey(uniqueKey, key)'),
          reason: 'MediaSource._dbPrefKey 应转调编码器');
      expect(pr, contains("dbSourcePrefKey('reader_ttu', row.key)"),
          reason: 'profile applyProfile 应转调编码器');
      expect(pr.contains("'src:reader_ttu:\${row.key}'"), isFalse,
          reason: 'profile 不应再硬编码 media_source 私有 key 格式');
    });

    // G-硬编码去重：reader_settings / custom_fonts_page / profile_repository /
    // data_root_migrator 的 `src:reader_ttu:` 字面量已改经编码器（值不变）。
    // backup_service 因 const 上下文保留字面量，由上面的 parity 用例锁一致。
    test('reader_settings / custom_fonts_page / profile / migrator 字面量已转编码器',
        () {
      final String rs =
          File('lib/src/reader/reader_settings.dart').readAsStringSync();
      final String cf =
          File('lib/src/pages/implementations/custom_fonts_page.dart')
              .readAsStringSync();
      final String pr =
          File('lib/src/profile/profile_repository.dart').readAsStringSync();
      final String dm =
          // BUG-1174：字体 key 组连同其余承载路径的 pref 一起搬进了声明式覆盖表；
          // data_root_migrator 现在只消费 kPathRebasePrefs，不再自持 key 常量。
          File('lib/src/storage/path_rebase_coverage.dart').readAsStringSync();
      expect(rs, contains("dbSourcePrefKey('reader_ttu', '')"),
          reason: 'ReaderSettings._prefix 应转调编码器');
      expect(rs.contains("'src:reader_ttu:'"), isFalse,
          reason: 'reader_settings 不应再持有前缀字面量');
      expect(cf, contains("dbSourcePrefKey('reader_ttu', shortKey)"),
          reason: 'custom_fonts_page._readerPrefKey 应转调编码器');
      expect(cf.contains("'src:reader_ttu:'"), isFalse,
          reason: 'custom_fonts_page 不应再持有前缀字面量');
      for (final String src in <String>[pr, dm]) {
        expect(src, contains("dbSourcePrefKey('reader_ttu', 'font_catalog')"),
            reason: '字体 key 组应经编码器生成');
        expect(src.contains("'src:reader_ttu:font_catalog'"), isFalse,
            reason: '不应再硬编码字体 key 字面量');
      }
    });
  });
}
