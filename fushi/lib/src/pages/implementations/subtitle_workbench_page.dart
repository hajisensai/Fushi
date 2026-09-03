/// 字幕工作台：**全屏页面**，取代原来的字幕下载弹窗。两个作用域：
/// - 本集：[SubtitleSearchPanel]（搜索 → 版本组/文件 → 下载一个 → 回给播放页应用）；
/// - 整个合集：[SubtitleCollectionPanel]（绑定系列 → 挑来源 → 逐集批量下载 + 合集级
///   语言/版本配置）。
///
/// 页面本身只是「AppBar + 作用域开关 + 面板」的壳，搜索/批量状态机各自只有一份
/// （面板文件）。播放页、媒体库右键、合集详情页三处入口都推这一页。
library;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'package:fushi/src/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/subtitle_collection_panel.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

enum SubtitleWorkbenchScope { episode, collection }

/// 「本集」作用域的输入：搜索种子 + 记忆键。
class SubtitleEpisodeSearchSpec {
  const SubtitleEpisodeSearchSpec({
    required this.initialQuery,
    required this.seriesKey,
    this.seed = const SubtitleSearchSeed(),
    this.videoPath,
  });

  /// 预填搜索词（文件名解析出的番名 / 刮削名）。
  final String initialQuery;

  /// 语言记忆键（番名小写 trim，与 prefs `jimaku_pref_langs` 约定一致）。
  final String seriesKey;

  /// 身份种子（AniList/TMDB id + 日文原名）。
  final SubtitleSearchSeed seed;

  /// 本地视频路径（OSDb 指纹用；远端流 null）。
  final String? videoPath;
}

/// 「整个合集」作用域的输入。
class SubtitleCollectionSpec {
  const SubtitleCollectionSpec({
    required this.collection,
    required this.members,
  });

  final MediaCollectionRow collection;

  /// 合集里**有序**的视频成员。
  final List<VideoBookRow> members;

  /// 语言记忆键（合集名小写 trim，与批量对话框约定一致）。
  String get seriesKey => collection.name.trim().toLowerCase();
}

/// 工作台依赖的宿主能力（全部可注入，便于 widget 测试不碰 AppModel）。
abstract interface class SubtitleWorkbenchHost {
  VideoSubtitleRegistry? get subtitleRegistry;
  String get jimakuApiKey;
  Future<void> setJimakuApiKey(String key);
  Future<http.Client> createHttpClient();
  String? preferredLanguageFor(String seriesKey);
  Future<void> setPreferredLanguage(String seriesKey, String langCode);
  String? get defaultContentLanguage;
  FushiDatabase get database;
  Future<void> persistRemoteSubtitle(String bookUid, String path);
}

/// 生产宿主：全部转发到 [AppModel]。
class AppSubtitleWorkbenchHost implements SubtitleWorkbenchHost {
  const AppSubtitleWorkbenchHost(this.appModel);

  final AppModel appModel;

  @override
  VideoSubtitleRegistry? get subtitleRegistry => appModel.videoSubtitleRegistry;

  @override
  String get jimakuApiKey => appModel.jimakuApiKey;

  @override
  Future<void> setJimakuApiKey(String key) => appModel.setJimakuApiKey(key);

  @override
  Future<http.Client> createHttpClient() => appModel.createDownloadHttpClient();

  /// 该系列没有记忆时兜底设置页的默认字幕语言（`''` = 跟随视频语言 → null）。
  @override
  String? preferredLanguageFor(String seriesKey) =>
      appModel.jimakuPreferredLanguages[seriesKey] ??
      appModel.jimakuDefaultLanguageOrNull;

  @override
  Future<void> setPreferredLanguage(String seriesKey, String langCode) =>
      appModel.setJimakuPreferredLanguage(seriesKey, langCode);

  @override
  String? get defaultContentLanguage {
    final String value = appModel.prefsRepo.defaultContentLanguage.trim();
    return value.isEmpty ? null : value;
  }

  @override
  FushiDatabase get database => appModel.database;

  /// 远端/流媒体集：episodeIndex 0 = 该 stream book 自身。
  @override
  Future<void> persistRemoteSubtitle(String bookUid, String path) =>
      appModel.setRemoteSubtitleSource(bookUid, 0, path);
}

class SubtitleWorkbenchPage extends StatefulWidget {
  const SubtitleWorkbenchPage({
    required this.host,
    required this.saveDirectory,
    this.episode,
    this.collection,
    this.initialScope = SubtitleWorkbenchScope.episode,
    super.key,
  }) : assert(episode != null || collection != null);

  final SubtitleWorkbenchHost host;

  /// 下载字幕保存目录（绝对路径，调用方已 `AppPaths.videoSubtitlesDirectory()`）。
  final String saveDirectory;

  /// null = 没有「本集」上下文（媒体库/合集页入口）。
  final SubtitleEpisodeSearchSpec? episode;

  /// null = 当前视频不属于任何合集。
  final SubtitleCollectionSpec? collection;

  final SubtitleWorkbenchScope initialScope;

