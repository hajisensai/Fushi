/// 漫画 OCR 的「大模型识别」层：框仍由本地 / 原引擎给，块里的**文字**交给用户
/// 自配的视觉大模型重读。
///
/// 为什么只换文字不换框：大模型读字比本地小模型准得多（手写体、艺术字、糊字），
/// 但给不出可靠的像素坐标，而漫画点词全靠框——所以检测与排版留在本地，模型只
/// 回答「这个框里写的是什么」。
///
/// 两档（[MangaAiOcrMode]）：
/// - [MangaAiOcrMode.lowConfidence]：只把本地识别器自己都没把握的块
///   （[MokuroBlock.confidence] 低于门槛）送去重读——「AI 兜底」，花钱最少；
/// - [MangaAiOcrMode.all]：每个块都重读——「有钱 AI 全干」。
///
/// 边界（`ai_feature.dart` 的 `AiFeature.mangaOcr` 写明了为什么这是那条
/// 「AI 只产出配置」硬边界的显式例外）：默认关；模型回复必须通过本地校验
/// （JSON 形状、编号在本批内、长度在合理范围、非空）才替换本地结果，任何失败都
/// 保留本地文字；鉴权 / 配置类失败后整卷不再发请求。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// 漫画 OCR 的大模型档位。
enum MangaAiOcrMode {
  /// 不用大模型。
  off,

  /// 只重读没把握的块：有分数按 [kMangaAiOcrLowConfidenceThreshold]，没分数的按
  /// [isSuspectMangaOcrText]。app 侧默认意图（首次使用前确认一次）。
  lowConfidence,

  /// 每个块都重读。
  all;

  String get storageKey => switch (this) {
    MangaAiOcrMode.off => 'off',
    MangaAiOcrMode.lowConfidence => 'low_confidence',
    MangaAiOcrMode.all => 'all',
  };

  static MangaAiOcrMode fromStorageKey(String? key) {
    for (final MangaAiOcrMode mode in MangaAiOcrMode.values) {
      if (mode.storageKey == key) return mode;
    }
    return MangaAiOcrMode.off;
  }
}

/// 「低置信度」门槛：块置信度低于它才送大模型。
///
/// 2026-10-03 用两章注音密集的在线漫画（21 页 Lens 逐字真值，逐块编辑距离）实测，
/// 「送出块占比 / 送出块覆盖的错字占比 / 送出块里本就全对的占比」：
/// - manga-ocr（beam 几何平均，10 页 116 块）：0.75 → 22% / 44% / 4%，
///   0.85 → 29% / 54% / 3%；
/// - 逐列 CTC（最弱一字概率，21 页 209 块）：0.75 → 35% / 44% / 15%，
///   0.85 → 43% / 53% / 14%。
/// CTC 的「最弱一字」分数整体偏低，同一门槛下送得更多；两者共用一个门槛取 0.75
/// 折中——「兜底」档的本意是少花钱。样本小，换更多真书再调。
const double kMangaAiOcrLowConfidenceThreshold = 0.75;

/// 一次请求最多带几个块：块多了单次回复变长、一处 JSON 写坏整批作废；太少则
/// 请求数与系统提示词的重复开销上去。
const int kMangaAiOcrBlocksPerRequest = 8;

/// 裁图长边上限（像素）：再大对读字没有帮助，只增加上传量与图片 token。
const int kMangaAiOcrMaxCropSide = 1024;

/// 裁图短边下限：小于它的块按整数倍放大——视觉模型对几十像素的小字读得很差。
const int kMangaAiOcrMinCropSide = 96;

/// 裁图四周外扩的像素：检测框常贴着字边，切掉笔画尾巴会读错。
const int kMangaAiOcrCropPadding = 6;

/// 送给大模型的系统提示词。只要它转写，不要它改写。
const String kMangaAiOcrSystemPrompt = '''
You are an OCR engine for manga. Each image is one text region cropped from a manga page. Transcribe exactly the text written in each image.

Rules:
- Japanese vertical text: read each column top to bottom, columns right to left. Horizontal text: left to right, top to bottom.
- Put a newline between columns (vertical) or lines (horizontal).
- Omit furigana (small reading glyphs printed beside kanji); keep only the main text.
- Do not translate, explain, correct, normalise or complete the text. Keep the original script (kanji, kana, latin), punctuation, small kana, long-vowel marks and sound effects as written.
- If an image contains no readable text, use an empty string.
- Hints may follow the images: the local OCR guess for each id (often partly wrong), nearby text that was already read, the work title and the expected language. Use them only to choose between characters that look alike in the image. The image is the only source of truth: never output a hint the image does not show, and never add words from nearby text.

Reply with JSON only, no prose:
{"blocks":[{"id":1,"text":"..."}]}''';

/// 字幕版系统提示词：图是整条字幕位图（PGS / VobSub / DVB），语言不限日语。
const String kSubtitleAiOcrSystemPrompt = '''
You are an OCR engine for video subtitles. Each image is one subtitle rendered as a bitmap. Transcribe exactly the text shown in each image.

Rules:
- Read lines top to bottom; put a newline between lines.
- Omit ruby / furigana (small reading glyphs above or beside the main text).
- Keep the original language and script. Do not translate, explain, correct, normalise or complete the text. Keep punctuation, dashes, music notes and speaker marks as written.
- If an image contains no readable text, use an empty string.
- Hints may follow the images: the local OCR guess for each id (often partly wrong), nearby text that was already read, the work title and the expected language. Use them only to choose between characters that look alike in the image. The image is the only source of truth: never output a hint the image does not show, and never add words from nearby text.

Reply with JSON only, no prose:
{"blocks":[{"id":1,"text":"..."}]}''';

/// 送给大模型的「附近已读文字」最多几行、每行最多几个字：只为消歧，多了只是花钱。
const int kMangaAiOcrMaxNearbyLines = 12;
const int kMangaAiOcrMaxNearbyLineLength = 80;

/// 文字来自哪类图：决定系统提示词与「这些图挨在一起」的说法。
enum MangaAiOcrSource { manga, subtitle }

/// 重读一卷 / 一条字幕轨时的上下文：随每次请求带给模型，只用于消歧（形近字），
/// 也给 [isSuspectMangaOcrText] 提供期望语言。全为空 = 与旧版只发图片一致。
class MangaAiOcrContext {
  const MangaAiOcrContext({
    this.source = MangaAiOcrSource.manga,
    this.title,
    this.language,
  });

  final MangaAiOcrSource source;

  /// 作品标题（系列名 / 视频标题）；null = 不带。
  final String? title;

  /// 期望语言（BCP 47 / ISO 639，如 `ja`、`zh-Hans`、`en`）；null = 不知道。
  final String? language;
}

/// 进程内按缓存文件规范化路径分桶的写锁（链尾 Future），形状同
/// `manga_json_writeback.dart` 的 `runExclusiveOnMangaJson`。
final Map<String, Future<void>> _mangaAiOcrCacheWriteChains =
    <String, Future<void>>{};

