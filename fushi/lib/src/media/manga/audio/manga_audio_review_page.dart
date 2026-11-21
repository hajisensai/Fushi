/// 漫画有声演出稿的逐句复核：左（窄屏为上）显示台词所在的原页，用 OCR 块坐标高亮
/// 这句的气泡；右（窄屏为下）在同一屏确认或改说话人，改完自动跳到下一句。默认只看
/// 待复核的行（[mangaLineNeedsReview]），也可切到全部台词。
///
/// 「确认」= 保留当前说话人并记为手改（含「不明」：保留给默认声线处理），之后重标
/// 不会再覆盖。页面自己开一份标注会话：本卷有标注任务在跑时编辑锁住，任务跑完重读
/// 盘上的演出稿，避免拿旧会话覆盖任务的结果。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/render/tts_cast.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ai/ai_manga_audio_assistant.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_flow.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_annotate_tasks.dart';
import 'package:fushi/src/media/manga/mokuro_geometry_ui.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_kit_core.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

// -----------------------------------------------------------------------------
// 纯逻辑
// -----------------------------------------------------------------------------

/// 复核队列：按页序、页内按演出稿顺序排的 `lineId`；[pendingOnly] 只取待复核的行。
List<String> mangaReviewQueue(
  MangaAudioScript script, {
  required bool pendingOnly,
}) {
  final List<(int, int, MangaScriptLine)> indexed =
      <(int, int, MangaScriptLine)>[
        for (int i = 0; i < script.lines.length; i++)
          if (!pendingOnly || mangaLineNeedsReview(script.lines[i]))
            (script.lines[i].page, i, script.lines[i]),
      ];
  indexed.sort(
    ((int, int, MangaScriptLine) a, (int, int, MangaScriptLine) b) =>
        a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2),
  );
  return <String>[
    for (final (int, int, MangaScriptLine) e in indexed) e.$3.lineId,
  ];
}

/// 从第 [page] 页开始复核：队列里第一条落在该页或之后的行；都在前面则从头。
int mangaReviewStartIndex(
  MangaAudioScript script,
  List<String> queue,
  int page,
) {
  for (int i = 0; i < queue.length; i++) {
    final MangaScriptLine? line = script.lineById(queue[i]);
    if (line != null && line.page >= page) return i;
  }
  return 0;
}

/// 页上第 [block] 块属于哪一句（没有任何行用到它时为 null）。
MangaScriptLine? mangaLineOfBlock(
  MangaAudioScript script,
  int page,
  int block,
) {
  for (final MangaScriptLine l in script.lines) {
    if (l.page == page && l.blocks.contains(block)) return l;
  }
  return null;
}

/// 存完 [lineId] 后该停的位置：它在 [queue] 里的下一句；它是最后一句（或已不在
/// 队列里）时为 null。
int? mangaReviewNextIndex(List<String> queue, String lineId) {
  final int at = queue.indexOf(lineId);
  return at >= 0 && at < queue.length - 1 ? at + 1 : null;
}

/// 原页坐标（OCR 像素）里命中 [point] 的块下标；块重叠时取 zIndex 高的。
int? mangaBlockAt(MokuroImage image, Offset point) {
  int? hit;
  int best = -1 << 30;
  for (int i = 0; i < image.blocks.length; i++) {
    final MokuroBlock b = image.blocks[i];
    if (b.rectangle.toRect().contains(point) && b.zIndex >= best) {
      hit = i;
      best = b.zIndex;
    }
  }
  return hit;
}

// -----------------------------------------------------------------------------
// 入口与状态
// -----------------------------------------------------------------------------

Future<void> openMangaAudioReviewPage(
  BuildContext context, {
  required AppModel appModel,
  required String bookKey,
  int startPage = 0,
}) => Navigator.of(context).push<void>(
  adaptivePageRoute<void>(
    context: context,
    builder: (_) => MangaAudioReviewPage(
      appModel: appModel,
      bookKey: bookKey,
      startPage: startPage,
    ),
  ),
);

class MangaAudioReviewPage extends StatefulWidget {
  const MangaAudioReviewPage({
    required this.appModel,
    required this.bookKey,
    this.startPage = 0,
    super.key,
  });

  final AppModel appModel;
  final String bookKey;
  final int startPage;

  @override
  State<MangaAudioReviewPage> createState() => _MangaAudioReviewPageState();
}

class _MangaAudioReviewPageState extends State<MangaAudioReviewPage> {
  late final MangaAnnotateTasks _tasks = mangaAnnotateTasksFor(widget.appModel);
  MangaAudioAnnotateSession? _session;
  String? _loadError;