  /// 推整页路由。返回「本集」作用域下载落盘的字幕绝对路径（用户直接返回为 null）。
  ///
  /// `fullscreenDialog` + root navigator：播放页全屏态自建的路由在 root 上，工作台
  /// 必须盖在它之上；关闭后由调用方归还播放器焦点。
  static Future<String?> open(
    BuildContext context, {
    required SubtitleWorkbenchHost host,
    required String saveDirectory,
    SubtitleEpisodeSearchSpec? episode,
    SubtitleCollectionSpec? collection,
    SubtitleWorkbenchScope initialScope = SubtitleWorkbenchScope.episode,
  }) {
    return Navigator.of(context, rootNavigator: true).push<String>(
      MaterialPageRoute<String>(
        fullscreenDialog: true,
        builder: (_) => SubtitleWorkbenchPage(
          host: host,
          saveDirectory: saveDirectory,
          episode: episode,
          collection: collection,
          initialScope: initialScope,
        ),
      ),
    );
  }

  @override
  State<SubtitleWorkbenchPage> createState() => _SubtitleWorkbenchPageState();
}

class _SubtitleWorkbenchPageState extends State<SubtitleWorkbenchPage> {
  late SubtitleWorkbenchScope _scope = _resolveInitialScope();

  SubtitleWorkbenchScope _resolveInitialScope() {
    if (widget.episode == null) return SubtitleWorkbenchScope.collection;
    if (widget.collection == null) return SubtitleWorkbenchScope.episode;
    return widget.initialScope;
  }

  bool get _canSwitchScope =>
      widget.episode != null && widget.collection != null;

  Widget _buildEpisodePanel() {
    final SubtitleEpisodeSearchSpec spec = widget.episode!;
    final SubtitleWorkbenchHost host = widget.host;
    return SubtitleSearchPanel(
      key: const ValueKey<String>('subtitle-workbench-episode'),
      showTitle: false,
      seed: spec.seed,
      videoPath: spec.videoPath,
      initialQuery: spec.initialQuery,
      initialApiKey: host.jimakuApiKey,
      onApiKeyChanged: host.setJimakuApiKey,
      subtitleRegistry: () => host.subtitleRegistry,
      saveDirectory: widget.saveDirectory,
      httpClientFactory: host.createHttpClient,
      initialPreferredLanguage: host.preferredLanguageFor(spec.seriesKey),
      onPreferredLanguageChanged: (String lang) =>
          host.setPreferredLanguage(spec.seriesKey, lang),
      onDownloaded: (String path) => Navigator.of(context).pop(path),
    );
  }

  Widget _buildCollectionPanel() {
    final SubtitleCollectionSpec spec = widget.collection!;
    final SubtitleWorkbenchHost host = widget.host;
    return SubtitleCollectionPanel(
      key: const ValueKey<String>('subtitle-workbench-collection'),
      showTitle: false,
      database: host.database,
      collection: spec.collection,
      members: spec.members,
      subtitleRegistry: () => host.subtitleRegistry,
      initialApiKey: host.jimakuApiKey,
      onApiKeyChanged: host.setJimakuApiKey,
      saveDirectory: widget.saveDirectory,
      httpClientFactory: host.createHttpClient,
      initialPreferredLanguage: host.preferredLanguageFor(spec.seriesKey),
      onPreferredLanguageChanged: (String lang) =>
          host.setPreferredLanguage(spec.seriesKey, lang),
      globalDefaultContentLanguage: host.defaultContentLanguage,
      onRemoteSubtitlePersist: host.persistRemoteSubtitle,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget panel = _scope == SubtitleWorkbenchScope.episode
        ? _buildEpisodePanel()
        : _buildCollectionPanel();
    return Scaffold(
      appBar: AppBar(
        title: Text(t.video_subtitle_workbench_title),
        // 作用域开关与标题**同一行**。原来它挂在 `AppBar.bottom` 上独占 56px：
        // 标题行右侧整条空着，开关与面板之间又多一截死白。
        //
        // 开关**只放图标、文案落 tooltip**。`AppBar.actions` 不给子级任何宽度上界，
        // 带文字标签的分段开关按自身固有宽度摊开，宽度随译文长度走：实测
        // zh 220.8px / ru 474.6px / de 502.8px / en 559.2px / fr 643.8px，360 宽
        // 的手机上后四种当场 `RenderFlex overflowed by 127~296 pixels`、标题被压成
        // 0 宽（zh 只是压到 44px，所以只按中文验会整批漏掉）。按屏宽设阈值挡不住：
        // 「放不放得下」同时取决于宽度、语言和字体，一个常量在任一维度上都必然选错。
        // 去掉文字标签，这三个变量一起消失——图标宽度是常量，再窄也不会溢出。
        actions: <Widget>[
          if (_canSwitchScope)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: SegmentedButton<SubtitleWorkbenchScope>(
                  key: const ValueKey<String>('subtitle-workbench-scope'),
                  showSelectedIcon: false,
                  segments: <ButtonSegment<SubtitleWorkbenchScope>>[
                    ButtonSegment<SubtitleWorkbenchScope>(
                      value: SubtitleWorkbenchScope.episode,
                      icon: const Icon(Icons.subtitles_outlined),
                      tooltip: t.video_subtitle_scope_episode,
                    ),
                    ButtonSegment<SubtitleWorkbenchScope>(
                      value: SubtitleWorkbenchScope.collection,
                      icon: const Icon(Icons.video_library_outlined),
                      tooltip: t.video_subtitle_scope_collection,
                    ),
                  ],
                  selected: <SubtitleWorkbenchScope>{_scope},
                  onSelectionChanged: (Set<SubtitleWorkbenchScope> value) =>
                      setState(() => _scope = value.first),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: panel,
        ),
      ),
    );
  }
}