/// 同一缓存文件的写操作串行执行 [action]；失败不毒化链。
Future<T> _runExclusiveOnCacheFile<T>(File file, Future<T> Function() action) {
  final String key = p.canonicalize(file.path);
  final Future<void> previous =
      _mangaAiOcrCacheWriteChains[key] ?? Future<void>.value();
  final Completer<void> gate = Completer<void>();
  _mangaAiOcrCacheWriteChains[key] = gate.future;
  return previous.then((_) => action()).whenComplete(() {
    gate.complete();
    if (identical(_mangaAiOcrCacheWriteChains[key], gate.future)) {
      _mangaAiOcrCacheWriteChains.remove(key);
    }
  });
}

/// 临时文件名的进程内序号（与时间戳一起保证同进程内唯一）。
int _mangaAiOcrCacheTempSequence = 0;

/// 已读过的裁图 → 文字的磁盘缓存（按裁图字节的 SHA-1 键）。
///
/// 存在的理由：本地任务中断后续跑、整卷缓存快路径回放时，页面会再次经过本层；
/// 没有缓存就是同一张图重复付费。键是**裁图内容**而不是页号 / 块号，所以换了
/// 检测结果、换了页序都不会读到别人的字。
///
/// 同一文件可能有多个实例同时在写（直读识别器与整卷任务、整卷任务结束后仍在
/// 收尾的大模型步骤与同目录新起的任务）：写入一律在按路径的进程内锁里**先重读
/// 盘上内容再合并**，临时文件名带唯一后缀——后写者不会吞掉先写者的条目，两个
/// 写者也不会踩同一个 `.tmp`。
class MangaAiOcrCache {
  MangaAiOcrCache(this.file);

  /// `<卷目录>/manga_ocr_out/_ai/<提供商签名>.json`。
  factory MangaAiOcrCache.forVolume(
    String volumeDir,
    AiProviderConfig provider,
  ) => MangaAiOcrCache(
    File(
      p.join(
        volumeDir,
        'manga_ocr_out',
        '_ai',
        '${mangaAiOcrProviderSignature(provider)}.json',
      ),
    ),
  );

  final File file;
  Map<String, String>? _entries;

  Future<Map<String, String>> _load() async {
    final Map<String, String>? loaded = _entries;
    if (loaded != null) return loaded;
    return _entries = await _readDisk();
  }

  Future<Map<String, String>> _readDisk() async {
    final Map<String, String> entries = <String, String>{};
    try {
      if (await file.exists()) {
        final Object? decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          decoded.forEach((Object? key, Object? value) {
            if (key is String && value is String) entries[key] = value;
          });
        }
      }
    } on FormatException {
      // 写坏的缓存当没有：最坏多付一次钱，不让整卷失败。
    } on FileSystemException {
      // 同上。
    }
    return entries;
  }

  Future<String?> lookup(String key) async => (await _load())[key];

  /// 并入 [values]：锁内重读盘上现状再合并写回，别的实例刚写进去的条目不丢。
  Future<void> storeAll(Map<String, String> values) async {
    if (values.isEmpty) return;
    await _runExclusiveOnCacheFile<void>(file, () async {
      final Map<String, String> entries = await _readDisk()
        ..addAll(values);
      await file.parent.create(recursive: true);
      final File temporary = File(
        '${file.path}.${pid}_${DateTime.now().microsecondsSinceEpoch}_'
        '${_mangaAiOcrCacheTempSequence++}.tmp',
      );
      try {
        await temporary.writeAsString(jsonEncode(entries), flush: true);
        // rename 直接覆盖目标（Windows 上 Dart 的 rename 也能覆盖），不先删：
        // 删与 rename 之间目标不存在，别的读者会当成「没有缓存」多付一次钱。
        await temporary.rename(file.path);
      } on FileSystemException {
        if (await temporary.exists()) await temporary.delete();
        rethrow;
      }
      _entries = entries;
    });
  }

  /// 清空本缓存（整卷「重新识别」时调用：用户要的是让大模型重读，不是回放）。
  Future<void> clear() async {
    await _runExclusiveOnCacheFile<void>(file, () async {
      _entries = <String, String>{};
      if (await file.exists()) await file.delete();
    });
  }
}

/// 缓存分桶用的提供商签名：换了地址或模型就是另一份缓存（读字能力不同）。
String mangaAiOcrProviderSignature(AiProviderConfig provider) {
  final String raw = '${provider.baseUrl}|${provider.model}';
  return sha1.convert(utf8.encode(raw)).toString().substring(0, 16);
}

/// 一页的识别统计（给调用方记日志 / 进度用）。
class MangaAiOcrPageStats {
  const MangaAiOcrPageStats({
    this.candidates = 0,
    this.replaced = 0,
    this.cached = 0,
    this.failure,
  });

  /// 按档位应送大模型的块数。
  final int candidates;

  /// 文字被大模型结果替换（或确认）的块数。
  final int replaced;

  /// 其中直接命中磁盘缓存、没发请求的块数。
  final int cached;

  /// 本页遇到的请求失败（已脱敏短码）；null = 没失败。
  final String? failure;
}

/// 一张已裁好的文字图（PNG）+ 它的本地识别块（字幕整轨重读用）。块里的本地文字
/// 会作为「本地猜测」随请求带给模型。
class MangaAiOcrCropRequest {
  const MangaAiOcrCropRequest({required this.crop, required this.block});
  final Uint8List crop;
  final MokuroBlock block;
}

/// 一张待读裁图在一次重读里的状态：缓存键按裁图字节算一次，读出的文字回填
/// [text]（null = 没读到 / 校验不过）。
class _CropRead {
  _CropRead(this.crop, this.block) : key = sha1.convert(crop).toString();

  final Uint8List crop;

  /// 校验（[isPlausibleMangaAiOcrText]）用的本地块。
  final MokuroBlock block;
  final String key;
  String? text;

  /// [text] 来自磁盘缓存（没发请求）。
  bool cached = false;
}

/// 大模型重读器。一卷一个实例（[cache] 绑卷目录）。
///
/// 整个实例共用**一个** [AiChatClient]（首次发请求时建），多个 [refinePage] /
/// [refineCrops] 可以同时在途——底层 HTTP 客户端本身支持并发请求，不必每页各开
/// 一个连接池。
///
/// [cancel] / [dispose] 之后本实例作废：在途请求被中止（关掉共享的 HTTP 客户端），
/// 之后的 [refinePage] 一律原样交回本地结果、[refineCrops] 一律交回 null，不再
/// 发请求。
class MangaAiOcrRefiner {
  MangaAiOcrRefiner({
    required this.provider,
    required this.mode,
    this.context = const MangaAiOcrContext(),
    AiChatClient Function()? clientFactory,
    this.threshold = kMangaAiOcrLowConfidenceThreshold,
    this.blocksPerRequest = kMangaAiOcrBlocksPerRequest,
  }) : assert(mode != MangaAiOcrMode.off),
       _clientFactory = clientFactory ?? AiChatClient.new;

