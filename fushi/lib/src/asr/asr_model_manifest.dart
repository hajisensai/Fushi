/// 有声书 ASR 模型清单：按**语言**分成模型包，每包列出文件名、下载直链、
/// 预期字节数、角色，以及该包与通用解码路径的两个契约参数（decoder 上下文长度、
/// 索引张量整型）。
///
/// 17 种界面语言各有一个包服务。前 8 种是 sherpa-onnx / icefall 导出的非流式
/// zipformer2 RNN-T，IO **名称**完全同构（见 `asr_types.dart` 文件头），差异只在
/// 词表与两个契约参数；其余 9 种（de / es / fr / it / nl / pt / tr / id / ar）共用
/// Meta Omnilingual ASR 1B CTC（[AsrModelArchitecture.ctc]，原始波形输入）。每个
/// 包的 IO 都已用 `onnx` 逐文件核实（2026-09-06，`inspect_models.py`）：
///
/// | 语言 | 模型 | 词表 | ctx | 索引整型 | 备注 |
/// |---|---|---|---|---|---|
/// | ja | ReazonSpeech k2-v2 | 字符级 5224 | 2 | int64 | Apache-2.0 |
/// | en | LibriHeavy zipformer large punct-case | BPE 756、byte-fallback | 2 | int64 | 5 万小时**有声书**语料、输出带标点大小写 |
/// | zh | X-ASR zipformer zh-en punct（2026-06-03） | BPE 5000，含中英标点 token | 2 | **int32** | 词表无 `<unk>`；官方 `icefall-asr-zipformer-wenetspeech` 不带标点故不选 |
/// | yue | MDCC zipformer（2024-03-11） | 字符级 4852 | **1** | int64 | icefall `mdcc` recipe，只此一个非流式粤语 transducer |
/// | ko | zipformer-korean-2024-06-24 | BPE 5000，含 `.`/`?`/`,` | 2 | int64 | |
/// | ru | zipformer-ru-2025-04-20 | BPE 500 小写 | 2 | int64 | int8 仓库不含 int8 decoder，两变体共用 fp32 decoder |
/// | vi | zipformer-vi-2025-04-20 | BPE 2000 全大写 | 2 | int64 | 同上 |
/// | th | GigaSpeech 2 泰语 zipformer（2024-06-20） | BPE 2000 | 2 | int64 | icefall 仓库 `exp/` 里的导出 |
/// | 其余 9 种 | Omnilingual ASR 1B CTC v2（2026-02-05） | 字符级 10288，blank=`<s>` | — | — | `x[N,num_samples]` → `logits[N,T,10288]`，20 ms/帧；fp32 3.9 GB 外置权重走 GPU（≥ 8 GiB 显存），int8 1 GB 走 CPU |
///
/// 真机核对（2026-09-06，RTX 5090，各包自带 test wav，CPU int8 / GPU DirectML 两条
/// 路径）：韩语逐字命中参考；泰语除一个外来词外一致；越/俄/粤/中读出完整句子；
/// Omnilingual 德/英/法逐字命中（`alles hat ein ende nur die wurst hat zwei` /
/// `ask not what your country…` / `ne vous demandez pas…`），西语一处词序差。
///
/// - **英语**选 LibriHeavy 而不是 GigaSpeech / LibriSpeech 导出：LibriHeavy 本身就是
///   有声书语料，且输出**带标点大小写**——切句（`asr_cue_builder.dart` 按句末标点切）
///   与正文匹配都直接受益；GigaSpeech 版只吐全大写无标点。2026-09-05 用 int8 对
///   《Harry Potter and the Philosopher's Stone》前 90 s 实测：
///   `Mr. and Mrs. Dursley, of No. 4 Privet Drive, were proud to say that they
///   were perfectly normal thank you very. "Much.`——大写字母/数字大量走 byte-fallback
///   token（`<0x50>` = P），解码时必须把连续字节 token 合成 UTF-8（`AsrTokenTable`）。
/// - **上下文长度**（[AsrModelPack.decoderContextSize]）决定 decoder 输入 `y[N,ctx]`
///   与 Loop 图里 loop-carried `ctx` 的宽度；写错 ORT 建会话就报形状不符，不会静默
///   出错字。
/// - **索引整型**（[AsrModelPack.indexType]）决定 `x_lens` / `y` / `encoder_out_lens`
///   是 int64 还是 int32：X-ASR 的导出脚本把全部索引张量导成 int32，喂 int64 会被
///   ORT 直接拒绝。
///
/// VAD 是 k2-fsa 在 sherpa-onnx release 里重新导出的 silero-vad v4（Apache-2.0，
/// 仅 16 kHz 分支），每个包各带一份（643 KB，与「一个包一个目录、删包即清空」的
/// 磁盘语义一致，不值得为它引入跨包共享目录）。
///
/// 字节数**精确值**已核实（HF API `?blobs=true` 与 GitHub release 资产大小），
/// 每个 [AsrModelFile.expectedBytes] 旁不再重复列表。
///
/// decoder / joiner 也分精度：它们恒在 CPU 上逐帧跑，2026-09-05 真机对拍
/// （无職転生 01 前 10 分钟、185 段）：编码器走 DirectML 时 fp32 decoder/joiner 的
/// ASR 阶段 6.18 s、int8 8.66 s（小批次动态量化开销大于收益）；编码器走 CPU int8 时
/// 两者持平。故 fp32 变体全套 fp32、int8 变体全套 int8（上游没给 int8 decoder 的包
/// 两变体共用 fp32 decoder——它只有几 MB，且 int8 decoder 本来就不省时间）。
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

