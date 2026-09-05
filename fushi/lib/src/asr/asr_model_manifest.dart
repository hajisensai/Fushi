/// 有声书 ASR 模型清单：文件名、下载直链、预期字节数、角色。
///
/// 模型是 ReazonSpeech k2-v2（字符级 zipformer2 RNN-T，sherpa-onnx 导出，
/// Apache-2.0，`reazon-research/reazonspeech-k2-v2`），VAD 是 k2-fsa 在
/// sherpa-onnx release 里重新导出的 silero-vad v4（Apache-2.0，仅 16 kHz 分支）。
/// IO 名称/形状见 `asr_types.dart` 文件头。
///
/// 字节数**精确值**已核实（2026-09-05，HF API `?blobs=true` 与 GitHub release
/// 资产大小）：
///
/// | 文件 | 字节 | 备注 |
/// |---|---|---|
/// | `encoder-epoch-99-avg-1.onnx` | 592,347,848 | fp32 编码器（GPU EP 用） |
/// | `encoder-epoch-99-avg-1.int8.onnx` | 154,670,139 | int8 编码器（CPU 用） |
/// | `decoder-epoch-99-avg-1.int8.onnx` | 2,959,337 | 两个变体共用 |
/// | `joiner-epoch-99-avg-1.int8.onnx` | 2,696,970 | 两个变体共用 |
/// | `tokens.txt` | 45,754 | 5224 行 |
/// | `silero_vad.onnx` | 643,854 | k2-fsa release `asr-models` |
///
/// decoder / joiner 两个变体都用 int8：它们是自回归小 batch 逐帧调用，永远在
/// CPU 上跑（GPU 往返是负优化，见 `asr_engine.dart`），int8 在 CPU 上更快更小。
///
/// 镜像：`DeL-TaiseiOzaki/sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01`
/// 只托管了 int8 编码器（同字节数）与 `tokens.txt`，作为这两个文件的第二源；
/// hf-mirror 规则由共享层 `defaultHuggingFaceUrlCandidates` 对每个源派生。
///
/// 本层是纯数据 + 纯函数（就绪判定），没有 IO 副作用；下载与磁盘管理见
/// `asr_model_store.dart`。
library;

import 'dart:io';

import 'package:fushi/src/onnx/model_file_downloader.dart';

/// 编码器变体：fp32 给 GPU EP，int8 给 CPU（选择策略见 `asr_engine.dart`）。
enum AsrEncoderVariant { fp32, int8 }

/// 模型文件角色。decoder / joiner 也分精度：它们恒在 CPU 上逐帧跑，2026-09-05
/// 真机对拍（无職転生 01 前 10 分钟、185 段）：编码器走 DirectML 时 fp32
/// decoder/joiner 的 ASR 阶段 6.18 s、int8 8.66 s（小批次动态量化开销大于收益）；
/// 编码器走 CPU int8 时两者持平（19.5 s vs 18.9 s）。故 fp32 变体全套 fp32、int8
/// 变体全套 int8。
enum AsrModelRole {
  encoderFp32,
  encoderInt8,
  decoderFp32,
  decoderInt8,
  joinerFp32,
  joinerInt8,
  tokens,
  vad,
}

/// 清单里的一个模型文件。
class AsrModelFile implements DownloadableModelFile {
  const AsrModelFile({
    required this.fileName,
    required this.url,
    required this.expectedBytes,
    required this.role,
    this.mirrorUrls = const <String>[],
  });

  /// 落盘文件名（与远端 basename 一致，Range 续传直接复用同 URL）。
  @override
  final String fileName;

  /// 主源直链。
  @override
  final String url;

  /// 预期字节数（精确值；用于 totalBytes 展示与下载后长度校验）。
  @override
  final int expectedBytes;

  final AsrModelRole role;

  /// 第二源直链（同一 blob 的其他托管处）；主源及其 hf-mirror 全失败后按序尝试。
  final List<String> mirrorUrls;
}

const String _kPrimaryBase =
    'https://huggingface.co/reazon-research/reazonspeech-k2-v2/resolve/main/';
const String _kSecondaryBase =
    'https://huggingface.co/DeL-TaiseiOzaki/'
    'sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01/resolve/main/';

const AsrModelFile kAsrEncoderFp32File = AsrModelFile(
  fileName: 'encoder-epoch-99-avg-1.onnx',
  url: '${_kPrimaryBase}encoder-epoch-99-avg-1.onnx',
  expectedBytes: 592347848,
  role: AsrModelRole.encoderFp32,
);

const AsrModelFile kAsrEncoderInt8File = AsrModelFile(
  fileName: 'encoder-epoch-99-avg-1.int8.onnx',
  url: '${_kPrimaryBase}encoder-epoch-99-avg-1.int8.onnx',
  expectedBytes: 154670139,
  role: AsrModelRole.encoderInt8,
  mirrorUrls: <String>['${_kSecondaryBase}encoder-epoch-99-avg-1.int8.onnx'],
);

const AsrModelFile kAsrDecoderFp32File = AsrModelFile(
  fileName: 'decoder-epoch-99-avg-1.onnx',
  url: '${_kPrimaryBase}decoder-epoch-99-avg-1.onnx',
  expectedBytes: 11767836,
  role: AsrModelRole.decoderFp32,
  mirrorUrls: <String>['${_kSecondaryBase}decoder-epoch-99-avg-1.onnx'],
);

