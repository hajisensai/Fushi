/// 小说有声书（制作台 / 朗读 / 生成）挂系列档案：选角表 [TtsCast] 叠在系列声音指派
/// 上读，角色表从系列来、学回系列；未配音账本与选角表同目录。
///
/// 所有读「某角色 / 某句用哪个声音」的地方都走 [TtsCast.voiceOf] / [TtsCast.presetFor]，
/// 不直接读 `cast.voices`（那只是本书自己的一层）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_line_voicing.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_service.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi/src/models/app_model.dart';

/// 每本书的未配音账本：`<db>/tts_cast/<sha1>.voicing.json`。
CastVoicingStore ttsVoicingStoreFor(AppModel appModel) => CastVoicingStore(
  Directory(p.join(appModel.databaseDirectory.path, 'tts_cast')),
);

/// 制作用的计划：按系列用词替换表改写每句的显示文字（进 cue / SRT / 制卡）与送去合成
/// 的文字（纯函数）。只在制作流程与补回里用；AI 标注在构造提示词时替换，不改原计划。
/// 单句手动填写的念法（`TtsCast.sayFor`）在 `ttsSentenceSpokenText` 里优先，不过表。
///
/// 送去合成的文字可能已被读音词典改写过（ruby 底本换成读音、词典规则）：两者相同时
/// 直接用替换后的显示文字；不同时对念法单独替换（原文写法被读音改掉的就不再命中）。
/// 选角表的行键是 `(section, matchStart)`，与文字无关，所以替换不影响选角与账本。
TtsBookPlan ttsPlanWithSubstitutions(
  TtsBookPlan plan,
  List<CastTextSubstitution> table,
) {
  if (table.isEmpty) return plan;
  return TtsBookPlan(<TtsPlanSentence>[
    for (final TtsPlanSentence s in plan.sentences) _substituted(s, table),
  ]);
}

TtsPlanSentence _substituted(
  TtsPlanSentence s,
  List<CastTextSubstitution> table,
) {
  final String text = applyCastSubstitutions(s.text, table);
  final String spoken = s.spokenText == s.text
      ? text
      : applyCastSubstitutions(s.spokenText, table);
  if (identical(text, s.text) && identical(spoken, s.spokenText)) return s;
  return TtsPlanSentence(
    section: s.section,
    href: s.href,
    text: text,
    spokenText: spoken,
    matchStart: s.matchStart,
    matchEnd: s.matchEnd,
    studyStart: s.studyStart,
    studyEnd: s.studyEnd,
    endsParagraph: s.endsParagraph,
    sceneBreakAfter: s.sceneBreakAfter,
  );
}

/// 一本书的选角表 + 它所属的系列档案（没有系列时为 null）。
typedef TtsCastBundle = ({TtsCast cast, SeriesCastProfile? series});

/// 读选角表并挂上系列声音（[TtsCast.series]）。系列档案读不出时按没有系列处理。
Future<TtsCastBundle> loadTtsCastBundle(
  AppModel appModel,
  String bookKey,
) async {
  final TtsCast cast = await ttsCastStoreFor(appModel).load(bookKey);
  final SeriesCastProfile? series = await loadTtsSeriesProfile(
    appModel,
    bookKey,
  );
  cast.series = series?.voices;
  return (cast: cast, series: series);
}

/// [bookKey] 所属系列的档案；合集推断的系列首次读到时补上展示名。
Future<SeriesCastProfile?> loadTtsSeriesProfile(
  AppModel appModel,
  String bookKey,
) async {
  final String? key = await resolveSeriesKey(appModel, bookKey);
  if (key == null) return null;
  final SeriesCastProfile profile = await seriesCastStoreFor(
    appModel,
  ).load(key);
  if (profile.title.isEmpty) {
    profile.title = await ttsSeriesTitle(appModel, key);
  }
  return profile;
}

/// 系列展示名：合集推断的取合集名，其余用身份本身。
Future<String> ttsSeriesTitle(AppModel appModel, String seriesKey) async {
  final int? id = seriesCollectionId(seriesKey);
  if (id == null) return seriesKey;
  final MediaCollectionRow? row = await appModel.database
      .getMediaCollectionById(id);
  return row?.name ?? seriesKey;
}

/// 可以把书关联过去的系列：书架域的合集（`collection:<id>`）。
Future<List<({String key, String title})>> ttsSeriesCandidates(
  AppModel appModel,
) async => <({String key, String title})>[
  for (final MediaCollectionRow c
      in await appModel.database.getMediaCollectionsInDomain(
        CollectionShelfDomain.books,
      ))
    if (c.collectionType == 'collection')
      (key: '$kSeriesKeyCollectionPrefix${c.id}', title: c.name),
];

/// 系列成员书（bookKey），按系列顺序（[seriesMemberBooks]）。
Future<List<String>> ttsSeriesMemberBooks(
  AppModel appModel,
  SeriesCastProfile profile,
) => seriesMemberBooks(appModel, profile.seriesKey);

/// 给角色选声音写到哪一层。
enum TtsVoiceScope {
  /// 写进系列档案（同系列其它卷也用），并清掉本书对它的覆盖。
  series,

  /// 只写进这本书的选角表。
  book,
}

/// 给 [speaker] 设声音（[presetId] 为 null = 清掉这一层）。没有系列时一律写本书。
/// 返回系列档案是否被改动（调用方据此决定要不要存档案）。
bool setTtsCastVoice({
  required TtsCast cast,
  required SeriesCastProfile? series,
  required String speaker,
  required String? presetId,
  required TtsVoiceScope scope,
}) {
  if (series == null || scope == TtsVoiceScope.book) {
    if (presetId == null) {
      cast.voices.remove(speaker);
    } else {
      cast.voices[speaker] = presetId;
    }
    return false;
  }
  final CastVoiceAssignment voices = series.voices;
  if (speaker == kTtsNarrator) {
    voices.narrationVoice = presetId;
  } else if (presetId == null) {
    voices.byCharacter.remove(speaker);
    voices.byCharacterKind.remove(speaker);
  } else {
    voices.byCharacter[speaker] = presetId;
  }
  // 系列这一层要生效，本书对它的覆盖得让开。
  cast.voices.remove(speaker);
  cast.series = voices;
  return true;
}

/// 角色改名 / 合并：本书选角表与系列档案一起改。
void renameTtsCastSpeaker({
  required TtsCast cast,
  required SeriesCastProfile? series,
  required String from,
  required String to,
}) {
  cast.renameSpeaker(from, to);
  series?.renameCharacter(from, to);
}

/// 标注前：系列里记住的角色并进本书角色表（标注只能从角色表里选人，名字不随卷漂移）。
void seedTtsRosterFromSeries(TtsCast cast, SeriesCastProfile? series) {
  if (series == null || series.roster.isEmpty) return;
  cast.mergeRoster(series.roster.values);
}

/// 标注后：本书角色表学回系列。返回系列角色表是否有变化。
bool learnTtsRosterIntoSeries(TtsCast cast, SeriesCastProfile? series) {
  if (series == null || cast.roster.isEmpty) return false;
  final String before = _rosterSignature(series.roster);
  series.learnRoster(cast.roster.values);
  return _rosterSignature(series.roster) != before;
}

String _rosterSignature(Map<String, TtsCastCharacter> roster) => <String>[
  for (final TtsCastCharacter c in roster.values) c.toJson().toString(),
].join('\n');