/// 转录语言。持久化用 [AsrLanguage.tag]（BCP-47 主子标签；粤语用 ISO 639-3
/// `yue` 与普通话 `zh` 区分——它们是两种口语，不是两种书写），不要存枚举下标。
///
/// [nativeName] 是该语言母语者认得的名字，转录弹层下拉与设置页模型行直接显示它
/// （与界面语言选择器同一惯例，`FushiLocalisations.localeNames`），不走 i18n。
enum AsrLanguage {
  japanese('ja', '日本語'),
  english('en', 'English'),
  mandarin('zh', '中文（普通话）'),
  cantonese('yue', '粵語'),
  korean('ko', '한국어'),
  russian('ru', 'Русский'),
  vietnamese('vi', 'Tiếng Việt'),
  thai('th', 'ไทย'),
  // 以下 9 种走 Omnilingual CTC 包（[kAsrOmnilingualPack]），与界面语言表
  // （`FushiLocalisations.localeNames`）一一对应。
  german('de', 'Deutsch'),
  spanish('es', 'Español'),
  french('fr', 'Français'),
  italian('it', 'Italiano'),
  dutch('nl', 'Nederlands'),
  portuguese('pt', 'Português'),
  turkish('tr', 'Türkçe'),
  indonesian('id', 'Bahasa Indonesia'),
  arabic('ar', 'العربية');

  const AsrLanguage(this.tag, this.nativeName);

  /// 语言标签（`ja` / `en` / `zh` / `yue` …），偏好与任务目录用它。
  final String tag;

  /// 母语写法的语言名。
  final String nativeName;

  /// 由标签反查；不认识的标签返回 null（调用方自己定兜底）。
  static AsrLanguage? fromTag(String? tag) {
    for (final AsrLanguage l in values) {
      if (l.tag == tag) return l;
    }
    return null;
  }

  /// 由书的语言标签（EPUB `dc:language`，如 `ja-JP` / `en_GB` / `EN` / `zh-Hant-HK`）
  /// 推转录语言：先看整串是否指向粤语（`yue` 主子标签、或 `zh` 带 `HK` / `MO` /
  /// `yue` 子标签），否则取主子标签查 [fromTag]。空 / 空白 / 没有对应语音模型的
  /// 语言返回 null，调用方回退到「上次选择」偏好。
  static AsrLanguage? fromBookLanguage(String? bookLanguage) {
    if (bookLanguage == null) return null;
    final String trimmed = bookLanguage.trim();
    if (trimmed.isEmpty) return null;
    final List<String> parts = trimmed
        .split(RegExp(r'[-_]'))
        .map((String s) => s.toLowerCase())
        .toList();
    final String primary = parts.first;
    if (primary == 'yue') return cantonese;
    if (primary == 'zh' || primary == 'cmn') {
      const Set<String> cantoneseSubtags = <String>{'hk', 'mo', 'yue'};
      final bool isCantonese = parts
          .skip(1)
          .any((String s) => cantoneseSubtags.contains(s));
      return isCantonese ? cantonese : mandarin;
    }
    return fromTag(primary);
  }
}

