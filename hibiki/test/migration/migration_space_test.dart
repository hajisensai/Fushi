import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/migration/migration_exporter.dart';
import 'package:hibiki/src/migration/migration_space.dart';
import 'package:path/path.dart' as p;

/// 迁移存储空间闸门（用户诉求「别炸了」）的判据测试。
///
/// 重点覆盖「测不出 = 硬拦」这条：把 null 当「够用」正是要防的那次导到一半炸。
void main() {
  group('MigrationSpaceVerdict.decide 峰值倍数（导出份 + 导入份）', () {
    test('默认按两份算：中转归档 + Fushi 解压副本同时在盘上', () {
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 1000,
        freeBytes: 0,
        includeApkReserve: false,
        headroom: 1.0,
      );
      expect(v.requiredBytes, 2000, reason: '只算中转那一份＝放行后必在 Fushi 侧解压时磁盘满');
    });

    test('刚好够放导出、放不下导入 → 必须拦下（真实翻车形态）', () {
      // 用户实测：中转目录 11GB 导出全部成功，手机只剩 14GB，
      // Fushi 导入要再解压 11GB → 装不下。旧闸门（只算一份）会放行。
      const int gb = 1024 * 1024 * 1024;
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 11 * gb,
        freeBytes: 14 * gb,
        includeApkReserve: false,
        headroom: 1.0,
      );
      expect(v.sufficient, isFalse,
          reason: '11GB 导出 + 11GB 导入 = 22GB > 14GB 可用，必须在开始前就拦');
      expect(v.shortfallBytes, 22 * gb - 14 * gb);
    });

    test('关掉大批次后需求同步减半，用户有可操作的出路', () {
      // 关掉本地发音库（7.5GB）后只剩 3.5GB 要搬 → 峰值 7GB，14GB 装得下。
      const int gb = 1024 * 1024 * 1024;
      final MigrationSpaceVerdict v = MigrationSpaceVerdict.decide(
        estimatedBytes: 3 * gb + gb ~/ 2,
        freeBytes: 14 * gb,
        includeApkReserve: false,
        headroom: 1.0,
      );
      expect(v.sufficient, isTrue);
    });
  });

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
        peakCopies: 1.0,
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
        // 本组只测 headroom / APK / 边界的算术，峰值倍数固定为 1 隔离开。
        peakCopies: 1.0,
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
        // 本组只测 headroom / APK / 边界的算术，峰值倍数固定为 1 隔离开。
        peakCopies: 1.0,
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
        // 本组只测 headroom / APK / 边界的算术，峰值倍数固定为 1 隔离开。
        peakCopies: 1.0,
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
        peakCopies: 1.0,
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

  group('MigrationContentRoots', () {
    MigrationContentRoots rootsAt(String dbDir) => MigrationContentRoots(
          databaseFilePath: p.join(dbDir, 'hibiki.db'),
          databaseDirectoryPath: dbDir,
          dictionaryResourceDirectoryPath: '/dict',
          booksRootDirectoryPath: '/books',
          audiobooksRootDirectoryPath: '/audiobooks',
          fontsRootDirectoryPath: '/fonts',
        );

    test('core 与 localAudio 无「整棵树」根，其余各批各归其根', () {
      final MigrationContentRoots roots = rootsAt('/db');
      expect(roots.rootPathForBatch(MigrationBatch.core), isNull);
      expect(roots.rootPathForBatch(MigrationBatch.books), '/books');
      // localAudio 不是一棵树：它是 DB 目录一层里按文件名匹配的若干 .db。
      expect(roots.rootPathForBatch(MigrationBatch.localAudio), isNull);
    });

    test('core 的测量函数恒 0（只带 DB 行，无文件树）', () {
      expect(rootsAt('/db').measurerForBatch(MigrationBatch.core)(), 0);
    });
  });

  group('measureLocalAudioBytes', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('migration_local_audio_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    void write(String name, int bytes) => File(p.join(tmp.path, name))
        .writeAsBytesSync(List<int>.filled(bytes, 0));

    test('只算 local_audio_*.db 及其 -wal/-shm 兄弟，主库与其它支持文件不计', () {
      write('local_audio_jp.db', 100);
      write('local_audio_jp.db-wal', 20);
      write('local_audio_jp.db-shm', 5);
      // 以下都**不能**计入：主库、日志、其它 sidecar。
      write('hibiki.db', 9999);
      write('hibiki.db-wal', 8888);
      write('something_local_audio_x.db', 7777);
      expect(measureLocalAudioBytes(tmp), 125);
    });

    test('非递归：子目录里的同名文件不计（与打包规则一致）', () {
      write('local_audio_a.db', 10);
      final Directory sub = Directory(p.join(tmp.path, 'sub'))..createSync();
      File(p.join(sub.path, 'local_audio_b.db'))
          .writeAsBytesSync(List<int>.filled(500, 0));
      expect(measureLocalAudioBytes(tmp), 10);
    });

    test('目录不存在返回 0（不抛）', () {
      expect(measureLocalAudioBytes(Directory(p.join(tmp.path, 'nope'))), 0);
    });

    test('接进 measureBatchBytes 后按批落位', () {
      write('local_audio_a.db', 42);
      final MigrationSpaceEstimate e = measureBatchBytes(
        MigrationContentRoots(
          databaseFilePath: p.join(tmp.path, 'hibiki.db'),
          databaseDirectoryPath: tmp.path,
          dictionaryResourceDirectoryPath: p.join(tmp.path, 'nope_d'),
          booksRootDirectoryPath: p.join(tmp.path, 'nope_b'),
          audiobooksRootDirectoryPath: p.join(tmp.path, 'nope_ab'),
          fontsRootDirectoryPath: p.join(tmp.path, 'nope_f'),
        ),
        <MigrationBatch>[MigrationBatch.core, MigrationBatch.localAudio],
      );
      expect(e.perBatchBytes[MigrationBatch.localAudio], 42);
      expect(e.perBatchBytes[MigrationBatch.core], 0);
    });
  });
}
