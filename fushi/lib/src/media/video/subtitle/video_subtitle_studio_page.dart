/// 「字幕工作台」**全屏页面**（反馈 E1pq561P2q，维护者批示：把「自动生成字幕」那块改成
/// 工作台样式，带各种可参考信息与开关；2026-11-17 维护者：工作台应该是全屏的、更专业）。
///
/// 宽屏两栏、窄屏上下排。一栏是**参考**：当前画面（换句时自动重截）、当前字幕的语言、
/// **整条**主字幕的逐句表格（序号、起点时间码、时长、正文、同一时刻的其它语言字幕）——
/// 表格跟随播放头滚动（用户自己滚就停，点「跟随播放」恢复），点某句跳过去。另一栏先是
/// **交给 AI 的参考**（spec
/// `2026-11-11-video-subtitle-ai-reference`）：上面这两样不只给人看——「生成字幕」开着
/// AI 校对时，画面（开关，首次说明会发送什么）与其它语言字幕会真的交给 AI。下半是**工具**：生成字幕（原入口，管线 / 本机
/// 转录分流不变）、拆出双语字幕中的日语、按每句语音逐句对轴（模型重定时）、按内嵌
/// 字幕对齐。
///
/// 音乐歌词也进这一页（[VideoSubtitleStudioToolset.music]，拍板台 niQk_Ns4OV）：参考区是
/// 歌词逐行表格，工具是生成字幕与纯文本歌词自动对时，对时结果可在表格里逐行把起点设成
/// 播放头（[VideoSubtitleStudioActions.setCueStart]）。
///
/// 面板只渲染与分派：每个工具都是视频页注入的回调（编排、落盘、换轨、OSD 都在视频
/// 页既有路径里），点了先关面板再跑，跑的过程照旧由视频页提示。ASR / 重定时算法在
/// 上游 `fushi-subtitles`，双语拆分是 `fushi_engine` 的纯函数。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

/// 参考区的数据源。全部是**读取函数**而不是快照：面板开着时视频照常播，
/// [listenable]（播放位置推送）一响就按当前值重算对照表。
class VideoSubtitleStudioReference {
  const VideoSubtitleStudioReference({
    required this.listenable,
    required this.primaryCues,
    required this.secondaryCues,
    required this.primaryPositionMs,
    required this.secondaryPositionMs,
    required this.primaryLanguage,
    this.captureFrame,
    this.jumpToCue,
    this.notice,
    this.noticeListenable,
  });

  /// 播放位置变化的推送源（视频页给 `positionMsListenable`）。
  final Listenable listenable;

  /// 当前主字幕轨的 cue（文本轨；图形字幕没有 cue）。
  final List<AudioCue> Function() primaryCues;

  /// 当前副字幕轨（其它语言字幕）的 cue；没选副字幕时为空。
  final List<AudioCue> Function() secondaryCues;

  /// 主 / 副字幕各自的「查 cue 用等效位置」（已扣各自的调轴偏移）。
  final int Function() primaryPositionMs;
  final int Function() secondaryPositionMs;

  /// 主字幕正文语言；决定「拆出日语」能不能点。读取函数：工具就地跑完会换主字幕
  /// （拆分 / 对轴另存的新档被选中），语言跟着变。
  final SubtitleContentLanguage Function() primaryLanguage;

  /// 播放页当前的提示（OSD）。工具的进度与结果都走播放页的 OSD，工作台是整页、盖住了
  /// 它，所以由这里转给工作台显示；null = 现在没有提示。
  final VideoSubtitleStudioNotice? Function()? notice;

  /// [notice] 变化的推送源。
  final Listenable? noticeListenable;

  /// 截取当前画面（裸画面 JPEG）；null = 这种播放来源截不了，不显示画面开关。
  final Future<Uint8List?> Function()? captureFrame;

  /// 点对照表某句跳过去；null = 只读。
  final void Function(AudioCue cue)? jumpToCue;
}

/// 工具跑出来的一条提示（进度 / 结果 / 失败原因）。
class VideoSubtitleStudioNotice {
  const VideoSubtitleStudioNotice({
    required this.message,
    required this.severity,
  });

  final String message;
  final ToastSeverity severity;
}

/// 画面现在发不到 AI 手里的原因（面板写在「参考画面」那一行下面）。
enum VideoSubtitleStudioFramesProblem {
  /// 「字幕校对」没指派提供商。
  noProvider,

  /// 指派的提供商没开图片输入。
  providerRejectsImages,

  /// 不是本机视频文件，管线取不到画面。
  notLocalFile,
}

/// 「交给 AI 的参考」区的数据源（视频页注入）。全部是读取函数：开关改完面板现读。
class VideoSubtitleStudioAiReference {
  const VideoSubtitleStudioAiReference({
    required this.framesEnabled,
    required this.setFramesEnabled,
    required this.framesProblem,
  });

  /// 「参考画面」开关的现值（设备本地偏好，与生成面板里的是同一个）。
  final bool Function() framesEnabled;