  /// 本卷正在跑的标注任务；非 null 时编辑锁住。
  MangaAnnotateTask? _task;

  bool _pendingOnly = true;

  /// 当前队列（进页 / 切筛选时定一次：复核过的行不从队列里消失，前后翻不跳号）。
  List<String> _queue = const <String>[];
  int _index = 0;

  bool get _busy => _task != null;

  /// 正在存刚改的那句；期间不接受新的提交（见 [_commit]）。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tasks.addListener(_syncTask);
    _task = _tasks.runningFor(widget.bookKey);
    unawaited(_load(page: widget.startPage));
  }

  @override
  void dispose() {
    _tasks.removeListener(_syncTask);
    super.dispose();
  }

  void _syncTask() {
    final MangaAnnotateTask? task = _tasks.runningFor(widget.bookKey);
    if (identical(task, _task)) return;
    final bool ended = _task != null && task == null;
    setState(() => _task = task);
    // 任务跑完：重读盘上的演出稿，停在原来那一句附近。
    if (ended) {
      final MangaScriptLine? current = _current;
      unawaited(_load(page: current?.page ?? widget.startPage, keep: current));
    }
  }

  Future<void> _load({required int page, MangaScriptLine? keep}) async {
    try {
      final MangaAudioAnnotateSession s = await MangaAudioAnnotateSession.open(
        widget.appModel,
        widget.bookKey,
      );
      if (!mounted) return;
      setState(() {
        // 首次进页：有待复核的行就只看它们，没有就看全部；重读时沿用用户选的筛选。
        if (_session == null) {
          _pendingOnly = mangaReviewQueue(
            s.script,
            pendingOnly: true,
          ).isNotEmpty;
        }
        _session = s;
        _loadError = null;
        _rebuildQueue(page: page, keepLineId: keep?.lineId);
      });
    } on MangaAudioAnnotateError catch (e) {
      if (mounted) setState(() => _loadError = e.code);
    }
  }

  void _rebuildQueue({required int page, String? keepLineId}) {
    final MangaAudioAnnotateSession s = _session!;
    _queue = mangaReviewQueue(s.script, pendingOnly: _pendingOnly);
    final int kept = keepLineId == null ? -1 : _queue.indexOf(keepLineId);
    _index = kept >= 0 ? kept : mangaReviewStartIndex(s.script, _queue, page);
  }

  MangaScriptLine? get _current {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null || _index < 0 || _index >= _queue.length) return null;
    return s.script.lineById(_queue[_index]);
  }

  int get _pendingCount => _session == null
      ? 0
      : _session!.script.lines.where(mangaLineNeedsReview).length;

  void _setFilter(bool pendingOnly) {
    if (pendingOnly == _pendingOnly || _session == null) return;
    final MangaScriptLine? current = _current;
    setState(() {
      _pendingOnly = pendingOnly;
      _rebuildQueue(page: current?.page ?? 0, keepLineId: current?.lineId);
    });
  }

  void _go(int delta) {
    final int next = _index + delta;
    if (next < 0 || next >= _queue.length) return;
    setState(() => _index = next);
  }

  /// 点原页上的气泡：跳到用这一块的那句（不在当前队列里就切到全部台词）。
  void _jumpToBlock(int block) {
    final MangaAudioAnnotateSession? s = _session;
    final MangaScriptLine? current = _current;
    if (s == null || current == null) return;
    final MangaScriptLine? line = mangaLineOfBlock(
      s.script,
      current.page,
      block,
    );
    if (line == null || line.lineId == current.lineId) return;
    setState(() {
      if (!_queue.contains(line.lineId)) {
        _pendingOnly = false;
        _queue = mangaReviewQueue(s.script, pendingOnly: false);
      }
      _index = _queue.indexOf(line.lineId);
    });
  }

  /// 写入说话人（或原样确认）并记为手改，存盘后跳到这句的下一句。
  ///
  /// 一次只存一句（[_saving]）：存盘是异步的，连点两下会让两次提交都落在同一句上、
  /// 各自 `+1` 而跳过下一句，并让两次存盘并发写同一个临时文件。下一句按刚存的这句
  /// 在队列里的位置算，不依赖存盘期间 [_index] 有没有被翻动。
  Future<void> _commit(String speaker) async {
    final MangaAudioAnnotateSession? s = _session;
    final MangaScriptLine? line = _current;
    if (s == null || line == null || _busy || _saving) return;
    setState(() => _saving = true);
    s.script.replaceLine(
      line.lineId,
      (MangaScriptLine l) =>
          l.copyWith(speaker: speaker, source: TtsCastSource.user),
    );
    try {
      await s.saveAll();
    } finally {
      _saving = false;
    }
    if (!mounted) return;
    final int? next = mangaReviewNextIndex(_queue, line.lineId);
    if (next != null) {
      setState(() => _index = next);
    } else {
      setState(() {});
      FushiToast.show(
        msg: _pendingCount == 0
            ? t.manga_audio_review_done
            : t.audiobook_studio_cast_review(n: _pendingCount),
        severity: _pendingCount == 0
            ? ToastSeverity.success
            : ToastSeverity.neutral,
      );
    }
  }

  Future<void> _newSpeaker() async {
    final MangaAudioAnnotateSession? s = _session;
    if (s == null || _busy || _saving) return;
    final String? typed = await showFushiTextInputDialog(
      context: context,
      title: t.audiobook_studio_cast_new_speaker,
      labelText: t.manga_audio_line_speaker,
      icon: FushiIcons.personAdd,
    );
    if (typed == null || typed.trim().isEmpty || !mounted) return;
    s.addCharacter(typed.trim());
    await _commit(typed.trim());
  }

  @override
  Widget build(BuildContext context) {
    final MangaAudioAnnotateSession? s = _session;
    final MangaScriptLine? line = _current;
    return SettingsKitScaffold(
      title: t.manga_audio_review_title,
      leadingIcon: FushiIcons.voice,
      leadingTone: SettingsIconTone.purple,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            final EdgeInsets safe = EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top,
              bottom: bottomSafeInsetOf(context),
            );
            if (s == null) {
              return Padding(
                padding: safe,
                child: Center(
                  child: _loadError == null
                      ? const FushiCircularProgressIndicator()
                      : Text(mangaAudioErrorText(_loadError!)),
                ),
              );
            }
            final MokuroImage? image =
                line == null || line.page < 0 || line.page >= s.pageCount
                ? null
                : s.volume.payload.images[line.page];
            return Padding(
              padding: safe,
              child: MangaAudioReviewView(
                image: image,
                pageFile: image == null ? null : s.volume.pageFiles[image.url],
                line: line,
                text: line == null ? '' : s.textOf(line),
                roster: s.roster.values.toList(),
                position: _index,
                total: _queue.length,
                pendingOnly: _pendingOnly,
                pendingCount: _pendingCount,
                locked: _busy,
                saving: _saving,
                onFilter: _setFilter,
                onPrevious: () => _go(-1),
                onNext: () => _go(1),
                onSpeaker: (String speaker) => unawaited(_commit(speaker)),
                onNewSpeaker: () => unawaited(_newSpeaker()),
                onBlockTap: _jumpToBlock,
              ),
            );
          },
    );
  }
}

