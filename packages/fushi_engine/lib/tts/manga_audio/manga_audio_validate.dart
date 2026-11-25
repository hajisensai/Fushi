/// 演出稿的本地校验与台词文本解析（纯函数，对着一页的 OCR 块）。
///
/// 设计 §1 / §4：AI 只能引用给定的块下标；落地前校验「下标在范围内、同一块至多归
/// 一句、说话人在角色表内或旁白 / 不明、类型与情绪在词表内」，数值夹到范围。不合格的
/// 行丢弃（不抛异常），连同原因返回；没被任何保留行认领的块按「不读」处理，单独列出
/// 供复核界面展示。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:fushi_engine/media/manga/manga_ruby.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';

/// 一行被丢弃的原因。
enum MangaLineRejection {
  /// 不是对象，或缺 `b` / `s` / `k`、类型不对。
  malformed,

  /// 带了 `p` 但不是正在校验的这一页。
  wrongPage,

  /// 块下标列表为空。
  noBlocks,

  /// 块下标超出该页范围。
  blockOutOfRange,

  /// 同一句里重复引用了同一个块。
  blockRepeated,

  /// 块已被本页前面某一句认领（每块至多归一句）。
  blockAlreadyClaimed,

  /// 说话人不在角色表内，也不是旁白 / 不明。
  unknownSpeaker,

  /// 类型不在词表内。
  unknownKind,

  /// 情绪不在词表内。
  unknownEmotion,
}

/// 被丢弃的一行：原始输出里的下标、原样数据、原因与可读细节。
class MangaRejectedLine {
  const MangaRejectedLine({
    required this.index,
    required this.raw,
    required this.reason,
    this.detail,
  });

  final int index;
  final Object? raw;
  final MangaLineRejection reason;
  final String? detail;

  @override
  String toString() =>
      'MangaRejectedLine(#$index ${reason.name}${detail == null ? '' : ': $detail'})';
}

/// 一页的校验结果。
class MangaPageValidation {
  const MangaPageValidation({
    required this.accepted,
    required this.rejected,
    required this.unclaimedBlocks,
  });

  /// 保留下来的行（顺序 = 输入顺序，来源一律 AI）。
  final List<MangaScriptLine> accepted;

  final List<MangaRejectedLine> rejected;

  /// 没有被任何保留行认领的块下标（升序），按「不读」处理。
  final List<int> unclaimedBlocks;
}

/// 校验 AI 对第 [page] 页给出的行（已 JSON 解码，字段同 `MangaScriptLine.toJson`：
/// `b` 块下标、`s` 说话人、`k` 类型，可选 `p` / `beat` / `e` / `ei` / `rate` / `pitch` /
/// `vol` / `seed` / `fix` / `c`）。[blockCount] 是该页 OCR 块数，[roster] 是角色表里的
/// 规范名。先到先得：同一块被两句引用时保留前一句。
MangaPageValidation validateMangaPageLines({
  required int page,
  required int blockCount,
  required List<Object?> rawLines,
  required Iterable<String> roster,
}) {
  final Set<String> speakers = <String>{...roster, kTtsNarrator, kTtsUnknown};
  final List<MangaScriptLine> accepted = <MangaScriptLine>[];
  final List<MangaRejectedLine> rejected = <MangaRejectedLine>[];
  final Set<int> claimed = <int>{};

  for (int i = 0; i < rawLines.length; i++) {
    final Object? raw = rawLines[i];
    void reject(MangaLineRejection reason, [String? detail]) => rejected.add(
      MangaRejectedLine(index: i, raw: raw, reason: reason, detail: detail),
    );

    if (raw is! Map) {
      reject(MangaLineRejection.malformed, 'not an object');
      continue;
    }
    final Object? rawPage = raw['p'];
    final Object? rawBlocks = raw['b'];
    final Object? speaker = raw['s'];
    final Object? rawKind = raw['k'];
    if (rawBlocks is! List || speaker is! String || rawKind is! String) {
      reject(MangaLineRejection.malformed, 'missing b / s / k');
      continue;
    }
    if (rawPage != null && rawPage != page) {
      reject(MangaLineRejection.wrongPage, 'p=$rawPage');
      continue;
    }
    final CastLineKind? kind = CastLineKind.parse(rawKind);
    if (kind == null) {
      reject(MangaLineRejection.unknownKind, rawKind);
      continue;
    }
    if (rawBlocks.isEmpty) {
      reject(MangaLineRejection.noBlocks);
      continue;
    }
    final List<int> blocks = <int>[];
    MangaLineRejection? blockError;
    String? blockDetail;
    for (final Object? b in rawBlocks) {
      if (b is! int || b < 0 || b >= blockCount) {
        blockError = MangaLineRejection.blockOutOfRange;
        blockDetail = '$b (page has $blockCount)';
        break;
      }
      if (blocks.contains(b)) {
        blockError = MangaLineRejection.blockRepeated;
        blockDetail = '$b';
        break;
      }
      blocks.add(b);
    }
    if (blockError != null) {
      reject(blockError, blockDetail);
      continue;
    }
    if (!speakers.contains(speaker)) {
      reject(MangaLineRejection.unknownSpeaker, speaker);
      continue;
    }
    final Object? rawEmotion = raw['e'];
    final CastEmotion? emotion = CastEmotion.parse(rawEmotion);
    if (rawEmotion != null && emotion == null) {
      reject(MangaLineRejection.unknownEmotion, '$rawEmotion');
      continue;
    }
    final int? taken = blocks.cast<int?>().firstWhere(
      (int? b) => claimed.contains(b),
      orElse: () => null,
    );
    if (taken != null) {
      reject(MangaLineRejection.blockAlreadyClaimed, '$taken');
      continue;
    }
    claimed.addAll(blocks);
    accepted.add(
      mangaLineFromFields(
        raw,
        page: page,
        blocks: blocks,
        speaker: speaker,
        kind: kind,
        emotion: emotion,
        source: TtsCastSource.llm,
      ),
    );
  }

  return MangaPageValidation(
    accepted: accepted,
    rejected: rejected,
    unclaimedBlocks: <int>[
      for (int b = 0; b < blockCount; b++)
        if (!claimed.contains(b)) b,
    ],
  );
}

