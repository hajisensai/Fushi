import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:fushi_audio/fushi_audio_core.dart' show decodeTextBytes;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_scroll.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart'
    show pickFilesByExtensions;
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_storage.dart';
import 'package:fushi/src/web_browser/features/extension_host/web_browser_extension_strings.dart';
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
    this.length = 0,
  });

  final String lang;
  final String label;
  final bool pending;
  final String signature;

  /// 轨内句数（懒加载轨未加载时为 0）。
  final int length;
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
          length: _int(t['length']),
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

/// 列表跟随的定位句：在播那句；字幕间隙 / 片头 / 片尾取最近的一句（与扩展 side-panel.js
/// `nearestCueIndex` 同义）。空列表 → -1。
int webBrowserSubtitleNearestIndex(
  List<WebBrowserSubtitleCue> cues,
  int nowMs,
) {
  final int active = webBrowserSubtitleActiveIndex(cues, nowMs);
  if (active >= 0 || cues.isEmpty) return active;
  int lo = 0;
  int hi = cues.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (cues[mid].startMs <= nowMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo == 0) return 0;
  if (lo == cues.length) return lo - 1;
  return nowMs - cues[lo - 1].endMs <= cues[lo].startMs - nowMs ? lo - 1 : lo;
}

/// 偏移读数（秒，带符号，最多两位小数；0 显示 `0`）。与扩展 side-panel.js
/// `formatOffsetSeconds` 同律。
String formatWebBrowserSubtitleOffset(int ms) {
  if (ms == 0) return '0';
  final double sec = (ms / 10).round() / 100;
  if (sec == 0) return '0';
  String abs = sec.abs().toStringAsFixed(2);
  abs = abs.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return '${sec > 0 ? '+' : '-'}$abs';
}

/// 手填偏移（秒）→ 毫秒；写歪 / 超过 1 小时 → null。与扩展 side-panel.js
/// `parseOffsetSeconds` 同律（全角正负号、逗号小数点、`s` / `秒` 后缀都认）。
int? parseWebBrowserSubtitleOffset(String text) {
  final String t = text
      .trim()
      .replaceAll(RegExp('[−－–]'), '-')
      .replaceAll('＋', '+')
      .replaceAll(RegExp('[，,]'), '.')
      .replaceFirst(RegExp(r'\s*(s|秒)$', caseSensitive: false), '');
  if (!RegExp(r'^[+-]?(\d+(\.\d*)?|\.\d+)$').hasMatch(t)) return null;
  final double? v = double.tryParse(t);
  if (v == null || !v.isFinite) return null;
  final int ms = (v * 1000).round();
  if (ms.abs() > 3600 * 1000) return null;
  return ms;
}

/// 侧栏字号档（与扩展 side-panel.js `FONT_STEPS` 同）。
const List<double> kWebBrowserSubtitleFontSteps = <double>[0.85, 1, 1.15, 1.3];

/// 缺省字号档（1.0）。
const int kWebBrowserSubtitleDefaultFontStep = 1;

/// 「列表跟随当前句」：扩展同一个存储键（页内字幕面板 subtitle-panel.js 也读它）。
const String kWebBrowserSubtitleAutoScrollKey = 'subtitleAutoScroll';

/// 侧栏字号档的存储键（扩展 Side Panel 只在会话内记；app 侧栏跨会话记住）。
const String kWebBrowserSubtitleFontStepKey = 'subtitleSidePanelFontStep';

/// 本地字幕文件上限（与扩展 side-panel.js 同：8 MiB）。
const int kWebBrowserSubtitleFileMaxBytes = 8 * 1024 * 1024;

/// 本地字幕文件的扩展名（与扩展 side-panel.html 的 accept 同）。
const Set<String> kWebBrowserSubtitleFileExtensions = <String>{
  'srt',
  'ass',
  'ssa',
  'vtt',
};

/// 选中的一份本地字幕文件。
typedef WebBrowserSubtitleFile = ({String name, Uint8List bytes});

