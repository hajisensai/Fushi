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
  /// 不用大模型（默认）。
  off,

  /// 只重读本地识别器低置信度的块。
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

Reply with JSON only, no prose:
{"blocks":[{"id":1,"text":"..."}]}''';

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

/// 大模型重读器。一卷一个实例（[cache] 绑卷目录）；不是线程安全的，按页顺序调用。
///
/// [cancel] 之后本实例作废：在途请求被中止（关掉它的 HTTP 客户端），之后的
/// [refinePage] 一律原样交回本地结果、不再发请求。
class MangaAiOcrRefiner {
  MangaAiOcrRefiner({
    required this.provider,
    required this.mode,
    AiChatClient Function()? clientFactory,
    this.threshold = kMangaAiOcrLowConfidenceThreshold,
    this.blocksPerRequest = kMangaAiOcrBlocksPerRequest,
  }) : assert(mode != MangaAiOcrMode.off),
       _clientFactory = clientFactory ?? AiChatClient.new;

  final AiProviderConfig provider;
  final MangaAiOcrMode mode;
  final double threshold;
  final int blocksPerRequest;
  final AiChatClient Function() _clientFactory;

  String? _fatalFailure;
  bool _cancelled = false;
  final Set<AiChatClient> _activeClients = <AiChatClient>{};

  /// 遇到过「重试也没用」的失败（鉴权 / 配置 / 4xx）：此后不再发请求，整卷保留
  /// 本地结果。null = 仍可用。
  String? get fatalFailure => _fatalFailure;

  /// 已被 [cancel]。
  bool get isCancelled => _cancelled;

  /// 调用方不再要结果（阅读会话关了 / 任务取消了 / 书删了）：中止在途请求，此后
  /// 不再发任何请求。幂等。
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final AiChatClient client in _activeClients) {
      client.close();
    }
    _activeClients.clear();
  }

  /// 这个块要不要送大模型。
  bool wants(MokuroBlock block) {
    if (block.aiRecognized || block.lines.join().trim().isEmpty) return false;
    return switch (mode) {
      MangaAiOcrMode.off => false,
      MangaAiOcrMode.all => true,
      // 不出分的引擎（Lens / 系统 OCR / 旧缓存）null：不知道就不花钱。
      MangaAiOcrMode.lowConfidence =>
        block.confidence != null && block.confidence! < threshold,
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

    final Map<int, String> texts = <int, String>{};
    final List<int> pending = <int>[];
    final Map<int, String> keys = <int, String>{};
    int cached = 0;
    for (int k = 0; k < wanted.length; k++) {
      final Uint8List? crop = crops[k];
      if (crop == null) continue;
      final String key = sha1.convert(crop).toString();
      keys[k] = key;
      final String? hit = await cache?.lookup(key);
      if (hit != null) {
        texts[k] = hit;
        cached++;
      } else {
        pending.add(k);
      }
    }

    String? failure;
    final Map<String, String> fresh = <String, String>{};
    if (_cancelled) {
      return (page: page, stats: const MangaAiOcrPageStats());
    }
    final AiChatClient client = _clientFactory();
    _activeClients.add(client);
    try {
      for (int start = 0; start < pending.length; start += blocksPerRequest) {
        if (_cancelled) break;
        final List<int> batch = pending.sublist(
          start,
          math.min(start + blocksPerRequest, pending.length),
        );
        final Map<int, String>? read;
        try {
          read = await _requestBatch(client, <Uint8List>[
            for (final int k in batch) crops[k]!,
          ]);
        } on AiChatFailure catch (error) {
          if (_cancelled) break;
          failure = error.message;
          if (!error.isTransient) {
            _fatalFailure = error.message;
            break;
          }
          continue;
        }
        if (read == null) {
          failure = 'bad_response';
          continue;
        }
        for (int j = 0; j < batch.length; j++) {
          final int k = batch[j];
          final String? text = read[j + 1];
          if (text == null) continue;
          final MokuroBlock source = page.blocks[wanted[k]];
          if (!isPlausibleMangaAiOcrText(
            text,
            local: source.lines.join(),
            block: source,
          )) {
            continue;
          }
          texts[k] = text;
          fresh[keys[k]!] = text;
        }
      }
    } finally {
      _activeClients.remove(client);
      client.close();
    }
    if (_cancelled) {
      // 调用方已不要结果：不落缓存（它可能是因为删书而取消），也不交改写。
      return (page: page, stats: const MangaAiOcrPageStats());
    }
    if (cache != null && fresh.isNotEmpty) {
      try {
        await cache.storeAll(fresh);
      } on FileSystemException {
        // 缓存写不进去只影响下次花不花钱，不影响本次结果。
      }
    }

    final List<MokuroBlock> blocks = List<MokuroBlock>.of(page.blocks);
    for (final MapEntry<int, String> entry in texts.entries) {
      final int index = wanted[entry.key];
      blocks[index] = applyMangaAiOcrText(blocks[index], entry.value);
    }
    return (
      page: MokuroImage(url: page.url, size: page.size, blocks: blocks),
      stats: MangaAiOcrPageStats(
        candidates: wanted.length,
        replaced: texts.length,
        cached: cached,
        failure: failure,
      ),
    );
  }

  /// 一批裁图一次请求；回复按 1 起的编号对回。形状不对返回 null。
  Future<Map<int, String>?> _requestBatch(
    AiChatClient client,
    List<Uint8List> crops,
  ) async {
    final String reply = await client.complete(
      provider: provider,
      maxTokens: 256 + 192 * crops.length,
      messages: <AiChatMessage>[
        const AiChatMessage.system(kMangaAiOcrSystemPrompt),
        AiChatMessage.user(
          'There are ${crops.length} images, ids 1 to ${crops.length} in '
          'order. Return one entry per id.',
          images: <AiChatImage>[
            for (final Uint8List crop in crops) AiChatImage(bytes: crop),
          ],
        ),
      ],
    );
    return parseMangaAiOcrReply(reply, count: crops.length);
  }
}

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
/// 都不行就退成整块单行（覆盖层退回整块均铺）。字符级命中区（Lens 的
/// `regions`）的偏移量对新文字无效，一律丢掉。
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
  final List<List<List<double>>>? coords = block.linesCoords;
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
        linesCoords = <List<List<double>>>[
          for (final OcrRect r in layout.boxes)
            <List<double>>[
              <double>[r.left, r.top],
              <double>[r.right, r.top],
              <double>[r.right, r.bottom],
              <double>[r.left, r.bottom],
            ],
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
