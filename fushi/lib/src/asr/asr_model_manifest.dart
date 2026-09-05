/// 有声书 ASR 模型清单：按**语言**分成模型包，每包列出文件名、下载直链、
/// 预期字节数、角色。
///
/// 两个包都是 sherpa-onnx 导出的非流式 zipformer2 RNN-T，IO 名称/形状完全同构
/// （见 `asr_types.dart` 文件头），只有词表不同：
///
/// - **日语** ReazonSpeech k2-v2（字符级，5224 token，Apache-2.0，
///   `reazon-research/reazonspeech-k2-v2`）。
/// - **英语** LibriHeavy zipformer（BPE 756 token、带标点与大小写、byte-fallback，
///   Apache-2.0，`csukuangfj/sherpa-onnx-zipformer-en-libriheavy-20230830-large-punct-case`）。
///   选它而不是 GigaSpeech / LibriSpeech 导出：LibriHeavy 本身就是 5 万小时**有声书**
///   语料，且输出**带标点大小写**——切句（`asr_cue_builder.dart` 按句末标点切）与
///   正文匹配都直接受益；GigaSpeech 版只吐全大写无标点。2026-09-05 用 int8 对
///   《Harry Potter and the Philosopher's Stone》前 90 s 实测：
///   `Mr. and Mrs. Dursley, of No. 4 Privet Drive, were proud to say that they
///   were perfectly normal thank you very. "Much.`——大写字母/数字大量走 byte-fallback
///   token（`<0x50>` = P），解码时必须把连续字节 token 合成 UTF-8（`AsrTokenTable`）。
///
/// VAD 是 k2-fsa 在 sherpa-onnx release 里重新导出的 silero-vad v4（Apache-2.0，
/// 仅 16 kHz 分支），每个包各带一份（643 KB，与「一个包一个目录、删包即清空」的
/// 磁盘语义一致，不值得为它引入跨包共享目录）。
///
/// 字节数**精确值**已核实（HF API `?blobs=true` 与 GitHub release 资产大小）：
///
/// | 包 | 文件 | 字节 |
/// |---|---|---|
/// | ja | `encoder-epoch-99-avg-1.onnx` | 592,347,848 |
/// | ja | `encoder-epoch-99-avg-1.int8.onnx` | 154,670,139 |
/// | ja | `decoder-epoch-99-avg-1.onnx` / `.int8.onnx` | 11,767,836 / 2,959,337 |
/// | ja | `joiner-epoch-99-avg-1.onnx` / `.int8.onnx` | 10,720,115 / 2,696,970 |
/// | ja | `tokens.txt` | 45,754（5224 行） |
/// | en | `encoder-epoch-16-avg-2.onnx` | 259,807,148 |
/// | en | `encoder-epoch-16-avg-2.int8.onnx` | 68,780,141 |
/// | en | `decoder-epoch-16-avg-2.onnx` / `.int8.onnx` | 2,616,855 / 670,318 |
/// | en | `joiner-epoch-16-avg-2.onnx` / `.int8.onnx` | 1,551,717 / 391,431 |
/// | en | `tokens.txt` | 7,368（756 行） |
/// | 共 | `silero_vad.onnx` | 643,854 |
///
/// decoder / joiner 也分精度：它们恒在 CPU 上逐帧跑，2026-09-05 真机对拍
/// （无職転生 01 前 10 分钟、185 段）：编码器走 DirectML 时 fp32 decoder/joiner 的
/// ASR 阶段 6.18 s、int8 8.66 s（小批次动态量化开销大于收益）；编码器走 CPU int8 时
/// 两者持平。故 fp32 变体全套 fp32、int8 变体全套 int8。
///
/// 日语镜像：`DeL-TaiseiOzaki/sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01`
/// 只托管了 int8 编码器、fp32 decoder/joiner 与 `tokens.txt`，作为第二源；
/// hf-mirror 规则由共享层 `defaultHuggingFaceUrlCandidates` 对每个源派生。
///
/// 本层是纯数据 + 纯函数（就绪判定），没有 IO 副作用；下载与磁盘管理见
/// `asr_model_store.dart`。
library;

import 'dart:io';