// -----------------------------------------------------------------------------
// 视图（无状态，测试直接喂数据）
// -----------------------------------------------------------------------------

class MangaAudioReviewView extends StatelessWidget {
  const MangaAudioReviewView({
    required this.image,
    required this.line,
    required this.text,
    required this.roster,
    required this.position,
    required this.total,
    required this.pendingOnly,
    required this.pendingCount,
    required this.onFilter,
    required this.onPrevious,
    required this.onNext,
    required this.onSpeaker,
    required this.onNewSpeaker,
    required this.onBlockTap,
    this.pageFile,
    this.pageImage,
    this.locked = false,
    this.saving = false,
    super.key,
  });

  static const String keyPrefix = 'manga-audio-review';

  /// 当前句所在页的 OCR 数据；null = 没有可复核的句子。
  final MokuroImage? image;

  /// 原页图文件（找不到时显示占位）。
  final File? pageFile;

  /// 直接给的页图（测试用；优先于 [pageFile]）。
  final ImageProvider<Object>? pageImage;

  final MangaScriptLine? line;
  final String text;
  final List<TtsCastCharacter> roster;
  final int position;
  final int total;
  final bool pendingOnly;
  final int pendingCount;

  /// 本卷正在标注：只能看，不能改。
  final bool locked;

  /// 正在存上一次改动：改说话人 / 确认 / 新角色暂不可点，存完自动跳下一句。
  final bool saving;

  bool get _readOnly => locked || saving;

