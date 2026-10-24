/// 查词弹窗 popup.js 的两根桥（`librarySentences` / `librarySentenceOpen`），app 内 WebView
/// 弹窗与 Windows app 外查词窗（overlay_bridge_handlers）共用这一份回包构造。
///
/// 回包形态见 popup.js `applyLibrarySentences`：文案（标题 / 组名 / 出处）在这里本地化好，
/// popup.js 不带任何语言串；每条的 `ref` 是 [CorpusHit.toJson]，点击时原样交回。
library;

import 'package:fushi/src/corpus/corpus_origin_navigation.dart';
import 'package:fushi/src/corpus/library_corpus_service.dart';
import 'package:fushi/src/models/module_id.dart' show ModuleVisibility;
import 'package:fushi/utils.dart';
import 'package:fushi_corpus/fushi_corpus.dart';

String _groupLabel(CorpusSourceKind kind) => switch (kind) {
  CorpusSourceKind.book => t.lookup_library_sentences_group_books,
  CorpusSourceKind.video => t.lookup_library_sentences_group_videos,
  CorpusSourceKind.music => t.lookup_library_sentences_group_music,
  CorpusSourceKind.game => t.lookup_library_sentences_group_games,
};

String _clock(int ms) {
  final int totalSeconds = ms ~/ 1000;
  final int minutes = totalSeconds ~/ 60;
  final int seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// 一条例句的出处描述（标题 · 集号 / 时间点）。
String librarySentenceSourceLabel(CorpusHit hit) {
  final List<String> parts = <String>[if (hit.title.isNotEmpty) hit.title];
  switch (hit.kind) {
    case CorpusSourceKind.video:
      if (hit.part > 0) {
        parts.add(
          t.lookup_library_sentences_episode(number: '${hit.part + 1}'),
        );
      }
      parts.add(_clock(hit.pos));
    case CorpusSourceKind.music:
      parts.add(_clock(hit.pos));
    case CorpusSourceKind.book:
    case CorpusSourceKind.game:
      break;
  }
  return parts.join(' · ');
}

/// 按 [result] 构造 popup.js 的回包；去掉所属模块被关掉的组，全空时回 null（区块不出现）。
Map<String, Object?>? librarySentencesPayload(
  CorpusQueryResult result,
  ModuleVisibility visibility,
) {
  final List<CorpusGroup> groups = <CorpusGroup>[
    for (final CorpusGroup g in result.groups)
      if (g.items.isNotEmpty &&
          visibility.isEnabled(moduleOfCorpusKind(g.kind)))
        g,
  ];
  if (groups.isEmpty) return null;
  int total = 0;
  for (final CorpusGroup g in groups) {
    total += g.total;
  }
  return <String, Object?>{
    'title': t.lookup_library_sentences_title(count: '$total'),
    'groups': <Map<String, Object?>>[
      for (final CorpusGroup g in groups)
        <String, Object?>{
          'kind': g.kind.code,
          'label': _groupLabel(g.kind),
          'total': g.total,
          'items': <Map<String, Object?>>[
            for (final CorpusHit hit in g.items)
              <String, Object?>{
                'text': hit.text,
                'hl': <List<int>>[
                  for (final ({int start, int length}) h in hit.highlights)
                    <int>[h.start, h.length],
                ],
                'source': librarySentenceSourceLabel(hit),
                'ref': hit.toJson(),
              },
          ],
        },
    ],
  };
}

/// `librarySentences` 桥：args[0] = `{expression, reading}`。关着 / 没有命中回 null。
Future<Map<String, Object?>?> librarySentencesHandleBridge(
  List<dynamic> args,
  ModuleVisibility visibility, {
  LibraryCorpusService? service,
}) async {
  final LibraryCorpusService corpus = service ?? LibraryCorpusService.instance;
  if (!corpus.enabled || args.isEmpty || args.first is! Map) return null;
  final Map<dynamic, dynamic> data = args.first as Map<dynamic, dynamic>;
  final String expression = data['expression']?.toString().trim() ?? '';
  if (expression.isEmpty) return null;
  final CorpusQueryResult result = await corpus.query(<String>[expression]);
  return librarySentencesPayload(result, visibility);
}

/// `librarySentenceOpen` 桥：args[0] = 回包里的 `ref`。回是否打开。
Future<bool> librarySentenceOpenHandleBridge(List<dynamic> args) async {
  if (args.isEmpty) return false;
  final CorpusHit? hit = CorpusHit.tryFromJson(args.first);
  if (hit == null) return false;
  return LibraryCorpusService.openHit(hit);
}
