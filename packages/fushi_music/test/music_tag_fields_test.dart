import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_music/fushi_music.dart';
import 'package:test/test.dart';

/// 经真原生库读写 native/fushi_music/tests/fixtures/library 的副本（原件不动）。
/// 原生库是硬依赖：找不到库这里判红，不 skip。
String _fixture(String rel) {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final File candidate = File(
      '${dir.path}/native/fushi_music/tests/fixtures/library/$rel',
    );
    if (candidate.existsSync()) return candidate.path;
    dir = dir.parent;
  }
  throw StateError('fixture $rel not found from ${Directory.current.path}');
}

void main() {
  late MusicTagFieldsIo io;
  late Directory tmp;
  setUpAll(() => io = MusicTagFieldsIo.instance);
  setUp(() => tmp = Directory.systemTemp.createTempSync('ffm_tag_fields'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('线格式往返（含中文与空值）', () {
    final Map<MusicTagField, String> fields = <MusicTagField, String>{
      MusicTagField.title: '残酷な天使のテーゼ',
      MusicTagField.trackNo: '',
      MusicTagField.mbRecordingId: 'b1a9c0e9-d987-4042-ae91-78d6a3267d69',
    };
    final Uint8List bytes = encodeMusicTagFields(fields);
    expect(decodeMusicTagFields(bytes), fields);
  });

  for (final String rel in <String>[
    'Album A/01 First Song.flac',
    'Album A/02 Second Song.mp3',
    'Formats/alac.m4a',
  ]) {
    test('写后读回：$rel', () {
      final String path =
          '${tmp.path}/${rel.split('/').last.replaceAll(' ', '_')}';
      File(_fixture(rel)).copySync(path);
      final Map<MusicTagField, String> want = <MusicTagField, String>{
        MusicTagField.title: '新しい曲名',
        MusicTagField.artist: '歌手',
        MusicTagField.album: 'アルバム',
        MusicTagField.trackNo: '3',
        MusicTagField.catalogNo: 'LACA-15000',
        MusicTagField.mbRecordingId: 'b1a9c0e9-d987-4042-ae91-78d6a3267d69',
        MusicTagField.mbReleaseId: '2b7a4a8d-5d71-4f6f-9f8e-0c1d2e3f4a5b',
      };
      io.write(path, want);
      final Map<MusicTagField, String> got = io.read(path);
      for (final MapEntry<MusicTagField, String> e in want.entries) {
        expect(got[e.key], e.value, reason: e.key.wire);
      }
      io.write(path, <MusicTagField, String>{MusicTagField.catalogNo: ''});
      expect(io.read(path).containsKey(MusicTagField.catalogNo), isFalse);
    });
  }

  test('非法数字字段：抛异常且文件字节不变', () {
    final String path = '${tmp.path}/bad.flac';
    File(_fixture('Album A/01 First Song.flac')).copySync(path);
    final Uint8List before = File(path).readAsBytesSync();
    expect(
      () => io.write(path, <MusicTagField, String>{
        MusicTagField.title: 'x',
        MusicTagField.trackNo: 'seven',
      }),
      throwsA(
        isA<MusicTagWriteException>().having(
          (MusicTagWriteException e) => e.status,
          'status',
          FfmStatus.invalidArgument,
        ),
      ),
    );
    expect(File(path).readAsBytesSync(), before);
  });

  test('文件读不了：badInput', () {
    expect(
      () => io.read('${tmp.path}/missing.flac'),
      throwsA(
        isA<MusicTagWriteException>().having(
          (MusicTagWriteException e) => e.status,
          'status',
          FfmStatus.badInput,
        ),
      ),
    );
  });

  // #SIZTG3MNjt：ID3v2 encoding=0（ISO-8859-1）帧里装的是 Shift_JIS 字节。有声书导入页
  // 的作者栏经 [MusicTagFieldsIo.read] 取值，必须解成日文而不是 Latin-1 乱码。
  test('ID3 Latin-1 帧里的 Shift_JIS 字节按日文读出', () {
    final Uint8List mp3 = File(
      _fixture('Album A/02 Second Song.mp3'),
    ).readAsBytesSync();
    int start = 0;
    if (mp3[0] == 0x49 && mp3[1] == 0x44 && mp3[2] == 0x33) {
      final int size = mp3
          .sublist(6, 10)
          .fold<int>(0, (int acc, int x) => (acc << 7) | (x & 0x7F));
      start = 10 + size;
    }
    List<int> frame(String id, List<int> raw) => <int>[
      ...id.codeUnits,
      ...(ByteData(4)..setUint32(0, raw.length + 1)).buffer.asUint8List(),
      0, 0, // flags
      0, // encoding = ISO-8859-1
      ...raw,
    ];
    final List<int> body = <int>[
      // 「act.2 夜に駆ける」
      ...frame('TIT2', <int>[
        0x61, 0x63, 0x74, 0x2E, 0x32, 0x20, 0x96, 0xE9, 0x82, 0xC9, //
        0x8B, 0xEC, 0x82, 0xAF, 0x82, 0xE9,
      ]),
      // 「ヨルシカ」（片假名尾字节落在 ASCII 区）
      ...frame('TPE1', <int>[0x83, 0x88, 0x83, 0x8B, 0x83, 0x56, 0x83, 0x4A]),
    ];
    final int n = body.length;
    final List<int> tag = <int>[
      0x49, 0x44, 0x33, 3, 0, 0, //
      (n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F,
      ...body,
    ];
    final String path = '${tmp.path}/sjis.mp3';
    File(path).writeAsBytesSync(<int>[...tag, ...mp3.sublist(start)]);
    final Map<MusicTagField, String> got = io.read(path);
    expect(got[MusicTagField.title], 'act.2 夜に駆ける');
    expect(got[MusicTagField.artist], 'ヨルシカ');
  });
}