/// 在线字幕来源的展示名（扩展 side-panel.js `SUBTITLE_PROVIDER_LABELS`）；未知 id 原样显示。
String webBrowserSubtitleProviderLabel(Object? id) {
  if (id is! String || id.isEmpty) return '';
  return switch (id) {
    'jimaku' => 'Jimaku',
    'opensubtitles' => 'OpenSubtitles',
    'subdl' => 'SubDL',
    'ajatt' => 'AJATT',
    _ => id,
  };
}

/// app 原生的字幕侧栏（扩展浏览器 Side Panel 的 app 版）：当前视频的整轨字幕列表，
/// 在播那句高亮并跟随（可关；手动翻阅即暂停跟随）；点时间 / 行内空白跳转，点字查词（app
/// 查词弹窗，查词暂停 / 关窗续播走扩展同一份契约）；选轨、时轴偏移（±0.1 / ±0.5 / 手填 /
/// 重置）、加载本地字幕文件、在线字幕搜索、字号、打开浏览器设置。
///
/// 数据与执行全在页面里的扩展脚本（subtitle-panel.js）：发给页面的经 [request]
/// （`fushiSubtitleSidePanel*`，扩展里是 `tabs.sendMessage`），要后台能力的经 [runtime]
/// （`parseSubtitle` / `subtitleSearch` / `subtitleFetch`，扩展里是 `runtime.sendMessage`，
/// app 内落到同一份 [routeWebBrowserExtensionMessage]）。
class WebBrowserSubtitlePanel extends StatefulWidget {
  const WebBrowserSubtitlePanel({
    required this.request,
    required this.onClose,
    super.key,
    this.runtime,
    this.storage,
    this.onOpenSettings,
    this.tabTitle,
    this.pickFiles,
    this.pollInterval = const Duration(milliseconds: 500),
  });

  final Future<Object?> Function(Map<String, Object?> message) request;

  /// 扩展后台消息（null = 没有后台：加载文件 / 在线搜索不可用）。
  final Future<Object?> Function(Map<String, Object?> message)? runtime;

  /// 扩展存储（跟随开关、字号档）。null = 只在本会话内记。
  final WebBrowserExtensionStorage? storage;

  final VoidCallback onClose;

  /// 齿轮：打开浏览器设置（落在字幕组）。null = 不显示齿轮。
  final VoidCallback? onOpenSettings;

  /// 当前标签页标题（在线搜索框预填）。
  final String Function()? tabTitle;

  /// 选本地字幕文件（测试注入；缺省走系统文件选择）。
  final Future<List<WebBrowserSubtitleFile>> Function()? pickFiles;

  final Duration pollInterval;

  @override
  State<WebBrowserSubtitlePanel> createState() =>
      WebBrowserSubtitlePanelState$();
}

/// 侧栏状态（测试经它读）。
class WebBrowserSubtitlePanelState$ extends State<WebBrowserSubtitlePanel> {
  Timer? _poll;
  bool _polling = false;
  bool _connected = true;
  WebBrowserSubtitlePanelState? _state;
  List<WebBrowserSubtitleCue> _cues = const <WebBrowserSubtitleCue>[];
  String? _cueIdentity;
  int _active = -1;
  int _scrollIndex = -1;
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _rowKeys = <int, GlobalKey>{};
  final GlobalKey<SrsNativeLookupRegionState> _lookupRegion =
      GlobalKey<SrsNativeLookupRegionState>();
  SrsCardLookupController? _lookup;

  /// 这次查词是本侧栏发起的：弹窗关掉时回页面续播。
  WebBrowserSubtitleCue? _lookupCue;
  WebBrowserSubtitleCue? _pressedCue;

  /// 跟随当前句（存储里的偏好；手动翻阅只暂停本会话，不改偏好）。
  bool _follow = true;
  int _fontStep = kWebBrowserSubtitleDefaultFontStep;

  final TextEditingController _offsetText = TextEditingController(text: '0');
  final FocusNode _offsetFocus = FocusNode();

  bool _searchOpen = false;
  bool _searching = false;
  final TextEditingController _query = TextEditingController();
  final TextEditingController _episode = TextEditingController();
  final FocusNode _queryFocus = FocusNode();

  /// 在线搜索结果；null = 没在显示。
  List<Map<String, Object?>>? _candidates;
  bool _candidatesTruncated = false;

