// ffc_archive_* 绑定：真 7-Zip 打包的加密夹具（test/fixtures/archive，生成见
// make_fixture_pages.py），口令一律 `fushi-pw`。
import 'dart:io';

import 'package:fushi_compute/fushi_compute.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _fixtures = 'test/fixtures/archive';
const String _password = 'fushi-pw';

String _fixture(String name) => p.join(_fixtures, name);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('ffc_archive_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('探测：格式、加密方式、条目数与指纹', () {
    final Map<String, (FfcArchiveFormat, FfcArchiveEncryption, int)> cases =
        <String, (FfcArchiveFormat, FfcArchiveEncryption, int)>{
          'plain.zip': (FfcArchiveFormat.zip, FfcArchiveEncryption.none, 4),
          'aes256.zip': (FfcArchiveFormat.zip, FfcArchiveEncryption.entries, 4),
          'zipcrypto.zip': (
            FfcArchiveFormat.zip,
            FfcArchiveEncryption.entries,
            4,
          ),
          'plain.7z': (FfcArchiveFormat.sevenZip, FfcArchiveEncryption.none, 4),
          'content_encrypted.7z': (
            FfcArchiveFormat.sevenZip,
            FfcArchiveEncryption.entries,
            4,
          ),
          'header_encrypted.7z': (
            FfcArchiveFormat.sevenZip,
            FfcArchiveEncryption.headers,
            0,
          ),
        };
    final Set<String> fingerprints = <String>{};
    for (final MapEntry<String, (FfcArchiveFormat, FfcArchiveEncryption, int)> c
        in cases.entries) {
      final FfcArchiveInfo info = ffcArchiveProbeSync(_fixture(c.key));
      expect(info.format, c.value.$1, reason: c.key);
      expect(info.encryption, c.value.$2, reason: c.key);
      expect(info.entryCount, c.value.$3, reason: c.key);
      expect(info.fingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
      fingerprints.add(info.fingerprint);
    }
    expect(fingerprints, hasLength(cases.length));
    expect(
      ffcArchiveProbeSync(_fixture('aes256.zip')).fingerprint,
      ffcArchiveProbeSync(_fixture('aes256.zip')).fingerprint,
    );
  });

  for (final String name in <String>[
    'aes256.zip',
    'zipcrypto.zip',
    'content_encrypted.7z',
    'header_encrypted.7z',
  ]) {
    test('$name：无口令 → 要口令；错口令 → 口令错；对口令 → 解出', () {
      FfcArchiveFailure failureOf(String? password) {
        try {
          ffcArchiveExtractSync(
            _fixture(name),
            p.join(tmp.path, 'bad'),
            password: password,
          );
        } on FfcArchiveException catch (e) {
          return e.failure;
        }
        fail('$name 应当失败');
      }

      expect(failureOf(null), FfcArchiveFailure.passwordRequired);
      expect(failureOf('not-it'), FfcArchiveFailure.wrongPassword);

      final String out = p.join(tmp.path, 'ok');
      final FfcArchiveExtractStats stats = ffcArchiveExtractSync(
        _fixture(name),
        out,
        password: _password,
        includeExtensions: <String>{'.png'},
      );
      expect(stats.files, 3);
      for (final String page in <String>['001.png', '002.png', '003.png']) {
        final List<int> bytes = File(p.join(out, '卷1', page)).readAsBytesSync();
        expect(bytes.take(4), <int>[0x89, 0x50, 0x4E, 0x47]);
      }
      expect(File(p.join(out, '卷1', '读我.txt')).existsSync(), isFalse);
    });
  }

  test('上限按实际写出量强制', () {
    expect(
      () => ffcArchiveExtractSync(
        _fixture('plain.7z'),
        tmp.path,
        maxTotalBytes: 10,
      ),
      throwsA(
        isA<FfcArchiveException>().having(
          (FfcArchiveException e) => e.failure,
          'failure',
          FfcArchiveFailure.tooLarge,
        ),
      ),
    );
  });
}
