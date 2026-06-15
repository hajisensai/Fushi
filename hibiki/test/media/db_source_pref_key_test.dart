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
  });
}
