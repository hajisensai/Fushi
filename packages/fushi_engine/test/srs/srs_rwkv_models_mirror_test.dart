import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:test/test.dart';

// 3.3.x 热修：RWKV 权重不再下作者 release 里的 `sm56-package.zip`（作者重新打包了同名资产，
// 钉死的包大小 / 哈希对不上，所有人启用 RWKV 都报 size mismatch），改从 Fushi 镜像直接下
// int8 权重。这里咬住下载源和失败路径。

void main() {
  test('权重从 Fushi 镜像直接下载，钉的就是运行时校验的那份', () {
    expect(
      kSrsRwkvSmallWeights.url,
      startsWith(
        'https://github.com/hajisensai/Fushi/releases/download/rwkv-models/',
      ),
    );
    expect(
      kSrsRwkvSmallWeights.url,
      endsWith(
        '/${kSrsRwkvSmallWeightsSha256.substring(0, 16)}-sm56-weights.int8.bin',
      ),
    );
    expect(kSrsRwkvSmallWeights.fileName, kSrsRwkvSmallWeightsName);
    expect(kSrsRwkvSmallWeights.expectedBytes, kSrsRwkvSmallWeightsBytes);
    expect(kSrsRwkvSmallWeights.sha256, kSrsRwkvSmallWeightsSha256);
  });

  test('源码里不再有作者 release 的下载地址', () {
    final String source = File(
      'lib/srs/srs_rwkv_models.dart',
    ).readAsStringSync();
    expect(source, isNot(contains('JSchoreels/anki-rwkv/releases/download')));
  });

  test('旧下载路径留下的发布包会被清理', () async {
    expect(kSrsRwkvRetiredWeightsNames, contains('sm56-package.zip'));
    final Directory dir = await Directory.systemTemp.createTemp('rwkv_retired');
    addTearDown(() => dir.delete(recursive: true));
    final File leftover = File('${dir.path}/sm56-package.zip')
      ..writeAsBytesSync(Uint8List(16));
    await SrsRwkvModels(dir: dir).deleteRetired();
    expect(leftover.existsSync(), isFalse);
  });

  test('哈希对不上：删掉文件、不写校验标记、抛异常', () async {
    final Directory dir = await Directory.systemTemp.createTemp('rwkv_verify');
    addTearDown(() => dir.delete(recursive: true));
    final SrsRwkvModels models = SrsRwkvModels(dir: dir);
    models.weightsFile.writeAsBytesSync(Uint8List(kSrsRwkvSmallWeightsBytes));

    await expectLater(
      SrsRwkvModels.verifyDownloadedWeights(models.weightsFile),
      throwsA(isA<SrsRwkvModelException>()),
    );
    expect(models.weightsFile.existsSync(), isFalse);
    expect(File('${models.weightsFile.path}.verified').existsSync(), isFalse);
    expect(models.isReady, isFalse);
  });
}