  /// 改「参考画面」。打开时由实现负责首次的「会发送什么」说明；用户没同意就不改。
  final Future<void> Function(BuildContext context, bool value)
  setFramesEnabled;

  /// 画面现在发不出去的原因；null = 发得出去。
  final VideoSubtitleStudioFramesProblem? Function() framesProblem;
}

/// 工作台给哪一类媒体用：决定工具区列哪些工具。
enum VideoSubtitleStudioToolset {
  /// 视频：生成、拆分双语、逐句对轴、按内嵌字幕对齐。
  video,

  /// 音乐歌词（拍板台 niQk_Ns4OV：歌词走通用字幕工作台，不另立编辑界面）：生成字幕、
  /// 纯文本歌词自动对时；视频专属的拆分 / 对轴 / 内嵌对齐不列。
  music,
}

/// 工具区的动作。null = 当前视频用不了这一项（面板显示原因、按钮置灰）。
class VideoSubtitleStudioActions {
  const VideoSubtitleStudioActions({
    this.toolset = VideoSubtitleStudioToolset.video,
    this.generate,
    this.generatePanel,
    this.splitBilingual,
    this.retime,
    this.alignEmbedded,
    this.syncPlainText,
    this.setCueStart,
    this.canSetCueStart,
  });

  final VideoSubtitleStudioToolset toolset;

  /// 「生成字幕」的选项面板，直接嵌在工具栏里（对象、语言、识别模型、分段方式、
  /// AI 校对、任务进度、开始 / 取消 / 继续都在原地）：本机管线与互联 host 管线各有
  /// 一块。null = 这个视频只能本机转录（不在媒体库里、蓝光、非互联的远端流），退回
  /// [generate] 那一行按钮，点了转录弹层盖在工作台上。
  final WidgetBuilder? generatePanel;

  /// 生成字幕（原「生成字幕」入口：管线 / 本机转录分流）。
  final Future<void> Function()? generate;

  /// 拆出双语字幕中的日语（只在主字幕被检测为中日双语时可点）。
  final Future<void> Function()? splitBilingual;

  /// 按每句语音逐句对轴（模型重定时）。
  final Future<void> Function()? retime;

  /// 按视频内嵌文本字幕轨对齐。
  final Future<void> Function()? alignEmbedded;

  /// 纯文本（没有时间轴）的正文按本机转录逐行对时（[VideoSubtitleStudioToolset.music]
  /// 才列）。null = 当前正文已有时间轴或没有正文。
  final Future<void> Function()? syncPlainText;

  /// 逐句表格的逐行微调：把这一句的起点设成 `startMs`（[VideoSubtitleStudioReference.
  /// primaryPositionMs] 的当前值，即播放头）。null = 这条轨不能逐行改（每行不出按钮）。
  final Future<void> Function(AudioCue cue, int startMs)? setCueStart;

  /// [setCueStart] 此刻可不可用（工具跑完可能变，例如刚对完时）；null = 只看
  /// [setCueStart] 是否为 null。
  final bool Function()? canSetCueStart;

  /// 逐行微调此刻可用。
  bool get cueStartEditable =>
      setCueStart != null && (canSetCueStart?.call() ?? true);
}

/// 逐句表格的一行：主字幕一句 + 同一时刻的其它语言字幕。
class VideoSubtitleStudioRow {
  const VideoSubtitleStudioRow({
    required this.cue,
    required this.secondaryText,
  });

  final AudioCue cue;

  /// 与这一句时间重叠的副字幕正文（多句用换行连）；没有重叠为 null。
  final String? secondaryText;
}

/// **纯函数**：整条主字幕的逐句表格（全集，不再只取播放头附近几句）。
///
/// 副字幕按 [secondaryShiftMs]（= 副等效位置 − 主等效位置）把主句的时间窗平移到副字幕
/// 轴上再找重叠，两条轨各自的调轴偏移因此都算进去了。渲染专用 cue（ASS 矢量绘图）和
/// 空文本 cue 不进表。
List<VideoSubtitleStudioRow> videoSubtitleStudioTable({
  required List<AudioCue> primary,
  required List<AudioCue> secondary,
  required int secondaryShiftMs,
}) => <VideoSubtitleStudioRow>[
  for (final AudioCue c in primary)
    if (!c.isRenderOnly && c.text.trim().isNotEmpty)
      VideoSubtitleStudioRow(
        cue: c,
        secondaryText: _overlappingText(
          secondary,
          c.startMs + secondaryShiftMs,
          c.endMs + secondaryShiftMs,
        ),
      ),
];