import 'package:fushi/src/onnx/model_file_downloader.dart';

/// 转录语言（= 模型包）。持久化用 [AsrLanguage.tag]（BCP-47 主子标签），不要存
/// 枚举下标。
enum AsrLanguage {
  japanese('ja'),
  english('en');

  const AsrLanguage(this.tag);

  /// BCP-47 主子标签（`ja` / `en`），偏好与任务目录用它。
  final String tag;

  /// 由标签反查；不认识的标签返回 null（调用方自己定兜底）。
  static AsrLanguage? fromTag(String? tag) {
    for (final AsrLanguage l in values) {
      if (l.tag == tag) return l;
    }
    return null;
  }
}

/// 编码器变体：fp32 给 GPU EP，int8 给 CPU（选择策略见 `asr_engine.dart`）。
enum AsrEncoderVariant { fp32, int8 }

/// 模型文件角色。
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

/// 一种语言的整套模型文件（两个编码器变体的并集 + 共用 tokens / vad）。
class AsrModelPack {
  const AsrModelPack({
    required this.language,
    required this.id,
    required this.displayName,
    required this.sourceUrl,
    required this.files,
  });

  final AsrLanguage language;

  /// 磁盘目录名（`<appSupport>/asr_models/<id>`）与任务目录哈希的一部分；
  /// **冻结**，改了等于让用户已下载的模型与进行中的任务全部失联。
  final String id;

  /// 给用户看的模型名。
  final String displayName;

  /// 模型主页（设置页「来源」链接）。
  final String sourceUrl;

  /// 全部已知文件，按角色唯一。
  final List<AsrModelFile> files;

  /// 按角色取清单条目。
  AsrModelFile fileForRole(AsrModelRole role) =>
      files.firstWhere((AsrModelFile file) => file.role == role);

  /// 某个编码器变体跑起来需要的全部文件（同精度的 encoder / decoder / joiner +
  /// 共用的 tokens / vad）。编码器排第一：下载进度条与「先下最大的」都依赖这个顺序。
  List<AsrModelFile> filesFor(AsrEncoderVariant variant) {
    return <AsrModelFile>[
      fileForRole(asrEncoderRole(variant)),
      fileForRole(asrDecoderRole(variant)),
      fileForRole(asrJoinerRole(variant)),
      fileForRole(AsrModelRole.tokens),
      fileForRole(AsrModelRole.vad),
    ];
  }

  /// 某个变体全套文件的预期总字节数（用于「需要下多少」展示）。
  int totalBytes(AsrEncoderVariant variant) {
    return filesFor(
      variant,
    ).fold<int>(0, (int acc, AsrModelFile file) => acc + file.expectedBytes);
  }
}

const AsrModelFile kAsrVadFile = AsrModelFile(
  fileName: 'silero_vad.onnx',
  url:
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
      'asr-models/silero_vad.onnx',
  expectedBytes: 643854,
  role: AsrModelRole.vad,
);

// ── 日语：ReazonSpeech k2-v2 ────────────────────────────────────────────────

const String _kJaPrimaryBase =
    'https://huggingface.co/reazon-research/reazonspeech-k2-v2/resolve/main/';
const String _kJaSecondaryBase =
    'https://huggingface.co/DeL-TaiseiOzaki/'
    'sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01/resolve/main/';