/// 编码器变体：fp32 给 GPU EP，int8 给 CPU（选择策略见 `asr_engine.dart`）。
enum AsrEncoderVariant { fp32, int8 }

/// 模型索引张量（`x_lens` / `y` / `encoder_out_lens`）的整型宽度。
enum AsrIndexType { int64, int32 }

/// 模型架构 = 解码路径：
/// - [transducer]：zipformer RNN-T，encoder / decoder / joiner 三个文件，逐帧贪心
///   （`asr_transducer_decoder.dart`）；
/// - [ctc]：单个编码器直接吐 `logits[N, T, V]`，逐帧 argmax 折叠
///   （`asr_ctc_decoder.dart`）。Omnilingual 吃**原始波形** `x[N, num_samples]`，
///   没有 fbank。
enum AsrModelArchitecture { transducer, ctc }

/// 模型文件角色。transducer 包用前六个，ctc 包用 `ctc*` 三个；tokens / vad 共用。
enum AsrModelRole {
  encoderFp32,
  encoderInt8,
  decoderFp32,
  decoderInt8,
  joinerFp32,
  joinerInt8,
  ctcModelFp32,
  ctcModelInt8,

  /// fp32 CTC 模型的 ONNX 外置权重（`model.weights`，与 `model.onnx` 同目录才能
  /// 建会话；ORT 按 `model.onnx` 所在目录解析相对路径）。
  ctcWeightsFp32,
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
    required this.languages,
    required this.id,
    required this.displayName,
    required this.sourceUrl,
    required this.files,
    this.architecture = AsrModelArchitecture.transducer,
    this.decoderContextSize = 2,
    this.indexType = AsrIndexType.int64,
    this.blankToken = '<blk>',
    this.fp32GpuMinBudgetBytes,
  });

  /// 本包服务的语言（transducer 包一语言一包；Omnilingual 一包多语言）。
  final List<AsrLanguage> languages;

  /// 主语言（一语言一包时就是那一种；多语言包取首个，只作诊断/排序用）。
  AsrLanguage get language => languages.first;

  final AsrModelArchitecture architecture;

  /// `tokens.txt` 里 CTC blank / transducer blank 的记号名：sherpa-onnx 导出统一
  /// `<blk>`；Omnilingual 词表是 fairseq2 的 `<s> <pad> </s> <unk>`，blank 是 id 0
  /// 的 `<s>`（2026-09-06 用 onnxruntime 对四个 test wav 逐帧核实：id 0 占 6~7 成
  /// 帧、按它折叠得到正确文本，按 `<pad>`=1 折叠满屏 `<s>`）。
  final String blankToken;

  /// fp32 变体要上 GPU 至少需要的本进程显存预算（字节）；null = 不设门槛。
  /// Omnilingual 1B fp32 权重 3.9 GB + 激活，8 GiB 以下的卡直接给 int8 · CPU。
  final int? fp32GpuMinBudgetBytes;

  /// 磁盘目录名（`<appSupport>/asr_models/<id>`）与任务目录哈希的一部分；
  /// **冻结**，改了等于让用户已下载的模型与进行中的任务全部失联。
  final String id;

  /// 给用户看的模型名。
  final String displayName;

  /// 模型主页（设置页「来源」链接）。
  final String sourceUrl;

  /// 全部已知文件。角色互不相同；上游没给 int8 decoder 的包，int8 角色与 fp32
  /// 角色可以指向**同一个**文件名（[filesFor] 每个变体内文件名仍唯一）。
  final List<AsrModelFile> files;

  /// decoder 输入 `y[N, ctx]` 的上下文长度（模型元数据 `context_size`）。
  final int decoderContextSize;

  /// 索引张量整型宽度（文件头表格按模型核实）。
  final AsrIndexType indexType;

  /// 按角色取清单条目。
  AsrModelFile fileForRole(AsrModelRole role) =>
      files.firstWhere((AsrModelFile file) => file.role == role);

  /// 某个编码器变体跑起来需要的全部文件（同精度的 encoder / decoder / joiner +
  /// 共用的 tokens / vad）。编码器排第一：下载进度条与「先下最大的」都依赖这个顺序。
  List<AsrModelFile> filesFor(AsrEncoderVariant variant) {
    return switch (architecture) {
      AsrModelArchitecture.transducer => <AsrModelFile>[
        fileForRole(asrEncoderRole(variant)),
        fileForRole(asrDecoderRole(variant)),
        fileForRole(asrJoinerRole(variant)),
        fileForRole(AsrModelRole.tokens),
        fileForRole(AsrModelRole.vad),
      ],
      // ctc：模型（fp32 可能带外置权重）+ tokens / vad。
      AsrModelArchitecture.ctc => <AsrModelFile>[
        fileForRole(asrCtcModelRole(variant)),
        if (variant == AsrEncoderVariant.fp32)
          for (final AsrModelFile f in files)
            if (f.role == AsrModelRole.ctcWeightsFp32) f,
        fileForRole(AsrModelRole.tokens),
        fileForRole(AsrModelRole.vad),
      ],
    };
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

const String _kHf = 'https://huggingface.co/';

// ── 日语：ReazonSpeech k2-v2 ────────────────────────────────────────────────

const String _kJaPrimaryBase =
    'https://huggingface.co/reazon-research/reazonspeech-k2-v2/resolve/main/';
const String _kJaSecondaryBase =
    'https://huggingface.co/DeL-TaiseiOzaki/'
    'sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01/resolve/main/';

const AsrModelPack kAsrJapanesePack = AsrModelPack(
  languages: <AsrLanguage>[AsrLanguage.japanese],
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
  languages: <AsrLanguage>[AsrLanguage.english],
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

// ── 普通话：X-ASR zipformer zh-en punct（2026-06-03） ───────────────────────
//
// 全部索引张量是 int32（`y` / `x_lens` / `encoder_out_lens`）；词表无 `<unk>`，
// 标点是带 `▁` 的独立 token（`▁，` / `▁。` / `▁,`），`AsrTokenTable.materialize`
// 不会在标点前留空格。

const String _kZhRepo =
    'csukuangfj2/sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-2026-06-03';
const String _kZhInt8Repo =
    'csukuangfj2/'
    'sherpa-onnx-x-asr-zipformer-transducer-zh-en-punct-int8-2026-06-03';
const String _kZhBase = '$_kHf$_kZhRepo/resolve/main/';
const String _kZhInt8Base = '$_kHf$_kZhInt8Repo/resolve/main/';

const AsrModelPack kAsrMandarinPack = AsrModelPack(
  languages: <AsrLanguage>[AsrLanguage.mandarin],
  id: 'x-asr-zipformer-zh-en-punct-2026-06-03',
  displayName: 'X-ASR zipformer zh-en (punct)',
  sourceUrl: '$_kHf$_kZhRepo',
  indexType: AsrIndexType.int32,
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'encoder-epoch-99-avg-1.onnx',
      url: '${_kZhBase}encoder-epoch-99-avg-1.onnx',
      expectedBytes: 599081672,
      role: AsrModelRole.encoderFp32,
    ),
    AsrModelFile(
      fileName: 'encoder-epoch-99-avg-1.int8.onnx',
      url: '${_kZhInt8Base}encoder-epoch-99-avg-1.int8.onnx',
      expectedBytes: 161744450,
      role: AsrModelRole.encoderInt8,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-99-avg-1.onnx',
      url: '${_kZhBase}decoder-epoch-99-avg-1.onnx',
      expectedBytes: 11309084,
      role: AsrModelRole.decoderFp32,
    ),
    // 上游 int8 仓库没有 int8 decoder：两变体共用 fp32 decoder。
    AsrModelFile(
      fileName: 'decoder-epoch-99-avg-1.onnx',
      url: '${_kZhBase}decoder-epoch-99-avg-1.onnx',
      expectedBytes: 11309084,
      role: AsrModelRole.decoderInt8,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-99-avg-1.onnx',
      url: '${_kZhBase}joiner-epoch-99-avg-1.onnx',
      expectedBytes: 10260467,
      role: AsrModelRole.joinerFp32,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-99-avg-1.int8.onnx',
      url: '${_kZhInt8Base}joiner-epoch-99-avg-1.int8.onnx',
      expectedBytes: 2581422,
      role: AsrModelRole.joinerInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kZhBase}tokens.txt',
      expectedBytes: 58806,
      role: AsrModelRole.tokens,
    ),
    kAsrVadFile,
  ],
);

