import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_sidecar.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki/src/media/video/video_subtitle_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_native.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// 视频页：media_kit 播放器 + 可点击字幕 overlay（点词查词 + 制卡）。
///
/// 装配：[VideoPlayerController.load] 打开视频 + cue 同步 → [Stack] 叠
/// [Video]（media_kit 桌面控制：播放/进度/音量/全屏 + 顶栏字幕轨/音轨切换）
/// 与 [VideoSubtitleOverlay]（逐字符可点）。点字幕字符 → [_lookupAt] 取词查词
/// → [DictionaryPopupNative] 弹窗 → [_mine] 制卡（截图 coverPath + 字幕音频
/// sasayakiAudioPath + 例句 sentence，复用现有 Anki 字段，不改 hibiki_anki）。
class VideoHibikiPage extends ConsumerStatefulWidget {
  const VideoHibikiPage({
    required this.bookUid,
    required this.repo,
    super.key,
  });

  final String bookUid;
  final VideoBookRepository repo;

  @override
  ConsumerState<VideoHibikiPage> createState() => _VideoHibikiPageState();
}

class _VideoHibikiPageState extends ConsumerState<VideoHibikiPage> {
  VideoPlayerController? _controller;
  bool _failed = false;
  String? _title;

  /// 多集播放列表（单视频导入时为空）。
  List<PlaylistEntry> _episodes = const <PlaylistEntry>[];

  /// 当前集索引（[_episodes] 下标）；单视频恒 0。
  int _currentEpisode = 0;

  /// 当前播放的视频文件绝对路径（枚举字幕源用）；未 load 时为 null。
  String? _currentVideoPath;

  /// 当前选中的字幕源持久化值（外挂路径 / `embedded:<n>` / null=关闭）；
  /// 用于字幕源菜单高亮当前项。
  String? _currentSubtitleSource;

  /// 当前选中的音轨 id（libmpv `AudioTrack.id`）；null=未选过跟随默认。
  /// 多集换集时复用同一值（用户选了日语音轨，每集都用日语）。
  String? _currentAudioTrackId;

  bool get _isPlaylist => _episodes.length > 1;

  AppModel get appModel => ref.read(appProvider);

  /// app 当前目标学习语言代码（如 `'ja'`/`'ko'`），用于 sidecar 字幕语言优先检测。
  String get _targetLangCode => appModel.targetLanguage.locale.languageCode;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final VideoBookRow? row = await widget.repo.getByBookUid(widget.bookUid);
    if (row == null) {
      if (mounted) setState(() => _failed = true);
      return;
    }

    // 记录持久化的字幕源（菜单高亮当前项用）+ 音轨偏好（换集复用）。
    _currentSubtitleSource = row.subtitleSource;
    _currentAudioTrackId = row.audioTrackId;

