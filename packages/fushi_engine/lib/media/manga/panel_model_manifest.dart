/// 分镜模型的不可变来源与输入/输出契约。
///
/// ONNX 二进制不入仓库；当前清单绑定不可变 prerelease asset 的 SHA-256 与字节数。
library;

import 'dart:io';

import 'package:crypto/crypto.dart';

const String kMangaPanelModelRevision =
    '535bbe1fc1e922d2108f918cd1bce29ba3516196';
const String kMangaPanelModelSource =
    'https://huggingface.co/leoxs22/manga-panel-detector-yolo26n';
const String kMangaPanelModelAssetUrl =
    'https://github.com/hajisensai/Fushi/releases/download/'
    'manga-panel-detector-onnx-v1/manga_panel_detector_yolo26n_fp32.onnx';
const String kMangaPanelModelFileName =
    'manga_panel_detector_yolo26n_fp32.onnx';
const String kMangaPanelModelLicense = 'Apache-2.0';

/// 上游模型训练所用的数据集。Manga109-s 的使用条款允许把训练所得模型用于商业
/// 用途，但**要求明确标明用到了该数据集**——署名因此必须跟着清单走，不能只留在
/// 上游模型卡里。README 的 On-device models 一节与 `tool/manga_panel/README.md`
/// 是同一份署名的人类可读出口。
const String kMangaPanelModelTrainingData = 'Manga109-s';
const String kMangaPanelModelTrainingDataUrl =
    'http://www.manga109.org/en/download_s.html';
const String kMangaPanelModelTrainingDataNotice =
    'The panel detection model is trained on the Manga109-s dataset '
    '(Matsui et al. 2017; Aizawa et al. 2020), whose terms require this use '
    'of the dataset to be clearly indicated.';

/// 由 [verify_onnx_contract.py] 对不可变 release asset 校验后回填。
const String? kMangaPanelModelSha256 =
    '6a2143c6130c358e390a8d425c51b22589fd43d4647485e2c011a553b73aaaed';
const int? kMangaPanelModelBytes = 9779394;

class MangaPanelModelManifest {
  const MangaPanelModelManifest({
    this.revision = kMangaPanelModelRevision,
    this.source = kMangaPanelModelSource,
    this.assetUrl = kMangaPanelModelAssetUrl,
    this.fileName = kMangaPanelModelFileName,
    this.sha256 = kMangaPanelModelSha256,
    this.bytes = kMangaPanelModelBytes,
    this.license = kMangaPanelModelLicense,
    this.trainingData = kMangaPanelModelTrainingData,
    this.trainingDataUrl = kMangaPanelModelTrainingDataUrl,
    this.trainingDataNotice = kMangaPanelModelTrainingDataNotice,
  });

  final String revision;
  final String source;
  final String assetUrl;
  final String fileName;
  final String? sha256;
  final int? bytes;
  final String license;
  final String trainingData;
  final String trainingDataUrl;
  final String trainingDataNotice;

  bool get isVerified =>
      bytes != null &&
      bytes! > 0 &&
      sha256 != null &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256!);
}

const MangaPanelModelManifest kMangaPanelModelManifest =
    MangaPanelModelManifest();

/// 原子 rename 前的模型校验。pending manifest 永远返回 false。
Future<bool> verifyMangaPanelModelFile(
  File file, {
  MangaPanelModelManifest manifest = kMangaPanelModelManifest,
}) async {
  if (!manifest.isVerified || !await file.exists()) return false;
  if (await file.length() != manifest.bytes) return false;
  final String digest = (await sha256.bind(file.openRead()).first).toString();
  return digest == manifest.sha256;
}
