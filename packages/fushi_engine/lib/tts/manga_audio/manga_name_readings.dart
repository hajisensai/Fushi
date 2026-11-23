/// 漫画有声的「查人名读法」（拍板 TW9ete_FHX 第三期）：给系列用词替换表里待复核的
/// 人名条目找**有出处**的读法，结果只作建议（[CastNameEvidence]），用户采用后才生效。
///
/// 两步，前一步找到的名字不进后一步：
/// 1. **页面注音**（[collectMangaNameRubyEvidence]，纯本地、不联网）：在系列各卷页面上
///    找 OCR 判出的注音块（`manga_ruby.dart`）恰好注在这个写法上的地方，记卷名与页码。
/// 2. **AI 看页图**（[MangaNameReadingFinder]）：剩下的名字取它在当前卷首次出现的页图
///    （自我介绍、名牌多在这里），加上可选的联网搜索结果摘要，让模型只抄页面印着的注音
///    （回页码）或搜索结果里写明的读法（回结果 URL）。页码必须是发过去的页、URL 必须是
///    发过去的结果，否则整条丢弃——模型凭汉字或记忆猜的读法进不来；同一名字出处读法
///    冲突时 [CastTextSubstitution.suggestedReading] 不给建议，留待复核。
///
/// 读法只进合成文本，不流到任何显示层（功能黑名单「自动注音」）：这里只抄来源写明的
/// 读法，不推断。调用、页图读取、联网搜索都由应用层注入。
library;

import 'dart:convert';

import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_reply_json.dart';
import 'package:fushi_engine/ai/web_search.dart';
import 'package:fushi_engine/media/manga/manga_ruby.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_annotate_runner.dart'
    show MangaAnnotateAsk, MangaAnnotateImageLoader;

/// 一个名字在当前卷最多带几页页图（首次出现起）。
const int kMangaNameReadingPagesPerName = 2;

/// 一次请求最多带几张页图。
const int kMangaNameReadingMaxImages = 6;

/// 一次最多联网查几个名字、每个名字取几条结果。
const int kMangaNameReadingMaxSearchNames = 8;
const int kMangaNameReadingHitsPerName = 4;

/// 一卷：卷名（出处里显示）与各页的 OCR 块。
typedef MangaNameReadingVolume = ({
  String label,
  List<List<MokuroBlock>> pages,
});

/// 一条要查的名字：写法与所属角色（系列角色表规范名，可空）。
typedef MangaNameToRead = ({String written, String? character});

/// 待复核（读法留空）的人名条目，按表顺序、写法去重。
List<MangaNameToRead> pendingMangaNamesToRead(
  List<CastTextSubstitution> table,
) {
  final Set<String> seen = <String>{};
  return <MangaNameToRead>[
    for (final CastTextSubstitution e in table)
      if (e.isPendingName && e.source.trim().isNotEmpty && seen.add(e.source))
        (written: e.source, character: e.character),
  ];
}

/// 第一步：在 [volumes] 的页面上找注音恰好注在 [written] 某个写法上的地方。
/// 返回 写法 → 出处（按卷、页顺序；同卷同页同读法只记一次）。
Map<String, List<CastNameEvidence>> collectMangaNameRubyEvidence({
  required List<MangaNameReadingVolume> volumes,
  required Iterable<String> written,
}) {
  final Set<String> wanted = <String>{
    for (final String w in written)
      if (w.trim().isNotEmpty) w,
  };
  final Map<String, Map<String, CastNameEvidence>> out =
      <String, Map<String, CastNameEvidence>>{};
  if (wanted.isEmpty) return const <String, List<CastNameEvidence>>{};
  for (final MangaNameReadingVolume v in volumes) {
    for (int p = 0; p < v.pages.length; p++) {
      final List<MokuroBlock> blocks = v.pages[p];
      for (final MangaRubyAnnotation a in detectMangaPageRuby(
        blocks,
      ).annotations) {
        final List<String> lines = blocks[a.baseBlock].lines;
        if (a.line >= lines.length || a.end > lines[a.line].length) continue;
        final String base = lines[a.line].substring(a.start, a.end);
        if (!wanted.contains(base)) continue;
        final String? reading = normalizeCastNameReading(a.reading);
        if (reading == null) continue;
        final CastNameEvidence ev = CastNameEvidence(
          origin: CastNameEvidenceOrigin.ruby,
          reading: reading,
          page: p + 1,
          volume: v.label,
        );
        (out[base] ??= <String, CastNameEvidence>{}).putIfAbsent(
          ev.key,
          () => ev,
        );
      }
    }
  }
  return <String, List<CastNameEvidence>>{
    for (final MapEntry<String, Map<String, CastNameEvidence>> e in out.entries)
      e.key: e.value.values.take(kCastNameMaxEvidence).toList(),
  };
}

