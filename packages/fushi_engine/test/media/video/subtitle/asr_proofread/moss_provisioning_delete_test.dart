import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/moss_provisioning.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('moss_delete_');
    asr.asrSupportRootResolver = () async => root;
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void writeFile(String relative, int bytes) =>
      File(p.join(root.path, relative))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(bytes, 1));

  test('量与删：所有后端的运行库目录 + 权重目录都算、都删；别的模型不动', () async {
    final List<asr.AudioCppRuntimePack> packs = asr.kAudioCppRuntimePacks;
    writeFile(
      p.join('asr_runtimes', packs.first.directoryName, 'cli.bin'),
      100,
    );
    writeFile(p.join('asr_runtimes', packs.last.directoryName, 'lib.bin'), 50);
    writeFile(p.join('asr_models', 'moss', 'moss.gguf'), 30);
    writeFile(p.join('asr_models', 'parakeet', 'model.onnx'), 7);

    expect(await mossProvisionedDiskBytes(), 180);
    expect(await deleteMossProvisioned(), 180);
    expect(await mossProvisionedDiskBytes(), 0);
    expect(
      Directory(p.join(root.path, 'asr_models', 'moss')).existsSync(),
      isFalse,
    );
    expect(
      File(
        p.join(root.path, 'asr_models', 'parakeet', 'model.onnx'),
      ).existsSync(),
      isTrue,
      reason: '只删 MOSS 的东西',
    );
    expect(await deleteMossProvisioned(), 0, reason: '没有可删的返回 0');
  });
}