// ── 粤语：MDCC zipformer（2024-03-11，icefall mdcc recipe） ─────────────────
//
// decoder `context_size=1`（`y[N,1]`）；导出在 icefall 仓库的 `exp/` 目录下。

const String _kYueRepo = 'zrjin/icefall-asr-mdcc-zipformer-2024-03-11';
const String _kYueBase = '$_kHf$_kYueRepo/resolve/main/';

const AsrModelPack kAsrCantonesePack = AsrModelPack(
  languages: <AsrLanguage>[AsrLanguage.cantonese],
  id: 'zipformer-cantonese-mdcc-2024-03-11',
  displayName: 'MDCC zipformer (Cantonese)',
  sourceUrl: '$_kHf$_kYueRepo',
  decoderContextSize: 1,
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'encoder-epoch-45-avg-35.onnx',
      url: '${_kYueBase}exp/encoder-epoch-45-avg-35.onnx',
      expectedBytes: 260000054,
      role: AsrModelRole.encoderFp32,
    ),
    AsrModelFile(
      fileName: 'encoder-epoch-45-avg-35.int8.onnx',
      url: '${_kYueBase}exp/encoder-epoch-45-avg-35.int8.onnx',
      expectedBytes: 69285978,
      role: AsrModelRole.encoderInt8,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-45-avg-35.onnx',
      url: '${_kYueBase}exp/decoder-epoch-45-avg-35.onnx',
      expectedBytes: 10989238,
      role: AsrModelRole.decoderFp32,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-45-avg-35.int8.onnx',
      url: '${_kYueBase}exp/decoder-epoch-45-avg-35.int8.onnx',
      expectedBytes: 2751632,
      role: AsrModelRole.decoderInt8,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-45-avg-35.onnx',
      url: '${_kYueBase}exp/joiner-epoch-45-avg-35.onnx',
      expectedBytes: 9956760,
      role: AsrModelRole.joinerFp32,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-45-avg-35.int8.onnx',
      url: '${_kYueBase}exp/joiner-epoch-45-avg-35.int8.onnx',
      expectedBytes: 2504924,
      role: AsrModelRole.joinerInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kYueBase}data/lang_char/tokens.txt',
      expectedBytes: 42525,
      role: AsrModelRole.tokens,
    ),
    kAsrVadFile,
  ],
);