/// 每个名字在 [pages] 里首次出现起的几页（0 起，OCR 文字里出现这个写法）。
Map<String, List<int>> mangaNameFirstPages(
  List<List<MokuroBlock>> pages,
  Iterable<String> written, {
  int perName = kMangaNameReadingPagesPerName,
}) {
  final List<String> pageText = <String>[
    for (final List<MokuroBlock> blocks in pages)
      blocks.map((MokuroBlock b) => b.lines.join()).join('\n'),
  ];
  return <String, List<int>>{
    for (final String w in written)
      w: <int>[
        for (int p = 0; p < pageText.length; p++)
          if (pageText[p].contains(w)) p,
      ].take(perName).toList(),
  };
}

/// 要发的页：按名字顺序轮流取各自首次出现的页（先保证每个名字都有一页），去重、
/// 最多 [kMangaNameReadingMaxImages] 页，升序返回。
List<int> mangaNameReadingPages(Map<String, List<int>> firstPages) {
  final Set<int> picked = <int>{};
  final int rounds = firstPages.values.fold<int>(
    0,
    (int m, List<int> l) => l.length > m ? l.length : m,
  );
  for (int r = 0; r < rounds; r++) {
    for (final List<int> pages in firstPages.values) {
      if (picked.length >= kMangaNameReadingMaxImages) break;
      if (r < pages.length) picked.add(pages[r]);
    }
  }
  return picked.toList()..sort();
}

const String kMangaNameReadingSystemPrompt = '''
You find how character names in a manga are read, for an audiobook's text-to-speech. You get page images, the OCR text of those pages, a list of names, and sometimes numbered web search results.

Return ONLY one JSON object — no prose, no code fence:
{"readings":[{"name":"豊川祥子","reading":"とがわさきこ","page":12},{"name":"祥","reading":"さき","url":"https://example.com/characters"}]}

- A reading counts ONLY when a source states it:
  (a) furigana printed beside that exact name on one of the attached pages — give "page", the page number shown in the text; or
  (b) one of the numbered web search results states it — give "url" copied exactly from that result. Use only results clearly about this work's character (official site, publisher, the work's wiki).
- Never guess a reading from the kanji, from common name readings or from memory. If no source states it, or sources disagree, leave the name out.
- "reading": kana only, the reading of exactly the written name (for a one-kanji nickname such as 祥 in 祥ちゃん, the reading of that kanji alone).
- "name": copy the name exactly from the list. Return {"readings":[]} when nothing is stated.
''';

