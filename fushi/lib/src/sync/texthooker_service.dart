import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/src/utils/misc/ruby_markup.dart';

enum TexthookerLineSource { websocket, engineHook, unknown }

/// 线程选择弹窗每条线程保留的预览句数上限（BUG-1474）。
///
/// 3 是因为选择弹窗那行本来就写着 `maxLines: 3`；再多也显示不出来，只是白占内存。
const int kTexthookerPreviewHistory = 3;

/// 线程选择下拉的副标题：`[N 行有音频 · ]最近台词预览`。两段都空返回 null
/// （该行保持单行）。[audioLabel] 由调用方用 i18n 拼好传入（纯函数不碰 t）。
String? texthookerThreadSubtitle({
  required int audioLineCount,
  required String? latestText,
  required String audioLabel,

  /// BUG-1474：该线程最近若干句（新→旧，已去重）。非空时**取代** [latestText]，
  /// 一句一行地展示——选择弹窗那行早就写着 `maxLines: 3`，缺的从来是数据不是 UI：
  /// native 线程预览区每线程恒一条，一句话根本不够用户判断"这条是不是正文流"。
  /// 缺省 const [] ⇒ 与旧行为逐字等价（既有调用点/测试不受影响）。
  List<String> recentTexts = const <String>[],
}) {
  final List<String> previews = <String>[
    for (final String text in recentTexts)
      if (collapseTexthookerPreview(text).isNotEmpty)
        collapseTexthookerPreview(text),
  ];
  final String preview = previews.isNotEmpty
      ? previews.join('\n')
      : (latestText == null ? '' : collapseTexthookerPreview(latestText));
  final List<String> parts = <String>[
    if (audioLineCount > 0) audioLabel,
    if (preview.isNotEmpty) preview,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// 台词预览归一：先折叠 hook 噪声（[foldRepeatedTextForPreview]），再把连续空白
/// （含换行）折成单空格、trim、按**字素簇**截断到 [maxCharacters]（绝不劈开代理对/
/// 组合字），超长补省略号。纯函数。
///
/// 只用于线程选择下拉的**预览**，不改任何入库/制卡文本——折叠是为了让 KiriKiriZ/
/// TextRender 这类逐字重绘、双写线程在列表里可读（对齐 Luna「选择文本」的清洗展示）。
String collapseTexthookerPreview(String text, {int maxCharacters = 40}) {
  final String folded = foldRepeatedTextForPreview(text);
  final String collapsed = folded.replaceAll(RegExp(r'\s+'), ' ').trim();
  final Characters chars = collapsed.characters;
  if (chars.length <= maxCharacters) return collapsed;
  return '${chars.take(maxCharacters)}…';
}

/// 折叠文本 hook 常见的三类重复噪声，**仅供预览展示**（不改行文本/制卡内容）。纯函数。
///
/// 逐字重绘引擎（KiriKiriZ、内部 TextRender）和双写线程（EmbedKrkrZ）会把一句话喂成
/// 「靴靴靴靴靴ををを脱脱…」「アトリアトリアトリ」「文本文本」这类字符串，Luna 的
/// 「选择文本」会清洗后再展示，Hibiki 之前原样显示、可用性差。这里按字素簇做三步：
///
/// 1. **整串周期折叠**：整串恰为某最短单元重复 ≥2 次 → 只留一个单元
///    （`アトリアトリアトリ`→`アトリ`、`文本文本`→`文本`、`ABAB`→`AB`）。
/// 2. **连续单字折叠**：同一字素连续出现 ≥[runThreshold] 次 → 收成 1 个
///    （`靴靴靴靴靴`→`靴`）。日文正常文本极少出现 3 连相同字素，阈值 3 足够保守。
/// 3. 再做一次整串周期折叠，兜住第 2 步之后新暴露出的周期。
///
/// 空串、单字素、正常句子原样返回。
String foldRepeatedTextForPreview(String text, {int runThreshold = 3}) {
  if (text.isEmpty) return text;
  final String periodic = _foldWholeStringRepetition(text);
  final String collapsed = _collapseLongRuns(periodic, runThreshold);
  return _foldWholeStringRepetition(collapsed);
}

/// 整串恰为最短单元重复 ≥2 次时返回该单元，否则原样返回。按字素簇比较。
String _foldWholeStringRepetition(String text) {
  final List<String> units = text.characters.toList();
  final int n = units.length;
  if (n < 2) return text;
  for (int period = 1; period <= n ~/ 2; period++) {
    if (n % period != 0) continue;
    bool periodic = true;
    for (int i = period; i < n && periodic; i++) {
      if (units[i] != units[i - period]) periodic = false;
    }
    if (periodic) return units.take(period).join();
  }
  return text;
}

/// 把连续出现 ≥[threshold] 次的同一字素簇收成**一个**；短于 [threshold] 的游程原样
/// 保留。按字素簇处理。例：threshold=3 时 `靴靴靴靴靴`→`靴`、`をを`→`をを`（不动）。
String _collapseLongRuns(String text, int threshold) {
  if (threshold < 2) return text;
  final List<String> units = text.characters.toList();
  if (units.length < threshold) return text;
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < units.length) {
    final String g = units[i];
    int j = i + 1;
    while (j < units.length && units[j] == g) {
      j++;
    }
    final int runLength = j - i;
    if (runLength >= threshold) {
      out.write(g);
    } else {
      for (int k = 0; k < runLength; k++) {
        out.write(g);
      }
    }
    i = j;
  }
  return out.toString();
}

/// 为一批线程分配**互不相同**的下拉展示标签：label 唯一时原样返回；多个线程共用同一
/// label（KiriKiriZ 同一 hook 面在不同调用上下文会报成多个线程，label 只含 hookName +
/// 地址，无法区分）时，给每个追加 `#N` 序号后缀，避免下拉里出现一整列一模一样的
/// `TextRender · 0x… · 0`。纯函数，输入顺序即编号顺序（[TexthookerService.textThreads]
/// 已按活跃度排好）。返回 key→展示 label 映射。
Map<String, String> assignThreadDisplayLabels(
  List<TexthookerTextThread> threads,
) {
  final Map<String, int> labelCounts = <String, int>{};
  for (final TexthookerTextThread thread in threads) {
    labelCounts[thread.label] = (labelCounts[thread.label] ?? 0) + 1;
  }
  final Map<String, int> seen = <String, int>{};
  final Map<String, String> result = <String, String>{};
  for (final TexthookerTextThread thread in threads) {
    if ((labelCounts[thread.label] ?? 0) <= 1) {
      result[thread.key] = thread.label;
    } else {
      final int index = (seen[thread.label] ?? 0) + 1;
      seen[thread.label] = index;
      result[thread.key] = '${thread.label} #$index';
    }
  }
  return result;
}

enum TexthookerLineAudioStatus {
  unavailable,
  pending,
  matched,
  fallback,
  missing,
  encoded,
}

/// [TexthookerLineEntry.fallbackReason] 的三个**语义化**值（其余 reason 是诊断字符串）：
/// UI 靠它们把「这句本来就没配音」从「疑似漏抓」的红标里分出来、把「超长可疑切片」
/// 从正常兜底里分出来、把「用户策略主动抑制了唯一可用音源」从前两者里分出来。
/// 生产与消费两侧共用本常量，别在别处重复字面量。
const String kGalLineNoVoiceReason = 'line_has_no_voice';
const String kGalOverlongSliceSuspectReason = 'slice_overlong_suspect';

/// 干净源策略把整机混音挡掉、且**没有任何证据**能判断这句到底有没有配音时用它。
///
/// 与 [kGalLineNoVoiceReason] 的区别是硬性的：那个是有证据的结论（候选轨在该句时刻
/// 窗内全静默），这个只是「你禁用了本会话唯一可用的音源」。把没证据的抑制说成
/// 「这句没配音」等于用前一阶段推断后一阶段——纯 loopback 降级会话下会把每一行都
/// 说成没配音，资源模式的**真漏抓**也会被这句话盖过去。
const String kGalCleanSourceSuppressedReason = 'clean_source_suppressed';

/// 实时台词列表的筛选维度。单一枚举驱动 [lineMatchesFilter] 一个 predicate，
/// 消除「有音频 / 已制卡 / 已收藏」各写一条 if 分支的特殊情况。与线程下拉筛选正交：
/// 先按线程取行，再按本枚举过滤。
enum TexthookerLineFilter { all, withAudio, mined, favorited }

/// 一条可由用户选择的文本 Hook 线程。
///
/// [key] 在一次捕获会话内稳定；LunaHook 使用 ThreadParam + hookcode 的哈希，
/// WebSocket/GDI 等没有线程信息的来源不会出现在该列表中。
@immutable
class TexthookerTextThread {
  const TexthookerTextThread({
    required this.key,
    required this.label,
    required this.lineCount,
    required this.latestAt,
    this.hookCode,
    this.nativeThreadId,
    this.latestText,
    this.audioLineCount = 0,
    this.previewText,
    this.observedLineCount = 0,
    this.observedArtifactCount = 0,
    this.previewIsArtifact = false,
    this.recentPreviewTexts = const <String>[],
  });

  /// 全字段拷贝。
  ///
  /// BUG-1474：本类原先有**四处**手写全字段构造，加一个字段就得改四处，漏一处就是
  /// 该字段在某条路径上被静默清空（`disambiguateThreadLabels` 只想改个 label，却要
  /// 把十几个字段逐个抄一遍）。纯拷贝的那两处改走这里，结构上不可能再漏。
  TexthookerTextThread copyWith({
    String? label,
    String? previewText,
    int? observedLineCount,
    int? observedArtifactCount,
    bool? previewIsArtifact,
    List<String>? recentPreviewTexts,
  }) =>
      TexthookerTextThread(
        key: key,
        label: label ?? this.label,
        hookCode: hookCode,
        nativeThreadId: nativeThreadId,
        lineCount: lineCount,
        latestAt: latestAt,
        latestText: latestText,
        audioLineCount: audioLineCount,
        previewText: previewText ?? this.previewText,
        observedLineCount: observedLineCount ?? this.observedLineCount,
        observedArtifactCount:
            observedArtifactCount ?? this.observedArtifactCount,
        previewIsArtifact: previewIsArtifact ?? this.previewIsArtifact,
        recentPreviewTexts: recentPreviewTexts ?? this.recentPreviewTexts,
      );

  final String key;
  final String label;
  final String? hookCode;
  final int? nativeThreadId;

  /// 已**发布**到文本环的行数（即当前生效线程的行）。v12 起未被选中的线程恒为 0，
  /// 判断「这条线程有没有内容」必须用 [observedLineCount]，不是本字段。
  final int lineCount;
  final DateTime latestAt;

  /// 该线程最近一条**已发布**台词原文（尚无已发布台词为 null）。
  final String? latestText;

  /// 该线程已配到句音的行数（[TexthookerLineEntry.hasAudio] 计数；语音线程
  /// 通常≈lineCount，UI 线程为 0——选择下拉靠它区分「选哪个」）。
  final int audioLineCount;

  /// native 线程预览区里该线程的最近一行（v12）。**不受线程选择门控影响**：未被选中
  /// 的线程也有值，这正是选择器能像 LunaTranslator 那样展示全部候选的来源。
  final String? previewText;

  /// native 观测到的该线程总行数，**含被伪影过滤和线程门控丢弃的**。
  ///
  /// 它和 [lineCount] 的区别是本次改动的关键：v12 取消自动选线程后，用户选定之前
  /// 文本环恒空，[lineCount] 对所有线程都是 0。凡是「这条线程活不活跃 / 该不该排前面 /
  /// 跨会话记忆能不能认回它」这类判断，都必须读本字段。
  final int observedLineCount;

  /// [observedLineCount] 中被判为重复伪影的行数。UI 据此把脏线程标出来而不是藏掉
  /// （对齐 LunaTranslator：逐字重绘那条一直显示，只是你不选它）。
  final int observedArtifactCount;

  /// 预览里这最近一行是否被判为伪影。
  final bool previewIsArtifact;

  /// 该线程最近若干句 native 预览（新→旧，已去重，最多 [kTexthookerPreviewHistory] 条）。
  ///
  /// native 预览区**每线程恒一条**，所以这份历史只能由 Dart 侧跨轮询累积
  /// （见 [TexthookerService.applyTextThreadPreviews]）。用户诉求是「一条线程要能看到
  /// 2~3 句才判断得出这是不是正文流」——一句话经常是「……」或人名，分辨不了。
  final List<String> recentPreviewTexts;

  /// 下拉展示用的预览文本：优先已发布台词，回落 native 预览行。
  String? get displayPreviewText => latestText ?? previewText;

  /// 该线程是否出过内容（发布与否无关）。
  bool get hasObservedLines => observedLineCount > 0 || lineCount > 0;
}

/// native 线程预览区的一条快照（v12）。按 native thread id 对齐到线程目录。
@immutable
class TexthookerThreadPreview {
  const TexthookerThreadPreview({
    required this.nativeThreadId,
    required this.text,
    required this.observedLineCount,
    required this.observedArtifactCount,
    required this.isArtifact,
  });

  final int nativeThreadId;
  final String text;
  final int observedLineCount;
  final int observedArtifactCount;
  final bool isArtifact;
}

@immutable
class TexthookerLineEntry {
  const TexthookerLineEntry({
    required this.id,
    required this.text,
    required this.source,
    required this.receivedAt,
    this.sourceLabel,
    this.sourceSequence,
    this.hookTimestampMs,
    this.textThreadKey,
    this.textThreadLabel,
    this.textHookCode,
    this.nativeTextThreadId,
    this.audioStatus = TexthookerLineAudioStatus.unavailable,
    this.audioBackend,
    this.audioResourceId,
    this.audioDurationMs,
    this.fallbackReason,
    this.mined = false,
    this.favorited = false,
    this.rubySpans = const <RubySpan>[],
  });

  final String id;

  /// 纯基准文本：注音标记已在 [TexthookerService.appendLine] 剥掉（注音落在
  /// [rubySpans]）。**全链路唯一坐标系**——浮窗显示、点字查词的 native index、
  /// 制卡 sentence、字数统计都以它为准，任何一处换成别的串都会立刻错位。
  final String text;
  final TexthookerLineSource source;
  final String? sourceLabel;
  final int? sourceSequence;
  final int? hookTimestampMs;
  final String? textThreadKey;
  final String? textThreadLabel;
  final String? textHookCode;
  final int? nativeTextThreadId;
  final DateTime receivedAt;
  final TexthookerLineAudioStatus audioStatus;
  final String? audioBackend;

  /// 与本句时间戳精确配对的游戏资源文件名。只保存 dump 目录内的 basename，
  /// 历史句子制卡时可直接定位同一份资源，避免重新扫描后误配到较新的语音。
  final String? audioResourceId;
  final int? audioDurationMs;
  final String? fallbackReason;

  /// 本行是否已成功制卡（会话内存态，不落 DB）。制卡成功由
  /// [GalHookMiningCoordinator] / fallback 制卡回写（见 [TexthookerService.markLineMined]）。
  final bool mined;

  /// 本行是否已被用户收藏（会话内存态，不落 DB；重启即失）。
  final bool favorited;

  /// 本行的注音（振假名）区间，下标落在 [text] 上（UTF-16 code unit）。
  /// 空表示这行没有可识别的注音标记。
  final List<RubySpan> rubySpans;

  /// 本行是否已有可用句音：matched（配到游戏资源）/ encoded（音频已提取进卡）/
  /// fallback（回退环回声）三态即有音频；pending/missing/unavailable 视作无。
  bool get hasAudio => switch (audioStatus) {
        TexthookerLineAudioStatus.matched ||
        TexthookerLineAudioStatus.encoded ||
        TexthookerLineAudioStatus.fallback =>
          true,
        TexthookerLineAudioStatus.pending ||
        TexthookerLineAudioStatus.missing ||
        TexthookerLineAudioStatus.unavailable =>
          false,
      };

  TexthookerLineEntry copyWith({
    TexthookerLineAudioStatus? audioStatus,
    String? audioBackend,
    String? audioResourceId,
    int? audioDurationMs,
    String? fallbackReason,
    bool? mined,
    bool? favorited,
    bool clearAudioResourceId = false,
    bool clearFallbackReason = false,
  }) {
    return TexthookerLineEntry(
      id: id,
      text: text,
      source: source,
      sourceLabel: sourceLabel,
      sourceSequence: sourceSequence,
      hookTimestampMs: hookTimestampMs,
      textThreadKey: textThreadKey,
      textThreadLabel: textThreadLabel,
      textHookCode: textHookCode,
      nativeTextThreadId: nativeTextThreadId,
      receivedAt: receivedAt,
      audioStatus: audioStatus ?? this.audioStatus,
      audioBackend: audioBackend ?? this.audioBackend,
      audioResourceId:
          clearAudioResourceId ? null : audioResourceId ?? this.audioResourceId,
      audioDurationMs: audioDurationMs ?? this.audioDurationMs,
      fallbackReason:
          clearFallbackReason ? null : fallbackReason ?? this.fallbackReason,
      mined: mined ?? this.mined,
      favorited: favorited ?? this.favorited,
      rubySpans: rubySpans,
    );
  }
}

/// 收到的 texthooker 结构化文本行 buffer。单例 + [ChangeNotifier]，
/// 外部 texthooker 软件可经 WebSocket 接入，游戏 Hook 则追加带线程与时间戳的行。
/// [lines] 保留旧字符串接口；捕获工作台与句音配对使用 [entries] 的稳定 id、
/// 来源、序号和时间戳，重复台词不会再因以 sentence 字符串作 key 而相互覆盖。
class TexthookerService extends ChangeNotifier {
  TexthookerService._();
  static final TexthookerService instance = TexthookerService._();

  @visibleForTesting
  TexthookerService.test();

  static const int maxLines = 500;

  final List<TexthookerLineEntry> _entries = <TexthookerLineEntry>[];
  final Map<String, TexthookerTextThread> _discoveredTextThreads =
      <String, TexthookerTextThread>{};
  int _nextId = 0;

  List<TexthookerLineEntry> get entries =>
      List<TexthookerLineEntry>.unmodifiable(_entries);
  List<String> get lines =>
      List<String>.unmodifiable(_entries.map((entry) => entry.text));

  /// 按稳定行 id 精确取回捕获项。找不到时返回 null，调用方不得回退到最新行。
  TexthookerLineEntry? entryById(String id) {
    for (final TexthookerLineEntry entry in _entries.reversed) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// 已发现的可选文本线程，最近活跃的排在前面。
  ///
  /// Luna 的 ThreadCreate 事件会先放入 [_discoveredTextThreads]，因此被自动赢家过滤、当前
  /// 尚无已发布台词的候选也会以 0 行显示；已有台词再从 [_entries] 聚合计数。
  List<TexthookerTextThread> get textThreads => textThreadsSince(null);

  /// [startedAt] 之后的会话级线程目录。Luna thread id 含进程身份，旧捕获会话里的
  /// `TextRender` 即使标签相同也不再对应当前 helper；把它混进选择器会出现「可选、选择
  /// 成功、但永远 0 行」的死候选。null 保留完整历史目录，供会话外查看。
  List<TexthookerTextThread> textThreadsSince(DateTime? startedAt) {
    final Map<String, TexthookerTextThread> byKey =
        <String, TexthookerTextThread>{
      for (final MapEntry<String, TexthookerTextThread> entry
          in _discoveredTextThreads.entries)
        if (startedAt == null || !entry.value.latestAt.isBefore(startedAt))
          entry.key: entry.value,
    };
    for (final TexthookerLineEntry entry in _entries) {
      if (startedAt != null && entry.receivedAt.isBefore(startedAt)) continue;
      final String? key = entry.textThreadKey;
      if (key == null || key.isEmpty) continue;
      final TexthookerTextThread? previous = byKey[key];
      byKey[key] = TexthookerTextThread(
        key: key,
        label: entry.textThreadLabel ?? previous?.label ?? key,
        hookCode: entry.textHookCode ?? previous?.hookCode,
        nativeThreadId: entry.nativeTextThreadId ?? previous?.nativeThreadId,
        lineCount: (previous?.lineCount ?? 0) + 1,
        latestAt: entry.receivedAt,
        // _entries 按接收顺序迭代，最后一次赋值即最新台词。
        latestText: entry.text,
        audioLineCount:
            (previous?.audioLineCount ?? 0) + (entry.hasAudio ? 1 : 0),
        previewText: previous?.previewText,
        observedLineCount: previous?.observedLineCount ?? 0,
        observedArtifactCount: previous?.observedArtifactCount ?? 0,
        previewIsArtifact: previous?.previewIsArtifact ?? false,
      );
    }
    // native 预览按 thread id 对齐：线程目录的 key 是 Dart 侧字符串，预览区只知道
    // native thread id，故在这里合流而不是在写入侧——写入侧拿不到 key 映射。
    if (_threadPreviews.isNotEmpty) {
      for (final MapEntry<String, TexthookerTextThread> entry
          in byKey.entries) {
        final int? nativeId = entry.value.nativeThreadId;
        if (nativeId == null) continue;
        final TexthookerThreadPreview? preview = _threadPreviews[nativeId];
        if (preview == null) continue;
        byKey[entry.key] = entry.value.copyWith(
          previewText: preview.text.isEmpty ? null : preview.text,
          observedLineCount: preview.observedLineCount,
          observedArtifactCount: preview.observedArtifactCount,
          previewIsArtifact: preview.isArtifact,
          recentPreviewTexts:
              _threadPreviewHistory[nativeId] ?? const <String>[],
        );
      }
    }
    final List<TexthookerTextThread> result = byKey.values.toList()
      ..sort(_compareTextThreads);
    return List<TexthookerTextThread>.unmodifiable(
      disambiguateThreadLabels(result),
    );
  }

  /// 同标签线程补可区分后缀。
  ///
  /// 标签 = `hookName · 0x<线程地址>`（见 `GalHookedLine.textThreadLabel`），而同一个
  /// hook 常有多条并行线程只在 ctx/ctx2 上不同——ctx 没透出到 Dart，于是下拉里出现
  /// 一串**完全相同**的 `CodeX · 0x459f50`，用户只能靠行数猜哪条是自己要的。
  /// 这里给重名的每条补上 key 里那段线程 id 的短哈希（`· #1a2b`），让它们至少可指认；
  /// 唯一的标签保持原样，不给不重名的线程加噪音。
  @visibleForTesting
  static List<TexthookerTextThread> disambiguateThreadLabels(
    List<TexthookerTextThread> threads,
  ) {
    final Map<String, int> labelCounts = <String, int>{};
    for (final TexthookerTextThread thread in threads) {
      labelCounts[thread.label] = (labelCounts[thread.label] ?? 0) + 1;
    }
    if (!labelCounts.values.any((int count) => count > 1)) return threads;
    return <TexthookerTextThread>[
      for (final TexthookerTextThread thread in threads)
        if ((labelCounts[thread.label] ?? 0) <= 1)
          thread
        else
          thread.copyWith(
            label: '${thread.label} · #${_threadKeySuffix(thread.key)}',
          ),
    ];
  }

  /// 线程 key（`<来源>:<线程 id 十六进制>`）里取末 4 位十六进制作可指认后缀。
  static String _threadKeySuffix(String key) {
    final int colon = key.lastIndexOf(':');
    final String tail = colon >= 0 ? key.substring(colon + 1) : key;
    return tail.length <= 4 ? tail : tail.substring(tail.length - 4);
  }

  /// 线程列表排序：**有台词的线程恒排在 0 行线程之前**，其次句音行数多者优先，
  /// 再次最近活跃者优先。此前只按 `latestAt` 排，而每个 ThreadCreate 都会把一条 0 行
  /// 线程的 `latestAt` 顶到当下，导致刚发现、尚无文本的线程压过真正在出台词的线程
  /// （用户看到列表最前面一堆 `· 0`）。有台词优先让「该选哪条」一眼可见（对齐 Luna
  /// 「选择文本」把有内容的线程排在前面的行为）。纯函数、静态，供 [textThreads] 复用。
  ///
  /// v12：判据从「已发布行数」改成 [TexthookerTextThread.hasObservedLines]。取消自动选
  /// 线程后，用户选定之前所有线程的 `lineCount` 都是 0，旧判据会退化成「只按时间排」，
  /// 又把刚发现的空线程顶回最前——正是本函数当初要修的那个症状换个方式复发。
  static int _compareTextThreads(
    TexthookerTextThread a,
    TexthookerTextThread b,
  ) {
    if (a.hasObservedLines != b.hasObservedLines) {
      return a.hasObservedLines ? -1 : 1;
    }
    if (a.audioLineCount != b.audioLineCount) {
      return b.audioLineCount.compareTo(a.audioLineCount);
    }
    // 干净线程排在脏线程之前：伪影占比低者优先。脏线程仍然可见可选（对齐 Luna），
    // 只是不该挡在真台词前面。
    final bool aDirty = a.observedArtifactCount * 2 > a.observedLineCount &&
        a.observedLineCount > 0;
    final bool bDirty = b.observedArtifactCount * 2 > b.observedLineCount &&
        b.observedLineCount > 0;
    if (aDirty != bDirty) return aDirty ? 1 : -1;
    if (a.observedLineCount != b.observedLineCount) {
      return b.observedLineCount.compareTo(a.observedLineCount);
    }
    return b.latestAt.compareTo(a.latestAt);
  }

  /// native thread id → 该线程的预览快照（v12 线程预览区的全量快照，每次轮询整体替换）。
  final Map<int, TexthookerThreadPreview> _threadPreviews =
      <int, TexthookerThreadPreview>{};

  /// native thread id → 该线程最近若干句（新→旧）。
  ///
  /// BUG-1474：native 预览区**每线程恒一条**（快照语义，见 [applyTextThreadPreviews]），
  /// 所以「显示 2~3 句」只能由 Dart 侧跨轮询累积。这份历史与 [_threadPreviews] 的
  /// 生命周期一致（同建同清），但**不是**替换语义——它就是要留住上一轮那句。
  final Map<int, List<String>> _threadPreviewHistory = <int, List<String>>{};

  /// 用 native 的线程预览快照整体替换本地副本。
  ///
  /// 是**替换**不是合并：预览区本身就是全量快照（每线程恒一条），合并只会让已经消失的
  /// 线程永远留在列表里。会话结束由 [clearTextThreadPreviews] 清。
  void applyTextThreadPreviews(List<TexthookerThreadPreview> previews) {
    bool changed = previews.length != _threadPreviews.length;
    if (!changed) {
      for (final TexthookerThreadPreview preview in previews) {
        final TexthookerThreadPreview? existing =
            _threadPreviews[preview.nativeThreadId];
        if (existing == null ||
            existing.text != preview.text ||
            existing.observedLineCount != preview.observedLineCount ||
            existing.observedArtifactCount != preview.observedArtifactCount ||
            existing.isArtifact != preview.isArtifact) {
          changed = true;
          break;
        }
      }
    }
    if (!changed) return; // 无变化不通知，避免每次轮询都重建线程下拉
    // BUG-1474：先按新快照累积历史，再整体替换快照。顺序不能反——替换之后就再也
    // 分不出「这句是新的还是上一轮那句」了。
    for (final TexthookerThreadPreview preview in previews) {
      final String text = preview.text.trim();
      if (text.isEmpty) continue;
      final List<String> ring = _threadPreviewHistory.putIfAbsent(
        preview.nativeThreadId,
        () => <String>[],
      );
      // 同一句在多轮快照里会重复出现（逐字重绘引擎尤其）；只在**变了**的时候入环。
      if (ring.isNotEmpty && ring.first == text) continue;
      ring.insert(0, text);
      if (ring.length > kTexthookerPreviewHistory) {
        ring.removeRange(kTexthookerPreviewHistory, ring.length);
      }
    }
    // 本轮快照里已消失的线程，其历史也跟着走——否则死线程会一直挂在列表里带着旧句。
    final Set<int> live = <int>{
      for (final TexthookerThreadPreview p in previews) p.nativeThreadId,
    };
    _threadPreviewHistory.removeWhere((int id, _) => !live.contains(id));
    _threadPreviews
      ..clear()
      ..addEntries(
        previews.map(
          (TexthookerThreadPreview p) =>
              MapEntry<int, TexthookerThreadPreview>(p.nativeThreadId, p),
        ),
      );
    notifyListeners();
  }

  void clearTextThreadPreviews() {
    if (_threadPreviews.isEmpty && _threadPreviewHistory.isEmpty) return;
    _threadPreviews.clear();
    _threadPreviewHistory.clear();
    notifyListeners();
  }

  void registerTextThread({
    required String key,
    required String label,
    String? hookCode,
    int? nativeThreadId,
    DateTime? discoveredAt,
  }) {
    final String normalizedKey = key.trim();
    if (normalizedKey.isEmpty) return;
    final TexthookerTextThread? previous =
        _discoveredTextThreads[normalizedKey];
    final DateTime observedAt = discoveredAt ?? DateTime.now();
    _discoveredTextThreads[normalizedKey] = TexthookerTextThread(
      key: normalizedKey,
      label: label.trim().isEmpty
          ? previous?.label ?? normalizedKey
          : label.trim(),
      hookCode: hookCode ?? previous?.hookCode,
      nativeThreadId: nativeThreadId ?? previous?.nativeThreadId,
      lineCount: 0,
      latestAt: previous != null && previous.latestAt.isAfter(observedAt)
          ? previous.latestAt
          : observedAt,
      // 线程发现事件不携带内容，但**不得清掉已有预览**：ThreadCreate 会在同一条线程上
      // 重复触发，清掉等于每次重新发现都把用户刚看到的预览抹成空白。
      previewText: previous?.previewText,
      observedLineCount: previous?.observedLineCount ?? 0,
      observedArtifactCount: previous?.observedArtifactCount ?? 0,
      previewIsArtifact: previous?.previewIsArtifact ?? false,
    );
    notifyListeners();
  }

  /// [threadKey] 为 null 时返回所有行；否则只返回指定 Hook 线程的文本。
  List<TexthookerLineEntry> entriesForTextThread(String? threadKey) {
    if (threadKey == null) return entries;
    return List<TexthookerLineEntry>.unmodifiable(
      _entries.where((entry) => entry.textThreadKey == threadKey),
    );
  }

  TexthookerLineEntry? appendLine(
    String line, {
    TexthookerLineSource source = TexthookerLineSource.unknown,
    String? sourceLabel,
    int? sourceSequence,
    int? hookTimestampMs,
    String? textThreadKey,
    String? textThreadLabel,
    String? textHookCode,
    int? nativeTextThreadId,
    DateTime? receivedAt,
    TexthookerLineAudioStatus audioStatus =
        TexthookerLineAudioStatus.unavailable,
  }) {
    // 注音标记在这里、也只在这里剥。这是所有下游消费方（浮窗显示 / 点字查词 /
    // 制卡 sentence / 字数统计 / 跨线程折叠）拿到 `entry.text` 之前的唯一收口，
    // 剥在这里才能保证它们天然共用同一坐标系；放到显示层剥会让
    // `_onLookupText` 的 `entry.text != text` 守卫恒真，点字直接失效。
    final RubyMarkupText parsed = parseRubyMarkup(line).trimmed();
    final String trimmed = parsed.text;
    if (trimmed.isEmpty) return null;
    final DateTime now = receivedAt ?? DateTime.now();
    final TexthookerLineEntry entry = TexthookerLineEntry(
      id: '${now.microsecondsSinceEpoch}-${_nextId++}',
      text: trimmed,
      rubySpans: parsed.spans,
      source: source,
      sourceLabel: sourceLabel,
      sourceSequence: sourceSequence,
      hookTimestampMs: hookTimestampMs,
      textThreadKey: textThreadKey,
      textThreadLabel: textThreadLabel,
      textHookCode: textHookCode,
      nativeTextThreadId: nativeTextThreadId,
      receivedAt: now,
      audioStatus: audioStatus,
    );
    _entries.add(entry);
    if (_entries.length > maxLines) {
      _entries.removeRange(0, _entries.length - maxLines);
    }
    notifyListeners();
    return entry;
  }

  bool updateLineAudio(
    String id, {
    required TexthookerLineAudioStatus status,
    String? backend,
    String? resourceId,
    int? durationMs,
    String? fallbackReason,
    bool clearResourceId = false,
  }) {
    final int index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    _entries[index] = _entries[index].copyWith(
      audioStatus: status,
      audioBackend: backend,
      audioResourceId: resourceId,
      audioDurationMs: durationMs,
      fallbackReason: fallbackReason,
      clearAudioResourceId: clearResourceId,
      clearFallbackReason: fallbackReason == null,
    );
    notifyListeners();
    return true;
  }

  /// 把 [id] 行标记为已制卡（幂等：已是 mined 直接返回 false 不重复通知）。
  /// 制卡成功后由挖矿编排回写，供列表显示「已制卡」徽章。
  bool markLineMined(String id) {
    final int index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || _entries[index].mined) return false;
    _entries[index] = _entries[index].copyWith(mined: true);
    notifyListeners();
    return true;
  }

  /// 设置 [id] 行的收藏态（会话内存态，不落 DB）。状态无变化时不通知。
  bool setLineFavorite(String id, bool favorited) {
    final int index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || _entries[index].favorited == favorited) return false;
    _entries[index] = _entries[index].copyWith(favorited: favorited);
    notifyListeners();
    return true;
  }

  /// 翻转 [id] 行的收藏态，返回翻转后的新状态（行不存在返回 false）。
  bool toggleLineFavorite(String id) {
    final int index = _entries.indexWhere((entry) => entry.id == id);
    if (index < 0) return false;
    final bool next = !_entries[index].favorited;
    _entries[index] = _entries[index].copyWith(favorited: next);
    notifyListeners();
    return next;
  }

  void clear() {
    if (_entries.isEmpty &&
        _discoveredTextThreads.isEmpty &&
        _threadPreviews.isEmpty) {
      return;
    }
    _entries.clear();
    _discoveredTextThreads.clear();
    // 预览必须一并清：它是**会话级**快照，thread id 含 processId，跨会话残留会让上一局
    // 的预览挂在这一局的空线程上，用户照着选到一条死线程。
    _threadPreviews.clear();
    notifyListeners();
  }
}

