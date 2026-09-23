import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_cuda_worker.dart';
import 'package:path/path.dart' as p;

// No torch installation or GPU is needed. The real worker runs in Python with
// fake model dependencies that validate its preprocessing/generation contract.
const String _fakeModules = r'''
import sys
import types

class OOM(Exception):
    pass

class Scope:
    def __enter__(self):
        return self
    def __exit__(self, *args):
        pass

torch = types.ModuleType("torch")
torch.cuda = types.SimpleNamespace(is_available=lambda: True,
    OutOfMemoryError=OOM, empty_cache=lambda: None)
torch.inference_mode = Scope
torch.set_num_threads = lambda count: None
sys.modules["torch"] = torch

class Image:
    def __init__(self, value, conversions=None):
        self.value = value
        self.conversions = conversions or []
    def __enter__(self):
        return self
    def __exit__(self, *args):
        pass
    def convert(self, mode):
        return Image(self.value, self.conversions + [mode])

pil = types.ModuleType("PIL")
pil.Image = types.SimpleNamespace(open=lambda data: Image(data.read().decode()))
sys.modules["PIL"] = pil
conv = types.ModuleType("jaconv")
conv.h2z = lambda text, **kwargs: text
sys.modules["jaconv"] = conv

class Tensor:
    def __init__(self, images):
        self.images = images
    def to(self, device):
        self.device = device
        return self

class LocalOnly:
    @classmethod
    def from_pretrained(cls, directory, **kwargs):
        assert kwargs == {"local_files_only": True, "trust_remote_code": False}
        return cls()

class Processor(LocalOnly):
    def __call__(self, images, return_tensors):
        assert return_tensors == "pt"
        assert all(image.conversions == ["L", "RGB"] for image in images)
        return types.SimpleNamespace(pixel_values=Tensor(images))

class Tokenizer(LocalOnly):
    def batch_decode(self, tokens, skip_special_tokens):
        assert skip_special_tokens
        return tokens

class Model(LocalOnly):
    def eval(self):
        return self
    def to(self, device):
        self.device = device
        return self
    def generate(self, pixels, **kwargs):
        assert pixels.device == self.device
        assert kwargs == dict(use_cache=True, num_beams=4, early_stopping=True,
            max_length=300, length_penalty=2.0, no_repeat_ngram_size=3,
            decoder_start_token_id=2, pad_token_id=0, eos_token_id=3)
        if self.device == "cuda":
            raise OOM("simulated full GPU")
        return [" cpu : " + image.value for image in pixels.images]

transformers = types.ModuleType("transformers")
transformers.BertTokenizer = Tokenizer
transformers.ViTImageProcessor = Processor
transformers.VisionEncoderDecoderModel = Model
transformers.GenerationMixin = type("GenerationMixin", (), {})
sys.modules["transformers"] = transformers
''';

Future<Map<String, dynamic>> _next(StreamIterator<String> lines) async {
  expect(await lines.moveNext().timeout(const Duration(seconds: 5)), isTrue);
  return jsonDecode(lines.current) as Map<String, dynamic>;
}

void main() {
  String? python;
  setUpAll(() async {
    final String candidate =
        Platform.environment['FUSHI_TEST_PYTHON'] ?? 'python';
    try {
      final ProcessResult probe = await Process.run(candidate, <String>[
        '--version',
      ]);
      if (probe.exitCode == 0) python = candidate;
    } on ProcessException {
      // Protocol/client tests remain mandatory without a system Python.
    }
  });

  Future<(Process, Directory)> startWorker(
    String prefix, {
    int? parentPid,
  }) async {
    final Directory root = Directory.systemTemp.createTempSync(
      'manga_cuda_worker_',
    );
    final File worker = File(p.join(root.path, 'worker.py'));
    await worker.writeAsString('$prefix\n$kMangaOcrCudaWorkerSource');
    final Process process = await Process.start(python!, <String>[
      '-u',
      worker.path,
      '--model-dir',
      root.path,
      '--batch-size',
      '8',
      '--parent-pid',
      '${parentPid ?? pid}',
    ]);
    addTearDown(() async {
      process.kill(ProcessSignal.sigkill);
      unawaited(process.stdin.close().catchError((Object _) {}));
      await process.exitCode.timeout(const Duration(seconds: 5));
      if (root.existsSync()) await root.delete(recursive: true);
    });
    return (process, root);
  }

  test(
    'worker preserves order and generation while OOM falls back 8/4/2/1/CPU',
    () async {
      if (python == null) {
        markTestSkipped(
          'Python is unavailable; set FUSHI_TEST_PYTHON to run worker tests',
        );
        return;
      }
      final (Process process, _) = await startWorker(_fakeModules);
      final StreamIterator<String> lines = StreamIterator<String>(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final Future<String> diagnostics = process.stderr
          .transform(utf8.decoder)
          .join();
      addTearDown(lines.cancel);
      expect((await _next(lines))['device'], 'cuda');
      process.stdin.writeln(
        jsonEncode(<String, Object>{
          'id': 1,
          'op': 'recognize',
          'images': <String>[
            for (int i = 0; i < 8; i++) base64Encode(utf8.encode('$i')),
          ],
        }),
      );
      for (final int count in <int>[4, 2, 1, 1]) {
        final Map<String, dynamic> status = await _next(lines);
        expect(status['event'], 'status');
        expect(status['batch_size'], count);
      }
      final Map<String, dynamic> first = await _next(lines);
      expect(first['event'], 'result');
      expect(first['id'], 1);
      expect(first['device'], 'cpu');
      expect(first['texts'], <String>[for (int i = 0; i < 8; i++) 'cpu:$i']);
      expect((first['degrade_reasons'] as List).last, contains('using CPU'));

      process.stdin.writeln(
        jsonEncode(<String, Object>{
          'id': 2,
          'op': 'recognize',
          'images': <String>[base64Encode(utf8.encode('next'))],
        }),
      );
      final Map<String, dynamic> second = await _next(lines);
      expect(
        second['event'],
        'result',
        reason: 'later requests must stay on CPU without retrying CUDA',
      );
      expect(second['texts'], <String>['cpu:next']);
      expect(second['degrade_reasons'], first['degrade_reasons']);
      await process.stdin.close();
      expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
      expect(await diagnostics, isEmpty);
    },
  );

  const String blockedImport = r'''
import importlib.abc
import sys
import time

class BlockTorch(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if fullname == "torch":
            print("blocked torch import", file=sys.stderr, flush=True)
            time.sleep(30)
        return None

sys.meta_path.insert(0, BlockTorch())
''';

  test('stdin EOF kills worker during blocked torch import', () async {
    if (python == null) {
      markTestSkipped('Python is unavailable');
      return;
    }
    final (Process process, _) = await startWorker(blockedImport);
    final StreamIterator<String> errors = StreamIterator<String>(
      process.stderr.transform(utf8.decoder).transform(const LineSplitter()),
    );
    addTearDown(errors.cancel);
    unawaited(process.stdout.drain<void>());
    expect(await errors.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    expect(errors.current, 'blocked torch import');
    await process.stdin.close();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 5)),
      0,
      reason: 'reader/watchdog must exist before heavyweight imports',
    );
  });

  test(
    'missing parent terminates worker even while stdin remains open',
    () async {
      if (python == null) {
        markTestSkipped('Python is unavailable');
        return;
      }
      final (Process process, _) = await startWorker(
        blockedImport,
        parentPid: 0,
      );
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      expect(await process.exitCode.timeout(const Duration(seconds: 5)), 0);
    },
  );
}
