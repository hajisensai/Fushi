// inspectTorrentMetainfo 的 bencode 解析已搬到原生（ffc_parse_bencode_*，
// native/fushi_compute/src/parse/bencode.rs），Dart 实现已删除。
//
// 删除之前，用旧 Dart 实现在 [buildTorrentCorpus]（手写边界 + 深度 / 值数上限 + 2000 文件
// 大种子 + 600 个随机种子各带 3 个畸形变体）上生成了结果摘要 [_oldDartCorpusDigest]——异常
// 类型、错误码、消息、hash、name、文件清单全算在内；本测试对原生实现复算并比对。
//
// 原生库是硬依赖：找不到库直接失败，不 skip。
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fushi_engine/media/torrent/torrent_metainfo.dart';
import 'package:test/test.dart';

import 'torrent_metainfo_corpus.dart';

/// 旧 Dart 实现在 [buildTorrentCorpus] 上的 [digestOutcomes]（2026-10-18 生成）。
const int _oldDartCorpusDigest = -0xc7312281cff2afd;

String _describe(String latin1, {String? expected}) => describeTorrentOutcome((
  label: latin1,
  bytes: Uint8List.fromList(<int>[
    for (final int u in latin1.codeUnits) u & 0xFF,
  ]),
  expected: expected,
));

void main() {
  test('corpus digest matches the deleted Dart implementation', () {
    final List<TorrentCase> corpus = buildTorrentCorpus();
    expect(corpus.length, kHandWrittenTorrents.length + 13 + 2400);
    final int digest = digestOutcomes(<String>[
      for (final TorrentCase c in corpus) describeTorrentOutcome(c),
    ]);
    expect(digest.toRadixString(16), _oldDartCorpusDigest.toRadixString(16));
  });

  test('entry checks stay in Dart (empty / too large)', () {
    expect(
      () => inspectTorrentMetainfo(Uint8List(0)),
      throwsA(
        isA<TorrentMetainfoException>().having(
          (TorrentMetainfoException e) => e.message,
          'message',
          'torrent metainfo empty: body was empty',
        ),
      ),
    );
    expect(
      () => inspectTorrentMetainfo(Uint8List(kMaximumTorrentMetainfoBytes + 1)),
      throwsA(
        isA<TorrentMetainfoException>().having(
          (TorrentMetainfoException e) => e.code,
          'code',
          TorrentMetainfoErrorCode.tooLarge,
        ),
      ),
    );
  });

  test('representative outcomes (old Dart outputs)', () {
    String hand(int i) => describeTorrentOutcome((
      label: '',
      bytes: Uint8List.fromList(<int>[
        for (final int u in kHandWrittenTorrents[i].codeUnits) u & 0xFF,
      ]),
      expected: null,
    ));
    const String bad = 'TME invalidBencode torrent metainfo invalidBencode:';
    // 字节串长度让 index + length 溢出 i64：旧实现的 catch-all 消息。
    expect(hand(39), '$bad truncated or malformed bencode');
    // 两个不同的非法字节解码后都是 U+FFFD → 重复键；`﻿info` 剥 BOM 后就是 info。
    expect(hand(52), '$bad duplicate root key');
    expect(hand(54), '$bad duplicate root key');
    expect(
      hand(55),
      'ok id=7546833b94e434ef75a3365b623a47a76a4153e7 '
      'v1=7546833b94e434ef75a3365b623a47a76a4153e7 v2=null name="x" bytes=true '
      'files=1 [0 1 "x"]',
    );
    // Uint8List 也是 List：files / path 写成字节串。
    expect(hand(67), '$bad info.files[0] has an invalid path component');
    expect(hand(71), '$bad info.files[0] must be a dictionary');
    expect(hand(64), '$bad info.files[0] has an empty path');
    expect(
      hand(70),
      'ok id=fe9eb1fc4b33353d27f46762bf0d46154170b7dc '
      'v1=fe9eb1fc4b33353d27f46762bf0d46154170b7dc v2=null name=null bytes=true '
      'files=1 [0 1 "�("]',
    );
    expect(
      hand(80),
      'ok id=e0d2bc1ccffc9eb092df2c3d940050fd45b30861 '
      'v1=e0d2bc1ccffc9eb092df2c3d940050fd45b30861 v2=null '
      'name="���" bytes=true files=1 [0 1 "���"]',
    );
    expect(
      hand(85),
      'ok id=a52d0793c515d66ca365feda43e2182d35c2608e '
      'v1=a52d0793c515d66ca365feda43e2182d35c2608e '
      'v2=d426611517a8d59a9b61290706851a05d14fc5b78c8dc2869cb8f6318790a67e '
      'name="test" bytes=true files=1 [0 3 "test"]',
    );
    expect(
      hand(86),
      'ok id=a946d14f0c3ad6f86938f19b90ba988688d0847f v1=null '
      'v2=a946d14f0c3ad6f86938f19b90ba988688d0847fc50622bf9106a50fb68dc6ff '
      'name="test" bytes=true files=1 [0 3 "test"]',
    );
  });

  test('declared hash is compared before the file list is validated', () {
    // 文件清单不合法 + 声明的 hash 也不匹配：旧实现先报 hashMismatch。
    expect(
      _describe('d4:infod5:filesli1ee6:pieces0:ee', expected: '0' * 40),
      'TME hashMismatch torrent metainfo hashMismatch: declared info hash does not match metainfo',
    );
    expect(
      _describe('d4:infod5:filesli1ee6:pieces0:ee', expected: 'zz'),
      'TME hashMismatch torrent metainfo hashMismatch: declared info hash has an unsupported format',
    );
    expect(
      _describe('d4:infod5:filesli1ee6:pieces0:ee'),
      'TME invalidBencode torrent metainfo invalidBencode: info.files[0] must be a dictionary',
    );
  });

  test('suggestedName is trimmed after the BOM-stripping decode', () {
    final InspectedTorrentMetainfo r = inspectTorrentMetainfo(
      Uint8List.fromList(<int>[
        ...ascii.encode('d4:infod6:lengthi1e4:name7:'),
        0xEF,
        0xBB,
        0xBF,
        0x20,
        0x61,
        0x20,
        0x20,
        ...ascii.encode('6:pieces0:ee'),
      ]),
    );
    expect(r.suggestedName, 'a');
    expect(r.files.single.path, ' a  ');
  });
}