  final AiProviderConfig provider;
  final MangaAiOcrMode mode;

  /// 本实例读的是什么（漫画 / 字幕、标题、语言）。工厂在不知道媒体的地方建实例，
  /// 装配方（`prepareMangaStreamOcr`）在第一次请求前补上；之后不再改。
  MangaAiOcrContext context;
  final double threshold;
  final int blocksPerRequest;
  final AiChatClient Function() _clientFactory;

  String? _fatalFailure;
  bool _cancelled = false;

  /// 共享客户端；第一次真要发请求时才建，[cancel] / [dispose] 时关掉。
  AiChatClient? _client;

  /// 遇到过「重试也没用」的失败（鉴权 / 配置 / 4xx）：此后不再发请求，整卷保留
  /// 本地结果。null = 仍可用。
  String? get fatalFailure => _fatalFailure;

  /// 已被 [cancel]（或 [dispose]）。
  bool get isCancelled => _cancelled;

  /// 调用方不再要结果（阅读会话关了 / 任务取消了 / 书删了）：中止在途请求，此后
  /// 不再发任何请求。幂等。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    // 关掉共享客户端即中止它上面所有在途请求（IOClient 强制关闭底层连接）。
    final AiChatClient? client = _client;
    _client = null;
    client?.close();
  }

  /// 用完释放共享的 HTTP 客户端。语义同 [cancel]：还在途的请求被中止，之后不再
  /// 发请求——调用方确定不再需要本实例时调它，别让连接池等 GC。幂等。
  void dispose() => cancel();

  /// 共享客户端（懒建）。只在确认未取消后的同一个同步段里调用，取消之后不会
  /// 再建出新客户端。
  AiChatClient _sharedClient() => _client ??= _clientFactory();

  /// 这个块要不要送大模型。
  bool wants(MokuroBlock block) {
    if (block.aiRecognized || block.lines.join().trim().isEmpty) return false;
    return switch (mode) {
      MangaAiOcrMode.off => false,
      MangaAiOcrMode.all => true,
      // 不出分的引擎（Lens / 系统 OCR / 旧缓存）：看文字本身可不可疑。想不漏就选
      // 「全部」档（2026-10-13 用户拍板：两种做法可选）。
      MangaAiOcrMode.lowConfidence => switch (block.confidence) {
        final double score => score < threshold,
        null => isSuspectMangaOcrText(
          block.lines.join('\n'),
          language: context.language,
        ),
      },
    };
  }

  /// 重读一页：返回替换后的页与统计。任何失败都原样保留对应块的本地文字。
  ///
  /// [imageBytes] 是该页原图（与 OCR 用的同一张）；块坐标按 [page] 的尺寸换算到
  /// 实际像素，所以引擎给的是缩放后坐标也能裁对。
  Future<({MokuroImage page, MangaAiOcrPageStats stats})> refinePage(
    MokuroImage page,
    Uint8List imageBytes, {
    MangaAiOcrCache? cache,
  }) async {
    final List<int> wanted = <int>[
      for (int i = 0; i < page.blocks.length; i++)
        if (wants(page.blocks[i])) i,
    ];
    if (wanted.isEmpty || _cancelled) {
      return (page: page, stats: const MangaAiOcrPageStats());
    }
    if (_fatalFailure != null) {
      return (
        page: page,
        stats: MangaAiOcrPageStats(
          candidates: wanted.length,
          failure: _fatalFailure,
        ),
      );
    }
    // 解码整页是几百毫秒级的 CPU 活，放后台 isolate，别卡阅读器 UI。
    final List<Uint8List?> crops = await Isolate.run(
      () => cropMangaAiOcrBlocks(
        imageBytes,
        pageWidth: page.size.width,
        pageHeight: page.size.height,
        boxes: <MokuroRect>[
          for (final int index in wanted) page.blocks[index].rectangle,
        ],
      ),
    );

    // 与 wanted 同序；裁不出图的块为 null（保留本地文字）。
    final List<_CropRead?> reads = <_CropRead?>[
      for (int k = 0; k < wanted.length; k++)
        crops[k] == null ? null : _CropRead(crops[k]!, page.blocks[wanted[k]]),
    ];
    final Set<int> wantedSet = wanted.toSet();
    final String? failure = await _readCrops(
      <_CropRead>[
        for (final _CropRead? read in reads)
          if (read != null) read,
      ],
      cache,
      nearby: <String>[
        for (int i = 0; i < page.blocks.length; i++)
          if (!wantedSet.contains(i)) page.blocks[i].lines.join(),
      ],
    );
    if (_cancelled) {
      // 调用方已不要结果：不交改写（缓存也已在 _readCrops 里跳过）。
      return (page: page, stats: const MangaAiOcrPageStats());
    }

    final List<MokuroBlock> blocks = List<MokuroBlock>.of(page.blocks);
    int replaced = 0;
    int cached = 0;
    for (int k = 0; k < wanted.length; k++) {
      final _CropRead? read = reads[k];
      final String? text = read?.text;
      if (read == null || text == null) continue;
      replaced++;
      if (read.cached) cached++;
      final int index = wanted[k];
      blocks[index] = applyMangaAiOcrText(blocks[index], text);
    }
    return (
      page: MokuroImage(url: page.url, size: page.size, blocks: blocks),
      stats: MangaAiOcrPageStats(
        candidates: wanted.length,
        replaced: replaced,
        cached: cached,
        failure: failure,
      ),
    );
  }

  /// 跨页批量重读：[items] 每项一张裁图。按 [wants] 筛、按裁图 SHA-1 查/写 [cache]，
  /// 未命中的按 [blocksPerRequest] 打包请求；回复过 [isPlausibleMangaAiOcrText] 校验。
  /// 返回与 [items] 等长的列表：替换后的文字，或 null（不需要 / 失败 / 校验不过 / 已取消）。
  /// 可并发调用（多个批次同时在途）。
  ///
  /// 返回的是模型原文（多行用 `\n` 分隔），没有按块几何排版——要落进
  /// [MokuroBlock] 时交 [applyMangaAiOcrText]。遇到致命失败（[fatalFailure]）后
  /// 只交回缓存命中的条目，不再发请求。
  ///
  /// [nearby] 是调用方已经读好的附近文字（字幕：前面几条已定稿的台词），只作消歧
  /// 提示随请求带上。
  Future<List<String?>> refineCrops(
    List<MangaAiOcrCropRequest> items, {
    MangaAiOcrCache? cache,
    List<String> nearby = const <String>[],
  }) async {
    final List<String?> texts = List<String?>.filled(items.length, null);
    if (_cancelled) return texts;
    final Map<int, _CropRead> reads = <int, _CropRead>{
      for (int i = 0; i < items.length; i++)
        if (wants(items[i].block)) i: _CropRead(items[i].crop, items[i].block),
    };
    if (reads.isEmpty) return texts;
    await _readCrops(reads.values.toList(), cache, nearby: nearby);
    if (_cancelled) return List<String?>.filled(items.length, null);
    for (final MapEntry<int, _CropRead> entry in reads.entries) {
      texts[entry.key] = entry.value.text;
    }
    return texts;
  }

  /// [refinePage] 与 [refineCrops] 共用的读字核心：查缓存 → 未命中的按
  /// [blocksPerRequest] 打包请求 → 逐条本地校验 → 新读到的写回缓存。读出的文字
  /// 回填到各 [_CropRead.text]；返回本次遇到的请求失败（已脱敏短码，null = 没失败）。
  ///
  /// 失败处理：瞬时失败（网络 / 限流 / 5xx）跳过这一批继续下一批；致命失败
  /// （鉴权 / 配置 / 4xx）记进 [fatalFailure]，本次与并发在途的其它调用都不再发
  /// 新请求。已取消时不落缓存（可能是因为删书而取消）。
  Future<String?> _readCrops(
    List<_CropRead> reads,
    MangaAiOcrCache? cache, {
    List<String> nearby = const <String>[],
  }) async {
    final List<_CropRead> pending = <_CropRead>[];
    for (final _CropRead read in reads) {
      final String? hit = await cache?.lookup(read.key);
      if (hit != null) {
        read
          ..text = hit
          ..cached = true;
      } else {
        pending.add(read);
      }
    }

    String? failure;
    final Map<String, String> fresh = <String, String>{};
    for (int start = 0; start < pending.length; start += blocksPerRequest) {
      if (_cancelled) break;
      final String? fatal = _fatalFailure;
      if (fatal != null) {
        // 别的调用（或本次前一批）已撞上致命失败：剩下的不再花钱。
        failure ??= fatal;
        break;
      }
      final List<_CropRead> batch = pending.sublist(
        start,
        math.min(start + blocksPerRequest, pending.length),
      );
      final Map<int, String>? replies;
      try {
        replies = await _requestBatch(batch, nearby);
      } on AiChatFailure catch (error) {
        if (_cancelled) break;
        failure = error.message;
        if (!error.isTransient) {
          _fatalFailure ??= error.message;
          break;
        }
        continue;
      }
      if (replies == null) {
        failure = 'bad_response';
        continue;
      }
      for (int j = 0; j < batch.length; j++) {
        final _CropRead read = batch[j];
        final String? text = replies[j + 1];
        if (text == null) continue;
        final String local = read.block.lines.join();
        if (!isPlausibleMangaAiOcrText(text, local: local, block: read.block) ||
            !mangaAiOcrReplyBelongsToCrop(
              text,
              local: local,
              batchmates: <String>[
                for (int k = 0; k < batch.length; k++)
                  if (k != j) batch[k].block.lines.join(),
              ],
              nearby: nearby,
            )) {
          continue;
        }
        read.text = text;
        fresh[read.key] = text;
      }
    }
    if (_cancelled) return failure;
    if (cache != null && fresh.isNotEmpty) {
      try {
        await cache.storeAll(fresh);
      } on FileSystemException {
        // 缓存写不进去只影响下次花不花钱，不影响本次结果。
      }
    }
    return failure;
  }

  /// 一批裁图一次请求（走共享客户端）；回复按 1 起的编号对回。形状不对返回 null。
  /// 调用方须先确认未取消（见 [_sharedClient]）。
  Future<Map<int, String>?> _requestBatch(
    List<_CropRead> batch,
    List<String> nearby,
  ) async {
    final String reply = await _sharedClient().complete(
      provider: provider,
      maxTokens: 256 + 192 * batch.length,
      messages: <AiChatMessage>[
        AiChatMessage.system(switch (context.source) {
          MangaAiOcrSource.manga => kMangaAiOcrSystemPrompt,
          MangaAiOcrSource.subtitle => kSubtitleAiOcrSystemPrompt,
        }),
        AiChatMessage.user(
          buildMangaAiOcrUserPrompt(
            localGuesses: <String>[
              for (final _CropRead read in batch) read.block.lines.join('\n'),
            ],
            nearby: nearby,
            context: context,
          ),
          images: <AiChatImage>[
            for (final _CropRead read in batch) AiChatImage(bytes: read.crop),
          ],
        ),
      ],
    );
    return parseMangaAiOcrReply(reply, count: batch.length);
  }
}

