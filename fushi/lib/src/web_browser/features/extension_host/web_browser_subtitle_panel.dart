import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 侧栏一条字幕。
@immutable
class WebBrowserSubtitleCue {
  const WebBrowserSubtitleCue({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;

  /// 侧栏把它交回页面（查词暂停 / 制卡精确窗）时的形状，与扩展 side-panel.js 同。
  Map<String, Object?> toJson() => <String, Object?>{
    'startMs': startMs,
    'endMs': endMs,
    'text': text,
  };
}

/// 一条字幕轨（`fushiSubtitleSidePanelState.tracks[]`）。
@immutable
class WebBrowserSubtitleTrack {
  const WebBrowserSubtitleTrack({
    required this.lang,
    required this.label,
    required this.pending,
    required this.signature,
  });

  final String lang;
  final String label;
  final bool pending;
  final String signature;
}

/// 页面回报的侧栏状态（扩展 subtitle-panel.js `sidePanelState` 的形状）。
@immutable
class WebBrowserSubtitlePanelState {
  const WebBrowserSubtitlePanelState({
    required this.videoKey,
    required this.hasVideo,
    required this.activeLang,
    required this.currentTimeMs,
    required this.offsetMs,
    required this.tracks,
    required this.cues,
  });

  final String videoKey;
  final bool hasVideo;
  final String? activeLang;
  final int currentTimeMs;
  final int offsetMs;
  final List<WebBrowserSubtitleTrack> tracks;

  /// null = 这次没带 cue（只取了状态）。
  final List<WebBrowserSubtitleCue>? cues;

  /// 活动轨的身份（换视频 / 换轨 / 改偏移 / 轨内容变了都会变）：变了就重取 cue。
  String get cueIdentity {
    String signature = '';
    for (final WebBrowserSubtitleTrack t in tracks) {
      if (t.lang == activeLang) signature = t.signature;
    }
    return '$videoKey|$activeLang|$offsetMs|$signature';
  }
}

int _int(Object? v) => v is num ? v.round() : 0;

/// 解析页面回报；形状不对 → null。
WebBrowserSubtitlePanelState? parseWebBrowserSubtitlePanelState(Object? raw) {
  if (raw is! Map || raw['ok'] != true) return null;
  final List<WebBrowserSubtitleTrack> tracks = <WebBrowserSubtitleTrack>[];
  final Object? rawTracks = raw['tracks'];
  if (rawTracks is List) {
    for (final Object? t in rawTracks) {
      if (t is! Map || t['lang'] is! String) continue;
      final String lang = t['lang'] as String;
      tracks.add(
        WebBrowserSubtitleTrack(
          lang: lang,
          label: t['label'] is String && (t['label'] as String).isNotEmpty
              ? t['label'] as String
              : lang,
          pending: t['pending'] == true,
          signature: '${t['signature'] ?? ''}',
        ),
      );
    }
  }
  List<WebBrowserSubtitleCue>? cues;
  final Object? rawCues = raw['cues'];
  if (rawCues is List) {
    cues = <WebBrowserSubtitleCue>[
      for (final Object? c in rawCues)
        if (c is Map && c['text'] is String)
          WebBrowserSubtitleCue(
            startMs: _int(c['startMs']),
            endMs: _int(c['endMs']),
            text: c['text'] as String,
          ),
    ];
  }
  return WebBrowserSubtitlePanelState(
    videoKey: '${raw['videoKey'] ?? ''}',
    hasVideo: raw['hasVideo'] == true,
    activeLang: raw['activeLang'] is String
        ? raw['activeLang'] as String
        : null,
    currentTimeMs: _int(raw['currentTimeMs']),
    offsetMs: _int(raw['offsetMs']),
    tracks: tracks,
    cues: cues,
  );
}

/// [cues] 里此刻在播的那句（没有 → -1）。
int webBrowserSubtitleActiveIndex(List<WebBrowserSubtitleCue> cues, int nowMs) {
  int lo = 0;
  int hi = cues.length - 1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    final WebBrowserSubtitleCue c = cues[mid];
    if (nowMs < c.startMs) {
      hi = mid - 1;
    } else if (nowMs >= c.endMs) {
      lo = mid + 1;
    } else {
      return mid;
    }
  }
  return -1;
}

/// app 原生的字幕侧栏（扩展浏览器 Side Panel 的 app 版）：当前视频的整轨字幕列表，
/// 在播那句高亮并跟随；点时间跳转，点字查词（app 查词弹窗，查词暂停 / 关窗续播走扩展同一份
/// 契约）；选轨、时轴偏移。数据与执行全在页面里的扩展脚本（subtitle-panel.js），这里只经
/// [request] 发 `fushiSubtitleSidePanel*` 消息。
class WebBrowserSubtitlePanel extends StatefulWidget {
  const WebBrowserSubtitlePanel({
    required this.request,
    required this.onClose,
    super.key,
    this.pollInterval = const Duration(milliseconds: 500),
  });