/// 请求的用户消息。[pages] = 带图的页（0 起页码 + 该页块），图按同序附在消息里；
/// [hits] = 编号后的联网搜索结果（可空）。
String buildMangaNameReadingUserPrompt({
  required String workTitle,
  required List<MangaNameToRead> names,
  required List<({int page, List<MokuroBlock> blocks})> pages,
  required List<WebSearchHit> hits,
  List<CastTextSubstitution> substitutions = const <CastTextSubstitution>[],
}) {
  final StringBuffer b = StringBuffer();
  b.writeln('[work] ${jsonEncode(workTitle)}');
  b.writeln();
  b.writeln('[names]');
  for (final MangaNameToRead n in names) {
    final String? who = n.character;
    b.writeln(
      '- ${jsonEncode(n.written)}'
      '${who == null || who == n.written ? '' : ' (character: ${jsonEncode(who)})'}',
    );
  }
  b.writeln();
  if (pages.isEmpty) {
    b.writeln('[images] none.');
  } else {
    b.writeln(
      '[images] ${pages.length} attached in order: '
      '${pages.map((({int page, List<MokuroBlock> blocks}) e) => 'page ${e.page + 1}').join(', ')}.',
    );
  }
  for (final ({int page, List<MokuroBlock> blocks}) e in pages) {
    b.writeln();
    b.writeln(
      '[page ${e.page + 1} text blocks] '
      '(a block marked ruby-of:N is furigana printed beside block N)',
    );
    final MangaPageRuby ruby = detectMangaPageRuby(e.blocks);
    for (int i = 0; i < e.blocks.length; i++) {
      final int? base = ruby.baseOfRuby[i];
      b.writeln(
        '$i ${base == null ? '' : 'ruby-of:$base '}'
        '${jsonEncode(applyCastSubstitutions(e.blocks[i].lines.join(), substitutions))}',
      );
    }
  }
  if (hits.isNotEmpty) {
    b.writeln();
    b.writeln('[web search results]');
    for (int i = 0; i < hits.length; i++) {
      final WebSearchHit h = hits[i];
      b.writeln('${i + 1}. ${jsonEncode(h.title)} — ${h.url}');
      if (h.snippet.isNotEmpty) b.writeln('   ${jsonEncode(h.snippet)}');
    }
  }
  return b.toString();
}

/// 解析回复：不是 `{"readings":[…]}` 返回 null。只收 [names] 里的写法、只含假名的
/// 读法；`page` 必须是 [sentPages]（1 起）里的页，`url` 必须是 [sentUrls] 里的结果，
/// 两者都不成立的整条丢弃。页面出处记卷名 [volume] 并标为 AI 抄录。
Map<String, List<CastNameEvidence>>? parseMangaNameReadingReply(
  String reply, {
  required Set<String> names,
  required Set<int> sentPages,
  required Set<String> sentUrls,
  required String volume,
}) {
  final Map<String, Object?>? json = decodeAiJsonObject(reply);
  final Object? list = json?['readings'];
  if (list is! List) return null;
  final Map<String, Map<String, CastNameEvidence>> out =
      <String, Map<String, CastNameEvidence>>{};
  for (final Object? raw in list) {
    if (raw is! Map) continue;
    final Object? name = raw['name'];
    if (name is! String || !names.contains(name)) continue;
    final String? reading = normalizeCastNameReading(raw['reading']);
    if (reading == null) continue;
    final Object? page = raw['page'];
    final Object? url = raw['url'];
    final int? pageNumber = switch (page) {
      final int p => p,
      final String s => int.tryParse(s.trim()),
      _ => null,
    };
    final CastNameEvidence? ev =
        pageNumber != null && sentPages.contains(pageNumber)
        ? CastNameEvidence(
            origin: CastNameEvidenceOrigin.ruby,
            reading: reading,
            page: pageNumber,
            volume: volume,
            byAi: true,
          )
        : url is String && sentUrls.contains(url.trim())
        ? CastNameEvidence(
            origin: CastNameEvidenceOrigin.official,
            reading: reading,
            url: url.trim(),
            byAi: true,
          )
        : null;
    if (ev == null) continue;
    (out[name] ??= <String, CastNameEvidence>{}).putIfAbsent(ev.key, () => ev);
  }
  return <String, List<CastNameEvidence>>{
    for (final MapEntry<String, Map<String, CastNameEvidence>> e in out.entries)
      e.key: e.value.values.toList(),
  };
}

/// 联网搜索：关键词 → 结果（失败返回空，不抛）。
typedef MangaNameReadingSearch =
    Future<List<WebSearchHit>> Function(String query);

/// 一次「查人名读法」的结果：写法 → 出处；[failure] 是 AI 那一步失败的脱敏短码
/// （页面注音那一步的结果照样在 [evidence] 里）。
class MangaNameReadingResult {
  const MangaNameReadingResult({required this.evidence, this.failure});

  final Map<String, List<CastNameEvidence>> evidence;
  final String? failure;

  int get nameCount => evidence.length;
}

/// 两步查人名读法（见库注释）。[ask] 为 null（没配 AI）只做页面注音那一步；[search]
/// 为 null（没配联网搜索或没同意）不带搜索结果。
class MangaNameReadingFinder {
  MangaNameReadingFinder({
    required this.workTitle,
    required this.names,
    required this.volumes,
    required this.currentVolume,
    this.ask,
    this.imageFor,
    this.search,
    this.substitutions = const <CastTextSubstitution>[],
  });