  @visibleForTesting
  List<WebBrowserSubtitleCue> get cues => _cues;

  @visibleForTesting
  int get activeIndex => _active;

  @visibleForTesting
  bool get following => _follow;

  @visibleForTesting
  double get fontScale => kWebBrowserSubtitleFontSteps[_fontStep];

  static String _x(String key, [Map<String, String>? params]) =>
      WebBrowserExtensionStrings.instance.tr(key, params);

  @override
  void initState() {
    super.initState();
    _readPrefs();
    widget.storage?.addListener(_onStorageChanged);
    _offsetFocus.addListener(_onOffsetFocusChanged);
    if (!WebBrowserExtensionStrings.instance.isLoaded) {
      unawaited(
        WebBrowserExtensionStrings.instance.ensureLoaded().then((_) {
          if (mounted) setState(() {});
        }),
      );
    }
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
  void didUpdateWidget(WebBrowserSubtitlePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.storage, widget.storage)) {
      oldWidget.storage?.removeListener(_onStorageChanged);
      widget.storage?.addListener(_onStorageChanged);
      _readPrefs();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _lookup?.removeListener(_onLookupChanged);
    widget.storage?.removeListener(_onStorageChanged);
    _scroll.dispose();
    _offsetText.dispose();
    _offsetFocus.dispose();
    _query.dispose();
    _episode.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  // ── 偏好（扩展存储）─────────────────────────────────────────────────

  void _readPrefs() {
    final WebBrowserExtensionStorage? storage = widget.storage;
    if (storage == null) return;
    final Map<String, Object?> v = storage.get(<String>[
      kWebBrowserSubtitleAutoScrollKey,
      kWebBrowserSubtitleFontStepKey,
    ]);
    _follow = v[kWebBrowserSubtitleAutoScrollKey] != false;
    final Object? step = v[kWebBrowserSubtitleFontStepKey];
    _fontStep = step is num
        ? step.round().clamp(0, kWebBrowserSubtitleFontSteps.length - 1)
        : kWebBrowserSubtitleDefaultFontStep;
  }

  void _onStorageChanged() {
    if (!mounted) return;
    final bool wasFollowing = _follow;
    setState(_readPrefs);
    if (_follow && !wasFollowing) _followNow();
  }

  void _setFollow(bool on) {
    setState(() => _follow = on);
    if (on) _followNow();
    unawaited(
      widget.storage?.set(<String, Object?>{
        kWebBrowserSubtitleAutoScrollKey: on,
      }),
    );
  }

  /// 用户主动翻阅：暂停跟随（与扩展同：只停本会话，点跟随钮才重新定位）。
  void _pauseFollow() {
    if (!_follow) return;
    setState(() => _follow = false);
  }

  void _followNow() {
    _scrollIndex = -1;
    final WebBrowserSubtitlePanelState? s = _state;
    if (s != null) _updateFollow(s.currentTimeMs);
  }

  void _setFontStep(int step) {
    final int next = step.clamp(0, kWebBrowserSubtitleFontSteps.length - 1);
    if (next == _fontStep) return;
    setState(() => _fontStep = next);
    unawaited(
      widget.storage?.set(<String, Object?>{
        kWebBrowserSubtitleFontStepKey: next,
      }),
    );
  }

  // ── 状态轮询 ─────────────────────────────────────────────────────────

  Future<void> _refresh({bool forceCues = false}) async {
    if (_polling) return;
    _polling = true;
    try {
      final Object? first = await widget.request(<String, Object?>{
        'type': 'fushiSubtitleSidePanelState',
        'includeCues': forceCues || _cueIdentity == null,
      });
      WebBrowserSubtitlePanelState? s = parseWebBrowserSubtitlePanelState(
        first,
      );
      if (s != null && s.cues == null && s.cueIdentity != _cueIdentity) {
        s = parseWebBrowserSubtitlePanelState(
          await widget.request(<String, Object?>{
            'type': 'fushiSubtitleSidePanelState',
            'includeCues': true,
          }),
        );
      }
      if (!mounted) return;
      if (s == null) {
        if (_connected) setState(() => _connected = false);
        return;
      }
      _apply(s);
    } finally {
      _polling = false;
    }
  }

  void _apply(WebBrowserSubtitlePanelState s) {
    setState(() {
      _connected = true;
      _state = s;
      if (s.cues != null) {
        if (s.cueIdentity != _cueIdentity) _scrollIndex = -1;
        _cues = s.cues!;
        _cueIdentity = s.cueIdentity;
        _rowKeys.clear();
      }
      _active = webBrowserSubtitleActiveIndex(_cues, s.currentTimeMs);
      // 正在手填时不打断（状态每 500ms 刷新一次）。
      if (!_offsetFocus.hasFocus) {
        _offsetText.text = formatWebBrowserSubtitleOffset(s.offsetMs);
      }
    });
    _updateFollow(s.currentTimeMs);
  }

  void _updateFollow(int nowMs) {
    if (!_follow) return;
    final int target = webBrowserSubtitleNearestIndex(_cues, nowMs);
    if (target < 0 || target == _scrollIndex) return;
    final bool first = _scrollIndex < 0;
    _scrollIndex = target;
    _scheduleFollow(target, animate: !first);
  }

  void _scheduleFollow(int index, {required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final BuildContext? row = _rowKeys[index]?.currentContext;
      final Duration d = animate
          ? fushiMotionDuration(context, FushiMotion.medium)
          : Duration.zero;
      if (row != null) {
        unawaited(
          FushiFocusScroll.ensureVisible(
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
          unawaited(
            FushiFocusScroll.ensureVisible(
              again,
              alignment: 0.3,
              duration: Duration.zero,
            ),
          );
        }
      });
    });
  }