  final ValueChanged<bool> onFilter;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<String> onSpeaker;
  final VoidCallback onNewSpeaker;
  final ValueChanged<int> onBlockTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth >= 720;
        final Widget preview = Padding(
          padding: EdgeInsets.all(tokens.spacing.gap),
          child: _PagePreview(
            image: image,
            pageFile: pageFile,
            pageImage: pageImage,
            highlight: line?.blocks ?? const <int>[],
            onBlockTap: onBlockTap,
          ),
        );
        final Widget panel = _panel(context, tokens);
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(flex: 3, child: preview),
              SizedBox(width: 380, child: panel),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(flex: 5, child: preview),
            Expanded(flex: 4, child: panel),
          ],
        );
      },
    );
  }

  Widget _panel(BuildContext context, FushiDesignTokens tokens) {
    final ThemeData theme = Theme.of(context);
    final MangaScriptLine? l = line;
    final Widget filter = adaptiveSegmentedButton<bool>(
      context: context,
      segments: <ButtonSegment<bool>>[
        ButtonSegment<bool>(
          value: true,
          label: Text(t.audiobook_studio_cast_review(n: pendingCount)),
        ),
        ButtonSegment<bool>(
          value: false,
          label: Text(t.manga_audio_section_lines),
        ),
      ],
      selected: <bool>{pendingOnly},
      onSelectionChanged: (Set<bool> v) => onFilter(v.first),
    );
    final Widget nav = Row(
      children: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('$keyPrefix-prev'),
          icon: FushiIcons.chevronLeft,
          tooltip: t.manga_audio_review_previous,
          enabled: position > 0,
          onTap: onPrevious,
        ),
        Expanded(
          child: Text(
            total == 0
                ? ''
                : '${t.manga_audio_page(page: l!.page + 1)} · '
                      '${t.manga_audio_review_position(index: position + 1, total: total)}',
            key: const ValueKey<String>('$keyPrefix-position'),
            textAlign: TextAlign.center,
            style: theme.textTheme.labelLarge,
          ),
        ),
        FushiIconButton(
          key: const ValueKey<String>('$keyPrefix-next'),
          icon: FushiIcons.chevronRight,
          tooltip: t.manga_audio_review_next,
          enabled: position < total - 1,
          onTap: onNext,
        ),
      ],
    );
    final List<Widget> body = <Widget>[
      filter,
      nav,
      if (locked)
        AdaptiveSettingsRow(
          key: const ValueKey<String>('$keyPrefix-locked'),
          icon: FushiIcons.lock,
          showIcon: true,
          title: t.manga_audio_review_locked,
        ),
      if (l == null)
        Padding(
          padding: EdgeInsets.all(tokens.spacing.page),
          child: Text(
            pendingOnly ? t.manga_audio_review_empty : t.manga_audio_page_empty,
            key: const ValueKey<String>('$keyPrefix-empty'),
            textAlign: TextAlign.center,
          ),
        )
      else ...<Widget>[
        Text(
          text.isEmpty ? '—' : text,
          key: const ValueKey<String>('$keyPrefix-text'),
          style: theme.textTheme.titleMedium,
        ),
        Text(
          <String>[
            mangaLineKindLabel(l.kind),
            if (mangaLineNeedsReview(l) && l.speaker != kTtsUnknown)
              t.manga_audio_low_confidence,
            if (l.source == TtsCastSource.user) t.manga_audio_user_edited,
          ].join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(t.manga_audio_line_speaker, style: theme.textTheme.labelLarge),
        Wrap(
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            _speakerChip(kTtsNarrator, t.audiobook_studio_cast_narrator, l),
            for (final TtsCastCharacter c in roster)
              if (c.name != kTtsNarrator && c.name != kTtsUnknown)
                _speakerChip(c.name, c.name, l),
            _speakerChip(kTtsUnknown, t.audiobook_studio_cast_unknown, l),
            if (!locked)
              FushiActionChip(
                key: const ValueKey<String>('$keyPrefix-new-speaker'),
                icon: FushiIcons.personAdd,
                label: t.audiobook_studio_cast_new_speaker,
                onPressed: saving ? null : onNewSpeaker,
              ),
          ],
        ),
        if (l.speaker == kTtsUnknown)
          Text(
            t.manga_audio_review_unknown_hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        FushiFilledButton.icon(
          key: const ValueKey<String>('$keyPrefix-confirm'),
          icon: const Icon(FushiIcons.check),
          label: Text(t.manga_audio_review_confirm),
          onPressed: _readOnly ? null : () => onSpeaker(l.speaker),
        ),
      ],
    ];
    return FushiEntranceScope(
      replayKey: l?.lineId,
      child: ListView(
        key: const ValueKey<String>('$keyPrefix-panel'),
        padding: EdgeInsets.all(tokens.spacing.page),
        children: <Widget>[
          for (int i = 0; i < body.length; i++)
            FushiStaggeredEntrance(
              index: i,
              child: Padding(
                padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                child: body[i],
              ),
            ),
        ],
      ),
    );
  }

  Widget _speakerChip(String value, String label, MangaScriptLine line) =>
      FushiChoiceChip(
        key: ValueKey<String>('$keyPrefix-speaker-$value'),
        label: Text(label),
        selected: line.speaker == value,
        onSelected: _readOnly ? null : (_) => onSpeaker(value),
      );
}