  final Future<Object?> Function(Map<String, Object?> message) request;
  final VoidCallback onClose;
  final Duration pollInterval;

  @override
  State<WebBrowserSubtitlePanel> createState() =>
      WebBrowserSubtitlePanelState$();
}

/// 侧栏状态（测试经它读）。
class WebBrowserSubtitlePanelState$ extends State<WebBrowserSubtitlePanel> {
  Timer? _poll;
  bool _polling = false;
  WebBrowserSubtitlePanelState? _state;
  List<WebBrowserSubtitleCue> _cues = const <WebBrowserSubtitleCue>[];
  String? _cueIdentity;
  int _active = -1;
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};
  SrsCardLookupController? _lookup;

  /// 这次查词是本侧栏发起的：弹窗关掉时回页面续播。
  WebBrowserSubtitleCue? _lookupCue;
  WebBrowserSubtitleCue? _pressedCue;

  @visibleForTesting
  List<WebBrowserSubtitleCue> get cues => _cues;

  @visibleForTesting
  int get activeIndex => _active;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(widget.pollInterval, (_) => unawaited(_refresh()));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final SrsCardLookupController? next = SrsCardLookupScope.of(context);
    if (!identical(next, _lookup)) {
      _lookup?.removeListener(_onLookupChanged);
      _lookup = next;
      next?.addListener(_onLookupChanged);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lookup?.removeListener(_onLookupChanged);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool forceCues = false}) async {
    if (_polling) return;
    _polling = true;
    try {
      WebBrowserSubtitlePanelState? s = parseWebBrowserSubtitlePanelState(
        await widget.request(<String, Object?>{
          'type': 'fushiSubtitleSidePanelState',
          'includeCues': forceCues || _cueIdentity == null,
        }),
      );
      if (s != null && s.cues == null && s.cueIdentity != _cueIdentity) {
        s = parseWebBrowserSubtitlePanelState(
          await widget.request(<String, Object?>{
            'type': 'fushiSubtitleSidePanelState',
            'includeCues': true,
          }),
        );
      }
      if (!mounted || s == null) return;
      _apply(s);
    } finally {
      _polling = false;
    }
  }

  void _apply(WebBrowserSubtitlePanelState s) {
    setState(() {
      _state = s;
      if (s.cues != null) {
        _cues = s.cues!;
        _cueIdentity = s.cueIdentity;
        _rowKeys.clear();
      }
      final int next = webBrowserSubtitleActiveIndex(_cues, s.currentTimeMs);
      if (next != _active) {
        _active = next;
        if (next >= 0) _scheduleFollow(next);
      }
    });
  }

  void _scheduleFollow(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final BuildContext? row = _rowKeys[index]?.currentContext;
      final Duration d = fushiMotionDuration(context, FushiMotion.medium);
      if (row != null) {
        unawaited(
          Scrollable.ensureVisible(
            row,
            alignment: 0.3,
            duration: d,
            curve: FushiMotion.standard,
          ),
        );
        return;
      }
      // 还没建出来的行：先按平均行高大致跳过去，下一帧再精确对齐。
      final double approx = (index * 56.0).clamp(
        0,
        _scroll.position.maxScrollExtent,
      );
      _scroll.jumpTo(approx);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final BuildContext? again = _rowKeys[index]?.currentContext;
        if (again != null && mounted) {
          unawaited(Scrollable.ensureVisible(again, alignment: 0.3));
        }
      });
    });
  }

  Future<void> _send(Map<String, Object?> message) async {
    final WebBrowserSubtitlePanelState? s = parseWebBrowserSubtitlePanelState(
      await widget.request(message),
    );
    if (mounted && s != null) _apply(s);
  }

  void _seek(WebBrowserSubtitleCue cue) => unawaited(
    widget.request(<String, Object?>{
      'type': 'fushiSubtitleSidePanelSeek',
      'ms': cue.startMs,
    }),
  );

  // 查词：点字由 [SrsNativeLookupRegion] 交给同一个查词控制器；这里只认「这次是侧栏发起的」，
  // 弹窗出现时让页面按「查词时暂停」停视频、弹窗关掉时续播（扩展 Side Panel 同一份消息）。
  void _onLookupChanged() {
    final SrsCardLookupController? c = _lookup;
    if (c == null) return;
    if (c.isOpen) {
      final WebBrowserSubtitleCue? cue = _pressedCue;
      _pressedCue = null;
      if (cue != null && _lookupCue == null) {
        _lookupCue = cue;
        unawaited(
          widget.request(<String, Object?>{
            'type': 'fushiSubtitleSidePanelPrepareLookup',
            'cue': cue.toJson(),
          }),
        );
      }
    } else if (_lookupCue != null) {
      _lookupCue = null;
      unawaited(
        widget.request(<String, Object?>{
          'type': 'fushiSubtitleSidePanelLookupClosed',
        }),
      );
    }
  }

  Future<void> _pickTrack() async {
    final WebBrowserSubtitlePanelState? s = _state;
    if (s == null || s.tracks.isEmpty) return;
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: t.video_menu_subtitle_track,
      icon: FushiIcons.subtitles,
      selected: s.activeLang,
      options: <FushiChoiceOption<String>>[
        for (final WebBrowserSubtitleTrack track in s.tracks)
          FushiChoiceOption<String>(value: track.lang, label: track.label),
      ],
    );
    if (picked == null || picked == s.activeLang) return;
    await _send(<String, Object?>{
      'type': 'fushiSubtitleSidePanelSelectTrack',
      'lang': picked,
    });
  }

  void _nudgeOffset(int deltaMs) => unawaited(
    _send(<String, Object?>{
      'type': 'fushiSubtitleSidePanelOffset',
      'deltaMs': deltaMs,
    }),
  );

  void _resetOffset() => unawaited(
    _send(<String, Object?>{
      'type': 'fushiSubtitleSidePanelOffset',
      'reset': true,
    }),
  );

  static String _clock(int ms) {
    final int total = (ms / 1000).floor().clamp(0, 1 << 31);
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  static String _offsetLabel(int ms) {
    final String v = (ms / 1000).toStringAsFixed(1);
    return ms > 0 ? '+${v}s' : '${v}s';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final WebBrowserSubtitlePanelState? s = _state;
    String trackLabel = t.video_remote_transcript_empty;
    if (s != null) {
      for (final WebBrowserSubtitleTrack track in s.tracks) {
        if (track.lang == s.activeLang) trackLabel = track.label;
      }
    }
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t.video_control_subtitle_list,
                    style: text.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: t.floating_dict_close,
                  icon: const Icon(FushiIcons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: <Widget>[
                TextButton.icon(
                  icon: const Icon(FushiIcons.subtitles),
                  label: Text(trackLabel, overflow: TextOverflow.ellipsis),
                  onPressed: s == null || s.tracks.isEmpty ? null : _pickTrack,
                ),
                Tooltip(
                  message: t.video_setting_av_delay,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(FushiIcons.remove),
                        onPressed: s == null ? null : () => _nudgeOffset(-100),
                      ),
                      TextButton(
                        onPressed: s == null ? null : _resetOffset,
                        child: Text(
                          _offsetLabel(s?.offsetMs ?? 0),
                          semanticsLabel:
                              '${t.video_setting_av_delay} ${_offsetLabel(s?.offsetMs ?? 0)}',
                        ),
                      ),
                      IconButton(
                        icon: const Icon(FushiIcons.add),
                        onPressed: s == null ? null : () => _nudgeOffset(100),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _cues.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        t.video_remote_transcript_empty,
                        style: text.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : FushiEntranceScope(
                    replayKey: _cueIdentity,
                    child: SrsNativeLookupRegion(
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _cues.length,
                        itemBuilder: fushiStaggeredItemBuilder(
                          (BuildContext context, int i) =>
                              _buildRow(context, i, scheme, text),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(
    BuildContext context,
    int i,
    ColorScheme scheme,
    TextTheme text,
  ) {
    final WebBrowserSubtitleCue cue = _cues[i];
    final bool active = i == _active;
    final GlobalKey key = _rowKeys.putIfAbsent(i, GlobalKey.new);
    return AnimatedContainer(
      key: key,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: active ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(64, 48),
              foregroundColor: active
                  ? scheme.onSecondaryContainer
                  : scheme.onSurfaceVariant,
            ),
            onPressed: () => _seek(cue),
            child: Text(
              _clock(cue.startMs),
              style: text.labelMedium?.copyWith(
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Listener(
              onPointerDown: (_) => _pressedCue = cue,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(4, 12, 12, 12),
                child: srsLookupText(
                  text: cue.text,
                  child: Text(
                    cue.text,
                    style: text.bodyLarge?.copyWith(
                      color: active
                          ? scheme.onSecondaryContainer
                          : scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
