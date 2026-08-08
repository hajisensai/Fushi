import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/migration/migration_exporter.dart';
import 'package:hibiki/src/migration/migration_space.dart';
import 'package:path/path.dart' as p;

/// 迁移存储空间闸门（用户诉求「别炸了」）的判据测试。
///
/// 重点覆盖「测不出 = 硬拦」这条：把 null 当「够用」正是要防的那次导到一半炸。
void main() {
  group('MigrationSpaceVerdict.decide', () {
    test('可用空间充足时放行，shortfall 为 0', () {
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 1000,
        freeBytes: 10 * 1024 * 1024 * 1024,
      );
      expect(v.measurable, isTrue);
      expect(v.sufficient, isTrue);
      expect(v.shortfallBytes, 0);
    });

    test('测不出可用空间（null）必须硬拦，绝不退化成「够用」', () {
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 1,
        freeBytes: null,
      );
      expect(v.measurable, isFalse);
      expect(v.sufficient, isFalse, reason: '「不知道」必须当「不够」处理，否则等于赌一把');
      expect(v.shortfallBytes, v.requiredBytes);
    });

    test('required 含留量系数与 APK 预留', () {
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 1000,
        freeBytes: 0,
        headroom: 2.0,
        apkReserveBytes: 500,
      );
      expect(v.requiredBytes, 2000 + 500);
      expect(v.sufficient, isFalse);
      expect(v.shortfallBytes, 2500);
    });

    test('可关掉 APK 预留（已装 Fushi 时不必再留）', () {
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 1000,
        freeBytes: 1100,
        includeApkReserve: false,
        headroom: 1.0,
      );
      expect(v.requiredBytes, 1000);
      expect(v.sufficient, isTrue);
    });

    test('恰好相等判为充足（>= 而非 >）', () {
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 100,
        freeBytes: 100,
        includeApkReserve: false,
        headroom: 1.0,
      );
      expect(v.sufficient, isTrue);
      expect(v.shortfallBytes, 0);
    });

    test('差一字节即拦（边界不放水）', () {
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 100,
        freeBytes: 99,
        includeApkReserve: false,
        headroom: 1.0,
      );
      expect(v.sufficient, isFalse);
      expect(v.shortfallBytes, 1);
    });

    test('留量系数用 ceil，不因取整少算', () {
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 3,
        freeBytes: 0,
        includeApkReserve: false,
        headroom: 1.10,
      );
      // 3 * 1.10 = 3.3 -> 4，绝不能是 3
      expect(v.requiredBytes, 4);
    });
  });

  group('MigrationSpaceEstimate.totalBytesFor', () {
    test('每批都整库带一份 DB，故 DB 按批数乘', () {
      const MigrationSpaceEstimate e = MigrationSpaceEstimate(
        perBatchBytes: <MigrationBatch, int>{
          MigrationBatch.core: 0,
          MigrationBatch.books: 500,
        },
        databaseBytes: 100,
      );
      expect(
        e.totalBytesFor(<MigrationBatch>[
          MigrationBatch.core,
          MigrationBatch.books,
        ]),
        // core: 0+100，books: 500+100
        700,
      );
    });

    test('未测量的批按 0 计，不抛', () {
      const MigrationSpaceEstimate e = MigrationSpaceEstimate(
        perBatchBytes: <MigrationBatch, int>{},
        databaseBytes: 0,
      );
      expect(e.totalBytesFor(<MigrationBatch>[MigrationBatch.localAudio]), 0);
    });
  });

  group('measureDirectoryBytes', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('migration_space_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('目录不存在返回 0（不抛）', () {
      expect(
        measureDirectoryBytes(Directory(p.join(tmp.path, 'nope'))),
        0,
      );
    });

    test('递归求和，含子目录', () {
      File(p.join(tmp.path, 'a.bin')).writeAsBytesSync(List<int>.filled(10, 0));
      final Directory sub = Directory(p.join(tmp.path, 'sub'))..createSync();
      File(p.join(sub.path, 'b.bin')).writeAsBytesSync(List<int>.filled(25, 0));
      expect(measureDirectoryBytes(tmp), 35);
    });

    test('空目录返回 0', () {
      expect(measureDirectoryBytes(tmp), 0);
    });
  });

  group('formatMigrationBytes', () {
    test('小于 1KB 用 B', () {
      expect(formatMigrationBytes(512), '512 B');
    });

    test('按 1024 进制换算', () {
      expect(formatMigrationBytes(1536), '1.5 KB');
      expect(formatMigrationBytes(5 * 1024 * 1024), '5.0 MB');
    });

    test('三位数以上省略小数，避免文案过长', () {
      expect(formatMigrationBytes(700 * 1024 * 1024), '700 MB');
    });
  });

  group('MigrationContentRoots.rootForBatch', () {
    test('core 无文件树，其余各批各归其根', () {
      final MigrationContentRoots roots = MigrationContentRoots(
        databaseFile: File('/db'),
        dictionaryResourceDirectory: Directory('/dict'),
        booksRootDirectory: Directory('/books'),
        audiobooksRootDirectory: Directory('/audiobooks'),
        fontsRootDirectory: Directory('/fonts'),
        localAudioRootDirectory: Directory('/localAudio'),
      );
      expect(roots.rootForBatch(MigrationBatch.core), isNull);
      expect(roots.rootForBatch(MigrationBatch.books)?.path, '/books');
      expect(
          roots.rootForBatch(MigrationBatch.localAudio)?.path, '/localAudio');
    });
  });
}
