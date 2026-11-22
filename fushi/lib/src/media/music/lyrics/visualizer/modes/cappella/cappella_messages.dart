/// 群唱的纯逻辑（可单测）：把运行时的歌词行补上间奏行、编排成确定性的聊天消息流
/// （发送者 / 左右侧 / 表情回复），逐字出现时间表，以及每个时刻的可见 / 当前消息。
///
/// 对应 folia `cappellaMessages.ts`、`cappellaMessageSenders.ts`、`cappellaReveal.ts`、
/// `cappellaMessageLayout.ts`（时间判定部分）与 `parserCore.attachInterludes`、
/// `renderHints.buildLineRenderEndTime`。时间一律是歌词显示时间（毫秒）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_config.dart';

// ---------------------------------------------------------------------------
// 行
// ---------------------------------------------------------------------------

/// 一个显示字符（字形）的时间。
class CappellaChar {
  const CappellaChar({
    required this.text,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final int startMs;
  final int endMs;
}

/// 群唱里的一行：歌词行或补出来的间奏行（`......`）。
class CappellaLine {
  const CappellaLine({
    required this.index,
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.chars,
    required this.renderEndMs,
    this.agent,
    this.source,
  });

  /// 在群唱行表里的下标（含间奏行）。
  final int index;
  final String text;
  final int startMs;
  final int endMs;
  final List<CappellaChar> chars;

  /// 最晚可在屏上保留「当前」状态到何时（folia `renderHints.renderEndTime`）。
  final int renderEndMs;

  /// 演唱者下标（`timeline.agents`）。
  final int? agent;

  /// 对应的运行时行；间奏行为 null。
  final LyricVisualizerLine? source;

  bool get isInterlude => source == null;
  int get durationMs => endMs - startMs;
}

/// folia `buildLineRenderEndTime`（时间换成毫秒）。
int cappellaRenderEndMs({
  required int startMs,
  required int endMs,
  required int lastWordEndMs,
}) {
  final double raw = math.max(endMs - startMs, 0) / 1000;
  final double start = startMs / 1000;
  final double end = endMs / 1000;
  final double lastWordEnd = lastWordEndMs / 1000;
  double result;
  if (raw < 0.10) {
    // micro：不做过渡。
    result = math.max(end, start + 0.067);
  } else if (raw < 0.18) {
    // short：快速过渡。
    final double enter = (raw * 0.45).clamp(0.045, 0.06);
    final double exit = (raw * 0.22).clamp(0.03, 0.04);
    const double hold = 0.03;
    final double passStart = math.max(lastWordEnd, start) + hold;
    final double exitStart = math.max(
      math.max(start + enter + 0.01, passStart),
      end - exit,
    );
    result = math.max(end, exitStart + exit);
  } else {
    final double base = math.max(raw, 0.12);
    final double exit = math.min(0.32, math.max(0.18, base * 0.18));
    const double hold = 0.06;
    final double passStart = math.max(lastWordEnd, start) + hold;
    final double exitStart = math.max(passStart, end - exit);
    result = math.max(end, exitStart + exit);
  }
  return (result * 1000).round();
}

/// 时长类别是否 normal（≥ 180ms；folia `timingClass === 'normal'`）。
bool cappellaIsNormalTiming(CappellaLine line) => line.durationMs >= 180;

CappellaLine _interlude(int index, int startMs, int endMs) {
  // folia 把间奏拆成 6 个等长「词」，每个点一个。
  final int d = endMs - startMs;
  final List<CappellaChar> chars = <CappellaChar>[
    for (int i = 0; i < 6; i++)
      CappellaChar(
        text: '.',
        startMs: startMs + (d * i / 6).round(),
        endMs: startMs + (d * (i + 1) / 6).round(),
      ),
  ];
  return CappellaLine(
    index: index,
    text: kCappellaInterludeText,
    startMs: startMs,
    endMs: endMs,
    chars: chars,
    renderEndMs: cappellaRenderEndMs(
      startMs: startMs,
      endMs: endMs,
      lastWordEndMs: endMs,
    ),
  );
}

CappellaLine _lyric(int index, LyricVisualizerLine l) {
  // 去掉首尾空白字形，让字符和 [LyricVisualizerLine.text]（已 trim）对齐。
  final List<LyricVisualizerGlyph> g = l.glyphs;
  int a = 0;
  int b = g.length;
  while (a < b && g[a].isSpace) {
    a++;
  }
  while (b > a && g[b - 1].isSpace) {
    b--;
  }
  final List<CappellaChar> chars = <CappellaChar>[
    for (int i = a; i < b; i++)
      CappellaChar(text: g[i].text, startMs: g[i].startMs, endMs: g[i].endMs),
  ];
  final String text = chars.isEmpty
      ? l.text
      : chars.map((CappellaChar c) => c.text).join();
  final int lastWordEnd = l.words.isEmpty ? l.endMs : l.words.last.endMs;
  return CappellaLine(
    index: index,
    text: text,
    startMs: l.startMs,
    endMs: l.endMs,
    chars: chars,
    renderEndMs: cappellaRenderEndMs(
      startMs: l.startMs,
      endMs: l.endMs,
      lastWordEndMs: lastWordEnd,
    ),
    agent: l.agent,
    source: l,
  );
}

/// 运行时行 → 群唱行，长空档补间奏行（folia `attachInterludes`：首句前超过 3s、
/// 句间超过 3s）。
List<CappellaLine> buildCappellaLines(List<LyricVisualizerLine> lines) {
  final List<CappellaLine> out = <CappellaLine>[];
  if (lines.isEmpty) return out;
  if (lines.first.startMs > kCappellaInterludeGapMs) {
    out.add(_interlude(out.length, 500, lines.first.startMs - 500));
  }
  for (int i = 0; i < lines.length; i++) {
    final LyricVisualizerLine cur = lines[i];
    out.add(_lyric(out.length, cur));
    if (i + 1 < lines.length) {
      final LyricVisualizerLine next = lines[i + 1];
      if (next.startMs - cur.endMs > kCappellaInterludeGapMs) {
        out.add(_interlude(out.length, cur.endMs + 50, next.startMs - 50));
      }
    }
  }
  return out;
}

/// 起点已到的最后一行（folia `getVisibleLineIndexAtTime`），一句都没到为 -1。
int cappellaVisibleLineIndexAt(List<CappellaLine> lines, int timeMs) {
  int lo = 0;
  int hi = lines.length - 1;
  int found = -1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    if (lines[mid].startMs <= timeMs) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

/// 当前行（folia `findLatestActiveLineIndex`：从后往前，第一条「已开始且没过 renderEnd」的行）。
int cappellaActiveLineIndexAt(List<CappellaLine> lines, int timeMs) {
  for (int i = cappellaVisibleLineIndexAt(lines, timeMs); i >= 0; i--) {
    if (timeMs <= lines[i].renderEndMs) return i;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// 消息
// ---------------------------------------------------------------------------

enum CappellaMessageKind { title, lyric, emo }

/// 一位发送者：左右侧 + 头像下标。
class CappellaSender {
  const CappellaSender({required this.right, required this.avatarIndex});

  final bool right;
  final int avatarIndex;

  @override
  bool operator ==(Object other) =>
      other is CappellaSender &&
      other.right == right &&
      other.avatarIndex == avatarIndex;

  @override
  int get hashCode => Object.hash(right, avatarIndex);
}

/// 一条聊天消息。
class CappellaMessage {
  const CappellaMessage({
    required this.id,
    required this.kind,
    required this.sender,
    this.text = '',
    this.line,
    this.stickerIndex = 0,
    this.activationStartMs = 0,
    this.activationEndMs = 0,
  });

  final String id;
  final CappellaMessageKind kind;
  final CappellaSender sender;

  /// 标题消息的文字。
  final String text;

  /// 歌词 / 表情消息挂的行。
  final CappellaLine? line;

  /// 表情图案下标（程序绘制的贴纸，见 `cappella_avatar.dart`）。
  final int stickerIndex;
  final int activationStartMs;
  final int activationEndMs;

  bool get right => sender.right;
  bool get isTimed => kind != CappellaMessageKind.title;

  /// 气泡里显示的文字（表情为空）。
  String get displayText => switch (kind) {
    CappellaMessageKind.title => text,
    CappellaMessageKind.lyric => line!.text,
    CappellaMessageKind.emo => '',
  };
}

/// 字符串 → [0, 1]（folia `seededUnit`：FNV-1a / 0xffffffff）。
double cappellaSeededUnit(List<Object> parts) =>
    lyricVisualizerSeedOf(parts.join('|')) / 0xFFFFFFFF;

int _pickSticker(int poolSize, List<Object> parts) =>
    (cappellaSeededUnit(parts) * poolSize).floor() % poolSize;

/// TTML 演唱者 → 发送者（folia `createCappellaAgentSenderResolver`）：少于两位演唱者返回
/// null；第一位出现的演唱者在右侧，其余在左侧轮流取头像。
Map<int, CappellaSender>? cappellaAgentSenders(List<CappellaLine> lines) {
  final List<int> ids = <int>[];
  for (final CappellaLine l in lines) {
    final int? a = l.agent;
    if (a != null && !ids.contains(a)) ids.add(a);
  }
  if (ids.length < 2) return null;
  final int leftCount = kCappellaLeftAvatarIndices.length;
  return <int, CappellaSender>{
    for (int i = 0; i < ids.length; i++)
      ids[i]: i == 0
          ? const CappellaSender(
              right: true,
              avatarIndex: kCappellaRightAvatarIndex,
            )
          : CappellaSender(right: false, avatarIndex: (i - 1) % leftCount),
  };
}

int _compactChars(String text) =>
    text.replaceAll(RegExp(r'\s'), '').runes.length;

/// 编排消息流（folia `buildCappellaMessages`）：同一首歌每次结果一样。
List<CappellaMessage> buildCappellaMessages({
  required List<CappellaLine> lines,
  required String titleText,
  required CappellaSequencing sequencing,
  required bool showEmo,
  required int stickerPoolSize,
}) {
  const CappellaSender rightSender = CappellaSender(
    right: true,
    avatarIndex: kCappellaRightAvatarIndex,
  );
  final List<CappellaMessage> messages = <CappellaMessage>[
    CappellaMessage(
      id: 'title',
      kind: CappellaMessageKind.title,
      text: titleText,
      sender: const CappellaSender(
        right: true,
        avatarIndex: kCappellaAvatarGridSize * kCappellaAvatarGridSize - 1,
      ),
    ),
  ];
  final bool emoOn = showEmo && stickerPoolSize > 0;
  if (lines.isEmpty) {
    if (emoOn) {
      messages.add(
        CappellaMessage(
          id: 'emo-no-lyrics',
          kind: CappellaMessageKind.emo,
          sender: rightSender,
          line: const CappellaLine(
            index: 0,
            text: kCappellaInterludeText,
            startMs: 0,
            endMs: 0,
            chars: <CappellaChar>[],
            renderEndMs: 0,
          ),
          stickerIndex: _pickSticker(stickerPoolSize, <Object>[
            'no-lyrics',
            titleText,
            sequencing.forceRightEveryLines,
          ]),
          activationEndMs: 999999000,
        ),
      );
    }
    return messages;
  }

  int sideCursor = 0;
  int nextLeftAvatar = 0;
  CappellaSender? lastSender;
  int sinceRandomEmo = 1 << 30;
  int randomEmoCount = 0;
  final int randomEmoCap = (lines.length * sequencing.maxRandomEmoRatio)
      .floor();
  final Map<int, CappellaSender>? agents = cappellaAgentSenders(lines);

  for (int i = 0; i < lines.length; i++) {
    final CappellaLine line = lines[i];
    final CappellaLine? next = i + 1 < lines.length ? lines[i + 1] : null;
    final bool isShort =
        _compactChars(line.text) <= kCappellaShortLineCharLimit;
    final CappellaSender? agentSender = line.agent == null
        ? null
        : agents?[line.agent];
    final bool forceRight =
        agentSender == null && (i + 1) % sequencing.forceRightEveryLines == 0;
    final bool carry =
        agentSender == null &&
        isShort &&
        lastSender != null &&
        cappellaSeededUnit(<Object>['carry', line.startMs, i]) <=
            sequencing.shortLineCarryChance;
    final bool baseRight =
        sequencing.sideSequence[sideCursor % sequencing.sideSequence.length];
    final bool flip =
        !forceRight &&
        cappellaSeededUnit(<Object>['flip', line.startMs, i]) <
            sequencing.sideFlipChance;
    final bool resolvedRight = flip ? !baseRight : baseRight;
    final CappellaSender sender;
    if (agentSender != null) {
      sender = agentSender;
    } else if (forceRight) {
      sender = rightSender;
    } else if (carry) {
      sender = lastSender;
    } else {
      sender = CappellaSender(
        right: resolvedRight,
        avatarIndex: resolvedRight ? kCappellaRightAvatarIndex : nextLeftAvatar,
      );
    }

    final int effectiveEnd = math.min(
      line.renderEndMs,
      next?.startMs ?? line.renderEndMs,
    );
    if (line.isInterlude && emoOn) {
      messages.add(
        CappellaMessage(
          id: 'emo-${line.startMs}-$i',
          kind: CappellaMessageKind.emo,
          sender: sender,
          line: line,
          stickerIndex: _pickSticker(stickerPoolSize, <Object>[
            'interlude',
            line.startMs,
            i,
          ]),
          activationStartMs: line.startMs,
          activationEndMs: math.max(line.startMs + 120, effectiveEnd),
        ),
      );
    } else {
      messages.add(
        CappellaMessage(
          id: 'line-${line.startMs}-$i',
          kind: CappellaMessageKind.lyric,
          sender: sender,
          line: line,
        ),
      );
    }
    sinceRandomEmo++;

    final bool canAppendEmo =
        !line.isInterlude &&
        emoOn &&
        sequencing.randomEmoChance > 0 &&
        randomEmoCount < randomEmoCap &&
        sinceRandomEmo >= sequencing.minLinesBetweenRandomEmos &&
        cappellaIsNormalTiming(line);
    if (canAppendEmo) {
      final double score = cappellaSeededUnit(<Object>[
        'random-emo',
        line.startMs,
        line.endMs,
        i,
        sequencing.randomEmoChance,
      ]);
      if (score < sequencing.randomEmoChance) {
        messages.add(
          CappellaMessage(
            id: 'emo-reaction-${line.startMs}-$i',
            kind: CappellaMessageKind.emo,
            sender: sender,
            line: line,
            stickerIndex: _pickSticker(stickerPoolSize, <Object>[
              'reaction',
              line.startMs,
              line.endMs,
              i,
              sender.right ? 'right' : 'left',
            ]),
            activationStartMs: line.endMs,
            activationEndMs: math.max(line.endMs + 80, effectiveEnd),
          ),
        );
        randomEmoCount++;
        sinceRandomEmo = 0;
      }
    }

    if (agentSender != null) {
      lastSender = sender;
    } else if (forceRight) {
      sideCursor = 0;
      lastSender = null;
    } else if (!carry) {
      if (!sender.right) nextLeftAvatar++;
      sideCursor++;
      lastSender = sender;
    } else {
      lastSender = sender;
    }
  }
  return messages;
}

/// 消息此刻的状态（folia `getTimedMessageState`）。
enum CappellaMessageState { idle, active, passed }

CappellaMessageState cappellaMessageState(
  CappellaMessage m,
  int timeMs,
  int activeLineIndex,
) {
  switch (m.kind) {
    case CappellaMessageKind.title:
      return CappellaMessageState.idle;
    case CappellaMessageKind.emo:
      if (timeMs >= m.activationEndMs) return CappellaMessageState.passed;
      if (timeMs >= m.activationStartMs) return CappellaMessageState.active;
      return CappellaMessageState.idle;
    case CappellaMessageKind.lyric:
      final int li = m.line!.index;
      if (li == activeLineIndex) return CappellaMessageState.active;
      if (li < activeLineIndex) return CappellaMessageState.passed;
      return CappellaMessageState.idle;
  }
}

/// 此刻已发出的消息（未按高度裁剪；folia `getVisibleMessages` 的筛选部分）。
List<CappellaMessage> cappellaSentMessages(
  List<CappellaMessage> messages,
  int timeMs,
  int visibleLineIndex,
) => <CappellaMessage>[
  for (final CappellaMessage m in messages)
    if (switch (m.kind) {
      CappellaMessageKind.title => true,
      CappellaMessageKind.emo => timeMs >= m.activationStartMs,
      CappellaMessageKind.lyric => m.line!.index <= visibleLineIndex,
    })
      m,
];

/// 从最新一条往前累加估算高度，放不下就停（至少留 2 条，最多
/// [kCappellaMaxVisibleMessages] 条）。[heightOf] 给出一条消息估算占的高度（含行间距）。
List<CappellaMessage> cappellaFitMessages(
  List<CappellaMessage> sent,
  double viewportHeight,
  double Function(CappellaMessage m) heightOf,
) {
  final double usable = math.max(200, viewportHeight - kCappellaReservedHeight);
  double acc = 0;
  final List<CappellaMessage> out = <CappellaMessage>[];
  for (int i = sent.length - 1; i >= 0; i--) {
    final double h = heightOf(sent[i]);
    if (acc + h > usable && out.length >= 2) break;
    acc += h;
    out.insert(0, sent[i]);
    if (out.length >= kCappellaMaxVisibleMessages) break;
  }
  return out;
}

// ---------------------------------------------------------------------------
// 逐字出现
// ---------------------------------------------------------------------------

/// 一行的逐字时间表（folia `PreparedBubbleMetrics` 的时间部分）。
class CappellaRevealPlan {
  const CappellaRevealPlan({
    required this.characters,
    required this.revealMs,
    required this.fadeMs,
    required this.bubbleTargetMs,
    required this.timestampReadyMs,
  });

  final List<String> characters;

  /// 每个字开始出现的时刻（单调不减）。
  final List<int> revealMs;

  /// 每个字的淡入时长。
  final List<int> fadeMs;

  /// 气泡尺寸用的提前时间轴（[revealMs] 整体提前 [kCappellaWidthLookaheadMs]）。
  final List<int> bubbleTargetMs;

  /// 最后一个字淡入完成的时刻：时间戳此时出现。
  final int timestampReadyMs;
}

/// folia `buildCharacterRevealTimes` + `buildCharacterFadeDurationsMs` +
/// `getTimestampReadyTimeFromMetrics`：字的出现时刻取字形起点，淡入时长取字形时长（≥40ms）。
CappellaRevealPlan cappellaRevealPlan(CappellaLine line) {
  final List<String> chars = <String>[];
  final List<int> reveal = <int>[];
  final List<int> fade = <int>[];
  int last = line.startMs;
  for (final CappellaChar c in line.chars) {
    // 保证单调（二分查找依赖它）。
    final int r = math.max(last, c.startMs);
    last = r;
    chars.add(c.text);
    reveal.add(r);
    fade.add(math.max(c.endMs - c.startMs, kCappellaMinCharFadeMs));
  }
  int ready = line.startMs;
  if (reveal.isEmpty) {
    ready = line.endMs;
  } else {
    for (int i = 0; i < reveal.length; i++) {
      ready = math.max(ready, reveal[i] + fade[i]);
    }
  }
  return CappellaRevealPlan(
    characters: chars,
    revealMs: reveal,
    fadeMs: fade,
    bubbleTargetMs: <int>[
      for (final int r in reveal) r - kCappellaWidthLookaheadMs,
    ],
    timestampReadyMs: ready,
  );
}

/// 此刻已出现几个字（folia `getCharacterCountAtTime`：二分，`times[i] <= t` 的个数）。
int cappellaCharCountAt(List<int> times, int timeMs) {
  int lo = 0;
  int hi = times.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (times[mid] <= timeMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// 时间戳文字（folia `formatTimestamp`，m:ss）。
String cappellaFormatTimestamp(int ms) {
  if (ms < 0) return '0:00';
  final int total = ms ~/ 1000;
  final int m = total ~/ 60;
  final int s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
