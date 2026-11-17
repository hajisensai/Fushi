import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;

import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi/src/media/video/anilist_client.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/pages/implementations/subtitle_search_panel.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

// 搜索状态机、候选投影（[JimakuCandidate]）、纯函数与列表 widget 全在
// subtitle_search_panel.dart；本文件只剩对话框外壳。存量调用方/测试仍从这里 import。
export 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart'
    show SubtitleSearchSeed, buildSubtitleSearchSeed;
export 'package:fushi/src/pages/implementations/subtitle_search_panel.dart';

/// 「自动获取字幕」**对话框壳**：[FushiDialogFrame] 包一层 [SubtitleSearchPanel]，
/// 下载成功 `pop` 回本地路径、取消 `pop` null。多选下载部分失败时面板留着显示原因
/// （BUG-4802），此后点「取消」带回已落盘的第一条。
///
/// 播放页/库页已改走全屏 `SubtitleWorkbenchPage`；本壳保留给仍以对话框形态调起的
/// 调用方与既有 widget 测试（两栏布局 / 滚动 / 路径穿越 / registry 接线等）。
class JimakuSubtitleDialog extends StatefulWidget {
  const JimakuSubtitleDialog({
    required this.initialQuery,
    required this.initialApiKey,
    required this.onApiKeyChanged,
    required this.saveDirectory,
    this.subtitleRegistry,
    this.initialPreferredLanguage,
    this.onPreferredLanguageChanged,
    this.httpClientFactory,
    this.seed = const SubtitleSearchSeed(),
    this.videoPath,
    this.initialSeason,
    this.debugInitialCandidates,
    this.debugInitialSeriesMatches,
    this.debugInitialSeriesLookupFailed = false,
    super.key,
  });

  final Future<VideoSubtitleRegistry?> Function()? subtitleRegistry;
  final String initialQuery;
  final SubtitleSearchSeed seed;
  final String? videoPath;

  /// 见 [SubtitleSearchPanel.initialSeason]。
  final int? initialSeason;
  final String initialApiKey;
  final Future<void> Function(String key) onApiKeyChanged;
  final String saveDirectory;
  final String? initialPreferredLanguage;
  final Future<void> Function(String langCode)? onPreferredLanguageChanged;
  final Future<http.Client> Function()? httpClientFactory;
  @visibleForTesting
  final List<JimakuCandidate>? debugInitialCandidates;
  @visibleForTesting
  final List<AniListMedia>? debugInitialSeriesMatches;
  @visibleForTesting
  final bool debugInitialSeriesLookupFailed;

  @override
  State<JimakuSubtitleDialog> createState() => _JimakuSubtitleDialogState();
}

class _JimakuSubtitleDialogState extends State<JimakuSubtitleDialog> {
  /// 多选下载已落盘、但面板没主动关页的路径（部分失败后留在面板里），按落盘顺序。
  final List<String> _savedWhileOpen = <String>[];

  @override
  Widget build(BuildContext context) {
    final double viewportWidth = MediaQuery.sizeOf(context).width;
    // scrollable:false：由 maxHeight 给整个对话框有界高度天花板，面板里的 Flexible
    // 才能正确分到剩余空间（BUG-279 不变量）；宽度按视口取 90%/94%/手机安全边距
    // （BUG-1509 后续）。
    return FushiDialogFrame(
      maxWidth: resolveJimakuDialogMaxWidth(viewportWidth),
      maxHeightFactor: 0.92,
      scrollable: false,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: SubtitleSearchPanel(
        initialQuery: widget.initialQuery,
        initialApiKey: widget.initialApiKey,
        onApiKeyChanged: widget.onApiKeyChanged,
        saveDirectory: widget.saveDirectory,
        subtitleRegistry: widget.subtitleRegistry,
        initialPreferredLanguage: widget.initialPreferredLanguage,
        onPreferredLanguageChanged: widget.onPreferredLanguageChanged,
        httpClientFactory: widget.httpClientFactory,
        seed: widget.seed,
        videoPath: widget.videoPath,
        initialSeason: widget.initialSeason,
        debugInitialCandidates: widget.debugInitialCandidates,
        debugInitialSeriesMatches: widget.debugInitialSeriesMatches,
        debugInitialSeriesLookupFailed: widget.debugInitialSeriesLookupFailed,
        // 这个存量对话框壳仍是单值出口（调用方只应用一条）：多选下载时
        // 取第一条，其余已落盘、由字幕轨列表承载。
        onDownloaded: (List<String> paths) =>
            Navigator.pop(context, paths.isEmpty ? null : paths.first),
        onSubtitleSaved: _savedWhileOpen.add,
        onCancel: () => Navigator.pop(
          context,
          _savedWhileOpen.isEmpty ? null : _savedWhileOpen.first,
        ),
      ),
    );
  }
}