const AsrModelFile kAsrDecoderInt8File = AsrModelFile(
  fileName: 'decoder-epoch-99-avg-1.int8.onnx',
  url: '${_kPrimaryBase}decoder-epoch-99-avg-1.int8.onnx',
  expectedBytes: 2959337,
  role: AsrModelRole.decoderInt8,
);

const AsrModelFile kAsrJoinerFp32File = AsrModelFile(
  fileName: 'joiner-epoch-99-avg-1.onnx',
  url: '${_kPrimaryBase}joiner-epoch-99-avg-1.onnx',
  expectedBytes: 10720115,
  role: AsrModelRole.joinerFp32,
  mirrorUrls: <String>['${_kSecondaryBase}joiner-epoch-99-avg-1.onnx'],
);

const AsrModelFile kAsrJoinerInt8File = AsrModelFile(
  fileName: 'joiner-epoch-99-avg-1.int8.onnx',
  url: '${_kPrimaryBase}joiner-epoch-99-avg-1.int8.onnx',
  expectedBytes: 2696970,
  role: AsrModelRole.joinerInt8,
);

const AsrModelFile kAsrTokensFile = AsrModelFile(
  fileName: 'tokens.txt',
  url: '${_kPrimaryBase}tokens.txt',
  expectedBytes: 45754,
  role: AsrModelRole.tokens,
  mirrorUrls: <String>['${_kSecondaryBase}tokens.txt'],
);

const AsrModelFile kAsrVadFile = AsrModelFile(
  fileName: 'silero_vad.onnx',
  url:
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'asr-models/silero_vad.onnx',
  expectedBytes: 643854,
  role: AsrModelRole.vad,
);

/// 全部已知文件（两个编码器变体的并集），按角色唯一。
const List<AsrModelFile> kAsrModelFiles = <AsrModelFile>[
  kAsrEncoderFp32File,
  kAsrEncoderInt8File,
  kAsrDecoderFp32File,
  kAsrDecoderInt8File,
  kAsrJoinerFp32File,
  kAsrJoinerInt8File,
  kAsrTokensFile,
  kAsrVadFile,
];

/// 某个编码器变体跑起来需要的全部文件（同精度的 encoder / decoder / joiner +
/// 共用的 tokens / vad）。
List<AsrModelFile> asrModelFilesFor(AsrEncoderVariant variant) {
  return <AsrModelFile>[
    asrModelFileForRole(asrEncoderRole(variant)),
    asrModelFileForRole(asrDecoderRole(variant)),
    asrModelFileForRole(asrJoinerRole(variant)),
    kAsrTokensFile,
    kAsrVadFile,
  ];
}

AsrModelRole asrEncoderRole(AsrEncoderVariant variant) => switch (variant) {
  AsrEncoderVariant.fp32 => AsrModelRole.encoderFp32,
  AsrEncoderVariant.int8 => AsrModelRole.encoderInt8,
};

AsrModelRole asrDecoderRole(AsrEncoderVariant variant) => switch (variant) {
  AsrEncoderVariant.fp32 => AsrModelRole.decoderFp32,
  AsrEncoderVariant.int8 => AsrModelRole.decoderInt8,
};

AsrModelRole asrJoinerRole(AsrEncoderVariant variant) => switch (variant) {
  AsrEncoderVariant.fp32 => AsrModelRole.joinerFp32,
  AsrEncoderVariant.int8 => AsrModelRole.joinerInt8,
};

/// 某个变体全套文件的预期总字节数（用于「需要下多少」展示）。
int asrModelTotalBytes(AsrEncoderVariant variant) {
  return asrModelFilesFor(
    variant,
  ).fold<int>(0, (int acc, AsrModelFile file) => acc + file.expectedBytes);
}

/// 按角色取清单条目。
AsrModelFile asrModelFileForRole(AsrModelRole role) {
  return kAsrModelFiles.firstWhere((AsrModelFile file) => file.role == role);
}

/// 一个模型文件的**下载候选 URL 序列**。
///
/// 顺序：主源 → 主源的 hf-mirror → 第二源 → 第二源的 hf-mirror。hf-mirror 排在
/// 第二源之前是因为两类失败的代价不对称：主源「连不上」是 20 s 超时，而第二源
/// 与主源同在 huggingface.co，网络不通时它也连不上，先试它只是再白付一次超时；
/// 反过来主源仓库下架是一次很快的 404，多试一个镜像几乎不花时间。
List<String> asrModelUrlCandidates(AsrModelFile file) {
  return <String>[
    for (final String source in <String>[file.url, ...file.mirrorUrls])
      ...defaultHuggingFaceUrlCandidates(source),
  ];
}

/// 最终文件是否就绪：存在且非空。
///
/// 刻意**不**在这里强校验长度==expected：下载器在 rename 前已做长度校验，能
/// 走到最终文件名的都通过了校验；而清单 expected 若因上游更新过期，强校验会把
/// 用户已可用的旧模型误判为缺失、陷入重复重下。
bool isAsrModelFileReady(File file) {
  if (!file.existsSync()) {
    return false;
  }
  return file.lengthSync() > 0;
}
