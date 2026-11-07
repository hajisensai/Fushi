/// 音乐库「生成日语字幕」与「搜索歌词」的界面接线（歌词页 / 专辑页 / 曲目详情页 / 来源页
/// 共用，不在各页各写一套）。
///
/// - 生成：解析音乐目标（[MusicSubtitleTargets]）后打开视频同一个面板
///   （[showVideoSubtitleGenerateSheet]：模型下载、分段、AI 校对、进度、取消都在里面）。
///   入口只在 [musicSubtitleGenerationAvailable] 时出现：没有本地 ONNX Runtime 的平台 /
///   架构（[isAsrSupported]）不显示，而不是点了才报错。
/// - 曲内搜索：在当前歌词 / 字幕行里做子串搜索（与有声书歌词模式同一个
///   [searchLyricsCueTextsOffUi] 与归一化口径），点结果跳到那一行的时间。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/media/music/asr/music_subtitle_target.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_generate_sheet.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/ai_settings_route.dart'
    show pushAiSettingsPage;
import 'package:fushi/src/reader/lyrics_cue_search.dart';
import 'package:fushi/src/reader/reader_panel_kit.dart'
    show ReaderQuoteCard, readerHighlightSpans;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 平台闸门（测试可覆盖）：本机能不能跑设备端转录。
@visibleForTesting
bool Function() musicSubtitleAsrSupported = () => isAsrSupported;

/// 本机能不能出「生成日语字幕」入口（不看具体曲目：来源批量入口用）。
bool musicSubtitleGenerationSupported() => musicSubtitleAsrSupported();

/// 这首（路径）能不能出「生成日语字幕」入口：本机有转录能力，且是本机文件。
bool musicSubtitleGenerationAvailable(String trackPath) =>
    musicSubtitleAsrSupported() && isMusicTrackLocallyTranscribable(trackPath);

/// 一批曲目里有没有能生成的（专辑 / 来源批量入口）。
bool musicSubtitleGenerationAvailableForAny(Iterable<String> trackPaths) =>
    musicSubtitleAsrSupported() &&
    trackPaths.any(isMusicTrackLocallyTranscribable);

/// 解析目标并打开生成面板。批量目标里全部曲目都已有生成字幕时只提示一句。
Future<void> openMusicSubtitleGenerateSheet({
  required BuildContext context,
  required AppModel appModel,
  required Future<AppVideoSubtitleTarget> Function(MusicSubtitleTargets t)
  resolve,
}) async {
  final AppVideoSubtitleTarget target;
  try {
    target = await resolve(
      MusicSubtitleTargets(
        database: appModel.database,
        lyrics: appModel.musicLyrics,
      ),
    );
  } on AppVideoSubtitleTargetNotFound {
    FushiToast.show(
      msg: t.video_subtitle_ai_no_local_episodes,
      severity: ToastSeverity.error,
    );
    return;
  }
  if (target.episodes.isEmpty && target.unavailable.isEmpty) {
    FushiToast.show(msg: t.music_subtitle_all_generated);
    return;
  }
  if (!context.mounted) return;
  await showVideoSubtitleGenerateSheet(
    context: context,
    service: appVideoSubtitleService(appModel),
    target: target,
    prefs: PrefsRepoVideoSubtitleGeneratePrefs(appModel.prefsRepo),
    openAiSettings: pushAiSettingsPage,
  );
}

/// 曲内搜索面板：搜 [timeline] 的行文本，点结果回调 [onJump]（行起点，毫秒）。
Future<void> showMusicLyricsSearchSheet({
  required BuildContext context,
  required LyricTimeline timeline,
  required Future<void> Function(int startMs) onJump,
  Future<LyricsCueTextSearch> Function(List<String> texts, String query)?
  search,
}) => adaptiveModalSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (BuildContext ctx) => MusicLyricsSearchSheet(
    timeline: timeline,
    onJump: onJump,
    search: search ?? searchLyricsCueTextsOffUi,
  ),
);

class MusicLyricsSearchSheet extends StatefulWidget {
  const MusicLyricsSearchSheet({
    super.key,
    required this.timeline,
    required this.onJump,
    required this.search,
  });

  final LyricTimeline timeline;
  final Future<void> Function(int startMs) onJump;
  final Future<LyricsCueTextSearch> Function(List<String> texts, String query)
  search;

  @override
  State<MusicLyricsSearchSheet> createState() => _MusicLyricsSearchSheetState();
}

class _MusicLyricsSearchSheetState extends State<MusicLyricsSearchSheet> {
  late final List<String> _texts = <String>[
    for (final LyricLine l in widget.timeline.lines) l.text,
  ];
  LyricsCueTextSearch _found = LyricsCueTextSearch.empty;
  String _query = '';
  int _generation = 0;

  Future<void> _onQuery(String query) async {
    final int generation = ++_generation;
    final String q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _found = LyricsCueTextSearch.empty;
      });
      return;
    }
    final LyricsCueTextSearch found = await widget.search(_texts, q);
    if (!mounted || generation != _generation) return;
    setState(() {
      _query = q;
      _found = found;
    });
  }

  String _clock(int ms) {
    final Duration d = Duration(milliseconds: ms < 0 ? 0 : ms);
    final String s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '${d.inMinutes}:$s';
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiModalSheetFrame(
      title: t.music_lyrics_search_in_track,
      leadingIcon: FushiIcons.search,
      bodyPadding: EdgeInsets.symmetric(horizontal: tokens.spacing.card),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiSearchBar(
            key: const ValueKey<String>('music_lyrics_search_field'),
            hintText: t.music_lyrics_search_hint,
            autofocus: true,
            debounce: const Duration(milliseconds: 200),
            onQueryChanged: (String q) => unawaited(_onQuery(q)),
          ),
          SizedBox(height: tokens.spacing.gap),
          if (_query.isNotEmpty && _found.hits.isEmpty)
            Padding(
              padding: EdgeInsets.all(tokens.spacing.card),
              child: Text(
                t.music_lyrics_search_none,
                key: const ValueKey<String>('music_lyrics_search_none'),
                textAlign: TextAlign.center,
              ),
            ),
          Flexible(
            child: FushiEntranceScope(
              child: ListView.separated(
                key: const ValueKey<String>('music_lyrics_search_results'),
                shrinkWrap: true,
                itemCount: _found.hits.length,
                separatorBuilder: (_, _) =>
                    SizedBox(height: tokens.spacing.gap),
                itemBuilder: fushiStaggeredItemBuilder((
                  BuildContext ctx,
                  int i,
                ) {
                  final LyricsCueTextHit hit = _found.hits[i];
                  final LyricLine line = widget.timeline.lines[hit.cueIndex];
                  return ReaderQuoteCard(
                    key: ValueKey<String>('music_lyrics_search_result_$i'),
                    overline: _clock(line.startMs - widget.timeline.offsetMs),
                    quote: Text.rich(
                      readerHighlightSpans(
                        ctx,
                        text: line.text,
                        start: hit.matchStart,
                        end: hit.matchEnd,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    focusIdPrefix: 'music-lyrics-search-result',
                    onTap: () async {
                      Navigator.of(context).pop();
                      // 行时间按整首偏移折回音频时间（正 = 歌词提前）。
                      await widget.onJump(
                        line.startMs - widget.timeline.offsetMs,
                      );
                    },
                  );
                }),
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
      ),
    );
  }
}
