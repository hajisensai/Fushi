import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/updates/build_info.dart';

const int _v2Id = 0x7109871a;
const int _v3Id = 0xf05368c0;

Uint8List _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

Uint8List _u64(int v) =>
    (ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List();

Uint8List _cat(List<List<int>> parts) {
  final BytesBuilder b = BytesBuilder();
  for (final List<int> p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

Uint8List _lp(List<int> bytes) => _cat(<List<int>>[_u32(bytes.length), bytes]);

Uint8List _seq(List<List<int>> items) =>
    _cat(<List<int>>[for (final List<int> i in items) _lp(i)]);

/// 一个 signer：signed data = digests, certificates, (v3 尾部字段)；后接 signatures, public key。
Uint8List _signer(List<List<int>> certs) {
  final Uint8List signedData = _cat(<List<int>>[
    _lp(
      _seq(<List<int>>[
        <int>[1, 2, 3],
      ]),
    ),
    _lp(_seq(certs)),
    _lp(Uint8List(0)),
  ]);
  return _cat(<List<int>>[
    _lp(signedData),
    _lp(
      _seq(<List<int>>[
        <int>[9, 9],
      ]),
    ),
    _lp(<int>[7, 7, 7]),
  ]);
}

Uint8List _schemeValue(List<Uint8List> signers) => _lp(_seq(signers));

Uint8List _pair(int id, List<int> value) =>
    _cat(<List<int>>[_u64(value.length + 4), _u32(id), value]);

Uint8List _block(List<Uint8List> pairs) {
  final Uint8List body = _cat(pairs);
  final int size = body.length + 24;
  return _cat(<List<int>>[
    _u64(size),
    body,
    _u64(size),
    'APK Sig Block 42'.codeUnits,
  ]);
}

/// 本地文件区 + 签名块 + 中央目录 + EOCD。
Uint8List _apk(Uint8List? block, {String comment = ''}) {
  final Uint8List local = Uint8List.fromList(List<int>.filled(37, 0x41));
  final Uint8List cd = Uint8List.fromList(<int>[0x50, 0x4b, 1, 2, 0, 0, 0, 0]);
  final int cdOffset = local.length + (block?.length ?? 0);
  final ByteData eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint32(12, cd.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little)
    ..setUint16(20, comment.length, Endian.little);
  return _cat(<List<int>>[
    local,
    if (block != null) block,
    cd,
    eocd.buffer.asUint8List(),
    comment.codeUnits,
  ]);
}

String _hex(List<int> der) => sha256.convert(der).toString();

void main() {
  final List<int> certA = List<int>.generate(40, (int i) => i);
  final List<int> certB = List<int>.generate(33, (int i) => 200 - i);
  final List<int> chainCert = <int>[5, 4, 3, 2, 1];

  test('v2 block yields first certificate digest of each signer', () {
    final Uint8List apk = _apk(
      _block(<Uint8List>[
        _pair(
          _v2Id,
          _schemeValue(<Uint8List>[
            _signer(<List<int>>[certA, chainCert]),
            _signer(<List<int>>[certB]),
          ]),
        ),
      ]),
    );
    expect(parseSignerCertDigests(apk), <String>[_hex(certA), _hex(certB)]);
  });

  test('v3 entry is used when both v2 and v3 are present', () {
    final Uint8List apk = _apk(
      _block(<Uint8List>[
        _pair(0x42726577, <int>[0, 0, 0, 0]),
        _pair(
          _v2Id,
          _schemeValue(<Uint8List>[
            _signer(<List<int>>[certA]),
          ]),
        ),
        _pair(
          _v3Id,
          _schemeValue(<Uint8List>[
            _signer(<List<int>>[certB]),
          ]),
        ),
      ]),
      comment: 'zip comment',
    );
    expect(parseSignerCertDigests(apk), <String>[_hex(certB)]);
  });

  test('duplicate signer certificates are reported once', () {
    final Uint8List apk = _apk(
      _block(<Uint8List>[
        _pair(
          _v3Id,
          _schemeValue(<Uint8List>[
            _signer(<List<int>>[certA]),
            _signer(<List<int>>[certA]),
          ]),
        ),
      ]),
    );
    expect(parseSignerCertDigests(apk), <String>[_hex(certA)]);
  });

  test('file reader matches the in-memory parser', () {
    final Directory dir = Directory.systemTemp.createTempSync('build_info_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final File f = File('${dir.path}/base.apk')
      ..writeAsBytesSync(
        _apk(
          _block(<Uint8List>[
            _pair(
              _v2Id,
              _schemeValue(<Uint8List>[
                _signer(<List<int>>[certA]),
              ]),
            ),
          ]),
        ),
      );
    expect(readApkSignerCertDigests(f.path), <String>[_hex(certA)]);
    expect(readApkSignerCertDigests('${dir.path}/missing.apk'), isEmpty);
  });

  test('no block, unknown entries only, or malformed inputs give empty', () {
    expect(parseSignerCertDigests(_apk(null)), isEmpty);
    expect(
      parseSignerCertDigests(
        _apk(
          _block(<Uint8List>[
            _pair(0x42726577, <int>[0, 0, 0, 0]),
          ]),
        ),
      ),
      isEmpty,
    );
    expect(parseSignerCertDigests(Uint8List(0)), isEmpty);
    expect(parseSignerCertDigests(Uint8List(10)), isEmpty);

    final Uint8List good = _apk(
      _block(<Uint8List>[
        _pair(
          _v2Id,
          _schemeValue(<Uint8List>[
            _signer(<List<int>>[certA]),
          ]),
        ),
      ]),
    );
    // 截断：EOCD 丢失。
    expect(
      parseSignerCertDigests(Uint8List.sublistView(good, 0, good.length - 5)),
      isEmpty,
    );
    // 块魔数损坏。
    final Uint8List badMagic = Uint8List.fromList(good);
    final int magicPos = 37 + (good.length - 37 - 8 - 22) - 16;
    badMagic[magicPos] ^= 0xff;
    expect(parseSignerCertDigests(badMagic), isEmpty);
    // 方案值里的长度前缀越界。
    final Uint8List badValue = _apk(
      _block(<Uint8List>[
        _pair(_v2Id, _cat(<List<int>>[_u32(9999), _u32(1)])),
      ]),
    );
    expect(parseSignerCertDigests(badValue), isEmpty);
  });

  test('non-Android platforms get an empty BuildInfo', () async {
    if (Platform.isAndroid) return;
    final BuildInfo info = await readBuildInfo();
    expect(info.id, isNull);
    expect(info.h, isEmpty);
    expect(info.k, isEmpty);
  });
}