  final String workTitle;
  final List<MangaNameToRead> names;

  /// 系列各卷（页面注音那一步全扫）。
  final List<MangaNameReadingVolume> volumes;

  /// AI 那一步看哪一卷的页图（[volumes] 的下标）。
  final int currentVolume;

  final MangaAnnotateAsk? ask;

  /// 取 [currentVolume] 第几页（0 起）的页图。
  final MangaAnnotateImageLoader? imageFor;
  final MangaNameReadingSearch? search;
  final List<CastTextSubstitution> substitutions;

  Future<MangaNameReadingResult> run() async {
    final Map<String, List<CastNameEvidence>> found =
        Map<String, List<CastNameEvidence>>.of(
          collectMangaNameRubyEvidence(
            volumes: volumes,
            written: names.map((MangaNameToRead n) => n.written),
          ),
        );
    final List<MangaNameToRead> rest = <MangaNameToRead>[
      for (final MangaNameToRead n in names)
        if (!found.containsKey(n.written)) n,
    ];
    final MangaAnnotateAsk? ask = this.ask;
    if (ask == null ||
        rest.isEmpty ||
        currentVolume < 0 ||
        currentVolume >= volumes.length) {
      return MangaNameReadingResult(evidence: found);
    }
    final MangaNameReadingVolume volume = volumes[currentVolume];

    final List<AiChatImage> images = <AiChatImage>[];
    final List<({int page, List<MokuroBlock> blocks})> pages =
        <({int page, List<MokuroBlock> blocks})>[];
    final MangaAnnotateImageLoader? imageFor = this.imageFor;
    if (imageFor != null) {
      for (final int p in mangaNameReadingPages(
        mangaNameFirstPages(
          volume.pages,
          rest.map((MangaNameToRead n) => n.written),
        ),
      )) {
        final AiChatImage? img = await imageFor(p);
        if (img == null) continue;
        images.add(img);
        pages.add((page: p, blocks: volume.pages[p]));
      }
    }

    final List<WebSearchHit> hits = <WebSearchHit>[];
    final MangaNameReadingSearch? search = this.search;
    if (search != null && workTitle.trim().isNotEmpty) {
      final Set<String> seen = <String>{};
      // 别名按所属角色的规范名查（同一角色只查一次）。
      final Set<String> queries = <String>{
        for (final MangaNameToRead n in rest)
          '${workTitle.trim()} ${n.character ?? n.written} 読み方',
      };
      for (final String query in queries.take(
        kMangaNameReadingMaxSearchNames,
      )) {
        final List<WebSearchHit> got = await search(query);
        for (final WebSearchHit h in got.take(kMangaNameReadingHitsPerName)) {
          if (seen.add(h.url.toString())) hits.add(h);
        }
      }
    }
    if (images.isEmpty && hits.isEmpty) {
      return MangaNameReadingResult(evidence: found);
    }

    final String reply;
    try {
      reply = await ask(<AiChatMessage>[
        AiChatMessage.system(kMangaNameReadingSystemPrompt, cacheable: true),
        AiChatMessage.user(
          buildMangaNameReadingUserPrompt(
            workTitle: workTitle,
            names: rest,
            pages: pages,
            hits: hits,
            substitutions: substitutions,
          ),
          images: images,
        ),
      ]);
    } on AiChatFailure catch (e) {
      return MangaNameReadingResult(evidence: found, failure: e.message);
    }
    final Map<String, List<CastNameEvidence>>? parsed =
        parseMangaNameReadingReply(
          reply,
          names: <String>{for (final MangaNameToRead n in rest) n.written},
          sentPages: <int>{
            for (final ({int page, List<MokuroBlock> blocks}) e in pages)
              e.page + 1,
          },
          sentUrls: <String>{
            for (final WebSearchHit h in hits) h.url.toString(),
          },
          volume: volume.label,
        );
    if (parsed == null) {
      return MangaNameReadingResult(evidence: found, failure: 'bad_output');
    }
    found.addAll(parsed);
    return MangaNameReadingResult(evidence: found);
  }
}