/// 末尾是这些字符时，与下一块直接相连；否则补一个「、」。
final RegExp _terminal = RegExp(r'[。、！？!?…～ー」』]$');

/// 把一句的各块文字按顺序拼成一句：前一段不以句读结尾时在块之间加「、」。
/// 每段先去掉首尾空白，空段跳过。
String joinMangaBlockTexts(Iterable<String> parts) {
  final StringBuffer out = StringBuffer();
  for (final String raw in parts) {
    final String part = raw.trim();
    if (part.isEmpty) continue;
    final String sofar = out.toString();
    if (sofar.isNotEmpty && !_terminal.hasMatch(sofar)) out.write('、');
    out.write(part);
  }
  return out.toString();
}

/// 一句的台词文本（显示 / 制卡用），即 [resolveMangaLineTexts] 的 `text`。
String resolveMangaLineText(
  MangaScriptLine line,
  List<MokuroBlock> pageBlocks,
) => resolveMangaLineTexts(line, pageBlocks).text;

/// 一句的台词文本与合成用文本。手动填写了 [MangaScriptLine.say] 两者都用它；否则按
/// [MangaScriptLine.blocks] 顺序取该页 OCR 块的文字（块内各行直接相连），有文本修正时
/// 用修正值，再按 [joinMangaBlockTexts] 拼接。越界的块下标跳过（校验过的行不会出现）。
///
/// 页面印着的注音（`manga_ruby.dart`）：底本块也在这句里时，注音块不进文本，合成用
/// 文本里底本换成注音读音（「CRYCHIC」念「クライシック」）；有文本修正的底本不换（修正
/// 后字位对不上）。只有注音、没有底本的行照常念注音块本身。
({String text, String spoken}) resolveMangaLineTexts(
  MangaScriptLine line,
  List<MokuroBlock> pageBlocks,
) {
  final String? say = line.say;
  if (say != null) return (text: say, spoken: say);
  final MangaPageRuby ruby = detectMangaPageRuby(pageBlocks);
  final Set<int> inLine = line.blocks.toSet();
  final List<String> text = <String>[];
  final List<String> spoken = <String>[];
  for (final int b in line.blocks) {
    if (line.textFixes[b] case final String fix) {
      text.add(fix);
      spoken.add(fix);
      continue;
    }
    if (b < 0 || b >= pageBlocks.length) continue;
    if (ruby.baseOfRuby[b] case final int base when inLine.contains(base)) {
      continue;
    }
    final List<String> lines = pageBlocks[b].lines;
    text.add(lines.join());
    spoken.add(ruby.spokenLinesOf(b, lines).join());
  }
  return (text: joinMangaBlockTexts(text), spoken: joinMangaBlockTexts(spoken));
}

/// 演出稿记录的 OCR 签名：OCR 结果自带引擎签名（`MangaOcrMetadata.engineSignature`）
/// 就用它；没有（mokuro 导入的卷）就按 OCR 内容算——每页的块数、块框坐标（取整到像素）
/// 与文字的 sha1，加 `content:` 前缀。块下标只在 OCR 内容不变时才稳定，所以内容签名
/// 一变（外部重跑 mokuro、换了文件）演出稿就判为需重新标注；从不因为「两边都没有引擎
/// 签名」而当成没变。
/// 一卷 `manga.json` 的 OCR 签名（[mangaOcrSignature] 的便捷入口）：标注记录、生成
/// 核对、播放 / 导入核对都用它，mokuro 导入的卷没有引擎签名也能比。
String mangaPayloadOcrSignature(MokuroPayload payload) => mangaOcrSignature(
  engineSignature: payload.ocr?.engineSignature,
  pages: <List<MokuroBlock>>[
    for (final MokuroImage image in payload.images) image.blocks,
  ],
);

String mangaOcrSignature({
  required String? engineSignature,
  required List<List<MokuroBlock>> pages,
}) {
  if (engineSignature != null && engineSignature.isNotEmpty) {
    return engineSignature;
  }
  final StringBuffer canon = StringBuffer();
  for (int p = 0; p < pages.length; p++) {
    canon.write('#$p:${pages[p].length}\n');
    for (final MokuroBlock b in pages[p]) {
      final MokuroRect r = b.rectangle;
      canon
        ..write(r.left.round())
        ..write(',')
        ..write(r.top.round())
        ..write(',')
        ..write(r.right.round())
        ..write(',')
        ..write(r.bottom.round())
        ..write('|')
        ..write(b.lines.join('\u0001'))
        ..write('\n');
    }
  }
  return 'content:${sha1.convert(utf8.encode(canon.toString()))}';
}
