// ArchiveUnpacker：导入链路唯一的解包点的口令流程。zip / 7z 用真 7-Zip 打包的加密夹具
// （packages/fushi_compute/test/fixtures/archive，口令 `fushi-pw`）走真原生库；RAR 走注入的
// 假 7-Zip 进程。
import 'dart:io';

import 'package:fushi_engine/utils/archive/archive_unpacker.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _fixtures = '../fushi_compute/test/fixtures/archive';
const String _password = 'fushi-pw';

String _fixture(String name) => p.join(_fixtures, name);

/// 记录调用的口令来源：[answers] 依次作答（null = 取消）。
final class _ScriptedPasswords implements ArchivePasswordProvider {
  _ScriptedPasswords(this.answers, {Map<String, String>? saved})
    : saved = saved ?? <String, String>{};

  final List<ArchivePasswordAnswer?> answers;
  final Map<String, String> saved;
  final List<ArchivePasswordRequest> asked = <ArchivePasswordRequest>[];
  final List<String> forgotten = <String>[];

  @override
  Future<ArchivePasswordAnswer?> ask(ArchivePasswordRequest request) async {
    asked.add(request);
    return answers.isEmpty ? null : answers.removeAt(0);
  }

  @override
  Future<void> forget(String fingerprint) async {
    forgotten.add(fingerprint);
    saved.remove(fingerprint);
  }

  @override
  Future<void> remember(String fingerprint, String password) async =>
      saved[fingerprint] = password;

  @override
  Future<String?> remembered(String fingerprint) async => saved[fingerprint];
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('archive_unpacker_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  void expectPages(String dir) {
    for (final String page in <String>['001.png', '002.png', '003.png']) {
      expect(File(p.join(dir, '卷1', page)).existsSync(), isTrue, reason: page);
    }
  }

  /// 目标目录旁不留暂存目录。
  void expectNoStagingLeft() {
    expect(
      tmp.listSync().where(
        (FileSystemEntity e) => e.path.contains('.unpacking-'),
      ),
      isEmpty,
    );
  }

  test('未加密的 zip / 7z 不问口令', () async {
    final _ScriptedPasswords passwords = _ScriptedPasswords(
      <ArchivePasswordAnswer?>[],
    );
    for (final String name in <String>['plain.zip', 'plain.7z']) {
      final String out = p.join(tmp.path, name);
      final ArchiveUnpackResult result = await ArchiveUnpacker(
        passwords: passwords,
      ).extract(_fixture(name), intoDir: out);
      expect(result.encrypted, isFalse);
      expect(result.files, 4);
      expectPages(out);
    }
    expect(passwords.asked, isEmpty);
    expectNoStagingLeft();
  });

  /// 把夹具按字节切成 `<name>.001`、`.002`、`.003`（7-Zip「分卷」的切法）放进 [dir]。
  List<String> splitFixture(String name, Directory dir) {
    final List<int> bytes = File(_fixture(name)).readAsBytesSync();
    final int chunk = (bytes.length + 2) ~/ 3;
    return <String>[
      for (int i = 0; i * chunk < bytes.length; i++)
        (File(
              p.join(dir.path, '$name.${'${i + 1}'.padLeft(3, '0')}'),
            )..writeAsBytesSync(
              bytes.sublist(
                i * chunk,
                (i + 1) * chunk > bytes.length ? bytes.length : (i + 1) * chunk,
              ),
            ))
            .path,
    ];
  }