/// 一批请求的用户消息：图片编号说明 + 上下文提示（标题 / 期望语言 / 每张图的本地
/// 猜测 / 附近已读文字）。提示只为消歧，规则写在系统提示词里。
///
/// 本地猜测与附近文字用 JSON 字符串字面量写出：多行文字、引号都不会和编号串行。
/// 附近文字按 [kMangaAiOcrMaxNearbyLines] / [kMangaAiOcrMaxNearbyLineLength] 截断，
/// 取**最后**几行（字幕：离这批最近的台词）。
String buildMangaAiOcrUserPrompt({
  required List<String> localGuesses,
  required List<String> nearby,
  required MangaAiOcrContext context,
}) {
  final int count = localGuesses.length;
  final StringBuffer
  out = StringBuffer('There are $count images, ids 1 to $count in order. ')
    ..writeln(switch (context.source) {
      MangaAiOcrSource.manga => 'They are text regions from the same manga.',
      MangaAiOcrSource.subtitle =>
        'They are subtitle lines from the same video, mostly in playback order.',
    });
  final String title = context.title?.trim() ?? '';
  if (title.isNotEmpty) out.writeln('Work title: ${jsonEncode(title)}');
  final String language = context.language?.trim() ?? '';
  if (language.isNotEmpty) out.writeln('Expected language: $language');
  out.writeln('Local OCR guess per id (may contain errors):');
  for (int i = 0; i < count; i++) {
    out.writeln('${i + 1}: ${jsonEncode(localGuesses[i].trim())}');
  }
  final List<String> lines = <String>[
    for (final String line in nearby)
      if (line.trim().isNotEmpty)
        line.trim().length > kMangaAiOcrMaxNearbyLineLength
            ? line.trim().substring(0, kMangaAiOcrMaxNearbyLineLength)
            : line.trim(),
  ];
  if (lines.isNotEmpty) {
    out.writeln('Nearby text already read (for disambiguation only):');
    final int from = math.max(0, lines.length - kMangaAiOcrMaxNearbyLines);
    for (final String line in lines.sublist(from)) {
      out.writeln(jsonEncode(line));
    }
  }
  out.write('Return one entry per id.');
  return out.toString();
}