const AsrModelPack kAsrJapanesePack = AsrModelPack(
  language: AsrLanguage.japanese,
  id: 'reazonspeech-k2-v2',
  displayName: 'ReazonSpeech k2-v2',
  sourceUrl: 'https://huggingface.co/reazon-research/reazonspeech-k2-v2',
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'encoder-epoch-99-avg-1.onnx',
      url: '${_kJaPrimaryBase}encoder-epoch-99-avg-1.onnx',
      expectedBytes: 592347848,
      role: AsrModelRole.encoderFp32,
    ),
    AsrModelFile(
      fileName: 'encoder-epoch-99-avg-1.int8.onnx',
      url: '${_kJaPrimaryBase}encoder-epoch-99-avg-1.int8.onnx',
      expectedBytes: 154670139,
      role: AsrModelRole.encoderInt8,
      mirrorUrls: <String>[
        '${_kJaSecondaryBase}encoder-epoch-99-avg-1.int8.onnx',
      ],
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-99-avg-1.onnx',
      url: '${_kJaPrimaryBase}decoder-epoch-99-avg-1.onnx',
      expectedBytes: 11767836,
      role: AsrModelRole.decoderFp32,
      mirrorUrls: <String>['${_kJaSecondaryBase}decoder-epoch-99-avg-1.onnx'],
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-99-avg-1.int8.onnx',
      url: '${_kJaPrimaryBase}decoder-epoch-99-avg-1.int8.onnx',
      expectedBytes: 2959337,
      role: AsrModelRole.decoderInt8,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-99-avg-1.onnx',
      url: '${_kJaPrimaryBase}joiner-epoch-99-avg-1.onnx',
      expectedBytes: 10720115,
      role: AsrModelRole.joinerFp32,
      mirrorUrls: <String>['${_kJaSecondaryBase}joiner-epoch-99-avg-1.onnx'],
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-99-avg-1.int8.onnx',
      url: '${_kJaPrimaryBase}joiner-epoch-99-avg-1.int8.onnx',
      expectedBytes: 2696970,
      role: AsrModelRole.joinerInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kJaPrimaryBase}tokens.txt',
      expectedBytes: 45754,
      role: AsrModelRole.tokens,
      mirrorUrls: <String>['${_kJaSecondaryBase}tokens.txt'],
    ),
    kAsrVadFile,
  ],
);

// ── 英语：LibriHeavy zipformer（标点 + 大小写） ──────────────────────────────

const String _kEnRepo =
    'csukuangfj/sherpa-onnx-zipformer-en-libriheavy-20230830-large-punct-case';
const String _kEnPrimaryBase = 'https://huggingface.co/$_kEnRepo/resolve/main/';

const AsrModelPack kAsrEnglishPack = AsrModelPack(
  language: AsrLanguage.english,
  id: 'zipformer-en-libriheavy-punct-case',
  displayName: 'LibriHeavy zipformer (English)',
  sourceUrl: 'https://huggingface.co/$_kEnRepo',
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'encoder-epoch-16-avg-2.onnx',
      url: '${_kEnPrimaryBase}encoder-epoch-16-avg-2.onnx',
      expectedBytes: 259807148,
      role: AsrModelRole.encoderFp32,
    ),
    AsrModelFile(
      fileName: 'encoder-epoch-16-avg-2.int8.onnx',
      url: '${_kEnPrimaryBase}encoder-epoch-16-avg-2.int8.onnx',
      expectedBytes: 68780141,
      role: AsrModelRole.encoderInt8,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-16-avg-2.onnx',
      url: '${_kEnPrimaryBase}decoder-epoch-16-avg-2.onnx',
      expectedBytes: 2616855,
      role: AsrModelRole.decoderFp32,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-16-avg-2.int8.onnx',
      url: '${_kEnPrimaryBase}decoder-epoch-16-avg-2.int8.onnx',
      expectedBytes: 670318,
      role: AsrModelRole.decoderInt8,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-16-avg-2.onnx',
      url: '${_kEnPrimaryBase}joiner-epoch-16-avg-2.onnx',
      expectedBytes: 1551717,
      role: AsrModelRole.joinerFp32,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-16-avg-2.int8.onnx',
      url: '${_kEnPrimaryBase}joiner-epoch-16-avg-2.int8.onnx',
      expectedBytes: 391431,
      role: AsrModelRole.joinerInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kEnPrimaryBase}tokens.txt',
      expectedBytes: 7368,
      role: AsrModelRole.tokens,
    ),
    kAsrVadFile,
  ],
);

/// 全部模型包，与 [AsrLanguage.values] 同序。
const List<AsrModelPack> kAsrModelPacks = <AsrModelPack>[
  kAsrJapanesePack,
  kAsrEnglishPack,
];

/// 某语言的模型包。
AsrModelPack asrModelPackFor(AsrLanguage language) {
  return kAsrModelPacks.firstWhere(
    (AsrModelPack pack) => pack.language == language,
  );
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