  test('分卷 7z：从第一卷解开，整包记住的口令通用；后续卷 / 缺卷报 missingVolume', () async {
    final Directory parts = Directory(p.join(tmp.path, 'parts'))..createSync();
    final List<String> volumes = splitFixture('content_encrypted.7z', parts);
    final String wholeFp = (await ArchiveUnpacker().probe(
      _fixture('content_encrypted.7z'),
    )).fingerprint;
    final _ScriptedPasswords passwords = _ScriptedPasswords(
      <ArchivePasswordAnswer?>[],
      saved: <String, String>{wholeFp: _password},
    );
    final String out = p.join(tmp.path, 'out');
    final ArchiveUnpackResult result = await ArchiveUnpacker(
      passwords: passwords,
    ).extract(volumes.first, intoDir: out);
    expect(result.encrypted, isTrue);
    expect(result.files, 4);
    expectPages(out);
    expect(passwords.asked, isEmpty);

    Future<void> expectMissing(String path) => expectLater(
      ArchiveUnpacker(
        passwords: passwords,
      ).extract(path, intoDir: p.join(tmp.path, 'bad')),
      throwsA(
        isA<ArchiveUnpackException>().having(
          (ArchiveUnpackException e) => e.failure,
          'failure',
          ArchiveUnpackFailure.missingVolume,
        ),
      ),
    );
    await expectMissing(volumes[1]);
    File(volumes.last).deleteSync();
    await expectMissing(volumes.first);
    expectNoStagingLeft();
  });

  for (final String name in <String>[
    'aes256.zip',
    'zipcrypto.zip',
    'content_encrypted.7z',
    'header_encrypted.7z',
  ]) {
    test('$name：错口令提示后重试，对了解开并按指纹记住', () async {
      final _ScriptedPasswords passwords =
          _ScriptedPasswords(<ArchivePasswordAnswer?>[
            const ArchivePasswordAnswer('nope', remember: true),
            const ArchivePasswordAnswer(_password, remember: true),
          ]);
      final String out = p.join(tmp.path, 'out');
      final ArchiveUnpackResult result = await ArchiveUnpacker(
        passwords: passwords,
      ).extract(_fixture(name), intoDir: out);

      expect(result.encrypted, isTrue);
      expectPages(out);
      expect(passwords.asked, hasLength(2));
      expect(passwords.asked[0].previousWrong, isFalse);
      expect(passwords.asked[1].previousWrong, isTrue);
      expect(passwords.asked[1].attempt, 1);
      // 错口令那次没被记住，记住的是解开的那个。
      expect(passwords.saved.values.single, _password);
      expect(passwords.saved.keys.single, passwords.asked[0].fingerprint);
      expectNoStagingLeft();

      // 第二次导入同一个包：直接用记住的口令，不再问。
      final _ScriptedPasswords again = _ScriptedPasswords(
        <ArchivePasswordAnswer?>[],
        saved: Map<String, String>.of(passwords.saved),
      );
      await ArchiveUnpacker(
        passwords: again,
      ).extract(_fixture(name), intoDir: p.join(tmp.path, 'again'));
      expect(again.asked, isEmpty);
    });
  }

  test('记住的口令失效：删掉它、带提示重问', () async {
    final String fingerprint = (await ArchiveUnpacker().probe(
      _fixture('aes256.zip'),
    )).fingerprint;
    final _ScriptedPasswords passwords = _ScriptedPasswords(
      <ArchivePasswordAnswer?>[const ArchivePasswordAnswer(_password)],
      saved: <String, String>{fingerprint: 'stale'},
    );
    await ArchiveUnpacker(
      passwords: passwords,
    ).extract(_fixture('aes256.zip'), intoDir: p.join(tmp.path, 'out'));
    expect(passwords.forgotten, <String>[fingerprint]);
    expect(passwords.asked.single.rememberedRejected, isTrue);
    // 这次没勾记住：不留旧口令也不存新口令。
    expect(passwords.saved, isEmpty);
  });

  test('用户取消 → passwordCancelled，目标目录不留半截文件', () async {
    final String out = p.join(tmp.path, 'out');
    await expectLater(
      ArchiveUnpacker(
        passwords: _ScriptedPasswords(<ArchivePasswordAnswer?>[
          const ArchivePasswordAnswer('nope'),
          null,
        ]),
      ).extract(_fixture('content_encrypted.7z'), intoDir: out),
      throwsA(
        isA<ArchiveUnpackException>().having(
          (ArchiveUnpackException e) => e.failure,
          'failure',
          ArchiveUnpackFailure.passwordCancelled,
        ),
      ),
    );
    expect(Directory(out).existsSync(), isFalse);
    expectNoStagingLeft();
  });