// ── 韩语：zipformer-korean-2024-06-24 ────────────────────────────────────────

const String _kKoRepo = 'k2-fsa/sherpa-onnx-zipformer-korean-2024-06-24';
const String _kKoBase = '$_kHf$_kKoRepo/resolve/main/';

const AsrModelPack kAsrKoreanPack = AsrModelPack(
  languages: <AsrLanguage>[AsrLanguage.korean],
  id: 'zipformer-korean-2024-06-24',
  displayName: 'Zipformer (Korean, 2024-06-24)',
  sourceUrl: '$_kHf$_kKoRepo',
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'encoder-epoch-99-avg-1.onnx',
      url: '${_kKoBase}encoder-epoch-99-avg-1.onnx',
      expectedBytes: 260990607,
      role: AsrModelRole.encoderFp32,
    ),
    AsrModelFile(
      fileName: 'encoder-epoch-99-avg-1.int8.onnx',
      url: '${_kKoBase}encoder-epoch-99-avg-1.int8.onnx',
      expectedBytes: 70784728,
      role: AsrModelRole.encoderInt8,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-99-avg-1.onnx',
      url: '${_kKoBase}decoder-epoch-99-avg-1.onnx',
      expectedBytes: 11309084,
      role: AsrModelRole.decoderFp32,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-99-avg-1.int8.onnx',
      url: '${_kKoBase}decoder-epoch-99-avg-1.int8.onnx',
      expectedBytes: 2844692,
      role: AsrModelRole.decoderInt8,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-99-avg-1.onnx',
      url: '${_kKoBase}joiner-epoch-99-avg-1.onnx',
      expectedBytes: 10260467,
      role: AsrModelRole.joinerFp32,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-99-avg-1.int8.onnx',
      url: '${_kKoBase}joiner-epoch-99-avg-1.int8.onnx',
      expectedBytes: 2581421,
      role: AsrModelRole.joinerInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kKoBase}tokens.txt',
      expectedBytes: 60246,
      role: AsrModelRole.tokens,
    ),
    kAsrVadFile,
  ],
);