/// 不出分的引擎（Lens / 系统 OCR / 没有置信度的旧卷）的「没把握」判据：识别出的
/// 文字本身带着认错的痕迹。只收有根据的信号，宁可漏判（漏判可改用「全部」档）：
///
/// - 出现替换符 U+FFFD、私用区或控制字符：引擎吐了乱码；
/// - 期望语言是中日文，却整段只有拉丁字母、或拉丁字母夹在两个中日文字之间
///   （`あいxう`）：典型的形近误认；
/// - 期望语言是韩文却没有一个谚文字母而有拉丁字母；
/// - 期望语言是拉丁文字语言，却混进了汉字 / 假名 / 谚文。
///
/// 只有标点（`！？`、`…`）**不**算：漫画里这类块本来就多，送去重读只是花钱。
/// [language] 为 null 时只看乱码一条。
bool isSuspectMangaOcrText(String text, {String? language}) {
  final List<int> runes = text.replaceAll(RegExp(r'\s'), '').runes.toList();
  if (runes.isEmpty) return false;
  for (final int rune in runes) {
    if (rune == 0xFFFD ||
        rune < 0x20 ||
        (rune >= 0x7F && rune < 0xA0) ||
        (rune >= 0xE000 && rune <= 0xF8FF)) {
      return true;
    }
  }
  final String lang = (language ?? '')
      .split(RegExp('[-_]'))
      .first
      .toLowerCase();
  if (lang.isEmpty) return false;
  final bool hasLatin = runes.any(_isLatinLetter);
  final bool hasCjk = runes.any(_isCjkOrKana);
  final bool hasHangul = runes.any(_isHangul);
  switch (lang) {
    case 'ja' || 'zh':
      // 「OK」「TV」「NG」「Ｈ」这类 ≤3 字母的大写 / 全角缩写在中日文里本来就常见。
      if (hasLatin && !hasCjk) return !_isShortCapsAbbreviation(runes);
      for (int i = 1; i + 1 < runes.length; i++) {
        if (_isLatinLetter(runes[i]) &&
            _isCjkOrKana(runes[i - 1]) &&
            _isCjkOrKana(runes[i + 1])) {
          return true;
        }
      }
      return false;
    case 'ko':
      return hasLatin && !hasHangul;
    default:
      return _latinScriptLanguages.contains(lang) && (hasCjk || hasHangul);
  }
}

/// 整块是不超过 3 个大写 / 全角拉丁字母（可带标点数字）：`OK`、`ＮＧ！`、`TV`。
bool _isShortCapsAbbreviation(List<int> runes) {
  final List<int> letters = runes.where(_isLatinLetter).toList();
  if (letters.isEmpty || letters.length > 3) return false;
  return letters.every(
    (int r) => (r >= 0x41 && r <= 0x5A) || (r >= 0xFF21 && r <= 0xFF3A),
  );
}

/// 用拉丁字母书写的常见语言（[isSuspectMangaOcrText] 的「混进中日韩文字」判据）。
const Set<String> _latinScriptLanguages = <String>{
  'en',
  'de',
  'es',
  'fr',
  'it',
  'pt',
  'nl',
  'id',
  'tr',
  'vi',
  'pl',
  'sv',
};

bool _isLatinLetter(int rune) =>
    (rune >= 0x41 && rune <= 0x5A) ||
    (rune >= 0x61 && rune <= 0x7A) ||
    (rune >= 0xFF21 && rune <= 0xFF3A) ||
    (rune >= 0xFF41 && rune <= 0xFF5A);

bool _isCjkOrKana(int rune) =>
    (rune >= 0x3040 && rune <= 0x30FF) ||
    (rune >= 0x31F0 && rune <= 0x31FF) ||
    (rune >= 0x3400 && rune <= 0x4DBF) ||
    (rune >= 0x4E00 && rune <= 0x9FFF) ||
    (rune >= 0xF900 && rune <= 0xFAFF) ||
    (rune >= 0xFF66 && rune <= 0xFF9F) ||
    (rune >= 0x20000 && rune <= 0x3FFFF);

bool _isHangul(int rune) =>
    (rune >= 0xAC00 && rune <= 0xD7AF) ||
    (rune >= 0x1100 && rune <= 0x11FF) ||
    (rune >= 0x3130 && rune <= 0x318F);

/// 解析模型回复：`{"blocks":[{"id":n,"text":"..."}]}`，只收 1..[count] 的编号。
/// 整体形状不对返回 null；单条坏的跳过。
Map<int, String>? parseMangaAiOcrReply(String reply, {required int count}) {
  final Map<String, Object?>? decoded = decodeAiJsonObject(reply);
  final Object? blocks = decoded?['blocks'];
  if (blocks is! List) return null;
  final Map<int, String> result = <int, String>{};
  for (final Object? entry in blocks) {
    if (entry is! Map) continue;
    final Object? rawId = entry['id'];
    final int? id = rawId is int
        ? rawId
        : rawId is num
        ? rawId.toInt()
        : int.tryParse('$rawId');
    final Object? text = entry['text'];
    if (id == null || id < 1 || id > count || text is! String) continue;
    result.putIfAbsent(id, () => text);
  }
  return result;
}

/// 本地校验：模型回的是不是「这个框里的字」而不是解释、翻译或幻觉。
///
/// 判据保守：去掉空白后非空（模型说「没字」时保留本地结果——本地检测器认定那里
/// 有字）；长度不超过「这个框装得下的字数」加 8（模型补出漏字是正常的，凭空写出
/// 一段说明或翻译不是）。
///
/// 上限按**框的几何**定（[mangaAiOcrBlockCapacity]），不按本地文字长度：「只读
/// 低置信度」档最该救的正是本地漏读了大半的块——本地只认出 2 个字而框里其实有
/// 十几个时，按「本地长度 × 3」的旧上限会把正确的重读当成幻觉拒掉。几何给不出
/// 容量（没有块信息）时退回旧的本地长度上限；两者取大，旧上限永远是下限。
///
/// 不按措辞判「是不是说明文字」：英文漫画里的台词本身就会有「sorry」「cannot」，
/// 按词黑名单只会误杀。
bool isPlausibleMangaAiOcrText(
  String text, {
  required String local,
  MokuroBlock? block,
}) {
  final String compact = text.replaceAll(RegExp(r'\s'), '');
  if (compact.isEmpty) return false;
  final int localLength = local.replaceAll(RegExp(r'\s'), '').length;
  final int byLocal = localLength * 3 + 8;
  final int? capacity = block == null ? null : mangaAiOcrBlockCapacity(block);
  final int byGeometry = capacity == null ? 0 : capacity + 8;
  return compact.length <= math.max(byLocal, byGeometry);
}

