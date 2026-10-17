import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/bluray_aacs_module.dart';
import 'package:fushi/src/media/video/video_disc_menu.dart';
import 'package:fushi_engine/media/video/bluray/aacs_configuration.dart';
import 'package:path/path.dart' as p;

final class _RecordingModule implements BlurayAacsModule {
  final List<(Uint8List, Uint8List?)> calls = <(Uint8List, Uint8List?)>[];

  @override
  void setDiscKey(Uint8List discId, Uint8List? volumeUniqueKey) {
    calls.add((discId, volumeUniqueKey));
  }
}

void main() {
  late Directory disc;
  final Uint8List unitKeyFile = Uint8List.fromList(
    List<int>.generate(64, (int i) => i * 3),
  );
  final Uint8List vuk = Uint8List.fromList(
    List<int>.generate(16, (int i) => i),
  );
  final Uint8List discId = Uint8List.fromList(sha1.convert(unitKeyFile).bytes);

  setUp(() {
    disc = Directory.systemTemp.createTempSync('fushi_aacs_menu_');
    Directory(p.join(disc.path, 'BDMV', 'STREAM')).createSync(recursive: true);
    for (final String clip in <String>['00000.m2ts', '00001.m2ts']) {
      File(
        p.join(disc.path, 'BDMV', 'STREAM', clip),
      ).writeAsBytesSync(const <int>[0]);
    }
  });

  tearDown(() => disc.deleteSync(recursive: true));

  void protect() {
    Directory(p.join(disc.path, 'AACS')).createSync();
    File(
      p.join(disc.path, 'AACS', 'Unit_Key_RO.inf'),
    ).writeAsBytesSync(unitKeyFile);
  }

  Future<({Uint8List unitKeyFile, Uint8List volumeUniqueKey})> keyed(
    String _,
  ) async => (unitKeyFile: unitKeyFile, volumeUniqueKey: vuk);

  Future<({Uint8List unitKeyFile, Uint8List volumeUniqueKey})> Function(String)
  failing(AacsConfigurationError code) =>
      (String _) async => throw AacsConfigurationException(code);

  group('prepareBlurayMenuAacs', () {
    test('a disc without Unit_Key_RO.inf never touches the module', () async {
      final _RecordingModule module = _RecordingModule();
      final BlurayMenuAacsState state = await prepareBlurayMenuAacs(
        disc.path,
        module: () => module,
        loadConfiguration: (_) => fail('no KEYDB lookup for clear discs'),
      );
      expect(state, BlurayMenuAacsState.notProtected);
      expect(module.calls, isEmpty);
    });

    test(
      'platforms without a bundled module leave AACS to the system',
      () async {
        protect();
        final BlurayMenuAacsState state = await prepareBlurayMenuAacs(
          disc.path,
          module: () => null,
          loadConfiguration: (_) => fail('no lookup without a module'),
        );
        expect(state, BlurayMenuAacsState.unmanaged);
      },
    );

    test('registers the exact disc-ID VUK from KEYDB', () async {
      protect();
      final _RecordingModule module = _RecordingModule();
      final BlurayMenuAacsState state = await prepareBlurayMenuAacs(
        disc.path,
        module: () => module,
        loadConfiguration: keyed,
        isEncryptedStream: (_) async => true,
      );
      expect(state, BlurayMenuAacsState.keyed);
      expect(module.calls, hasLength(1));
      expect(module.calls.single.$1, discId);
      expect(module.calls.single.$2, vuk);
    });

    test(
      'an encrypted disc without a key fails with the KEYDB error',
      () async {
        protect();
        final _RecordingModule module = _RecordingModule();
        final List<String> checked = <String>[];
        await expectLater(
          prepareBlurayMenuAacs(
            disc.path,
            module: () => module,
            loadConfiguration: failing(AacsConfigurationError.discNotMatched),
            isEncryptedStream: (String path) async {
              checked.add(p.basename(path));
              return p.basename(path) == '00001.m2ts';
            },
          ),
          throwsA(
            isA<AacsConfigurationException>().having(
              (AacsConfigurationException e) => e.code,
              'code',
              AacsConfigurationError.discNotMatched,
            ),
          ),
        );
        expect(checked, contains('00001.m2ts'));
        expect(module.calls, isEmpty);
      },
    );

    test('a decrypted copy that kept AACS metadata opens key-less', () async {
      protect();
      final _RecordingModule module = _RecordingModule();
      for (final AacsConfigurationError code in <AacsConfigurationError>[
        AacsConfigurationError.missingConfiguration,
        AacsConfigurationError.unsupportedDisc,
        AacsConfigurationError.networkFailure,
      ]) {
        module.calls.clear();
        final BlurayMenuAacsState state = await prepareBlurayMenuAacs(
          disc.path,
          module: () => module,
          loadConfiguration: failing(code),
          isEncryptedStream: (_) async => false,
        );
        expect(state, BlurayMenuAacsState.clear, reason: code.name);
        expect(module.calls.single.$1, discId, reason: code.name);
        expect(module.calls.single.$2, isNull, reason: code.name);
      }
    });
  });

  group('disc open failure log', () {
    test('libbluray and mpv stream errors mean the disc never opened', () {
      expect(isVideoDiscOpenFailureLog(prefix: 'bd', level: 'error'), isTrue);
      expect(
        isVideoDiscOpenFailureLog(prefix: ' stream ', level: 'error '),
        isTrue,
      );
    });

    test('warnings and other modules do not fail the session', () {
      // Read errors on a damaged clip are warnings while the menu still runs.
      expect(isVideoDiscOpenFailureLog(prefix: 'bd', level: 'warn'), isFalse);
      expect(isVideoDiscOpenFailureLog(prefix: 'vd', level: 'error'), isFalse);
      expect(
        isVideoDiscOpenFailureLog(prefix: 'ffmpeg', level: 'error'),
        isFalse,
      );
    });
  });

  test('library names match what each platform libbluray opens', () {
    // native/fushi_aacs/CMakeLists.txt OUTPUT_NAME per platform.
    final String? name = fushiAacsLibraryName();
    if (Platform.isWindows) expect(name, 'libaacs.dll');
    if (Platform.isMacOS) expect(name, 'libaacs.dylib');
    if (Platform.isLinux) expect(name, isNull);
  });
}