  Future<WebBrowserSubtitlePanelState?> _send(
    Map<String, Object?> message,
  ) async {
    final WebBrowserSubtitlePanelState? s = parseWebBrowserSubtitlePanelState(
      await widget.request(message),
    );
    if (mounted && s != null) _apply(s);
    return s;
  }

  void _seek(WebBrowserSubtitleCue cue) => unawaited(
    widget.request(<String, Object?>{
      'type': 'fushiSubtitleSidePanelSeek',
      'ms': cue.startMs,
    }),
  );

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(FushiSnackBar(content: Text(message)));
  }

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

  // ── 选轨 / 偏移 ──────────────────────────────────────────────────────

  String _trackLabel(WebBrowserSubtitleTrack track) => track.pending
      ? '${track.label}${_x('sp_track_pending_suffix')}'
      : '${track.label}（${track.length}）';

  Future<void> _pickTrack() async {
    final WebBrowserSubtitlePanelState? s = _state;
    if (s == null || s.tracks.isEmpty) return;
    final String? picked = await showFushiChoiceDialog<String>(
      context: context,
      title: _x('sp_track_aria_label'),
      icon: FushiIcons.subtitles,
      selected: s.activeLang,
      options: <FushiChoiceOption<String>>[
        for (final WebBrowserSubtitleTrack track in s.tracks)
          FushiChoiceOption<String>(
            value: track.lang,
            label: _trackLabel(track),
          ),
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

  void _onOffsetFocusChanged() {
    if (_offsetFocus.hasFocus) {
      _offsetText.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _offsetText.text.length,
      );
    } else {
      unawaited(_commitOffset());
    }
  }

  /// 手填偏移：秒数 = 绝对偏移，0 = 复位；写歪了退回当前值（扩展 `commitOffsetInput`）。
  Future<void> _commitOffset() async {
    final int current = _state?.offsetMs ?? 0;
    final int? ms = parseWebBrowserSubtitleOffset(_offsetText.text);
    if (ms == null) {
      _offsetText.text = formatWebBrowserSubtitleOffset(current);
      return;
    }
    if (ms == current) {
      _offsetText.text = formatWebBrowserSubtitleOffset(current);
      return;
    }
    final WebBrowserSubtitlePanelState? s = await _send(<String, Object?>{
      'type': 'fushiSubtitleSidePanelOffset',
      'absoluteMs': ms,
    });
    if (mounted && !_offsetFocus.hasFocus) {
      _offsetText.text = formatWebBrowserSubtitleOffset(s?.offsetMs ?? ms);
    }
  }

  // ── 本地字幕文件 ─────────────────────────────────────────────────────

  Future<List<WebBrowserSubtitleFile>> _pickSystemFiles() async {
    final FilePickerResult? result = await pickFilesByExtensions(
      context: context,
      allowedExtensions: kWebBrowserSubtitleFileExtensions,
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return const <WebBrowserSubtitleFile>[];
    return <WebBrowserSubtitleFile>[
      for (final PlatformFile f in result.files)
        if (f.bytes != null) (name: f.name, bytes: f.bytes!),
    ];
  }

  Future<void> _loadFiles() async {
    final Future<Object?> Function(Map<String, Object?>)? runtime =
        widget.runtime;
    if (runtime == null) return;
    final List<WebBrowserSubtitleFile> files =
        await (widget.pickFiles ?? _pickSystemFiles)();
    for (final WebBrowserSubtitleFile file in files) {
      if (!mounted) return;
      if (file.bytes.length > kWebBrowserSubtitleFileMaxBytes) {
        _toast(_x('subtitle_file_too_large'));
        continue;
      }
      final String content = await decodeTextBytes(file.bytes);
      final Object? parsed = await runtime(<String, Object?>{
        'type': 'parseSubtitle',
        'filename': file.name,
        'content': content,
      });
      final Object? data = parsed is Map && parsed['ok'] == true
          ? parsed['data']
          : null;
      final Object? cues = data is Map ? data['cues'] : null;
      if (cues is! List) {
        _toast(_x('subtitle_parse_failed_app'));
        continue;
      }
      final WebBrowserSubtitlePanelState? s = await _send(<String, Object?>{
        'type': 'fushiSubtitleSidePanelInstallTrack',
        'filename': file.name,
        'cues': cues,
      });
      if (s != null) {
        _toast(
          _x('subtitle_external_loaded', <String, String>{
            'n': '${cues.length}',
          }),
        );
      }
    }
  }

  // ── 在线字幕 ─────────────────────────────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) _candidates = null;
    });
    if (!_searchOpen) return;
    // 预填当前标签页标题（长显示名命中率低，用户可改成日文原名——占位文案已提示）。
    if (_query.text.isEmpty) {
      final String title = widget.tabTitle?.call().trim() ?? '';
      if (title.isNotEmpty) _query.text = title;
    }
    _queryFocus.requestFocus();
  }

  String _subsErrorText(Object? data, Object? response) {
    final Object? error = data is Map ? data['error'] : null;
    switch (error) {
      case 'no-provider':
        return _x('subs_err_no_provider');
      case 'no-api-key':
        return _x('subs_err_no_api_key');
      case 'unauthorized':
        return _x('subs_err_unauthorized');
      case 'rate-limited':
        return _x('subs_err_rate_limited');
      case 'missing-query':
        return _x('subs_err_missing_query');
    }
    if (response is! Map || response['ok'] != true) {
      return _x('subs_err_search_failed');
    }
    return _x('subs_err_unavailable');
  }

  Future<void> _search() async {
    final Future<Object?> Function(Map<String, Object?>)? runtime =
        widget.runtime;
    if (runtime == null || _searching) return;
    final String query = _query.text.trim();
    if (query.isEmpty) {
      _toast(_x('subs_err_missing_query'));
      return;
    }
    final int? episode = int.tryParse(_episode.text.trim());
    setState(() => _searching = true);
    try {
      final Object? response = await runtime(<String, Object?>{
        'type': 'subtitleSearch',
        'query': query,
        if (episode != null && episode > 0) 'episode': episode,
      });
      if (!mounted) return;
      final Object? data = response is Map ? response['data'] : null;
      if (response is! Map ||
          response['ok'] != true ||
          data is! Map ||
          data['ok'] != true) {
        _toast(_subsErrorText(data, response));
        return;
      }
      final Object? raw = data['candidates'];
      setState(() {
        _candidates = <Map<String, Object?>>[
          if (raw is List)
            for (final Object? c in raw)
              if (c is Map && c['handle'] is String)
                Map<String, Object?>.from(c),
        ];
        _candidatesTruncated = data['truncated'] == true;
      });
      final Object? failures = data['failures'];
      final List<String> failed = <String>[];
      if (failures is List) {
        for (final Object? f in failures) {
          final String name = webBrowserSubtitleProviderLabel(
            f is Map ? f['provider'] : null,
          );
          if (name.isNotEmpty && !failed.contains(name)) failed.add(name);
        }
      }
      if (failed.isNotEmpty) {
        _toast(
          _x('subs_partial_failures', <String, String>{
            'names': failed.join(', '),
          }),
        );
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _install(Map<String, Object?> candidate) async {
    final Future<Object?> Function(Map<String, Object?>)? runtime =
        widget.runtime;
    if (runtime == null) return;
    final String fileName = '${candidate['fileName'] ?? ''}';
    _toast(_x('subs_downloading', <String, String>{'name': fileName}));
    final Object? response = await runtime(<String, Object?>{
      'type': 'subtitleFetch',
      'handle': candidate['handle'],
    });
    if (!mounted) return;
    final Object? data = response is Map ? response['data'] : null;
    final Object? cues = data is Map ? data['cues'] : null;
    if (response is! Map ||
        response['ok'] != true ||
        data is! Map ||
        data['ok'] != true ||
        cues is! List ||
        cues.isEmpty) {
      final Object? error = data is Map ? data['error'] : null;
      _toast(switch (error) {
        'unknown-handle' => _x('subs_err_stale_candidate'),
        'unsupported' => _x('subs_err_unsupported'),
        _ => _subsErrorText(data, response),
      });
      return;
    }
    final WebBrowserSubtitlePanelState? s = await _send(<String, Object?>{
      'type': 'fushiSubtitleSidePanelInstallTrack',
      'filename': data['filename'] is String ? data['filename'] : fileName,
      'cues': cues,
    });
    if (!mounted || s == null) return;
    setState(() => _candidates = null);
    final String provider = webBrowserSubtitleProviderLabel(
      data['provider'] ?? candidate['provider'],
    );
    _toast(
      _x('subs_loaded', <String, String>{
        'provider': provider.isEmpty ? '' : '$provider ',
        'n': '${cues.length}',
      }),
    );
  }

  // ── 界面 ─────────────────────────────────────────────────────────────

  String _statusText() {
    final WebBrowserSubtitlePanelState? s = _state;
    if (!_connected || s == null) return _x('sp_status_not_connected');
    if (!s.hasVideo) return _x('sp_status_no_video');
    return s.tracks.isEmpty
        ? _x('sp_status_waiting_subtitles')
        : _x('sp_status_connected');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    final WebBrowserSubtitlePanelState? s = _state;
    final bool hasTracks = s != null && s.tracks.isNotEmpty;
    final Duration reveal = fushiMotionDuration(context, FushiMotion.short);
    return Material(
      color: FushiDesignTokens.of(context).surfaces.group,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 4, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _x('sp_heading'),
                        style: text.titleMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        _statusText(),
                        key: const ValueKey<String>(
                          'web-browser-subtitle-panel-status',
                        ),
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                FushiIconButtonControl(
                  tooltip: t.floating_dict_close,
                  icon: const Icon(FushiIcons.close),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          _buildToolbar(),
          FushiAnimatedSize(
            duration: reveal,
            curve: FushiMotion.standard,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (hasTracks) _buildTrackButton(s),
                if (_searchOpen) _buildSearch(scheme, text),
                if (hasTracks) _buildOffsetRow(),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildList(scheme, text)),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    final bool hasRuntime = widget.runtime != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          if (hasRuntime)
            FushiIconButtonControl(
              key: const ValueKey<String>('web-browser-subtitle-panel-load'),
              tooltip: _x('sp_load_title'),
              icon: const Icon(FushiIcons.upload),
              onPressed: () => unawaited(_loadFiles()),
            ),
          if (hasRuntime)
            FushiIconButtonControl(
              key: const ValueKey<String>('web-browser-subtitle-panel-search'),
              tooltip: _x('sp_subs_title'),
              isSelected: _searchOpen,
              icon: const Icon(FushiIcons.manageSearch),
              selectedIcon: Icon(FushiIcons.filled(FushiIcons.manageSearch)),
              onPressed: _toggleSearch,
            ),
          FushiIconButtonControl(
            key: const ValueKey<String>('web-browser-subtitle-panel-smaller'),
            tooltip: _x('sp_smaller_title'),
            icon: const Icon(FushiIcons.textDecrease),
            onPressed: _fontStep > 0 ? () => _setFontStep(_fontStep - 1) : null,
          ),
          FushiIconButtonControl(
            key: const ValueKey<String>('web-browser-subtitle-panel-larger'),
            tooltip: _x('sp_larger_title'),
            icon: const Icon(FushiIcons.textIncrease),
            onPressed: _fontStep < kWebBrowserSubtitleFontSteps.length - 1
                ? () => _setFontStep(_fontStep + 1)
                : null,
          ),
          FushiIconButtonControl(
            key: const ValueKey<String>('web-browser-subtitle-panel-follow'),
            tooltip: _x('sp_auto_scroll_title'),
            isSelected: _follow,
            icon: const Icon(FushiIcons.myLocation),
            selectedIcon: Icon(FushiIcons.filled(FushiIcons.myLocation)),
            onPressed: () => _setFollow(!_follow),
          ),
          if (widget.onOpenSettings != null)
            FushiIconButtonControl(
              key: const ValueKey<String>(
                'web-browser-subtitle-panel-settings',
              ),
              tooltip: _x('sp_settings_title'),
              icon: const Icon(FushiIcons.settings),
              onPressed: widget.onOpenSettings,
            ),
        ],
      ),
    );
  }

  Widget _buildTrackButton(WebBrowserSubtitlePanelState s) {
    String label = _x('sp_track_aria_label');
    for (final WebBrowserSubtitleTrack track in s.tracks) {
      if (track.lang == s.activeLang) label = _trackLabel(track);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: FushiOutlinedButton.icon(
        key: const ValueKey<String>('web-browser-subtitle-panel-track'),
        icon: const Icon(FushiIcons.subtitles),
        label: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                semanticsLabel: '${_x('sp_track_aria_label')} $label',
              ),
            ),
            const Icon(FushiIcons.dropDown),
          ],
        ),
        onPressed: _pickTrack,
      ),
    );
  }

  Widget _buildSearch(ColorScheme scheme, TextTheme text) {
    final List<Map<String, Object?>>? candidates = _candidates;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: FushiTextField(
                  key: const ValueKey<String>(
                    'web-browser-subtitle-panel-query',
                  ),
                  controller: _query,
                  focusNode: _queryFocus,
                  size: FushiInputSize.small,
                  hintText: _x('sp_subs_query_placeholder'),
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => unawaited(_search()),
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 72,
                child: FushiTooltip(
                  message: _x('sp_subs_ep_title'),
                  child: FushiTextField(
                    key: const ValueKey<String>(
                      'web-browser-subtitle-panel-episode',
                    ),
                    controller: _episode,
                    size: FushiInputSize.small,
                    hintText: _x('sp_subs_ep_placeholder'),
                    prefixIcon: const Icon(FushiIcons.tag, size: 18),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => unawaited(_search()),
                  ),
                ),
              ),
              FushiIconButtonControl(
                key: const ValueKey<String>('web-browser-subtitle-panel-go'),
                tooltip: _x('sp_subs_go_title'),
                icon: _searching
                    ? const SizedBox.square(
                        dimension: 20,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(FushiIcons.search),
                onPressed: _searching ? null : () => unawaited(_search()),
              ),
            ],
          ),
          if (candidates != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: FushiEntranceScope(
                replayKey: candidates,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 4),
                  children: <Widget>[
                    if (candidates.isEmpty)
                      _notice(_x('subs_no_results'), scheme, text),
                    for (int i = 0; i < candidates.length; i++)
                      FushiStaggeredEntrance(
                        index: i,
                        child: _buildCandidate(candidates[i]),
                      ),
                    if (_candidatesTruncated)
                      _notice(_x('subs_truncated'), scheme, text),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _notice(String message, ColorScheme scheme, TextTheme text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: FushiM3eShape.smallRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(FushiIcons.info, size: 20, color: scheme.onSecondaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: text.bodySmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _buildCandidate(Map<String, Object?> c) {
    final List<String> meta = <String>[
      webBrowserSubtitleProviderLabel(c['provider']),
      if (c['entryName'] is String) c['entryName']! as String,
      if (c['language'] is String) c['language']! as String,
      if (c['episode'] is num)
        _x('subs_episode_label', <String, String>{'n': '${c['episode']}'}),
      if (c['aiTranslated'] == true) _x('subs_machine_translated'),
    ]..removeWhere((String s) => s.isEmpty);
    return FushiListItem(
      density: FushiListDensity.compact,
      title: Text('${c['fileName'] ?? ''}'),
      titleMaxLines: 2,
      subtitle: meta.isEmpty ? null : Text(meta.join(' · ')),
      onTap: () => unawaited(_install(c)),
    );
  }

  Widget _offsetButton(String label, int deltaMs) => FushiTextButton(
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 40),
      padding: const EdgeInsets.symmetric(horizontal: 8),
    ),
    onPressed: () => _nudgeOffset(deltaMs),
    child: Text(label),
  );

  Widget _buildOffsetRow() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    child: FushiTooltip(
      message: t.video_setting_av_delay,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        runSpacing: 2,
        children: <Widget>[
          _offsetButton('−0.5', -500),
          _offsetButton('−0.1', -100),
          SizedBox(
            width: 72,
            child: FushiTextField(
              key: const ValueKey<String>('web-browser-subtitle-panel-offset'),
              controller: _offsetText,
              focusNode: _offsetFocus,
              size: FushiInputSize.small,
              keyboardType: const TextInputType.numberWithOptions(
                signed: true,
                decimal: true,
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _offsetFocus.unfocus(),
            ),
          ),
          _offsetButton('+0.1', 100),
          _offsetButton('+0.5', 500),
          FushiIconButtonControl(
            key: const ValueKey<String>(
              'web-browser-subtitle-panel-offset-reset',
            ),
            tooltip: _x('sp_offset_reset_title'),
            icon: const Icon(FushiIcons.restart),
            onPressed: _resetOffset,
          ),
        ],
      ),
    ),
  );

  Widget _buildList(ColorScheme scheme, TextTheme text) {
    if (_cues.isEmpty) {
      final WebBrowserSubtitlePanelState? s = _state;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _x(
              s == null || s.hasVideo
                  ? 'sp_empty_no_subtitles'
                  : 'sp_empty_no_video',
            ),
            style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    // 用户主动翻阅（拖动 / 滚轮）即暂停跟随；程序滚动（跟随本身）没有 dragDetails。
    return Listener(
      onPointerSignal: (PointerSignalEvent e) {
        if (e is PointerScrollEvent) _pauseFollow();
      },
      child: NotificationListener<ScrollStartNotification>(
        onNotification: (ScrollStartNotification n) {
          if (n.dragDetails != null) _pauseFollow();
          return false;
        },
        child: FushiEntranceScope(
          replayKey: _cueIdentity,
          child: SrsNativeLookupRegion(
            key: _lookupRegion,
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
    final TextStyle? base = text.bodyLarge;
    final double scale = kWebBrowserSubtitleFontSteps[_fontStep];
    return AnimatedContainer(
      key: key,
      duration: fushiMotionDuration(context, FushiMotion.short),
      curve: FushiMotion.standard,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: active ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: FushiM3eShape.smallRadius,
      ),
      // 点行内空白 = 跳到这句；点到字（取词表面已用掉这一下）只查词不跳。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (_lookupRegion.currentState?.tookTap ?? false) return;
          _seek(cue);
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            FushiTextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(64, 48),
                foregroundColor: active
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
              onPressed: () => _seek(cue),
              child: Text(
                _clock(cue.startMs),
                semanticsLabel:
                    '${_x('sp_row_seek_title')} '
                    '${_clock(cue.startMs)}',
                style: text.labelMedium?.copyWith(
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
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
                      style: base?.copyWith(
                        fontSize: (base.fontSize ?? 16) * scale,
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
      ),
    );
  }

  static String _clock(int ms) {
    final int total = (ms / 1000).floor().clamp(0, 1 << 31);
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