/// 大模型的回复是不是这张图自己的：它几乎就是同批另一张图的内容、而不像本图的
/// 本地猜测 [local] 时判为串号，返回 false。
///
/// 多图一批按编号对回，模型偶尔把邻图的字答到这张的编号上，或者照抄提示里的附近
/// 台词；长度校验拦不住——字幕里表现为相邻两条变成同一句（BUG-3314）。相似度按
/// 字的多重集合算 Dice 系数（与语序无关，形近字读错一两个仍算像）。
///
/// 串号的特征是「回复几乎等于别处的内容」，不是「和别处相似」：送去重读的恰是
/// 本地低置信度块，本图自身的相似度天生偏低，而字幕前后句常常近似（「そうだよね」
/// 与「そうなんだよ」约 0.73），按「像别条」判会把正确回复丢回糊掉的本地结果。
/// 所以：
/// - [batchmates]（同批别的图的本地猜测）：至少 [_kSwappedReplyDice] 且比本条
///   高出 0.2 才算答串了编号；
/// - [nearby]（附近已读文字）只拦逐字相同（去空白）的照抄，且本地猜测并不像它
///   ——台词本身重复一遍（本地也读出了同一句）照收。
/// 两条本来就几乎一样（「スタッフA / B」同一句台词）时分不出、照收。
bool mangaAiOcrReplyBelongsToCrop(
  String reply, {
  required String local,
  Iterable<String> batchmates = const <String>[],
  Iterable<String> nearby = const <String>[],
}) {
  final double own = _charDice(reply, local);
  for (final String other in batchmates) {
    final double score = _charDice(reply, other);
    if (score >= _kSwappedReplyDice && score > own + 0.2) return false;
  }
  final String compact = _compactText(reply);
  if (compact.isEmpty || own >= 0.8) return true;
  for (final String line in nearby) {
    if (_compactText(line) == compact) return false;
  }
  return true;
}

/// 「几乎就是同一句」的字 Dice 下限：差一两个形近字 / 全半角标点仍算同一句，
/// 句式相近的不同台词（共享助词、语尾）达不到。
const double _kSwappedReplyDice = 0.9;

String _compactText(String text) => text.replaceAll(RegExp(r'\s'), '');

double _charDice(String a, String b) {
  final List<String> x = a.replaceAll(RegExp(r'\s'), '').characters.toList();
  final List<String> y = b.replaceAll(RegExp(r'\s'), '').characters.toList();
  if (x.isEmpty || y.isEmpty) return 0;
  final Map<String, int> counts = <String, int>{};
  for (final String c in x) {
    counts[c] = (counts[c] ?? 0) + 1;
  }
  int common = 0;
  for (final String c in y) {
    final int n = counts[c] ?? 0;
    if (n > 0) {
      counts[c] = n - 1;
      common++;
    }
  }
  return 2 * common / (x.length + y.length);
}

/// 这个块的框按字号算最多装得下几个字；给不出（没有尺寸可用）返回 null。
///
/// 单字边长取行框「粗细」（竖排列宽 / 横排行高）的中位数——行框来自检测器，与
/// 识别出几个字无关；没有行几何时退回块字号。框面积 ÷ 单字面积本身就偏宽（列间距、
/// 气泡留白都被算成了「能放字」），所以不再额外乘系数。
int? mangaAiOcrBlockCapacity(MokuroBlock block) {
  final double width = block.rectangle.width;
  final double height = block.rectangle.height;
  if (width <= 0 || height <= 0) return null;
  final List<double> thicknesses = <double>[
    for (final List<List<double>> polygon
        in block.linesCoords ?? const <List<List<double>>>[])
      ocrLineThickness(_polygonBounds(polygon), vertical: block.isVertical),
  ]..removeWhere((double t) => !(t > 0));
  final double glyph;
  if (thicknesses.isNotEmpty) {
    thicknesses.sort();
    glyph = thicknesses[thicknesses.length ~/ 2];
  } else if (block.fontSize > 0) {
    glyph = block.fontSize;
  } else {
    return null;
  }
  return (width * height / (glyph * glyph)).ceil();
}

/// 竖排日文 / 中文里，字与字之间的空白不是词界：模型偶尔在假名之间插空格，
/// 原样落盘会让点词断在空格上。拉丁字母、韩文（谚文按词分写）之间的空白则是
/// 正文的一部分，删掉就是把 `sorry I cannot` 落成 `sorryIcannot`。
///
/// 判据只看空白两侧的字：任一侧是汉字 / 假名 / 中日文标点与全角字符时去掉，否则
/// 折叠成一个空格。不按「本地原文有没有空白」判：单词块（本地 `HEY`、模型
/// `HEY YOU`）与单个韩文语节的块本地都没有空白，按那条判据会把它们粘在一起。
bool _isSpaceFreeScript(int rune) =>
    (rune >= 0x2E80 && rune <= 0x2FDF) || // 部首
    (rune >= 0x3000 && rune <= 0x303F) || // 中日文标点
    (rune >= 0x3040 && rune <= 0x30FF) || // 平假名 / 片假名
    (rune >= 0x31F0 && rune <= 0x31FF) || // 片假名扩展
    (rune >= 0x3400 && rune <= 0x4DBF) || // 汉字扩展 A
    (rune >= 0x4E00 && rune <= 0x9FFF) || // 汉字
    (rune >= 0xF900 && rune <= 0xFAFF) || // 兼容汉字
    (rune >= 0xFF00 && rune <= 0xFFEF) || // 全角 / 半角形式
    (rune >= 0x20000 && rune <= 0x3FFFF); // 汉字扩展 B 及以后

/// 把若干段文字按 [_isSpaceFreeScript] 的规则接起来：接缝两侧任一为中日文时
/// 直接相连，否则用一个空格。
String _joinMangaAiOcrSegments(Iterable<String> segments) {
  final StringBuffer out = StringBuffer();
  String previous = '';
  for (final String segment in segments) {
    if (segment.isEmpty) continue;
    if (previous.isNotEmpty &&
        !_isSpaceFreeScript(previous.runes.last) &&
        !_isSpaceFreeScript(segment.runes.first)) {
      out.write(' ');
    }
    out.write(segment);
    previous = segment;
  }
  return out.toString();
}

/// 一行模型输出：去首尾空白，行内空白按 [_joinMangaAiOcrSegments] 处理。
String normalizeMangaAiOcrLine(String line) =>
    _joinMangaAiOcrSegments(line.trim().split(RegExp(r'\s+')));