/// **纯函数**：表格跟随播放时要滚到的那一行——「起点 ≤ 播放头的最后一句」（播放头在
/// 第一句之前时是第一句）；空表为 null。[rows] 按起点升序（字幕轨本来的顺序）。
int? videoSubtitleStudioAnchorIndex(
  List<VideoSubtitleStudioRow> rows,
  int positionMs,
) {
  if (rows.isEmpty) return null;
  int lo = 0;
  int hi = rows.length - 1;
  int anchor = 0;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    if (rows[mid].cue.startMs <= positionMs) {
      anchor = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return anchor;
}

/// 播放头正落在这一句里（句间空隙里没有任何一句是当前句）。
bool videoSubtitleStudioRowIsCurrent(
  VideoSubtitleStudioRow row,
  int positionMs,
) => row.cue.startMs <= positionMs && positionMs < row.cue.endMs;

String? _overlappingText(List<AudioCue> cues, int startMs, int endMs) {
  final List<String> texts = <String>[
    for (final AudioCue c in cues)
      if (!c.isRenderOnly &&
          c.text.trim().isNotEmpty &&
          c.startMs < endMs &&
          startMs < c.endMs)
        c.text.trim(),
  ];
  return texts.isEmpty ? null : texts.join('\n');
}

/// **纯函数**：播放器里一条字幕轨 → 交给 AI 校对的参考轨（`SubtitleEvidenceTrack`）。
///
/// [delayMs] 是这条轨在播放器里的调轴偏移：cue 的时刻加上它才是视频时间（播放器查
/// cue 用 `位置 − 偏移`），所以用户眼前对齐成什么样，AI 拿到的就是什么样。渲染专用
/// cue 与空文本不收；语言按文字判（判不出 → null：不知道是什么语言的轨不能当参考）。
/// 与目标语言相同的轨由管线那头丢掉（`SubtitleEvidenceWithPinnedTracks`）。
SubtitleEvidenceTrack? videoSubtitleStudioEvidenceTrack({
  required List<AudioCue> cues,
  required int delayMs,
  required String label,
}) {
  final List<SubtitleEvidenceCue> lines =
      <SubtitleEvidenceCue>[
        for (final AudioCue c in cues)
          if (!c.isRenderOnly &&
              c.text.trim().isNotEmpty &&
              c.endMs > c.startMs)
            SubtitleEvidenceCue(
              startMs: c.startMs + delayMs,
              endMs: c.endMs + delayMs,
              text: c.text.trim(),
              role: classifyPlainEvidenceText(c.text),
            ),
      ]..sort(
        (SubtitleEvidenceCue a, SubtitleEvidenceCue b) =>
            a.startMs.compareTo(b.startMs),
      );
  if (lines.isEmpty) return null;
  final String? language = detectSubtitleTextLanguage(<String>[
    for (final SubtitleEvidenceCue c in lines) c.text,
  ]);
  if (language == null) return null;
  return SubtitleEvidenceTrack(
    label: label,
    kind: SubtitleEvidenceKind.text,
    language: language,
    cues: lines,
  );
}

/// 逐句表格的时间码 `m:ss.cc`（≥1 小时 `h:mm:ss.cc`），精确到 1/100 秒。
String videoSubtitleStudioTimecode(int ms) {
  final int v = ms < 0 ? 0 : ms;
  final int h = v ~/ 3600000;
  final int m = (v ~/ 60000) % 60;
  final String s = ((v ~/ 1000) % 60).toString().padLeft(2, '0');
  final String cs = ((v ~/ 10) % 100).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s.$cs' : '$m:$s.$cs';
}

/// 当前字幕语言的显示名（母语写法，与字幕搜索同口径）；检测不出时「语言未知」。
String videoSubtitleStudioLanguageLabel(SubtitleContentLanguage language) =>
    subtitleContentLanguageNativeLabel(language) ??
    t.video_subtitle_studio_language_unknown;

/// 打开字幕工作台：**全屏页面**。root navigator：播放页全屏态自建的路由在 root 上，
/// 工作台必须盖在它之上（与字幕搜索页 `SubtitleWorkbenchPage.open` 同一做法）。
Future<void> openVideoSubtitleStudioPage({
  required BuildContext context,
  required VideoSubtitleStudioReference reference,
  required VideoSubtitleStudioActions actions,
  VideoSubtitleStudioAiReference? aiReference,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => VideoSubtitleStudioPage(
        reference: reference,
        actions: actions,
        aiReference: aiReference,
      ),
    ),
  );
}

class VideoSubtitleStudioPage extends StatefulWidget {
  const VideoSubtitleStudioPage({
    super.key,
    required this.reference,
    required this.actions,
    this.aiReference,
  });

  final VideoSubtitleStudioReference reference;
  final VideoSubtitleStudioActions actions;

  /// 「交给 AI 的参考」区；null = 这个视频走不了带 AI 校对的生成管线，不显示这一区。
  final VideoSubtitleStudioAiReference? aiReference;

  @override
  State<VideoSubtitleStudioPage> createState() =>
      _VideoSubtitleStudioPageState();
}

class _VideoSubtitleStudioPageState extends State<VideoSubtitleStudioPage> {
  /// 放得下「逐句表格 | 工具」两栏的最小宽度；更窄时上下排。
  static const double _twoPaneMinWidth = 840;
  static const double _toolsPaneWidth = 380;

  /// 画面跟着播放走：换句时重截一张，两次之间至少隔这么久（截图要编码一帧 JPEG）。
  static const Duration _autoCaptureInterval = Duration(milliseconds: 1500);

  VideoSubtitleStudioReference get _ref => widget.reference;

