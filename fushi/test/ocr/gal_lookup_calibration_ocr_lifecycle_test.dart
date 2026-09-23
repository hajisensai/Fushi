import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_model_manifest.dart';
import 'package:fushi_engine/ocr/ocr_inference.dart';
import 'package:fushi/src/ocr/gal_lookup_calibration_ocr.dart';
import 'package:path/path.dart' as p;

class _FakeSession implements OcrSession {
  _FakeSession(this.modelPath, {this.closeError});

  final String modelPath;
  final Error? closeError;
  bool closed = false;
  int closeCalls = 0;

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) async =>
      <String, OcrTensor>{};

  @override
  Future<void> close() async {
    closeCalls++;
    closed = true;
    final Error? error = closeError;
    if (error != null) throw error;
  }
}

class _FakeFactory implements OcrSessionFactory {
  _FakeFactory({
    this.failCreateAt,
    this.detectorCloseError,
    this.recognizerCloseError,
  });

  final int? failCreateAt;
  final Error? detectorCloseError;
  final Error? recognizerCloseError;
  final List<String> modelPaths = <String>[];
  final List<_FakeSession> sessions = <_FakeSession>[];

  @override
  Future<Set<OcrExecutionProvider>> availableAcceleratedProviders() async =>
      const <OcrExecutionProvider>{};

  @override
  Future<int?> deviceMemoryBudgetBytes() async => null;

  @override
  Future<OcrSession> createSession(
    String modelPath, {
    required List<OcrExecutionProvider> providers,
    void Function(OcrProviderResolution resolution)? onProviderResolved,
    int? intraOpNumThreads,
    Map<String, int>? freeDimensionOverrides,
  }) async {
    final int call = modelPaths.length + 1;
    modelPaths.add(modelPath);
    final int? failAt = failCreateAt;
    if (failAt == call) {
      throw StateError('fake create failed at call $call');
    }
    final Error? closeError = call == 1
        ? detectorCloseError
        : recognizerCloseError;
    final _FakeSession session = _FakeSession(
      modelPath,
      closeError: closeError,
    );
    sessions.add(session);
    return session;
  }
}

Future<Directory> _tempDirectory() async {
  final Directory directory = await Directory.systemTemp.createTemp(
    'gal-calibration-ocr-lifecycle-',
  );
  addTearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });
  return directory;
}

Future<GalCalibrationOcrEngine> _createEngine(
  Directory directory,
  _FakeFactory factory,
) {
  return GalCalibrationOcrEngine.create(
    directory: directory,
    factoryBuilder: () => factory,
  );
}

void main() {
  test('第二个 session 创建失败时关闭已创建的 detector session', () async {
    final Directory directory = await _tempDirectory();
    final _FakeFactory factory = _FakeFactory(failCreateAt: 2);

    await expectLater(
      _createEngine(directory, factory),
      throwsA(
        isA<StateError>().having(
          (StateError error) => error.message,
          'message',
          contains('fake create failed'),
        ),
      ),
    );

    expect(factory.modelPaths, hasLength(2));
    expect(p.basename(factory.modelPaths[1]), kPpOcrRecFileName);
    expect(factory.sessions, hasLength(1));
    expect(factory.sessions.single.closed, isTrue);
    expect(factory.sessions.single.closeCalls, 1);
  });

  test('字典读取失败时关闭 detector 和 recognizer session', () async {
    final Directory directory = await _tempDirectory();
    final _FakeFactory factory = _FakeFactory();

    await expectLater(
      _createEngine(directory, factory),
      throwsA(isA<FileSystemException>()),
    );

    expect(factory.sessions, hasLength(2));
    expect(
      factory.sessions.every((_FakeSession session) => session.closed),
      isTrue,
    );
    expect(
      factory.sessions.every((_FakeSession session) => session.closeCalls == 1),
      isTrue,
    );
  });

  test('字典解析失败时关闭 detector 和 recognizer session', () async {
    final Directory directory = await _tempDirectory();
    await File(
      p.join(directory.path, kPpOcrRecDictFileName),
    ).writeAsString('PostProcess:\n  character_dict:\n  - [unsupported]\n');
    final _FakeFactory factory = _FakeFactory();

    await expectLater(
      _createEngine(directory, factory),
      throwsA(isA<FormatException>()),
    );

    expect(factory.sessions, hasLength(2));
    expect(
      factory.sessions.every((_FakeSession session) => session.closed),
      isTrue,
    );
    expect(
      factory.sessions.every((_FakeSession session) => session.closeCalls == 1),
      isTrue,
    );
  });

  test('recognizer close 抛错时仍关闭 detector session', () async {
    final Directory directory = await _tempDirectory();
    await File(
      p.join(directory.path, kPpOcrRecDictFileName),
    ).writeAsString('PostProcess:\n  character_dict:\n  - あ\n');
    final StateError closeError = StateError('fake recognizer close failed');
    final _FakeFactory factory = _FakeFactory(recognizerCloseError: closeError);
    final GalCalibrationOcrEngine engine = await _createEngine(
      directory,
      factory,
    );

    await expectLater(engine.close(), throwsA(same(closeError)));
    expect(factory.sessions, hasLength(2));
    expect(factory.sessions[0].closed, isTrue);
    expect(factory.sessions[1].closed, isTrue);
    expect(factory.sessions[0].closeCalls, 1);
    expect(factory.sessions[1].closeCalls, 1);
  });

  test('detector close 抛错时 recognizer 已关闭', () async {
    final Directory directory = await _tempDirectory();
    await File(
      p.join(directory.path, kPpOcrRecDictFileName),
    ).writeAsString('PostProcess:\n  character_dict:\n  - あ\n');
    final StateError closeError = StateError('fake detector close failed');
    final _FakeFactory factory = _FakeFactory(detectorCloseError: closeError);
    final GalCalibrationOcrEngine engine = await _createEngine(
      directory,
      factory,
    );

    await expectLater(engine.close(), throwsA(same(closeError)));
    expect(factory.sessions, hasLength(2));
    expect(factory.sessions[0].closed, isTrue);
    expect(factory.sessions[1].closed, isTrue);
    expect(factory.sessions[0].closeCalls, 1);
    expect(factory.sessions[1].closeCalls, 1);
  });
}
