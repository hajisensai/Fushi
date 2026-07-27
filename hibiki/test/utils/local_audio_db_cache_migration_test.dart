import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:hibiki/src/utils/misc/local_audio_db.dart';

/// BUG-1124 回归：本地音频缓存键的弱哈希碰撞 + 旧键缓存惰性迁移。
///
/// 旧 `_localAudioCacheKey` 把 16 位 UTF-16 码元整体 XOR 进 FNV-1a（字节口径被
/// 喂宽单元），CJK 文件名存在真实碰撞（生日搜索实证对见下）→ 两个不同词条的
/// 音频塌缩到同一个缓存文件，`extractBlob` 的「已存在即复用」早退让后查的词
/// 永远播放先查词条的音频。修复后改用 UTF-8 逐字节强口径（hibiki_core
/// `fnv1a32Hex`），并对旧弱键缓存文件做惰性 renameSync 迁移（对齐
/// AudiobookStorage.ensurePersistDir 先例）。
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hibiki_local_audio_mig');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('BUG-1124：弱口径碰撞对提取到两个不同缓存文件、字节各自正确', () {
    // 生日搜索找到的真实弱哈希碰撞对（旧口径下两键同为 a0c11ea4）。
    const String source = 'jpod';
    const String fileA = '肌陒衎柚.mp3';
    const String fileB = '汅肘鹾圃.mp3';

    final String dbPath = '${dir.path}/audio.db';
    final Database db = sqlite3.open(dbPath);
    db.execute('CREATE TABLE entries '
        '(expression TEXT, reading TEXT, file TEXT, source TEXT)');
    db.execute('CREATE TABLE android (file TEXT, source TEXT, data BLOB)');
    final PreparedStatement stmt =
        db.prepare('INSERT INTO android (file, source, data) VALUES (?,?,?)');
    stmt.execute(<Object?>[
      fileA,
      source,
      Uint8List.fromList(<int>[1, 1, 1])
    ]);
    stmt.execute(<Object?>[
      fileB,
      source,
      Uint8List.fromList(<int>[2, 2, 2])
    ]);
    stmt.dispose();
    db.dispose();

    final String? first = LocalAudioDb.extractBlob(
      dbPath: dbPath,
      file: fileA,
      source: source,
      cacheDir: dir,
    );
    final String? second = LocalAudioDb.extractBlob(
      dbPath: dbPath,
      file: fileB,
      source: source,
      cacheDir: dir,
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first, isNot(second), reason: '旧弱口径下两键碰撞 → 同一路径；强口径必须区分');
    expect(File(first!).readAsBytesSync(), <int>[1, 1, 1]);
    expect(File(second!).readAsBytesSync(), <int>[2, 2, 2],
        reason: '旧实现里第二个词条会因缓存早退拿到第一个词条的音频字节');
  });

  test('旧弱键 CJK 缓存文件被惰性 rename 到新键名（源库已移除也能复用）', () {
    // (source, file) = ('nhk16', '猫.mp3')：
    // 旧弱键 = fnv1a32Hex('nhk16\n猫.mp3'.codeUnits) = 969e5240，
    // 新强键 = fnv1a32Hex(utf8('nhk16\n猫.mp3'))     = fefaefdd。
    // 两个金标与 hibiki_core stable_hash_test.dart 的向量一致。
    final File legacy = File('${dir.path}/local_audio_969e5240.mp3');
    legacy.writeAsBytesSync(<int>[7, 8, 9]);

    final String? path = LocalAudioDb.extractBlob(
      dbPath: '${dir.path}/no_such.db', // 源库不存在：只能靠缓存副本
      file: '猫.mp3',
      source: 'nhk16',
      cacheDir: dir,
    );

    expect(path, isNotNull);
    expect(path!.replaceAll('\\', '/'), endsWith('/local_audio_fefaefdd.mp3'));
    expect(File(path).readAsBytesSync(), <int>[7, 8, 9]);
    expect(legacy.existsSync(), isFalse, reason: '迁移是 rename 不是 copy：旧键文件不残留');
  });

  test('ASCII 键新旧口径同值：缓存文件名不漂移、直接命中', () {
    // fnv1a32Hex('src1\na.mp3') 在 codeUnits 与 UTF-8 两口径下同为 a60fad2d
    // （码元全 < 0x80）——存量 ASCII 缓存零迁移。
    final File cached = File('${dir.path}/local_audio_a60fad2d.mp3');
    cached.writeAsBytesSync(<int>[4, 5, 6]);

    final String? path = LocalAudioDb.extractBlob(
      dbPath: '${dir.path}/no_such.db',
      file: 'a.mp3',
      source: 'src1',
      cacheDir: dir,
    );

    expect(path, isNotNull);
    expect(path!.replaceAll('\\', '/'), endsWith('/local_audio_a60fad2d.mp3'));
    expect(File(path).readAsBytesSync(), <int>[4, 5, 6]);
  });
}