/// 把大模型的文字落进块：能按原行几何对上就逐行替换，对不上就按行框重新排版，
/// 都不行就退成整块单行（覆盖层退回整块均铺）。
///
/// 字符级命中区（Lens 的 `regions`）：模型读出的字与原文一致时原样保留（文字没变，
/// 偏移量仍然有效）；文字变了偏移量作废，但 Lens 块没有 `linesCoords`——行（竖排是
/// 列）几何只活在 `regions` 里，所以先按 [_lineBoxesFromRegions] 把它聚回行框再排版。
/// 直接丢掉会让多列气泡退成「整块单行」，每个字的热区横跨所有列，点第二列查到的是
/// 第一列的字（在线直读时本地结果先出、几秒后大模型结果覆盖才错位）。
///
/// 空白处理见 [normalizeMangaAiOcrLine]：中日文去掉、拉丁 / 韩文保留单个空格；
/// 多行拼成一行时接缝也按同一规则（英文行尾与下一行行首之间补空格）。
MokuroBlock applyMangaAiOcrText(MokuroBlock block, String text) {
  final List<String> modelLines = <String>[
    for (final String line in text.split('\n'))
      if (normalizeMangaAiOcrLine(line).isNotEmpty)
        normalizeMangaAiOcrLine(line),
  ];
  final String joined = _joinMangaAiOcrSegments(modelLines);
  final List<MangaOcrTextRegion>? regions = block.regions;
  if (regions != null && regions.isNotEmpty && joined == block.lines.join()) {
    return MokuroBlock(
      rectangle: block.rectangle,
      isVertical: block.isVertical,
      fontSize: block.fontSize,
      zIndex: block.zIndex,
      lines: block.lines,
      linesCoords: block.linesCoords,
      regions: regions,
      confidence: block.confidence,
      aiRecognized: true,
    );
  }
  final List<List<List<double>>>? coords =
      block.linesCoords ?? _lineBoxesFromRegions(block);
  List<String> lines = <String>[joined];
  List<List<List<double>>>? linesCoords;
  if (coords != null && coords.isNotEmpty) {
    if (modelLines.length == coords.length) {
      lines = modelLines;
      linesCoords = coords;
    } else {
      final OcrLineLayout? layout = layoutOcrTextOnLines(joined, <OcrRect>[
        for (final List<List<double>> polygon in coords)
          _polygonBounds(polygon),
      ], vertical: block.isVertical);
      if (layout != null) {
        // 拉丁文按字格切开时，接缝上的空格会落在行首 / 行尾。
        lines = <String>[for (final String line in layout.lines) line.trim()];
        // 切分按外接框做，写回时按原四边形的倾角还原（斜行不能退化成轴对齐框，
        // 否则覆盖层的逐字格又落不到字上）。
        final double tilt = _mangaLinesTilt(coords);
        linesCoords = <List<List<double>>>[
          for (final OcrRect r in layout.boxes) mangaTiltedLineQuad(r, tilt),
        ];
      }
    }
  }
  return MokuroBlock(
    rectangle: block.rectangle,
    isVertical: block.isVertical,
    fontSize: block.fontSize,
    zIndex: block.zIndex,
    lines: lines,
    linesCoords: linesCoords,
    confidence: block.confidence,
    aiRecognized: true,
  );
}

/// 把字符级命中区按阅读序聚成行框（竖排是列框）：相邻两个字主轴（竖排看 y、
/// 横排看 x）往回跳半个字以上，或横轴（竖排看 x、横排看 y）上与前一个字的区间
/// 重叠不到较窄者的一半，就算换行。没有命中区返回 null。
///
/// Lens 的字格是轴对齐外接框（协议层把字的旋转丢了），但斜排气泡里同一行的字
/// 中心仍沿斜线排开：按字数最多那一行的字中心做最小二乘拟合出整块倾角
/// （[_regionLinesTilt]），每行按这个倾角把字格四角投影到旋转后的轴上取范围，
/// 产出旋转四边形。这样改字后 [_mangaLinesTilt] 能从行框读回倾角，重排出来的
/// 逐字格仍沿斜行；倾角可忽略（[mokuroTiltIsNegligible]）时就是原来的轴对齐框。
///
/// 横轴比较的是**前一个字**而不是已聚好的整行：斜行的整行外接框在横轴上会被
/// 漂移撑宽，拿它比会把相邻一列的首字吞进来。
List<List<List<double>>>? _lineBoxesFromRegions(MokuroBlock block) {
  final List<MangaOcrTextRegion>? regions = block.regions;
  if (regions == null || regions.isEmpty) return null;
  final List<MangaOcrTextRegion> ordered = List<MangaOcrTextRegion>.of(regions)
    ..sort(
      (MangaOcrTextRegion a, MangaOcrTextRegion b) =>
          a.utf16Start.compareTo(b.utf16Start),
    );
  final bool vertical = block.isVertical;
  double crossStart(MokuroRect r) => vertical ? r.left : r.top;
  double crossEnd(MokuroRect r) => vertical ? r.right : r.bottom;
  double mainStart(MokuroRect r) => vertical ? r.top : r.left;
  double mainExtent(MokuroRect r) => vertical ? r.height : r.width;
  final List<List<MokuroRect>> lines = <List<MokuroRect>>[];
  for (final MangaOcrTextRegion region in ordered) {
    final MokuroRect rect = region.rectangle;
    if (rect.isEmpty) continue;
    if (lines.isNotEmpty) {
      final MokuroRect previous = lines.last.last;
      final double overlap =
          math.min(crossEnd(previous), crossEnd(rect)) -
          math.max(crossStart(previous), crossStart(rect));
      final double narrower = math.min(
        crossEnd(previous) - crossStart(previous),
        crossEnd(rect) - crossStart(rect),
      );
      final bool wrapsBack =
          mainStart(rect) <
          mainStart(previous) -
              math.min(mainExtent(previous), mainExtent(rect)) / 2;
      if (!wrapsBack && overlap >= narrower / 2) {
        lines.last.add(rect);
        continue;
      }
    }
    lines.add(<MokuroRect>[rect]);
  }
  if (lines.isEmpty) return null;
  final double tilt = _regionLinesTilt(lines, vertical: vertical);
  return <List<List<double>>>[
    for (final List<MokuroRect> line in lines) _orientedLineQuad(line, tilt),
  ];
}

/// 按字数最多那一行的字中心拟合整块倾角（弧度，正值顺时针，与
/// [MokuroOrientedRect.rotation] 同口径）：竖排拟合 `x = a + b·y`，列向下走时 x
/// 往左偏即顺时针，倾角 = `-atan(b)`；横排拟合 `y = a + b·x`，倾角 = `atan(b)`。
/// 不到两个字、拟合退化，或这一行按该倾角仍可忽略（[mokuroTiltIsNegligible]，
/// 字宽抖动的噪声角度落在这里）时返回 0。
double _regionLinesTilt(
  List<List<MokuroRect>> lines, {
  required bool vertical,
}) {
  List<MokuroRect>? longest;
  for (final List<MokuroRect> line in lines) {
    if (line.length < 2) continue;
    if (longest == null || line.length > longest.length) longest = line;
  }
  if (longest == null) return 0;
  final int n = longest.length;
  double meanMain = 0, meanCross = 0;
  for (final MokuroRect r in longest) {
    meanMain += (vertical ? r.center.dy : r.center.dx) / n;
    meanCross += (vertical ? r.center.dx : r.center.dy) / n;
  }
  double covariance = 0, variance = 0;
  for (final MokuroRect r in longest) {
    final double dm = (vertical ? r.center.dy : r.center.dx) - meanMain;
    final double dc = (vertical ? r.center.dx : r.center.dy) - meanCross;
    covariance += dm * dc;
    variance += dm * dm;
  }
  if (variance <= 0) return 0;
  final double slope = covariance / variance;
  final double tilt = vertical ? -math.atan(slope) : math.atan(slope);
  final MokuroOrientedRect oriented = _orientedLineRect(longest, tilt);
  final double length = math.max(oriented.width, oriented.height);
  final double thickness = math.min(oriented.width, oriented.height);
  return mokuroTiltIsNegligible(length, thickness, tilt) ? 0 : tilt;
}