// ── 俄语：zipformer-ru-2025-04-20 ────────────────────────────────────────────

const String _kRuRepo = 'csukuangfj/sherpa-onnx-zipformer-ru-2025-04-20';
const String _kRuInt8Repo = 'csukuangfj/sherpa-onnx-zipformer-ru-int8-2025-04-20';
const String _kRuBase = '$_kHf$_kRuRepo/resolve/main/';
const String _kRuInt8Base = '$_kHf$_kRuInt8Repo/resolve/main/';

const AsrModelPack kAsrRussianPack = AsrModelPack(
  languages: <AsrLanguage>[AsrLanguage.russian],
  id: 'zipformer-ru-2025-04-20',
  displayName: 'Zipformer (Russian, 2025-04-20)',
  sourceUrl: '$_kHf$_kRuRepo',
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'encoder.onnx',
      url: '${_kRuBase}encoder.onnx',
      expectedBytes: 261058126,
      role: AsrModelRole.encoderFp32,
    ),
    AsrModelFile(
      fileName: 'encoder.int8.onnx',
      url: '${_kRuInt8Base}encoder.int8.onnx',
      expectedBytes: 70876638,
      role: AsrModelRole.encoderInt8,
    ),
    AsrModelFile(
      fileName: 'decoder.onnx',
      url: '${_kRuBase}decoder.onnx',
      expectedBytes: 2093080,
      role: AsrModelRole.decoderFp32,
    ),
    AsrModelFile(
      fileName: 'decoder.onnx',
      url: '${_kRuBase}decoder.onnx',
      expectedBytes: 2093080,
      role: AsrModelRole.decoderInt8,
    ),
    AsrModelFile(
      fileName: 'joiner.onnx',
      url: '${_kRuBase}joiner.onnx',
      expectedBytes: 1026462,
      role: AsrModelRole.joinerFp32,
    ),
    AsrModelFile(
      fileName: 'joiner.int8.onnx',
      url: '${_kRuInt8Base}joiner.int8.onnx',
      expectedBytes: 259417,
      role: AsrModelRole.joinerInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kRuBase}tokens.txt',
      expectedBytes: 6388,
      role: AsrModelRole.tokens,
    ),
    kAsrVadFile,
  ],
);

// ── 越南语：zipformer-vi-2025-04-20 ──────────────────────────────────────────

const String _kViRepo = 'csukuangfj/sherpa-onnx-zipformer-vi-2025-04-20';
const String _kViInt8Repo = 'csukuangfj/sherpa-onnx-zipformer-vi-int8-2025-04-20';
const String _kViBase = '$_kHf$_kViRepo/resolve/main/';
const String _kViInt8Base = '$_kHf$_kViInt8Repo/resolve/main/';