/// 实时台词筛选的唯一 predicate：枚举驱动、无特殊分支。页面/服务共用，
/// 保证「有音频 / 已制卡 / 已收藏」的判据单一真相源。
bool lineMatchesFilter(
        TexthookerLineEntry entry, TexthookerLineFilter filter) =>
    switch (filter) {
      TexthookerLineFilter.all => true,
      TexthookerLineFilter.withAudio => entry.hasAudio,
      TexthookerLineFilter.mined => entry.mined,
      TexthookerLineFilter.favorited => entry.favorited,
    };

/// 「全部文本线程」的展示投影：折叠同一渲染瞬间被不同 Luna 线程各回传一次的同文行。
///
/// 原始 buffer 不删，线程选择、逐行音频和稳定 id 仍消费完整数据；这里只处理 UI 投影。
/// 仅当来源都是 engine hook、线程不同、文本相同，且 hook/接收时间都紧邻时才视为并行
/// 双写。同线程稍后重说同一句、外部来源重复、缺时间戳的行一律保留。
List<TexthookerLineEntry> collapseParallelTextThreadDuplicates(
  Iterable<TexthookerLineEntry> entries, {
  Duration hookWindow = const Duration(milliseconds: 100),
  Duration receiveWindow = const Duration(milliseconds: 500),
}) {
  final List<TexthookerLineEntry> result = <TexthookerLineEntry>[];
  for (final TexthookerLineEntry entry in entries) {
    if (result.isEmpty) {
      result.add(entry);
      continue;
    }
    final TexthookerLineEntry previous = result.last;
    final int? previousHookAt = previous.hookTimestampMs;
    final int? currentHookAt = entry.hookTimestampMs;
    final String? previousThread = previous.textThreadKey;
    final String? currentThread = entry.textThreadKey;
    final bool parallelDuplicate = previous.source ==
            TexthookerLineSource.engineHook &&
        entry.source == TexthookerLineSource.engineHook &&
        previousThread != null &&
        currentThread != null &&
        previousThread != currentThread &&
        previous.text == entry.text &&
        previousHookAt != null &&
        currentHookAt != null &&
        (currentHookAt - previousHookAt).abs() <= hookWindow.inMilliseconds &&
        entry.receivedAt.difference(previous.receivedAt).abs() <= receiveWindow;
    if (!parallelDuplicate) {
      result.add(entry);
      continue;
    }
    // 两份里若只有一份已经配到音频，展示那份，避免折叠后把播放/制卡能力藏掉。
    if (!previous.hasAudio && entry.hasAudio) {
      result[result.length - 1] = entry;
    }
  }
  return List<TexthookerLineEntry>.unmodifiable(result);
}