/// 一行字格在旋转 [tilt] 后的轴上的最小包围矩形：把每个字格的四角投影到
/// 旋转后的 x / y 轴取范围。[tilt] 为 0 时就是所有字格的轴对齐并集。
MokuroOrientedRect _orientedLineRect(List<MokuroRect> line, double tilt) {
  final double c = math.cos(tilt);
  final double s = math.sin(tilt);
  double minU = double.infinity, maxU = double.negativeInfinity;
  double minV = double.infinity, maxV = double.negativeInfinity;
  for (final MokuroRect r in line) {
    for (final MokuroPoint p in <MokuroPoint>[
      MokuroPoint(r.left, r.top),
      MokuroPoint(r.right, r.top),
      MokuroPoint(r.right, r.bottom),
      MokuroPoint(r.left, r.bottom),
    ]) {
      // 页面坐标 → 旋转后的局部轴（[MokuroOrientedRect.toPage] 的逆）。
      final double u = p.dx * c + p.dy * s;
      final double v = -p.dx * s + p.dy * c;
      minU = math.min(minU, u);
      maxU = math.max(maxU, u);
      minV = math.min(minV, v);
      maxV = math.max(maxV, v);
    }
  }
  final double cu = (minU + maxU) / 2;
  final double cv = (minV + maxV) / 2;
  return MokuroOrientedRect(
    center: MokuroPoint(cu * c - cv * s, cu * s + cv * c),
    width: maxU - minU,
    height: maxV - minV,
    rotation: tilt,
  );
}

/// [_orientedLineRect] 的四个角，顺时针、从旋转后的左上角起（[tilt] 为 0 时即
/// 轴对齐框的左上、右上、右下、左下）。
List<List<double>> _orientedLineQuad(List<MokuroRect> line, double tilt) {
  final MokuroOrientedRect rect = _orientedLineRect(line, tilt);
  final double halfW = rect.width / 2;
  final double halfH = rect.height / 2;
  List<double> corner(double x, double y) {
    final MokuroPoint p = rect.toPage(x, y);
    return <double>[p.dx, p.dy];
  }

  return <List<double>>[
    corner(-halfW, -halfH),
    corner(halfW, -halfH),
    corner(halfW, halfH),
    corner(-halfW, halfH),
  ];
}

/// 行四边形的共同倾角（同一块里各行同一个倾角，见 `ppBlockTilt`）：取能拟合成
/// 旋转矩形的四边形里**沿行方向最长**的那个的角度；都拟合不了视为正立。
///
/// 不能取第一个：[mokuroOrientedRectFromQuad] 按该四边形自己的长度判倾斜是否
/// 可忽略（[mokuroTiltIsNegligible]），整块斜 3° 时 3 个字的短列会被归成 0，
/// 而同块 20 个字的长列重排后就全退回轴对齐、首尾字点不中。最长的行角度估计
/// 最稳、可忽略判据也最宽；它都被判可忽略时，块里所有行（更短）同样可忽略。
double _mangaLinesTilt(List<List<List<double>>> coords) {
  double tilt = 0;
  double longest = -1;
  for (final List<List<double>> polygon in coords) {
    final MokuroOrientedRect? oriented = mokuroOrientedRectFromQuad(polygon);
    if (oriented == null) continue;
    final double length = math.max(oriented.width, oriented.height);
    if (length > longest) {
      longest = length;
      tilt = oriented.rotation;
    }
  }
  return tilt;
}

OcrRect _polygonBounds(List<List<double>> polygon) {
  double left = double.infinity;
  double top = double.infinity;
  double right = double.negativeInfinity;
  double bottom = double.negativeInfinity;
  for (final List<double> point in polygon) {
    if (point.length < 2) continue;
    left = math.min(left, point[0]);
    right = math.max(right, point[0]);
    top = math.min(top, point[1]);
    bottom = math.max(bottom, point[1]);
  }
  if (!left.isFinite) {
    return const OcrRect(left: 0, top: 0, right: 0, bottom: 0);
  }
  return OcrRect(left: left, top: top, right: right, bottom: bottom);
}

/// 解码整页并裁出 [boxes]（坐标系为 [pageWidth]×[pageHeight]），各编码成 PNG。
/// 解码失败或框落在图外的位置为 null。顶层函数：给 `Isolate.run` 用。
List<Uint8List?> cropMangaAiOcrBlocks(
  Uint8List imageBytes, {
  required double pageWidth,
  required double pageHeight,
  required List<MokuroRect> boxes,
}) {
  final img.Image? decoded = img.decodeImage(imageBytes);
  if (decoded == null) {
    return List<Uint8List?>.filled(boxes.length, null);
  }
  final double sx = pageWidth > 0 ? decoded.width / pageWidth : 1;
  final double sy = pageHeight > 0 ? decoded.height / pageHeight : 1;
  return <Uint8List?>[
    for (final MokuroRect box in boxes) _cropOne(decoded, box, sx, sy),
  ];
}

Uint8List? _cropOne(img.Image page, MokuroRect box, double sx, double sy) {
  final int left = math.max(
    0,
    (box.left * sx).floor() - kMangaAiOcrCropPadding,
  );
  final int top = math.max(0, (box.top * sy).floor() - kMangaAiOcrCropPadding);
  final int right = math.min(
    page.width,
    (box.right * sx).ceil() + kMangaAiOcrCropPadding,
  );
  final int bottom = math.min(
    page.height,
    (box.bottom * sy).ceil() + kMangaAiOcrCropPadding,
  );
  if (right - left < 2 || bottom - top < 2) return null;
  img.Image crop = img.copyCrop(
    page,
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  );
  final int shortSide = math.min(crop.width, crop.height);
  final int longSide = math.max(crop.width, crop.height);
  if (longSide > kMangaAiOcrMaxCropSide) {
    final double scale = kMangaAiOcrMaxCropSide / longSide;
    crop = img.copyResize(
      crop,
      width: math.max(1, (crop.width * scale).round()),
      height: math.max(1, (crop.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  } else if (shortSide < kMangaAiOcrMinCropSide) {
    final int factor = math.min(
      (kMangaAiOcrMinCropSide / math.max(1, shortSide)).ceil(),
      math.max(1, kMangaAiOcrMaxCropSide ~/ longSide),
    );
    if (factor > 1) {
      crop = img.copyResize(
        crop,
        width: crop.width * factor,
        height: crop.height * factor,
        interpolation: img.Interpolation.cubic,
      );
    }
  }
  return Uint8List.fromList(img.encodePng(crop));
}