const AsrModelPack kAsrVietnamesePack = AsrModelPack(
  languages: <AsrLanguage>[AsrLanguage.vietnamese],
  id: 'zipformer-vi-2025-04-20',
  displayName: 'Zipformer (Vietnamese, 2025-04-20)',
  sourceUrl: '$_kHf$_kViRepo',
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'encoder-epoch-12-avg-8.onnx',
      url: '${_kViBase}encoder-epoch-12-avg-8.onnx',
      expectedBytes: 261057692,
      role: AsrModelRole.encoderFp32,
    ),
    AsrModelFile(
      fileName: 'encoder-epoch-12-avg-8.int8.onnx',
      url: '${_kViInt8Base}encoder-epoch-12-avg-8.int8.onnx',
      expectedBytes: 70876129,
      role: AsrModelRole.encoderInt8,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-12-avg-8.onnx',
      url: '${_kViBase}decoder-epoch-12-avg-8.onnx',
      expectedBytes: 5165084,
      role: AsrModelRole.decoderFp32,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-12-avg-8.onnx',
      url: '${_kViBase}decoder-epoch-12-avg-8.onnx',
      expectedBytes: 5165084,
      role: AsrModelRole.decoderInt8,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-12-avg-8.onnx',
      url: '${_kViBase}joiner-epoch-12-avg-8.onnx',
      expectedBytes: 4104465,
      role: AsrModelRole.joinerFp32,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-12-avg-8.int8.onnx',
      url: '${_kViInt8Base}joiner-epoch-12-avg-8.int8.onnx',
      expectedBytes: 1033417,
      role: AsrModelRole.joinerInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kViBase}tokens.txt',
      expectedBytes: 25847,
      role: AsrModelRole.tokens,
    ),
    kAsrVadFile,
  ],
);

// ── 泰语：GigaSpeech 2 zipformer（2024-06-20，icefall 仓库 exp/ 导出） ────────

const String _kThRepo = 'yfyeung/icefall-asr-gigaspeech2-th-zipformer-2024-06-20';
const String _kThBase = '$_kHf$_kThRepo/resolve/main/';

const AsrModelPack kAsrThaiPack = AsrModelPack(
  languages: <AsrLanguage>[AsrLanguage.thai],
  id: 'zipformer-th-gigaspeech2-2024-06-20',
  displayName: 'GigaSpeech 2 zipformer (Thai)',
  sourceUrl: '$_kHf$_kThRepo',
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'encoder-epoch-12-avg-5.onnx',
      url: '${_kThBase}exp/encoder-epoch-12-avg-5.onnx',
      expectedBytes: 592348221,
      role: AsrModelRole.encoderFp32,
    ),
    AsrModelFile(
      fileName: 'encoder-epoch-12-avg-5.int8.onnx',
      url: '${_kThBase}exp/encoder-epoch-12-avg-5.int8.onnx',
      expectedBytes: 154671320,
      role: AsrModelRole.encoderInt8,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-12-avg-5.onnx',
      url: '${_kThBase}exp/decoder-epoch-12-avg-5.onnx',
      expectedBytes: 5165084,
      role: AsrModelRole.decoderFp32,
    ),
    AsrModelFile(
      fileName: 'decoder-epoch-12-avg-5.int8.onnx',
      url: '${_kThBase}exp/decoder-epoch-12-avg-5.int8.onnx',
      expectedBytes: 1308690,
      role: AsrModelRole.decoderInt8,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-12-avg-5.onnx',
      url: '${_kThBase}exp/joiner-epoch-12-avg-5.onnx',
      expectedBytes: 4104465,
      role: AsrModelRole.joinerFp32,
    ),
    AsrModelFile(
      fileName: 'joiner-epoch-12-avg-5.int8.onnx',
      url: '${_kThBase}exp/joiner-epoch-12-avg-5.int8.onnx',
      expectedBytes: 1033417,
      role: AsrModelRole.joinerInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kThBase}data/lang_bpe_2000/tokens.txt',
      expectedBytes: 39142,
      role: AsrModelRole.tokens,
    ),
    kAsrVadFile,
  ],
);

