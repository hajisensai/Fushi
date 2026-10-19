// 种子元数据 bencode 的原生实现（ffc_parse_bencode_*）的绑定层测试。
//
// 完整语义（异常类型 / 报错先后 / 冻结的对拍摘要）在
// packages/fushi_engine/test/media/torrent/torrent_metainfo_native_test.dart；这里只钉输出
// 布局与解码。原生库是硬依赖：找不到库直接失败，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

Uint8List _bytes(String latin1) =>
    Uint8List.fromList(<int>[for (final int u in latin1.codeUnits) u & 0xFF]);

String _hex(Uint8List? bytes) => bytes == null
    ? 'null'
    : bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('v1 multi-file torrent: SHA-1 of the raw info bytes, decoded paths', () {
    final FfcTorrentInspection r = ffcInspectTorrentMetainfo(
      _bytes(
        'd8:announce3:x:y4:infod5:filesld6:lengthi3e4:pathl1:a2:b\xffeed6:lengthi0e'
        '10:path.utf-8l3:\xe6\x97\xa5eee4:name5:\xef\xbb\xbf x6:pieces0:ee',
      ),
    );
    expect(r.errorCode, isNull);
    expect(r.v1InfoHash, hasLength(20));
    expect(r.v2InfoHash, isNull);
    expect(r.name, ' x', reason: 'leading BOM stripped like utf8.decode');
    expect(r.filesError, isNull);
    expect(
      <String>[for (final FfcTorrentFile f in r.files) '${f.path}:${f.length}'],
      <String>['a/b�:3', '日:0'],
    );
  });

  test('known digest of a tiny v1 info dictionary', () {
    final FfcTorrentInspection r = ffcInspectTorrentMetainfo(
      Uint8List.fromList(
        utf8.encode(
          'd4:infod6:lengthi1e4:name4:test6:pieces20:aaaaaaaaaaaaaaaaaaaaee',
        ),
      ),
    );
    // Python: hashlib.sha1(b'd6:lengthi1e4:name4:test6:pieces20:aaaaaaaaaaaaaaaaaaaae')
    expect(_hex(r.v1InfoHash), 'cd10b6cb5c9c8be4e44a631c52d7fa2276a5ff0e');
  });

  test('pure v2 torrent reports only the SHA-256 hash and no files', () {
    final FfcTorrentInspection r = ffcInspectTorrentMetainfo(
      _bytes('d4:infod9:file treede12:meta versioni2e4:name4:testee'),
    );
    expect(r.v1InfoHash, isNull);
    expect(r.v2InfoHash, hasLength(32));
    expect(r.files, isEmpty);
  });

  test('fatal errors carry the TorrentMetainfoErrorCode index and message', () {
    FfcTorrentInspection r = ffcInspectTorrentMetainfo(_bytes('d1:ai03ee'));
    expect((r.errorCode, r.errorDetail), (2, 'non-canonical integer'));
    r = ffcInspectTorrentMetainfo(_bytes('d1:a9223372036854775807:e'));
    expect((r.errorCode, r.errorDetail), (2, 'truncated or malformed bencode'));
    r = ffcInspectTorrentMetainfo(_bytes('d1:ai1ee'));
    expect(
      (r.errorCode, r.errorDetail),
      (3, 'root dictionary has no info dictionary'),
    );
    r = ffcInspectTorrentMetainfo(_bytes('d4:infod4:name1:xee'));
    expect(
      (r.errorCode, r.errorDetail),
      (4, 'info dictionary is neither v1 nor v2'),
    );
  });

  test('file list errors are reported separately from fatal errors', () {
    final FfcTorrentInspection r = ffcInspectTorrentMetainfo(
      _bytes('d4:infod5:filesld6:lengthi1e4:pathleee6:pieces0:ee'),
    );
    expect(r.errorCode, isNull);
    expect(r.v1InfoHash, isNotNull);
    expect(r.filesError, 'info.files[0] has an empty path');
    expect(r.files, isEmpty);
  });

  test('empty input is rejected before the native call', () {
    expect(() => ffcInspectTorrentMetainfo(Uint8List(0)), throwsArgumentError);
  });
}