/// 原页 + 气泡高亮。按 OCR 给的页尺寸定比例，块坐标按同一比例缩放；可双指缩放。
class _PagePreview extends StatelessWidget {
  const _PagePreview({
    required this.image,
    required this.pageFile,
    required this.pageImage,
    required this.highlight,
    required this.onBlockTap,
  });

  final MokuroImage? image;
  final File? pageFile;
  final ImageProvider<Object>? pageImage;
  final List<int> highlight;
  final ValueChanged<int> onBlockTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MokuroImage? img = image;
    final ImageProvider<Object>? provider =
        pageImage ?? (pageFile == null ? null : FileImage(pageFile!));
    if (img == null || img.size.isEmpty) return const SizedBox.shrink();
    final Widget placeholder = ColoredBox(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(FushiIcons.brokenImage),
            Text(t.manga_audio_review_no_image),
          ],
        ),
      ),
    );
    return InteractiveViewer(
      maxScale: 4,
      child: Center(
        child: AspectRatio(
          aspectRatio: img.size.width / img.size.height,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              final double scale = c.maxWidth / img.size.width;
              return GestureDetector(
                key: const ValueKey<String>(
                  '${MangaAudioReviewView.keyPrefix}-page',
                ),
                onTapUp: (TapUpDetails d) {
                  final int? block = mangaBlockAt(img, d.localPosition / scale);
                  if (block != null) onBlockTap(block);
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (provider == null)
                      placeholder
                    else
                      Image(
                        image: provider,
                        fit: BoxFit.fill,
                        errorBuilder: (_, _, _) => placeholder,
                      ),
                    TweenAnimationBuilder<double>(
                      key: ValueKey<String>(highlight.join('.')),
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: fushiMotionDuration(
                        context,
                        FushiMotion.medium,
                      ),
                      curve: Curves.easeOutCubic,
                      builder: (BuildContext context, double t, _) =>
                          CustomPaint(
                            key: const ValueKey<String>(
                              '${MangaAudioReviewView.keyPrefix}-highlight',
                            ),
                            painter: MangaReviewHighlightPainter(
                              rects: <Rect>[
                                for (final MokuroBlock b in img.blocks)
                                  b.rectangle.toRect(),
                              ],
                              highlight: highlight.toSet(),
                              scale: scale,
                              progress: t,
                              color: theme.colorScheme.primary,
                              outline: theme.colorScheme.outlineVariant,
                            ),
                          ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 页上所有块描淡边，当前句的块填色加粗边并随 [progress] 渐入。
@visibleForTesting
class MangaReviewHighlightPainter extends CustomPainter {
  MangaReviewHighlightPainter({
    required this.rects,
    required this.highlight,
    required this.scale,
    required this.progress,
    required this.color,
    required this.outline,
  });

  /// OCR 像素坐标里的块矩形（下标同 `MokuroImage.blocks`）。
  final List<Rect> rects;
  final Set<int> highlight;
  final double scale;
  final double progress;
  final Color color;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint faint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outline.withValues(alpha: 0.8);
    final Paint fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color.withValues(alpha: 0.22 * progress);
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = color.withValues(alpha: progress);
    for (int i = 0; i < rects.length; i++) {
      final Rect r = Rect.fromLTRB(
        rects[i].left * scale,
        rects[i].top * scale,
        rects[i].right * scale,
        rects[i].bottom * scale,
      );
      if (highlight.contains(i)) {
        final RRect rr = RRect.fromRectAndRadius(
          r.inflate(4),
          const Radius.circular(6),
        );
        canvas
          ..drawRRect(rr, fill)
          ..drawRRect(rr, stroke);
      } else {
        canvas.drawRect(r, faint);
      }
    }
  }

  @override
  bool shouldRepaint(MangaReviewHighlightPainter old) =>
      old.progress != progress ||
      old.scale != scale ||
      old.color != color ||
      old.outline != outline ||
      !setEquals(old.highlight, highlight) ||
      !listEquals(old.rects, rects);
}