  test('没有口令来源 / 只用记住的口令 → passwordRequired，不问', () async {
    final _ScriptedPasswords inner = _ScriptedPasswords(
      <ArchivePasswordAnswer?>[const ArchivePasswordAnswer(_password)],
    );
    for (final ArchivePasswordProvider? provider in <ArchivePasswordProvider?>[
      null,
      StoredOnlyArchivePasswords(inner),
    ]) {
      await expectLater(
        ArchiveUnpacker(passwords: provider).extract(
          _fixture('header_encrypted.7z'),
          intoDir: p.join(tmp.path, 'out'),
        ),
        throwsA(
          isA<ArchiveUnpackException>().having(
            (ArchiveUnpackException e) => e.failure,
            'failure',
            ArchiveUnpackFailure.passwordRequired,
          ),
        ),
      );
    }
    expect(inner.asked, isEmpty);
  });

  test('只用记住的口令：记过就能解', () async {
    final String fingerprint = (await ArchiveUnpacker().probe(
      _fixture('header_encrypted.7z'),
    )).fingerprint;
    final _ScriptedPasswords inner = _ScriptedPasswords(
      <ArchivePasswordAnswer?>[],
      saved: <String, String>{fingerprint: _password},
    );
    final String out = p.join(tmp.path, 'out');
    await ArchiveUnpacker(
      passwords: StoredOnlyArchivePasswords(inner),
    ).extract(_fixture('header_encrypted.7z'), intoDir: out);
    expectPages(out);
  });

  test('并入已存在的目标目录（同名覆盖、其它文件保留）', () async {
    final Directory out = Directory(p.join(tmp.path, 'out'))..createSync();
    File(p.join(out.path, 'keep.txt')).writeAsStringSync('keep');
    Directory(p.join(out.path, '卷1')).createSync();
    File(p.join(out.path, '卷1', '001.png')).writeAsStringSync('old');
    await ArchiveUnpacker().extract(_fixture('plain.zip'), intoDir: out.path);
    expect(File(p.join(out.path, 'keep.txt')).readAsStringSync(), 'keep');
    expect(
      File(p.join(out.path, '卷1', '001.png')).readAsBytesSync().take(4),
      <int>[0x89, 0x50, 0x4E, 0x47],
    );
    expectNoStagingLeft();
  });