// ── 其余 9 种界面语言：Meta Omnilingual ASR 1B CTC v2（1600+ 语言） ─────────
//
// 输入原始波形 `x[N, num_samples]` f32（逐段零均值单位方差归一化，同 sherpa-onnx
// `OfflineOmnilingualAsrCtcModel::NormalizeFeatures`），输出 `logits[N, num_frames,
// 10288]`，每帧 320 样本（20 ms）；词表字符级（含空格 token），无标点无大小写。
// 上限 40 s 音频，VAD 段 ≤ 20 s 在范围内。选 1B 不选 300M：2026-09-06 用 300M
// 跑四个 test wav，德语 Wurst→worst、西语 tu propio→te un puerto，字符级仍可用于
// 匹配但 1B 更稳；fp32 走 GPU（3.9 GB 外置权重）、int8 走 CPU（1 GB）。
// Apache-2.0（LICENSE 随包）。

const String _kOmniRepo =
    'csukuangfj2/sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-v2-2026-02-05';
const String _kOmniInt8Repo =
    'csukuangfj2/'
    'sherpa-onnx-omnilingual-asr-1600-languages-1B-ctc-v2-int8-2026-02-05';
const String _kOmniBase = '$_kHf$_kOmniRepo/resolve/main/';
const String _kOmniInt8Base = '$_kHf$_kOmniInt8Repo/resolve/main/';

const AsrModelPack kAsrOmnilingualPack = AsrModelPack(
  languages: <AsrLanguage>[
    AsrLanguage.german,
    AsrLanguage.spanish,
    AsrLanguage.french,
    AsrLanguage.italian,
    AsrLanguage.dutch,
    AsrLanguage.portuguese,
    AsrLanguage.turkish,
    AsrLanguage.indonesian,
    AsrLanguage.arabic,
  ],
  id: 'omnilingual-asr-1b-ctc-v2',
  displayName: 'Omnilingual ASR 1B (CTC, 1600+ languages)',
  sourceUrl: 'https://github.com/facebookresearch/omnilingual-asr',
  architecture: AsrModelArchitecture.ctc,
  blankToken: '<s>',
  fp32GpuMinBudgetBytes: 8 * 1024 * 1024 * 1024,
  files: <AsrModelFile>[
    AsrModelFile(
      fileName: 'model.onnx',
      url: '${_kOmniBase}model.onnx',
      expectedBytes: 1417766,
      role: AsrModelRole.ctcModelFp32,
    ),
    AsrModelFile(
      fileName: 'model.weights',
      url: '${_kOmniBase}model.weights',
      expectedBytes: 3902699712,
      role: AsrModelRole.ctcWeightsFp32,
    ),
    AsrModelFile(
      fileName: 'model.int8.onnx',
      url: '${_kOmniInt8Base}model.int8.onnx',
      expectedBytes: 1032239439,
      role: AsrModelRole.ctcModelInt8,
    ),
    AsrModelFile(
      fileName: 'tokens.txt',
      url: '${_kOmniBase}tokens.txt',
      expectedBytes: 90630,
      role: AsrModelRole.tokens,
      mirrorUrls: <String>['${_kOmniInt8Base}tokens.txt'],
    ),
    kAsrVadFile,
  ],
);

/// 全部模型包。transducer 包与 [AsrLanguage.values] 前 8 项同序，Omnilingual 包
/// 兜住其余 9 种。
const List<AsrModelPack> kAsrModelPacks = <AsrModelPack>[
  kAsrJapanesePack,
  kAsrEnglishPack,
  kAsrMandarinPack,
  kAsrCantonesePack,
  kAsrKoreanPack,
  kAsrRussianPack,
  kAsrVietnamesePack,
  kAsrThaiPack,
  kAsrOmnilingualPack,
];

/// 某语言的模型包（每种 [AsrLanguage] 恰有一个包服务它，见清单测试）。
AsrModelPack asrModelPackFor(AsrLanguage language) {
  return kAsrModelPacks.firstWhere(
    (AsrModelPack pack) => pack.languages.contains(language),
  );
}

AsrModelRole asrCtcModelRole(AsrEncoderVariant variant) => switch (variant) {
  AsrEncoderVariant.fp32 => AsrModelRole.ctcModelFp32,
  AsrEncoderVariant.int8 => AsrModelRole.ctcModelInt8,
};

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