    // 解析播放列表（若有）。非空则按 currentEpisode 载对应集；否则走单视频路径。
    final String? playlistJson = row.playlistJson;
    if (playlistJson != null && playlistJson.isNotEmpty) {
      final List<dynamic> raw = jsonDecode(playlistJson) as List<dynamic>;
      _episodes = raw
          .map((dynamic e) => PlaylistEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    if (_episodes.isNotEmpty) {
      final int idx = row.currentEpisode.clamp(0, _episodes.length - 1);
      await _loadEpisode(
        idx,
        initialPositionMs: row.lastPositionMs,
        subtitleSource: row.subtitleSource,
      );
      return;
    }

    // 单视频路径（无播放列表）。
    await _loadSingle(row);
  }

  /// 载入单视频（无播放列表）：优先用 DB 已存 cue；否则先尝试恢复用户上次选的
  /// 字幕源（[row.subtitleSource] 跨重启保留），无匹配再退默认 sidecar 探测。
  Future<void> _loadSingle(VideoBookRow row) async {
    List<AudioCue> cues = await widget.repo.loadCues(widget.bookUid);
    String? externalSub = row.subtitleSource;

    if (cues.isEmpty) {
      // ① 优先恢复持久化的字幕源（精确匹配本视频的同一源）。
      if (row.subtitleSource != null && row.subtitleSource!.isNotEmpty) {
        final ({String persisted, List<AudioCue> cues})? restored =
            await _restorePersistedSubtitle(
          videoPath: row.videoPath,
          persisted: row.subtitleSource,
          crossEpisode: false,
        );
        if (restored != null) {
          cues = restored.cues;
          externalSub = restored.persisted;
        }
      }
      // ② 无持久化 / 无匹配：退默认 sidecar 探测。
      if (cues.isEmpty && externalSub == null) {
        final ({String path, List<AudioCue> cues})? sidecar =
            await _detectSidecar(row.videoPath, widget.bookUid);
        if (sidecar != null) {
          cues = sidecar.cues;
          externalSub = sidecar.path;
        }
      }
    }
    await _applyLoad(
      videoPath: row.videoPath,
      cues: cues,
      title: row.title,
      initialPositionMs: row.lastPositionMs,
      externalSubtitlePath: externalSub,
    );
  }

  /// 尝试用持久化偏好 [persisted] 在 [videoPath] 的可用字幕源里选一个并加载 cue。
  ///
  /// [crossEpisode]=false（单视频重启恢复）：用 [SubtitleSource.matchesPersisted]
  /// 精确匹配同一源。[crossEpisode]=true（播放列表换集）：用
  /// [pickEpisodeSubtitleSource] 按「同类偏好」（内嵌同 streamIndex / 外挂同语言
  /// 后缀）从新集源里选。
  ///
  /// 返回所选源的「实际持久化值 + 解析出的 cue」；无匹配 / 解析空 cue 返回 null
  /// （调用方退默认 sidecar）。返回的 persisted 用作 [_applyLoad] 的
  /// externalSubtitlePath（内嵌源也走 `embedded:<n>` 字符串，与既有约定一致）。
  Future<({String persisted, List<AudioCue> cues})?> _restorePersistedSubtitle({
    required String videoPath,
    required String? persisted,
    required bool crossEpisode,
  }) async {
    if (persisted == null || persisted.isEmpty) return null;
    final List<SubtitleSource> sources =
        await listAllSubtitleSources(videoPath, langCode: _targetLangCode);
    if (sources.isEmpty) return null;

    final SubtitleSource? chosen = crossEpisode
        ? pickEpisodeSubtitleSource(persisted, sources)
        : _firstMatching(sources, persisted);
    if (chosen == null) return null;

    final List<AudioCue> cues =
        await loadCuesForSource(chosen, videoPath, widget.bookUid);
    if (cues.isEmpty) return null;
    return (persisted: chosen.toPersistedValue(), cues: cues);
  }

  /// 在 [sources] 中找第一个 [matchesPersisted] 命中的源（精确恢复用）。
  SubtitleSource? _firstMatching(
    List<SubtitleSource> sources,
    String persisted,
  ) {
    for (final SubtitleSource s in sources) {
      if (s.matchesPersisted(persisted)) return s;
    }
    return null;
  }

  /// 载入播放列表第 [index] 集：先按上次选择的「同类偏好」选新集字幕源
  /// （[subtitleSource] 是上次持久化的偏好），无匹配再退默认 sidecar 探测。
  ///
  /// cue 不存 DB——每集 load 时按文件动态解析（播放列表各集字幕是外部文件，本就随
  /// 磁盘存在；存 DB 只会与磁盘真相重复且引入跨集 book_uid 错配）。
  Future<void> _loadEpisode(
    int index, {
    int initialPositionMs = 0,
    String? subtitleSource,
  }) async {
    if (index < 0 || index >= _episodes.length) return;
    final PlaylistEntry episode = _episodes[index];

    List<AudioCue> cues = const <AudioCue>[];
    String? externalSub;

    // ① 按上次偏好（同类）选新集字幕源：内嵌同 streamIndex / 外挂同语言后缀。
    if (subtitleSource != null && subtitleSource.isNotEmpty) {
      final ({String persisted, List<AudioCue> cues})? restored =
          await _restorePersistedSubtitle(
        videoPath: episode.path,
        persisted: subtitleSource,
        crossEpisode: true,
      );
      if (restored != null) {
        cues = restored.cues;
        externalSub = restored.persisted;
      }
    }

    // ② 无偏好 / 无匹配：退默认 sidecar 探测。
    if (cues.isEmpty) {
      final ({String path, List<AudioCue> cues})? sidecar =
          await _detectSidecar(episode.path, widget.bookUid);
      if (sidecar != null) {
        cues = sidecar.cues;
        externalSub = sidecar.path;
      }
    }

    _currentEpisode = index;
    await _applyLoad(
      videoPath: episode.path,
      cues: cues,
      title: episode.title,
      initialPositionMs: initialPositionMs,
      externalSubtitlePath: externalSub,
    );
  }

  /// 探测视频同目录 sidecar 字幕并解析为 cue（无则 null）。
  ///
  /// 按 app 学习语言优先（学日语 → `.ja.srt > .ja.ass > … > .srt > .ass …`，
  /// 见 [findSidecarSubtitle]）；按扩展名路由 [SrtParser] / [AssParser]。IO + 解析
  /// 失败静默返回 null。
  Future<({String path, List<AudioCue> cues})?> _detectSidecar(
    String videoPath,
    String bookUid,
  ) async {
    final String? sidecarPath =
        findSidecarSubtitle(videoPath, langCode: _targetLangCode);
    if (sidecarPath == null) return null;
    try {
      final String text = await readTextWithEncoding(File(sidecarPath));
      final List<AudioCue> cues = sidecarPath.toLowerCase().endsWith('.ass')
          ? AssParser.parseString(content: text, bookUid: bookUid)
          : SrtParser.parseString(content: text, bookUid: bookUid);
      if (cues.isEmpty) return null;
      return (path: sidecarPath, cues: cues);
    } catch (e) {
      debugPrint('[VideoHibikiPage] sidecar parse failed: $e');
      return null;
    }
  }

  /// 共享 load 装配：复用或新建 controller，载入视频 + cue，挂位置持久化回调。
  Future<void> _applyLoad({
    required String videoPath,
    required List<AudioCue> cues,
    required String title,
    required int initialPositionMs,
    String? externalSubtitlePath,
  }) async {
    final VideoPlayerController controller =
        _controller ?? VideoPlayerController();
    try {
      await controller.load(
        bookUid: widget.bookUid,
        videoFile: File(videoPath),
        cues: cues,
        initialPositionMs: initialPositionMs,
        externalSubtitlePath: externalSubtitlePath,
      );
    } catch (e, stack) {
      debugPrint('[VideoHibikiPage] video load failed: $e\n$stack');
      if (_controller == null) controller.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    controller.onPositionWrite =
        (String uid, int posMs) => widget.repo.updatePosition(uid, posMs);
    if (!mounted) {
      if (_controller == null) controller.dispose();
      return;
    }
    setState(() {
      _controller = controller;
      _title = title;
      _failed = false;
      _currentVideoPath = videoPath;
      // 外挂字幕路径即持久化值；内嵌自动加载（externalSubtitlePath==null）时
      // 当前选中由 _currentSubtitleSource 保留（菜单切换时再写）。
      _currentSubtitleSource = externalSubtitlePath ?? _currentSubtitleSource;
    });

    // 恢复用户选过的音轨（含多集换集复用）：audioTracks 在 player open 后才填充，
    // 延迟一拍再读，按 id 匹配；找不到（轨不存在/未选过）就跳过保留 libmpv 默认。
    unawaited(_restoreAudioTrack(controller));
  }

  /// 若有持久化音轨偏好 [_currentAudioTrackId]，在 [controller] 的 audioTracks 里
  /// 按 id 匹配并切换。延迟读取以等待 libmpv open 后填充音轨列表。
  Future<void> _restoreAudioTrack(VideoPlayerController controller) async {
    final String? wantId = _currentAudioTrackId;
    if (wantId == null || wantId.isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted || _controller != controller) return;
    for (final AudioTrack track in controller.audioTracks) {
      if (track.id == wantId) {
        await controller.selectAudioTrack(track);
        return;
      }
    }
  }

  /// 选中某音轨：切轨 + 持久化 id（换集复用）+ SnackBar。
  Future<void> _selectAudioTrack(
    VideoPlayerController controller,
    AudioTrack track,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await controller.selectAudioTrack(track);
    await widget.repo.updateAudioTrackId(widget.bookUid, track.id);
    if (!mounted) return;
    setState(() => _currentAudioTrackId = track.id);
    messenger.showSnackBar(SnackBar(
      content: Text(t.video_audio_track_switched(
        label: _trackLabel(track.title, track.language, track.id),
      )),
    ));
  }

  /// 切到第 [index] 集：持久化 currentEpisode（位置归零）+ 重新 load 新集字幕。
  Future<void> _switchEpisode(int index) async {
    if (index < 0 || index >= _episodes.length) return;
    if (index == _currentEpisode) return;
    await widget.repo.updateCurrentEpisode(widget.bookUid, index);
    // 切集从头播：位置归零（避免把上一集的进度套到新集）。
    await widget.repo.updatePosition(widget.bookUid, 0);
    // 把上次选择的字幕偏好带进新集（同类应用：内嵌同轨 / 外挂同语言后缀）。
    await _loadEpisode(
      index,
      initialPositionMs: 0,
      subtitleSource: _currentSubtitleSource,
    );
  }

  void _showEpisodeList() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _episodes.length,
            itemBuilder: (BuildContext _, int i) {
              final bool selected = i == _currentEpisode;
              return ListTile(
                selected: selected,
                selectedColor: Theme.of(ctx).colorScheme.primary,
                textColor: Colors.white,
                leading: selected
                    ? const Icon(Icons.play_arrow)
                    : Text('${i + 1}',
                        style: const TextStyle(color: Colors.white70)),
                title: Text(
                  _episodes[i].title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _switchEpisode(i);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 点字幕第 [graphemeIndex] 个字符：暂停 → 从该位置起取词 → 查词 → 弹词典。
  Future<void> _lookupAt(String sentence, int graphemeIndex) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    await controller.pause();
    final String term = sentence.characters.skip(graphemeIndex).join();
    debugPrint('[video-lookup] tap idx=$graphemeIndex term="$term"');
    if (term.isEmpty) return;
    final DictionarySearchResult result = await appModel.searchDictionary(
      searchTerm: term,
      searchWithWildcards: false,
      overrideMaximumTerms: appModel.maximumTerms,
    );
    debugPrint('[video-lookup] entries=${result.entries.length}');
    if (!mounted || result.entries.isEmpty) {
      if (mounted && result.entries.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到该词')),
        );
      }
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xF2101010),
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.6,
          ),
          child: DictionaryPopupNative(
            result: result,
            onMineEntry: (Map<String, String> fields) =>
                _mine(fields, sentence),
          ),
        ),
      ),
    );
  }

  /// 制卡：词典字段 + 当前字幕例句 + 视频截图（coverPath→{book-cover}）
  /// + 字幕音频片段（sasayakiAudioPath→{sasayaki-audio}）。复用现有 Anki 字段。
  Future<void> _mine(Map<String, String> fields, String sentence) async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final Directory tmp = await getTemporaryDirectory();

    // 视频截图（当前帧）→ coverPath。
    String? coverPath;
    final Uint8List? shot = await controller.screenshot();
    if (shot != null && shot.isNotEmpty) {
      final File f = File('${tmp.path}/video_mine_shot.jpg');
      await f.writeAsBytes(shot);
      coverPath = f.path;
    }

    // 当前字幕 cue 的音频片段（桌面 ffmpeg 按时间裁）→ sasayakiAudioPath。
    String? audioPath;
    final AudioCue? cue = controller.currentCue;
    final String? videoPath = controller.videoPath;
    if (cue != null && videoPath != null) {
      audioPath = await extractAudioSegmentViaFfmpeg(
        inputPath: videoPath,
        startMs: cue.startMs,
        endMs: cue.endMs,
        outputPath: '${tmp.path}/video_mine_audio.aac',
      );
    }

    final AnkiMiningContext miningContext = AnkiMiningContext(
      sentence: sentence,
      cueSentence: cue?.text,
      documentTitle: _title,
      coverPath: coverPath,
      sasayakiAudioPath: audioPath,
    );
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    final MineResult result = await repo.mineEntry(
      rawPayloadJson: jsonEncode(fields),
      context: miningContext,
    );
    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String message;
    switch (result) {
      case MineResult.success:
        final AnkiSettings settings = await repo.loadSettings();
        message = t.card_exported(deck: settings.selectedDeckName ?? '');
      case MineResult.duplicate:
        message = t.card_duplicate;
      case MineResult.notConfigured:
        message = t.card_export_not_configured;
      case MineResult.error:
        message = t.card_export_failed;
    }
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
    if (mounted) Navigator.of(context).pop();
  }

  /// media_kit 桌面控制主题：底部默认控制条（播放/进度/音量/全屏）+ 顶栏
  /// 加字幕轨、音轨切换按钮（点击弹 track 列表，调 libmpv 切轨）。
  MaterialDesktopVideoControlsThemeData _desktopControlsTheme(
    VideoPlayerController controller,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return MaterialDesktopVideoControlsThemeData(
      seekBarPositionColor: cs.primary,
      seekBarThumbColor: cs.primary,
      buttonBarButtonColor: cs.onSurface,
      topButtonBar: <Widget>[
        const Spacer(),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.subtitles),
          onPressed: () => _showSubtitleSourceMenu(controller),
        ),
        MaterialDesktopCustomButton(
          icon: const Icon(Icons.audiotrack),
          onPressed: () => _showTrackMenu(
            controller.audioTracks
                .map((AudioTrack tr) => (
                      label: _trackLabel(tr.title, tr.language, tr.id),
                      onSelected: () => _selectAudioTrack(controller, tr),
                    ))
                .toList(),
          ),
        ),
      ],
    );
  }

  void _showTrackMenu(
    List<({String label, VoidCallback onSelected})> tracks,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      builder: (BuildContext ctx) => ListView(
        shrinkWrap: true,
        children: tracks
            .map((({String label, VoidCallback onSelected}) o) => ListTile(
                  textColor: Colors.white,
                  title: Text(o.label),
                  onTap: () {
                    o.onSelected();
                    Navigator.pop(ctx);
                  },
                ))
            .toList(),
      ),
    );
  }

  /// 弹「字幕源」菜单：枚举当前视频的全部字幕源（内嵌轨 + 同目录外挂文件）+
  /// 顶部「关闭字幕」项。选某源 → 解析成 cue → 切 overlay + 持久化 + SnackBar。
  ///
  /// 这是运行时覆盖；默认 load 行为（自动 sidecar 优先 + 内嵌兜底）不变。
  Future<void> _showSubtitleSourceMenu(
    VideoPlayerController controller,
  ) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return;

    final List<SubtitleSource> sources =
        await listAllSubtitleSources(videoPath, langCode: _targetLangCode);
    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      isScrollControlled: true,
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              ListTile(
                textColor: Colors.white,
                leading: const Icon(Icons.subtitles_off, color: Colors.white),
                title: Text(t.video_subtitle_off),
                selected: _currentSubtitleSource == null,
                selectedColor: Theme.of(ctx).colorScheme.primary,
                onTap: () {
                  Navigator.pop(ctx);
                  _selectSubtitleOff(controller);
                },
              ),
              for (final SubtitleSource source in sources)
                ListTile(
                  textColor: Colors.white,
                  leading: Icon(
                    source.isEmbedded ? Icons.movie : Icons.subtitles,
                    color: Colors.white,
                  ),
                  title: Text(source.label),
                  selected: source.matchesPersisted(_currentSubtitleSource),
                  selectedColor: Theme.of(ctx).colorScheme.primary,
                  onTap: () {
                    Navigator.pop(ctx);
                    _selectSubtitleSource(controller, source);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 选中某字幕源：加载 cue → 切 overlay → 持久化 → SnackBar。
  Future<void> _selectSubtitleSource(
    VideoPlayerController controller,
    SubtitleSource source,
  ) async {
    final String? videoPath = _currentVideoPath;
    if (videoPath == null) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    final List<AudioCue> cues =
        await loadCuesForSource(source, videoPath, widget.bookUid);
    controller.setCues(cues);
    // 选了文本字幕源就关掉 libmpv 画面字幕，避免与可点 overlay 双重渲染。
    await controller.selectSubtitleTrack(SubtitleTrack.no());

    final String persisted = source.toPersistedValue();
    await widget.repo.updateSubtitleSource(widget.bookUid, persisted);
    if (!mounted) return;
    setState(() => _currentSubtitleSource = persisted);
    messenger.showSnackBar(SnackBar(
      content: Text(t.video_subtitle_switched(label: source.label)),
    ));
  }

  /// 关闭字幕：清空 cue overlay + 关 libmpv 字幕轨 + 持久化 null。
  Future<void> _selectSubtitleOff(VideoPlayerController controller) async {
    controller.setCues(const <AudioCue>[]);
    await controller.selectSubtitleTrack(SubtitleTrack.no());
    await widget.repo.updateSubtitleSource(widget.bookUid, null);
    if (!mounted) return;
    setState(() => _currentSubtitleSource = null);
  }

  String _trackLabel(String? title, String? language, String id) {
    if ((title ?? '').isNotEmpty) return title!;
    if ((language ?? '').isNotEmpty) return language!;
    return id;
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    final VideoController? videoController = controller?.videoController;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(_title ?? ''),
        actions: _isPlaylist
            ? <Widget>[
                IconButton(
                  tooltip: t.video_prev_episode,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: _currentEpisode > 0
                      ? () => _switchEpisode(_currentEpisode - 1)
                      : null,
                ),
                IconButton(
                  tooltip: t.video_next_episode,
                  icon: const Icon(Icons.skip_next),
                  onPressed: _currentEpisode < _episodes.length - 1
                      ? () => _switchEpisode(_currentEpisode + 1)
                      : null,
                ),
                IconButton(
                  tooltip: t.video_episode_list,
                  icon: const Icon(Icons.playlist_play),
                  onPressed: _showEpisodeList,
                ),
              ]
            : null,
      ),
      body: _failed
          ? Center(
              child: Icon(Icons.error_outline, color: cs.error, size: 48),
            )
          : (controller == null || videoController == null)
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: MaterialDesktopVideoControlsTheme(
                        normal: _desktopControlsTheme(controller),
                        fullscreen: _desktopControlsTheme(controller),
                        child: Video(
                          controller: videoController,
                          controls: AdaptiveVideoControls,
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: VideoSubtitleOverlay(
                        controller: controller,
                        onCharTap: _lookupAt,
                      ),
                    ),
                  ],
                ),
    );
  }
}