  group('RAR（7-Zip 命令行）', () {
    late File rar;
    setUp(() {
      rar = File(p.join(tmp.path, 'book.rar'))
        ..writeAsBytesSync(<int>[0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0]);
    });

    const String listing = '''
Path = book.rar
Type = Rar5

----------
Path = pages\\001.png
Size = 3
Attributes = A
Encrypted = +
''';

    // 两种口令通道：标准输入（Windows 缺省，口令不进命令行）与 `-p`（类 Unix）。
    for (final bool viaStdin in <bool>[true, false]) {
      final String mode = viaStdin ? '标准输入' : '-p';

      /// 这次调用给 7-Zip 的口令（没给返回 null）。
      String? passwordOf(List<String> args, String? stdin) {
        if (viaStdin) {
          expect(
            args.where((String a) => a.startsWith('-p')),
            isEmpty,
            reason: '口令经标准输入时命令行里不能出现 -p',
          );
          expect(stdin, isNotNull);
          expect(stdin, endsWith('\n'));
          final String line = stdin!.substring(0, stdin.length - 1);
          return line.isEmpty ? null : line;
        }
        expect(stdin, isNull);
        final String flag = args.firstWhere((String a) => a.startsWith('-p'));
        return flag == '-p-' ? null : flag.substring(2);
      }

      test('条目表加密：问口令，错了重问，口令经$mode传给 7-Zip', () async {
        final List<List<String>> calls = <List<String>>[];
        final List<String?> given = <String?>[];
        final ArchiveUnpacker unpacker = ArchiveUnpacker(
          sevenZipOverride: 'fake-7z',
          passwordViaStdin: viaStdin,
          passwords: _ScriptedPasswords(<ArchivePasswordAnswer?>[
            const ArchivePasswordAnswer('nope'),
            const ArchivePasswordAnswer(_password),
          ]),
          runProcess: (String exe, List<String> args, {String? stdin}) async {
            calls.add(args);
            final String? password = passwordOf(args, stdin);
            given.add(password);
            // 包名前有 `--`：`-` 开头的包名不会被当成开关。
            expect(args[args.length - 2], '--');
            expect(args.last, rar.path);
            if (args.first == 'l') {
              return password == _password
                  ? ProcessResult(1, 0, listing, '')
                  : ProcessResult(
                      1,
                      2,
                      '',
                      'ERROR: book.rar : Can not open encrypted archive. Wrong password?',
                    );
            }
            final String outDir = args
                .firstWhere((String a) => a.startsWith('-o'))
                .substring(2);
            File(p.join(outDir, 'pages', '001.png'))
              ..createSync(recursive: true)
              ..writeAsStringSync('png');
            return ProcessResult(1, 0, '', '');
          },
        );
        final String out = p.join(tmp.path, 'out');
        final ArchiveUnpackResult result = await unpacker.extract(
          rar.path,
          intoDir: out,
          includeExtensions: <String>{'.png'},
        );
        expect(result.files, 1);
        expect(File(p.join(out, 'pages', '001.png')).existsSync(), isTrue);
        expect(calls.map((List<String> c) => c.first), <String>[
          'l', // 不带口令：列不出
          'l', // 错口令
          'l', // 对口令
          'x',
        ]);
        expect(given, <String?>[null, 'nope', _password, _password]);
        expect(calls.last, contains('-ir!*.png'));
      });

      test('条目内容加密（$mode）：清单不带口令就能读，解压报口令错就重问', () async {
        int extractCalls = 0;
        final _ScriptedPasswords passwords =
            _ScriptedPasswords(<ArchivePasswordAnswer?>[
              const ArchivePasswordAnswer('nope'),
              const ArchivePasswordAnswer(_password),
            ]);
        final ArchiveUnpacker unpacker = ArchiveUnpacker(
          sevenZipOverride: 'fake-7z',
          passwordViaStdin: viaStdin,
          passwords: passwords,
          runProcess: (String exe, List<String> args, {String? stdin}) async {
            final String? password = passwordOf(args, stdin);
            if (args.first == 'l') return ProcessResult(1, 0, listing, '');
            extractCalls++;
            if (password != _password) {
              return ProcessResult(
                1,
                2,
                'ERROR: Wrong password : pages\\001.png',
                '',
              );
            }
            final String outDir = args
                .firstWhere((String a) => a.startsWith('-o'))
                .substring(2);
            File(p.join(outDir, '001.png')).writeAsStringSync('png');
            return ProcessResult(1, 0, '', '');
          },
        );
        await unpacker.extract(rar.path, intoDir: p.join(tmp.path, 'out'));
        expect(extractCalls, 2);
        expect(
          passwords.asked.map((ArchivePasswordRequest r) => r.attempt),
          <int>[0, 1],
        );
        expectNoStagingLeft();
      });
    }

    test('找不到 7-Zip → toolMissing', () async {
      await expectLater(
        ArchiveUnpacker(
          sevenZipOverride: '',
        ).extract(rar.path, intoDir: p.join(tmp.path, 'out')),
        throwsA(
          isA<ArchiveUnpackException>().having(
            (ArchiveUnpackException e) => e.failure,
            'failure',
            ArchiveUnpackFailure.toolMissing,
          ),
        ),
      );
    });
  });

  test('不认识的格式 → unsupported', () async {
    final File junk = File(p.join(tmp.path, 'x.7z'))..writeAsStringSync('7z');
    await expectLater(
      ArchiveUnpacker().extract(junk.path, intoDir: p.join(tmp.path, 'out')),
      throwsA(
        isA<ArchiveUnpackException>().having(
          (ArchiveUnpackException e) => e.failure,
          'failure',
          ArchiveUnpackFailure.unsupported,
        ),
      ),
    );
  });
}