  bool _showFrame = true;
  bool _showSecondary = true;

  /// 表格跟随播放头滚动。用户自己拖 / 滚表格时关掉，点「跟随播放」重新打开。
  bool _follow = true;

  Uint8List? _frame;
  bool _capturing = false;
  bool _frameFailed = false;
  DateTime? _lastAutoCapture;

  final ScrollController _tableScroll = ScrollController();

  /// 正在就地跑的工具（[_toolRows] 的 key）；跑着时其它工具不能点。
  String? _busyTool;

  /// 播放页转过来的最后一条提示。OSD 自己两三秒就消失，工作台留着最后一条。
  VideoSubtitleStudioNotice? _notice;

  /// 上一次跟随到的行（[videoSubtitleStudioAnchorIndex]）；换行才滚、才重截画面。
  int? _anchor;

  // 逐句表格按「cue 列表 + 两轨相对偏移」缓存：播放位置每次推送都要读它，重叠查找是
  // O(主 × 副)，不能每一帧重算。
  List<VideoSubtitleStudioRow> _rows = const <VideoSubtitleStudioRow>[];
  List<AudioCue>? _rowsPrimary;
  List<AudioCue>? _rowsSecondary;
  int _rowsShift = 0;

  @override
  void initState() {
    super.initState();
    _ref.listenable.addListener(_onPosition);
    _ref.noticeListenable?.addListener(_onNotice);
    if (_ref.captureFrame != null) unawaited(_capture());
    // 首帧排完版才有滚动范围：直接跳到当前句（不做动画，打开就在位置上）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _anchor = videoSubtitleStudioAnchorIndex(
        _tableRows(),
        _ref.primaryPositionMs(),
      );
      _scrollToAnchor(animate: false);
    });
  }

  @override
  void didUpdateWidget(VideoSubtitleStudioPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.reference.listenable, _ref.listenable)) {
      oldWidget.reference.listenable.removeListener(_onPosition);
      _ref.listenable.addListener(_onPosition);
    }
    if (!identical(
      oldWidget.reference.noticeListenable,
      _ref.noticeListenable,
    )) {
      oldWidget.reference.noticeListenable?.removeListener(_onNotice);
      _ref.noticeListenable?.addListener(_onNotice);
    }
  }

  @override
  void dispose() {
    _ref.listenable.removeListener(_onPosition);
    _ref.noticeListenable?.removeListener(_onNotice);
    _tableScroll.dispose();
    super.dispose();
  }

  /// 播放器每次返回的 cue 列表可能是新包的一层 List：按长度 + 首尾元素身份判同一条轨。
  static bool _sameCues(List<AudioCue> a, List<AudioCue> b) =>
      identical(a, b) ||
      (a.length == b.length &&
          (a.isEmpty ||
              (identical(a.first, b.first) && identical(a.last, b.last))));

  List<VideoSubtitleStudioRow> _tableRows() {
    final List<AudioCue> primary = _ref.primaryCues();
    final List<AudioCue> secondary = _showSecondary
        ? _ref.secondaryCues()
        : const <AudioCue>[];
    final int shift = _ref.secondaryPositionMs() - _ref.primaryPositionMs();
    final List<AudioCue>? cachedPrimary = _rowsPrimary;
    final List<AudioCue>? cachedSecondary = _rowsSecondary;
    if (cachedPrimary != null &&
        cachedSecondary != null &&
        _rowsShift == shift &&
        _sameCues(cachedPrimary, primary) &&
        _sameCues(cachedSecondary, secondary)) {
      return _rows;
    }
    _rowsPrimary = primary;
    _rowsSecondary = secondary;
    _rowsShift = shift;
    return _rows = videoSubtitleStudioTable(
      primary: primary,
      secondary: secondary,
      secondaryShiftMs: shift,
    );
  }

  bool get _secondaryColumnShown =>
      _showSecondary && _ref.secondaryCues().isNotEmpty;

  /// 表格行高固定（主字幕一行 + 可选的对照一行，超长省略）：定高才能按行号直接算出
  /// 滚动位置，全集几百上千句也只建可见的那几行。
  double get _rowExtent => _secondaryColumnShown ? 64 : 48;

  void _onPosition() {
    final int? anchor = videoSubtitleStudioAnchorIndex(
      _tableRows(),
      _ref.primaryPositionMs(),
    );
    if (anchor == _anchor) return;
    _anchor = anchor;
    if (_follow) _scrollToAnchor(animate: true);
    if (_showFrame && _ref.captureFrame != null) {
      final DateTime now = DateTime.now();
      final DateTime? last = _lastAutoCapture;
      if (last == null || now.difference(last) >= _autoCaptureInterval) {
        _lastAutoCapture = now;
        unawaited(_capture());
      }
    }
  }

  /// 把当前句滚到表格中间。
  void _scrollToAnchor({required bool animate}) {
    final int? anchor = _anchor;
    if (anchor == null || !_tableScroll.hasClients) return;
    final ScrollPosition position = _tableScroll.position;
    final double extent = _rowExtent;
    final double target =
        (anchor * extent - (position.viewportDimension - extent) / 2).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    if (!animate) {
      _tableScroll.jumpTo(target);
      return;
    }
    unawaited(
      _tableScroll.animateTo(
        target,
        duration: context.fushiMotion.spatialDefault.duration,
        curve: context.fushiMotion.spatialDefault.curve,
      ),
    );
  }

  void _stopFollowing() {
    if (_follow) setState(() => _follow = false);
  }

  void _toggleFollow() {
    setState(() => _follow = !_follow);
    if (_follow) {
      _anchor = videoSubtitleStudioAnchorIndex(
        _tableRows(),
        _ref.primaryPositionMs(),
      );
      _scrollToAnchor(animate: true);
    }
  }

  Future<void> _capture() async {
    final Future<Uint8List?> Function()? capture = _ref.captureFrame;
    if (capture == null || _capturing) return;
    setState(() {
      _capturing = true;
      _frameFailed = false;
    });
    Uint8List? bytes;
    try {
      bytes = await capture();
    } on Exception catch (error, stack) {
      // 截不到就在面板里说「截不到当前画面」，原因留日志可查。
      ErrorLogService.instance.log('video.subtitleStudioFrame', error, stack);
      bytes = null;
    }
    if (!mounted) return;
    setState(() {
      _capturing = false;
      _frame = bytes ?? _frame;
      _frameFailed = bytes == null;
    });
  }

  void _onNotice() {
    final VideoSubtitleStudioNotice? notice = _ref.notice?.call();
    // 提示消失（null）不清：留着最后一条，结果不会一闪而过。
    if (notice == null || !mounted) return;
    setState(() => _notice = notice);
  }

  /// 跑一个工具：留在工作台里跑——期间其它工具不能点，进度与结果由播放页的提示转
  /// 过来显示（[VideoSubtitleStudioReference.notice]），跑完换了主字幕表格当场跟着
  /// 变。工具自己起的弹层（转录、确认）都开在 root navigator 上，盖在工作台之上，
  /// 五个平台同一行为。
  Future<void> _run(String key, Future<void> Function() action) async {
    if (_busyTool != null) return;
    setState(() {
      _busyTool = key;
      _notice = null;
    });
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busyTool = null);
    }
  }

  bool get _bilingual =>
      _ref.primaryLanguage() == SubtitleContentLanguage.bilingualJaZh;

  /// 逐行微调：这一句的起点设成播放头（[VideoSubtitleStudioActions.setCueStart]）。
  /// 跑的期间工具区照样显示忙；跑完按新轨重排表格。
  Future<void> _setCueStart(AudioCue cue) async {
    final Future<void> Function(AudioCue cue, int startMs)? set =
        widget.actions.setCueStart;
    if (set == null) return;
    await _run('set-start', () => set(cue, _ref.primaryPositionMs()));
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final VideoSubtitleStudioAiReference? ai = widget.aiReference;
    final WidgetBuilder? generatePanel = widget.actions.generatePanel;
    final int aiAt = generatePanel == null ? 0 : 2;
    final int toolsAt = aiAt + (ai == null ? 0 : 3);
    final VideoSubtitleStudioNotice? notice = _notice;
    final Widget tools = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (generatePanel != null) ...<Widget>[
            _sectionTitle(0, t.video_subtitle_ai_generate_title),
            FushiStaggeredEntrance(
              index: 1,
              child: KeyedSubtree(
                key: const ValueKey<String>(
                  'video-subtitle-studio-generate-panel',
                ),
                child: generatePanel(context),
              ),
            ),
          ],
          if (ai != null) ...<Widget>[
            _sectionTitle(aiAt, t.video_subtitle_studio_ai_label),
            // 生成面板嵌进来时「参考画面」开关在面板的 AI 校对那一项里，不摆两个。
            ..._aiRows(
              context,
              ai,
              aiAt + 1,
              showFrames: generatePanel == null,
            ),
          ],
          _sectionTitle(toolsAt, t.video_subtitle_studio_tools_label),
          ..._toolRows(context, toolsAt + 1),
          if (_busyTool != null)
            const Padding(
              padding: EdgeInsets.fromLTRB(4, 12, 4, 0),
              child: FushiLinearProgressIndicator(
                key: ValueKey<String>('video-subtitle-studio-busy'),
              ),
            ),
          if (notice != null) _noticeRow(context, notice),
        ],
      ),
    );
    return FushiPageScaffold(
      title: t.video_subtitle_studio_title,
      // 不叠放：正文是定高版面（表格自己滚、工具栏自己滚），不是单一滚动视图，叠到
      // 页头底下顶部控件会被胶囊盖住。
      extendBodyBehindHeader: false,
      body: Padding(
        padding: withBottomSafeInset(
          context,
          EdgeInsets.fromLTRB(tokens.spacing.card, 4, tokens.spacing.card, 8),
        ),
        child: FushiEntranceScope(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool twoPane = constraints.maxWidth >= _twoPaneMinWidth;
              final Widget reference = _referencePane(
                context,
                frameMaxHeight: twoPane ? 260 : 110,
              );
              if (twoPane) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: reference),
                    SizedBox(width: tokens.spacing.card),
                    SizedBox(width: _toolsPaneWidth, child: tools),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: reference),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * 0.36,
                    ),
                    child: tools,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(int index, String label) => FushiStaggeredEntrance(
    index: index,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(label, style: context.fushiType.titleSmallEmphasized),
    ),
  );

  Widget _noticeRow(BuildContext context, VideoSubtitleStudioNotice notice) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final IconData? icon = toastSeverityPalette(notice.severity)?.icon;
    // 图标形状区分四态（灰阶屏上颜色会塌）；颜色取主题色，深浅主题下都够对比。
    final Color tint = switch (notice.severity) {
      ToastSeverity.error => colors.error,
      ToastSeverity.warning => colors.tertiary,
      _ => colors.primary,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: Row(
        key: const ValueKey<String>('video-subtitle-studio-notice'),
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: <Widget>[
          if (icon != null) FushiIcon(icon, size: 18, color: tint),
          Expanded(
            child: Text(notice.message, style: context.fushiType.bodyMedium),
          ),
        ],
      ),
    );
  }

  Widget _hint(String text, {Key? key}) =>
      Text(text, key: key, style: FushiDesignTokens.of(context).type.metadata);

  Widget _toggle(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    required Key key,
  }) => Row(
    children: <Widget>[
      Expanded(child: Text(label, style: context.fushiType.bodyMedium)),
      KeyedSubtree(
        key: key,
        child: adaptiveSwitch(
          context: context,
          value: value,
          onChanged: onChanged,
        ),
      ),
    ],
  );

  // ── 参考：画面 + 逐句表格 ──────────────────────────────────────────────────

  Widget _referencePane(
    BuildContext context, {
    required double frameMaxHeight,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: _hint(
                t.video_subtitle_studio_track_language(
                  language: videoSubtitleStudioLanguageLabel(
                    _ref.primaryLanguage(),
                  ),
                ),
                key: const ValueKey<String>('video-subtitle-studio-language'),
              ),
            ),
            KeyedSubtree(
              key: const ValueKey<String>('video-subtitle-studio-follow'),
              child: FushiIconButton(
                icon: FushiIcons.myLocation,
                tooltip: t.video_subtitle_studio_follow_playhead,
                selected: _follow,
                onTap: _toggleFollow,
              ),
            ),
          ],
        ),
        if (_ref.captureFrame != null) ...<Widget>[
          _toggle(
            t.video_subtitle_studio_show_frame,
            _showFrame,
            (bool v) => setState(() => _showFrame = v),
            key: const ValueKey<String>('video-subtitle-studio-frame'),
          ),
          FushiAnimatedSize(
            duration: context.fushiMotion.spatialDefault.duration,
            curve: context.fushiMotion.spatialDefault.curve,
            alignment: Alignment.topCenter,
            child: _showFrame
                ? _framePreview(context, frameMaxHeight)
                : const SizedBox(width: double.infinity),
          ),
        ],
        _toggle(
          t.video_subtitle_studio_show_secondary,
          _showSecondary,
          (bool v) => setState(() => _showSecondary = v),
          key: const ValueKey<String>('video-subtitle-studio-secondary'),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListenableBuilder(
            listenable: _ref.listenable,
            builder: (BuildContext context, _) => _table(context),
          ),
        ),
      ],
    );
  }

  Widget _framePreview(BuildContext context, double maxHeight) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Uint8List? frame = _frame;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: <Widget>[
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(tokens.radii.control),
              child: ColoredBox(
                color: tokens.surfaces.overlay,
                child: frame != null
                    ? Image.memory(
                        frame,
                        key: const ValueKey<String>(
                          'video-subtitle-studio-frame-image',
                        ),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      )
                    : Center(
                        child: _capturing
                            ? const SizedBox(
                                width: 120,
                                child: FushiLinearProgressIndicator(),
                              )
                            : const FushiIcon(FushiIcons.image, size: 32),
                      ),
              ),
            ),
          ),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: _frameFailed
                  ? _hint(t.video_subtitle_studio_frame_unavailable)
                  : const SizedBox.shrink(),
            ),
            FushiPressScale(
              child: FushiOutlinedButton.icon(
                key: const ValueKey<String>('video-subtitle-studio-capture'),
                icon: const FushiIcon(FushiIcons.refresh, size: 18),
                label: Text(t.video_subtitle_studio_frame_refresh),
                onPressed: _capturing ? null : () => unawaited(_capture()),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _table(BuildContext context) {
    final List<VideoSubtitleStudioRow> rows = _tableRows();
    if (rows.isEmpty) {
      return Align(
        alignment: AlignmentDirectional.topStart,
        child: _hint(
          t.video_subtitle_studio_no_primary,
          key: const ValueKey<String>('video-subtitle-studio-no-primary'),
        ),
      );
    }
    final int positionMs = _ref.primaryPositionMs();
    final bool showSecondary = _secondaryColumnShown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_showSecondary && !showSecondary)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _hint(
              t.video_subtitle_studio_no_secondary,
              key: const ValueKey<String>('video-subtitle-studio-no-secondary'),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              // 窄屏放不下「时长」一列：先保正文。
              final bool compact = constraints.maxWidth < 480;
              return NotificationListener<ScrollStartNotification>(
                // 手指 / 鼠标拖表格 = 用户要自己看别处，停止跟随。程序滚动
                // （animateTo）没有 dragDetails，不会误关。
                onNotification: (ScrollStartNotification notification) {
                  if (notification.dragDetails != null) _stopFollowing();
                  return false;
                },
                child: Listener(
                  // 滚轮 / 触控板滚动不带 dragDetails，单独收。
                  onPointerSignal: (_) => _stopFollowing(),
                  child: ListView.builder(
                    key: const ValueKey<String>('video-subtitle-studio-table'),
                    controller: _tableScroll,
                    itemExtent: _rowExtent,
                    itemCount: rows.length,
                    itemBuilder: (BuildContext context, int index) => _tableRow(
                      context,
                      index,
                      rows[index],
                      current: videoSubtitleStudioRowIsCurrent(
                        rows[index],
                        positionMs,
                      ),
                      showSecondary: showSecondary,
                      compact: compact,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _tableRow(
    BuildContext context,
    int index,
    VideoSubtitleStudioRow row, {
    required bool current,
    required bool showSecondary,
    required bool compact,
  }) {
    final void Function(AudioCue cue)? jump = _ref.jumpToCue;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AudioCue cue = row.cue;
    final TextStyle mono = context.fushiType.labelSmall.copyWith(
      color: colors.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: <Widget>[
          SizedBox(width: 40, child: Text('${index + 1}', style: mono)),
          SizedBox(
            width: 76,
            child: Text(videoSubtitleStudioTimecode(cue.startMs), style: mono),
          ),
          if (!compact)
            SizedBox(
              width: 52,
              child: Text(
                '${((cue.endMs - cue.startMs) / 1000).toStringAsFixed(1)}s',
                style: mono,
              ),
            ),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  cue.text.trim().replaceAll('\n', ' '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: current
                      ? context.fushiType.titleSmallEmphasized
                      : context.fushiType.bodyMedium,
                ),
                if (showSecondary)
                  Text(
                    (row.secondaryText ?? '—').replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.fushiType.bodySmall.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (widget.actions.cueStartEditable)
            KeyedSubtree(
              key: ValueKey<String>(
                'video-subtitle-studio-set-start-${cue.startMs}',
              ),
              child: FushiIconButton(
                icon: FushiIcons.flag,
                tooltip: t.video_subtitle_studio_set_start_tooltip,
                enabled: _busyTool == null,
                onTap: () => unawaited(_setCueStart(cue)),
              ),
            ),
        ],
      ),
    );
    final Widget tile = Material(
      key: ValueKey<String>('video-subtitle-studio-row-${cue.startMs}'),
      color: current ? colors.secondaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(tokens.radii.control),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: jump == null ? null : () => jump(cue),
        child: content,
      ),
    );
    return jump == null
        ? tile
        : FushiTooltip(
            message: t.video_subtitle_studio_jump_tooltip,
            child: tile,
          );
  }

  // ── 交给 AI 的参考 ────────────────────────────────────────────────────────

  Future<void> _setAiFrames(VideoSubtitleStudioAiReference ai, bool on) async {
    await ai.setFramesEnabled(context, on);
    if (mounted) setState(() {});
  }

  /// 副字幕的语言名（给「其它语言字幕」那行）；没选副字幕 → null。
  String? _secondaryLanguageLabel() {
    final List<AudioCue> secondary = _ref.secondaryCues();
    final String text = <String>[
      for (final AudioCue c in secondary)
        if (!c.isRenderOnly && c.text.trim().isNotEmpty) c.text,
    ].join('\n');
    if (text.isEmpty) return null;
    return videoSubtitleStudioLanguageLabel(
      detectSubtitleContentLanguage(text),
    );
  }

  List<Widget> _aiRows(
    BuildContext context,
    VideoSubtitleStudioAiReference ai,
    int firstIndex, {
    required bool showFrames,
  }) {
    final VideoSubtitleStudioFramesProblem? problem = ai.framesProblem();
    final bool framesOn = ai.framesEnabled();
    final String framesHint = switch (problem) {
      null => t.video_subtitle_ai_frames_hint,
      VideoSubtitleStudioFramesProblem.noProvider =>
        t.video_subtitle_ai_no_provider,
      VideoSubtitleStudioFramesProblem.providerRejectsImages =>
        t.video_subtitle_ai_frames_unsupported,
      VideoSubtitleStudioFramesProblem.notLocalFile =>
        t.video_subtitle_studio_ai_frames_not_local,
    };
    final bool framesLocked =
        problem == VideoSubtitleStudioFramesProblem.notLocalFile;
    final String? secondaryLanguage = _secondaryLanguageLabel();
    return <Widget>[
      if (showFrames)
        FushiStaggeredEntrance(
          index: firstIndex,
          child: FushiGroupedListItem(
            index: 0,
            count: 2,
            child: FushiListTileControl(
              key: const ValueKey<String>('video-subtitle-studio-ai-frames'),
              leading: const FushiIcon(FushiIcons.image),
              title: Text(t.video_subtitle_ai_frames_label),
              subtitle: Text(
                framesHint,
                key: const ValueKey<String>(
                  'video-subtitle-studio-ai-frames-hint',
                ),
              ),
              enabled: !framesLocked,
              trailing: KeyedSubtree(
                key: const ValueKey<String>(
                  'video-subtitle-studio-ai-frames-switch',
                ),
                child: adaptiveSwitch(
                  context: context,
                  value: framesOn && !framesLocked,
                  onChanged: framesLocked
                      ? null
                      : (bool v) => unawaited(_setAiFrames(ai, v)),
                ),
              ),
            ),
          ),
        ),
      FushiStaggeredEntrance(
        index: firstIndex + 1,
        child: FushiGroupedListItem(
          index: showFrames ? 1 : 0,
          count: showFrames ? 2 : 1,
          child: FushiListTileControl(
            key: const ValueKey<String>('video-subtitle-studio-ai-subtitles'),
            leading: const FushiIcon(FushiIcons.language),
            title: Text(t.video_subtitle_studio_show_secondary),
            subtitle: Text(
              secondaryLanguage == null
                  ? t.video_subtitle_studio_ai_subtitles_auto
                  : t.video_subtitle_studio_ai_subtitles_secondary(
                      language: secondaryLanguage,
                    ),
              key: const ValueKey<String>(
                'video-subtitle-studio-ai-subtitles-hint',
              ),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: _hint(
          t.video_subtitle_studio_ai_scope_hint,
          key: const ValueKey<String>('video-subtitle-studio-ai-scope'),
        ),
      ),
    ];
  }

  // ── 工具 ────────────────────────────────────────────────────────────────

  List<Widget> _toolRows(BuildContext context, int firstIndex) {
    final VideoSubtitleStudioActions a = widget.actions;
    final List<
      ({
        String key,
        IconData icon,
        String title,
        String hint,
        Future<void> Function()? action,
      })
    >
    tools =
        <
          ({
            String key,
            IconData icon,
            String title,
            String hint,
            Future<void> Function()? action,
          })
        >[
          if (a.generatePanel == null)
            (
              key: 'generate',
              icon: FushiIcons.subtitles,
              title: t.video_subtitle_ai_generate_title,
              hint: a.generate == null
                  ? t.video_subtitle_studio_needs_audio
                  : t.video_subtitle_generate_entry_hint,
              action: a.generate,
            ),
          if (a.toolset == VideoSubtitleStudioToolset.music)
            (
              key: 'sync-plain',
              icon: FushiIcons.timer,
              title: t.music_lyrics_auto_sync_action,
              hint: a.syncPlainText == null
                  ? t.music_lyrics_auto_sync_not_plain
                  : t.music_lyrics_auto_sync_hint,
              action: a.syncPlainText,
            ),
          if (a.toolset == VideoSubtitleStudioToolset.video) ...<
            ({
              String key,
              IconData icon,
              String title,
              String hint,
              Future<void> Function()? action,
            })
          >[
            (
              key: 'split',
              icon: FushiIcons.language,
              title: t.video_subtitle_studio_split_action,
              hint: _bilingual && a.splitBilingual != null
                  ? t.video_subtitle_studio_split_hint
                  : t.video_subtitle_studio_split_not_bilingual,
              action: _bilingual ? a.splitBilingual : null,
            ),
            (
              key: 'retime',
              icon: FushiIcons.modelTraining,
              title: t.video_subtitle_retime_action,
              hint: a.retime == null
                  ? t.video_subtitle_studio_needs_audio
                  : t.video_subtitle_studio_retime_hint,
              action: a.retime,
            ),
            (
              key: 'align',
              icon: FushiIcons.sync,
              title: t.video_subtitle_reference_sync_action,
              hint: a.alignEmbedded == null
                  ? t.video_subtitle_studio_needs_local_file
                  : t.video_subtitle_studio_align_hint,
              action: a.alignEmbedded,
            ),
          ],
        ];
    return <Widget>[
      for (int i = 0; i < tools.length; i++)
        FushiStaggeredEntrance(
          index: firstIndex + i,
          child: FushiGroupedListItem(
            index: i,
            count: tools.length,
            child: FushiPressScale(
              child: FushiListTileControl(
                key: ValueKey<String>('video-subtitle-studio-${tools[i].key}'),
                leading: FushiIcon(tools[i].icon),
                title: Text(tools[i].title),
                subtitle: Text(tools[i].hint),
                enabled: tools[i].action != null && _busyTool == null,
                onTap: switch (tools[i].action) {
                  null => null,
                  final Future<void> Function() action => () => unawaited(
                    _run(tools[i].key, action),
                  ),
                },
              ),
            ),
          ),
        ),
    ];
  }
}
