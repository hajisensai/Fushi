/// 浏览页的检查器（宽屏右栏；手机是全屏详情页 [SrsBrowseDetailPage]，同三页）：
///
/// - 预览：卡面（[SrsBrowsePreview]，与复习页同一个卡面视图）+ 例句上下文（被挖的词高亮）+ 原声片段 +「回到出处」。
/// - 编辑：字段原地编辑（复用笔记编辑器的 [SrsFieldEditor]，停笔后自动保存）+ 标签；写入走浏览页的批量改字段 /
///   改标签（条件写 + 进撤销栈），见 [SrsBrowseInspector.onSaveField] / [SrsBrowseInspector.onSaveTags]。
/// - 历史：下次复习 / 当前保持率 / 间隔·难度 / 复习·遗忘四格，保持率预测曲线（按复习记录分段的 FSRS 遗忘
///   曲线，可提取度一次批量算），逐次评分记录（[SrsDbStore.history]）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki_core.dart'
    show CardSourceLink, FushiCardFields, kFushiCardSwitchFields;
import 'package:fushi_engine/srs/srs_browse.dart';
import 'package:fushi_engine/srs/srs_browse_ops.dart' show srsParseTags;
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/anki/card_source_origin.dart'
    show cardSourceLinkOfFields;
import 'package:fushi/src/anki/card_source_router.dart' show openCardSource;
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_card_tile.dart';
import 'package:fushi/src/pages/implementations/srs/srs_browse_preview.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart'
    show srsSoundPlayerProvider;
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/pages/implementations/srs/srs_field_editors.dart';
import 'package:fushi/src/srs/srs_fushi_card_fields.dart' show srsPlainText;
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_loading_view.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 检查器的页签。
enum SrsBrowseInspectorTab { preview, edit, history }

/// 改一个字段（按字段名，条件写 + 进撤销栈；由浏览页实现）。
typedef SrsBrowseSaveField =
    Future<void> Function(String noteId, String fieldName, String value);

/// 改标签（[before] → [after]，由浏览页拆成加 / 删两步批量写）。
typedef SrsBrowseSaveTags =
    Future<void> Function(
      String noteId,
      List<String> before,
      List<String> after,
    );

/// 检查器底部的动作（暂停 / 旗标 / 更多，由浏览页给）。
class SrsBrowseInspectorActions {
  const SrsBrowseInspectorActions({
    required this.onSuspend,
    required this.onFlag,
    required this.onMore,
    required this.suspended,
  });

  final VoidCallback onSuspend;
  final VoidCallback onFlag;
  final VoidCallback onMore;
  final bool suspended;
}

/// 笔记里的例句字段：名字含 sentence / 例句（不是音频 / 翻译 / 注音那几个）的第一个字段 id。
String? srsBrowseSentenceFieldId(SrsNoteTypeView type) {
  for (final SrsFieldDef f in type.fields) {
    final String n = f.name.toLowerCase();
    if ((n.contains('sentence') || n.contains('例句')) &&
        !n.contains('audio') &&
        !n.contains('translation') &&
        !n.contains('furigana') &&
        !n.contains('reading')) {
      return f.id;
    }
  }
  return null;
}

/// 原声片段字段：名字同时含 sentence 与 audio 的第一个字段 id。
String? srsBrowseSentenceAudioFieldId(SrsNoteTypeView type) {
  for (final SrsFieldDef f in type.fields) {
    final String n = f.name.toLowerCase();
    if (n.contains('sentence') && n.contains('audio')) return f.id;
  }
  return null;
}

final RegExp _sound = RegExp(r'\[sound:([^\]]+)\]');

/// 检查器。
class SrsBrowseInspector extends ConsumerStatefulWidget {
  const SrsBrowseInspector({
    super.key,
    required this.row,
    required this.revision,
    required this.tab,
    required this.onTabChanged,
    required this.showAnswer,
    required this.onCommand,
    required this.onSaveField,
    required this.onSaveTags,
    required this.onOpenEditor,
    required this.actions,
    this.position,
    this.hasPrevious = false,
    this.hasNext = false,
    this.lookup,
    this.onLookupClosed,
  });

  final SrsBrowseRow row;
  final int revision;
  final SrsBrowseInspectorTab tab;
  final ValueChanged<SrsBrowseInspectorTab> onTabChanged;
  final bool showAnswer;
  final void Function(SrsPreviewCommand command) onCommand;
  final SrsBrowseSaveField onSaveField;
  final SrsBrowseSaveTags onSaveTags;
  final void Function(String noteId) onOpenEditor;
  final SrsBrowseInspectorActions actions;
  final String? position;
  final bool hasPrevious;
  final bool hasNext;
  final SrsCardLookupController? lookup;
  final VoidCallback? onLookupClosed;

  @override
  ConsumerState<SrsBrowseInspector> createState() => _SrsBrowseInspectorState();
}

class _SrsBrowseInspectorState extends ConsumerState<SrsBrowseInspector> {
  SrsCardDetail? _detail;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(SrsBrowseInspector old) {
    super.didUpdateWidget(old);
    if (old.row.cardId != widget.row.cardId ||
        old.revision != widget.revision) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final int seq = ++_seq;
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final SrsCardDetail? detail = await store.cardDetail(widget.row.cardId);
    if (!mounted || seq != _seq) return;
    setState(() => _detail = detail);
  }

  CardSourceLink? get _link {
    final SrsCardDetail? d = _detail;
    return d == null ? null : cardSourceLinkOfFields(d.note.fields.values);
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsCardDetail? detail = _detail;
    final Widget page = switch (widget.tab) {
      SrsBrowseInspectorTab.preview => _PreviewTab(
        key: const ValueKey<String>('srs-browse-inspector-preview'),
        inspector: widget,
        detail: detail,
      ),
      SrsBrowseInspectorTab.edit =>
        detail == null
            ? const FushiLoadingView()
            : _EditTab(
                key: ValueKey<String>(
                  'srs-browse-inspector-edit-${detail.note.id}',
                ),
                detail: detail,
                onSaveField: widget.onSaveField,
                onSaveTags: widget.onSaveTags,
                onOpenEditor: widget.onOpenEditor,
              ),
      SrsBrowseInspectorTab.history =>
        detail == null
            ? const FushiLoadingView()
            : _HistoryTab(
                key: ValueKey<String>(
                  'srs-browse-inspector-history-${detail.card.id}',
                ),
                row: widget.row,
                detail: detail,
                revision: widget.revision,
              ),
    };
    final CardSourceLink? link = _link;
    return Column(
      key: const ValueKey<String>('srs-browse-inspector'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        adaptiveSegmentedButton<SrsBrowseInspectorTab>(
          context: context,
          segments: <ButtonSegment<SrsBrowseInspectorTab>>[
            ButtonSegment<SrsBrowseInspectorTab>(
              value: SrsBrowseInspectorTab.preview,
              label: Text(
                t.srs_browse_preview,
                key: const ValueKey<String>('srs-browse-tab-preview'),
              ),
            ),
            ButtonSegment<SrsBrowseInspectorTab>(
              value: SrsBrowseInspectorTab.edit,
              label: Text(
                t.srs_browse_tab_edit,
                key: const ValueKey<String>('srs-browse-tab-edit'),
              ),
            ),
            ButtonSegment<SrsBrowseInspectorTab>(
              value: SrsBrowseInspectorTab.history,
              label: Text(
                t.srs_browse_tab_history,
                key: const ValueKey<String>('srs-browse-tab-history'),
              ),
            ),
          ],
          selected: <SrsBrowseInspectorTab>{widget.tab},
          onSelectionChanged: (Set<SrsBrowseInspectorTab> v) =>
              widget.onTabChanged(v.first),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: fushiMotionDuration(context, FushiMotion.short),
            switchInCurve: FushiMotion.enter,
            switchOutCurve: FushiMotion.exit,
            // 卡面要拿到紧约束（默认 Stack 只给宽松约束，WebView 会量成 0）。
            layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
              fit: StackFit.expand,
              children: <Widget>[...previous, ?current],
            ),
            child: KeyedSubtree(
              key: ValueKey<SrsBrowseInspectorTab>(widget.tab),
              child: page,
            ),
          ),
        ),
        Row(
          spacing: tokens.spacing.gap,
          children: <Widget>[
            Expanded(
              child: FushiFilledButton.tonalIcon(
                key: const ValueKey<String>('srs-browse-open-source'),
                onPressed: link == null
                    ? null
                    : () => srsRunLogged(
                        'SrsBrowse.openSource',
                        () => openCardSource(ref: ref, link: link),
                      ),
                icon: const FushiIcon(FushiIcons.openInNew),
                label: Text(t.srs_browse_open_source),
              ),
            ),
            FushiIconButton(
              key: const ValueKey<String>('srs-browse-inspector-suspend'),
              icon: widget.actions.suspended
                  ? FushiIcons.play
                  : FushiIcons.pause,
              tooltip: widget.actions.suspended
                  ? t.srs_browse_swipe_unsuspend
                  : t.srs_browse_swipe_suspend,
              onTap: widget.actions.onSuspend,
            ),
            FushiIconButton(
              key: const ValueKey<String>('srs-browse-inspector-flag'),
              icon: FushiIcons.flag,
              tooltip: t.srs_card_flag,
              onTap: widget.actions.onFlag,
            ),
            FushiIconButton(
              key: const ValueKey<String>('srs-browse-inspector-more'),
              icon: FushiIcons.moreHoriz,
              tooltip: t.srs_browse_batch_actions,
              onTap: widget.actions.onMore,
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 预览

class _PreviewTab extends ConsumerWidget {
  const _PreviewTab({super.key, required this.inspector, required this.detail});

  final SrsBrowseInspector inspector;
  final SrsCardDetail? detail;

  Future<void> _play(WidgetRef ref, String name) async {
    final SrsMediaStore? media = await ref.read(srsMediaStoreProvider.future);
    final File? file = media?.resolve(name);
    if (file == null || !await file.exists()) {
      FushiToast.show(msg: t.srs_media_missing(name: name));
      return;
    }
    await ref.read(srsSoundPlayerProvider)(file.path);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsCardDetail? d = detail;
    String? sentence;
    String? clip;
    if (d != null) {
      final String? sid = srsBrowseSentenceFieldId(d.noteType);
      if (sid != null) {
        final String plain = srsPlainText(d.note.field(sid)).trim();
        if (plain.isNotEmpty) sentence = plain;
      }
      final String? aid = srsBrowseSentenceAudioFieldId(d.noteType);
      if (aid != null) clip = _sound.firstMatch(d.note.field(aid))?.group(1);
    }
    final String term = inspector.row.sortText;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final Color accent = apple ? appleColorsOf(context).accent : scheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: tokens.spacing.gap,
      children: <Widget>[
        Expanded(
          child: SrsBrowsePreview(
            cardId: inspector.row.cardId,
            revision: inspector.revision,
            showAnswer: inspector.showAnswer,
            position: inspector.position,
            hasPrevious: inspector.hasPrevious,
            hasNext: inspector.hasNext,
            onCommand: inspector.onCommand,
            onEdit: () => inspector.onOpenEditor(inspector.row.noteId),
            lookup: inspector.lookup,
            onLookupClosed: inspector.onLookupClosed,
          ),
        ),
        if (sentence != null || clip != null)
          FushiCard(
            key: const ValueKey<String>('srs-browse-context'),
            pressScale: false,
            child: Row(
              spacing: tokens.spacing.gap,
              children: <Widget>[
                if (clip != null)
                  FushiPressScale(
                    child: FushiIconButton(
                      key: const ValueKey<String>('srs-browse-play-clip'),
                      icon: FushiIcons.volumeUp,
                      tooltip: t.srs_browse_source_play,
                      onTap: () => srsRunLogged(
                        'SrsBrowse.playClip',
                        () => _play(ref, clip!),
                      ),
                    ),
                  ),
                if (sentence != null)
                  Expanded(
                    child: Text.rich(
                      _highlight(
                        sentence,
                        term,
                        context.fushiType.bodyLarge,
                        accent,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 例句里被挖的词高亮（按原文相等匹配，不做任何读音推断）。
  static TextSpan _highlight(
    String text,
    String term,
    TextStyle style,
    Color accent,
  ) {
    if (term.isEmpty || !text.contains(term)) {
      return TextSpan(text: text, style: style);
    }
    final List<String> parts = text.split(term);
    return TextSpan(
      style: style,
      children: <InlineSpan>[
        for (int i = 0; i < parts.length; i++) ...<InlineSpan>[
          TextSpan(text: parts[i]),
          if (i < parts.length - 1)
            TextSpan(
              text: term,
              style: TextStyle(color: accent, fontWeight: FontWeight.w700),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- 编辑

class _EditTab extends StatefulWidget {
  const _EditTab({
    super.key,
    required this.detail,
    required this.onSaveField,
    required this.onSaveTags,
    required this.onOpenEditor,
  });

  final SrsCardDetail detail;
  final SrsBrowseSaveField onSaveField;
  final SrsBrowseSaveTags onSaveTags;
  final void Function(String noteId) onOpenEditor;

  @override
  State<_EditTab> createState() => _EditTabState();
}

class _EditTabState extends State<_EditTab> {
  final Map<String, SrsFieldModel> _models = <String, SrsFieldModel>{};

  /// 每个字段最近一次落库（或载入）的值：外部重读时只重置没在改的字段。
  final Map<String, String> _saved = <String, String>{};
  final Map<String, Timer> _pending = <String, Timer>{};
  late final TextEditingController _tags = TextEditingController(
    text: widget.detail.note.tags.join(' '),
  );

  /// 标签最近一次落库（或载入）的值：与字段同一套生命周期（失焦 / 回车 / 关掉时落库，外部重读时没在改才同步）。
  late List<String> _savedTags = _normalTags(widget.detail.note.tags);
  bool _justSaved = false;

  bool get _tagsDirty => !_sameTags(srsParseTags(_tags.text), _savedTags);

  /// 笔记上的标签按输入框的解析规则规整（去重同 [srsParseTags]），比较才与输入框同口径。
  static List<String> _normalTags(List<String> tags) =>
      srsParseTags(tags.join(' '));

  static bool _sameTags(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    for (final SrsFieldDef f in widget.detail.noteType.fields) {
      final String v = widget.detail.note.field(f.id);
      _saved[f.id] = v;
      _models[f.id] = SrsFieldModel(v)..addListener(() => _schedule(f));
    }
  }

  @override
  void didUpdateWidget(_EditTab old) {
    super.didUpdateWidget(old);
    // 同一条笔记被别处写了（批量操作 / 撤销）：没在改的字段换成新值。
    for (final SrsFieldDef f in widget.detail.noteType.fields) {
      final String v = widget.detail.note.field(f.id);
      final SrsFieldModel? m = _models[f.id];
      if (m == null || _pending.containsKey(f.id)) continue;
      if (v != _saved[f.id] && m.value == _saved[f.id]) {
        _saved[f.id] = v;
        m.reset(v);
      }
    }
    // 标签同理：外部改了、这边没有未保存的改动时换成新值。
    final List<String> tags = _normalTags(widget.detail.note.tags);
    if (!_sameTags(tags, _savedTags) && !_tagsDirty) {
      _savedTags = tags;
      _tags.text = tags.join(' ');
    }
  }

  @override
  void dispose() {
    // 关掉前把停笔前的改动落库（不丢字）。
    for (final MapEntry<String, Timer> e in _pending.entries) {
      e.value.cancel();
      final SrsFieldDef? f = widget.detail.noteType.fields
          .where((SrsFieldDef x) => x.id == e.key)
          .firstOrNull;
      if (f != null) unawaited(_save(f));
    }
    // [_saveTags] 在第一个 await 之前就读完了输入框，随后释放控制器不影响落库。
    if (_tagsDirty) unawaited(_saveTags());
    for (final SrsFieldModel m in _models.values) {
      m.dispose();
    }
    _tags.dispose();
    super.dispose();
  }

  void _schedule(SrsFieldDef f) {
    _pending[f.id]?.cancel();
    _pending[f.id] = Timer(const Duration(milliseconds: 800), () {
      _pending.remove(f.id);
      unawaited(_save(f));
    });
  }

  Future<void> _save(SrsFieldDef f) async {
    final String value = _models[f.id]!.value;
    if (value == _saved[f.id]) return;
    _saved[f.id] = value;
    try {
      await widget.onSaveField(widget.detail.note.id, f.name, value);
      if (mounted) setState(() => _justSaved = true);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.inlineEdit', e, stack);
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    }
  }

  Future<void> _saveTags() async {
    final List<String> after = srsParseTags(_tags.text);
    final List<String> before = _savedTags;
    if (_sameTags(after, before)) return;
    _savedTags = after;
    try {
      await widget.onSaveTags(widget.detail.note.id, before, after);
      if (mounted) setState(() => _justSaved = true);
    } catch (e, stack) {
      ErrorLogService.instance.log('SrsBrowse.inlineTags', e, stack);
      // 没写进去：仍算未保存，下次失焦 / 回车再写。
      if (_sameTags(_savedTags, after)) _savedTags = before;
      FushiToast.show(msg: t.srs_action_failed, severity: ToastSeverity.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsNoteTypeView type = widget.detail.noteType;
    final bool builtin = type.builtinKey == kSrsBuiltinFushiCardKey;
    final List<SrsFieldDef> fields = type.fields;
    return FushiEntranceScope(
      replayKey: widget.detail.note.id,
      child: ListView.builder(
        key: const ValueKey<String>('srs-browse-edit-fields'),
        itemCount: fields.length + 2,
        itemBuilder: fushiStaggeredItemBuilder((BuildContext context, int i) {
          if (i == fields.length) {
            return Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap),
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: (bool focused) {
                  if (!focused) unawaited(_saveTags());
                },
                child: FushiTextField(
                  key: const ValueKey<String>('srs-browse-edit-tags'),
                  controller: _tags,
                  labelText: t.srs_browse_edit_tags,
                  hintText: t.srs_note_tags_hint,
                  onSubmitted: (_) => unawaited(_saveTags()),
                ),
              ),
            );
          }
          if (i == fields.length + 1) {
            return Padding(
              padding: EdgeInsets.only(top: tokens.spacing.gap),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: AnimatedOpacity(
                      opacity: _justSaved ? 1 : 0,
                      duration: fushiMotionDuration(context, FushiMotion.short),
                      child: Text(
                        t.srs_browse_edit_saved,
                        style: context.fushiType.bodySmall,
                      ),
                    ),
                  ),
                  FushiTextButton(
                    key: const ValueKey<String>('srs-browse-edit-full'),
                    onPressed: () => widget.onOpenEditor(widget.detail.note.id),
                    child: Text(t.srs_browse_edit_full),
                  ),
                ],
              ),
            );
          }
          final SrsFieldDef f = fields[i];
          return Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (bool focused) {
                if (!focused && _pending.containsKey(f.id)) {
                  _pending.remove(f.id)?.cancel();
                  unawaited(_save(f));
                }
              },
              child: SrsFieldEditor(
                key: ValueKey<String>('srs-browse-field-${f.name}'),
                name: f.name,
                model: _models[f.id]!,
                toggle:
                    builtin &&
                    kFushiCardSwitchFields.contains(
                      FushiCardFields.canonical(f.name),
                    ),
                css: type.css,
                fushiCard: builtin,
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ---------------------------------------------------------------- 历史

/// 曲线上的一段：某次复习后的记忆状态从 [fromMs] 起，到 [toMs] 止。
typedef _CurveSegment = ({int fromMs, int toMs, SrsMemory memory});

/// 一张卡的保持率预测曲线采样：按复习记录分段（每段用那次复习后的记忆状态），最后一段延到此刻之后
/// [futureDays] 天。可提取度一次批量算（[srsRetrievabilityBatch]）。没有记忆状态返回空表。
List<({int atMs, double r})> srsBrowseRetentionCurve({
  required FsrsEngine engine,
  required SrsAlgorithm algorithm,
  required List<double> params,
  required List<SrsReviewLog> logs,
  required int nowMs,
  required double futureDays,
  int samplesPerSegment = 24,
}) {
  final List<({int at, SrsMemory memory})> points =
      <({int at, SrsMemory memory})>[
        for (final SrsReviewLog l in logs)
          if (l.isRatingReview && l.result?.memory != null)
            (at: l.occurredAt, memory: l.result!.memory!),
      ]..sort((a, b) => a.at.compareTo(b.at));
  if (points.isEmpty) return const <({int atMs, double r})>[];
  final int end = nowMs + (futureDays * Duration.millisecondsPerDay).round();
  final List<_CurveSegment> segments = <_CurveSegment>[
    for (int i = 0; i < points.length; i++)
      (
        fromMs: points[i].at,
        toMs: i + 1 < points.length
            ? points[i + 1].at
            : math.max(end, points[i].at + 1),
        memory: points[i].memory,
      ),
  ];
  final List<int> at = <int>[];
  final List<SrsMemory> memories = <SrsMemory>[];
  final List<double> elapsed = <double>[];
  for (final _CurveSegment s in segments) {
    for (int k = 0; k <= samplesPerSegment; k++) {
      final int ms =
          s.fromMs + ((s.toMs - s.fromMs) * k / samplesPerSegment).round();
      at.add(ms);
      memories.add(s.memory);
      elapsed.add((ms - s.fromMs) / Duration.millisecondsPerDay);
    }
  }
  final List<double> r = srsRetrievabilityBatch(
    engine,
    algorithm: algorithm,
    params: params,
    memories: memories,
    elapsedDays: elapsed,
  );
  return <({int atMs, double r})>[
    for (int i = 0; i < at.length; i++) (atMs: at[i], r: r[i].clamp(0, 1)),
  ];
}

class _HistoryData {
  const _HistoryData({
    required this.logs,
    required this.curve,
    required this.target,
    required this.nowMs,
  });

  final List<SrsReviewLog> logs;
  final List<({int atMs, double r})> curve;
  final double target;
  final int nowMs;
}

class _HistoryTab extends ConsumerStatefulWidget {
  const _HistoryTab({
    super.key,
    required this.row,
    required this.detail,
    required this.revision,
  });

  final SrsBrowseRow row;
  final SrsCardDetail detail;
  final int revision;

  @override
  ConsumerState<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<_HistoryTab> {
  _HistoryData? _data;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(_HistoryTab old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) unawaited(_load());
  }

  Future<void> _load() async {
    final SrsDbStore? store = await readSrsStore(ref);
    if (store == null) return;
    final SrsCardHistory history = await store.history(widget.detail.card.id);
    final SrsDeckTree tree = await store.deckTree();
    final (int nowMs, _) = store.now();
    final String deck = tree.effectiveDeckOf(
      widget.detail.card.deckId,
      fallback: store.defaultDeckId,
    );
    final SrsSchedulingConfig config = tree[deck] == null
        ? const SrsSchedulingConfig()
        : tree.schedulingConfig(deck);
    final FsrsEngine? engine = store.engine;
    final SrsAlgorithm alg = config.algorithm.memoryAlgorithm;
    final List<SrsReviewLog> logs = history.effective;
    final int interval = widget.row.intervalDays ?? 1;
    final List<({int atMs, double r})> curve = engine == null
        ? const <({int atMs, double r})>[]
        : srsBrowseRetentionCurve(
            engine: engine,
            algorithm: alg,
            params: config.params.length == alg.paramCount
                ? config.params
                : engine.defaultParams(alg),
            logs: logs,
            nowMs: nowMs,
            futureDays: math.max(7, interval * 1.5),
          );
    if (!mounted) return;
    setState(
      () => _data = _HistoryData(
        logs: <SrsReviewLog>[
          for (final SrsReviewLog l in logs.reversed)
            if (l.kind == SrsLogKind.review) l,
        ],
        curve: curve,
        target: config.desiredRetention,
        nowMs: nowMs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SrsBrowseRow row = widget.row;
    final _HistoryData? data = _data;
    final double? retention = row.retention;
    final double? difficulty = row.difficulty;
    final List<(String, String)> stats = <(String, String)>[
      (t.srs_browse_history_next, srsBrowseDueText(row)),
      (
        t.srs_browse_history_retention,
        retention == null ? '—' : srsBrowsePercent(retention),
      ),
      (
        t.srs_browse_history_interval,
        '${row.intervalDays == null ? '—' : t.srs_browse_history_days(n: row.intervalDays!)}'
            ' · ${difficulty == null ? '—' : difficulty.toStringAsFixed(1)}',
      ),
      (t.srs_browse_history_reviews, '${row.reps} · ${row.lapses}'),
    ];
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = isGlassDesign(context);
    final Color muted = apple
        ? appleColorsOf(context).secondaryLabel
        : scheme.onSurfaceVariant;
    final List<Widget> children = <Widget>[
      LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) {
          final int perRow = c.maxWidth >= 420 ? 4 : 2;
          final double w =
              (c.maxWidth - tokens.spacing.gap * (perRow - 1)) / perRow;
          return Wrap(
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              for (final (String label, String value) in stats)
                SizedBox(
                  width: w,
                  child: FushiCard(
                    pressScale: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: <Widget>[
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.fushiType.labelMedium.copyWith(
                            color: muted,
                          ),
                        ),
                        Text(
                          value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.fushiType.titleMediumEmphasized,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      if (data != null && data.curve.length > 1)
        FushiCard(
          key: const ValueKey<String>('srs-browse-retention-curve'),
          pressScale: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: tokens.spacing.gap,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      t.srs_browse_history_curve,
                      style: context.fushiType.titleSmall,
                    ),
                  ),
                  Text(
                    t.srs_browse_history_target(
                      p: srsBrowsePercent(data.target),
                    ),
                    style: context.fushiType.labelMedium.copyWith(color: muted),
                  ),
                ],
              ),
              SizedBox(
                height: 120,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: fushiMotionDuration(context, FushiMotion.long),
                  curve: FushiMotion.enter,
                  builder: (BuildContext context, double p, Widget? _) =>
                      CustomPaint(
                        painter: _CurvePainter(
                          curve: data.curve,
                          target: data.target,
                          nowMs: data.nowMs,
                          progress: p,
                          line: apple
                              ? appleColorsOf(context).accent
                              : scheme.primary,
                          guide: muted.withValues(alpha: 0.4),
                        ),
                      ),
                ),
              ),
            ],
          ),
        ),
      Text(
        t.srs_browse_history_added(
          date: MaterialLocalizations.of(
            context,
          ).formatShortDate(DateTime.fromMillisecondsSinceEpoch(row.addedAt)),
        ),
        style: context.fushiType.bodySmall.copyWith(color: muted),
      ),
      if (data != null && data.logs.isEmpty)
        FushiPlaceholderMessage(
          icon: FushiIcons.history,
          message: t.srs_browse_history_empty,
        ),
      if (data != null)
        for (final SrsReviewLog l in data.logs) _LogRow(log: l),
    ];
    return FushiEntranceScope(
      replayKey: widget.detail.card.id,
      child: ListView.builder(
        key: const ValueKey<String>('srs-browse-history'),
        itemCount: children.length,
        itemBuilder: fushiStaggeredItemBuilder(
          (BuildContext context, int i) => Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.gap),
            child: children[i],
          ),
        ),
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.log});

  final SrsReviewLog log;

  @override
  Widget build(BuildContext context) {
    final int? rating = log.rating;
    final String grade = switch (rating) {
      1 => t.srs_rating_again,
      2 => t.srs_rating_hard,
      3 => t.srs_rating_good,
      4 => t.srs_rating_easy,
      _ => '—',
    };
    final FushiTagTone tone = switch (rating) {
      1 => FushiTagTone.error,
      2 => FushiTagTone.warning,
      3 => FushiTagTone.success,
      4 => FushiTagTone.accent,
      _ => FushiTagTone.neutral,
    };
    final String type = switch (log.reviewType) {
      SrsReviewType.learn => t.srs_browse_history_learn,
      SrsReviewType.review => t.srs_browse_history_review,
      SrsReviewType.relearn => t.srs_browse_history_relearn,
      _ => t.srs_browse_history_other,
    };
    final int? days = log.result?.scheduledDays;
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(log.occurredAt);
    return FushiListItem(
      density: FushiListDensity.compact,
      leading: FushiTag(text: grade, tone: tone, dense: true),
      title: Text(
        <String>[
          MaterialLocalizations.of(context).formatShortMonthDay(at),
          type,
          if (days != null && days > 0) t.srs_browse_history_days(n: days),
        ].join(' · '),
      ),
      trailing: log.durationMs > 0
          ? Text(
              t.srs_browse_history_seconds(n: (log.durationMs / 1000).round()),
            )
          : null,
    );
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.curve,
    required this.target,
    required this.nowMs,
    required this.progress,
    required this.line,
    required this.guide,
  });

  final List<({int atMs, double r})> curve;
  final double target;
  final int nowMs;
  final double progress;
  final Color line;
  final Color guide;

  @override
  void paint(Canvas canvas, Size size) {
    final int t0 = curve.first.atMs;
    final int t1 = curve.last.atMs;
    final double span = math.max(1, t1 - t0).toDouble();
    Offset pos(int at, double r) =>
        Offset((at - t0) / span * size.width, (1 - r) * size.height);
    final Paint guidePaint = Paint()
      ..color = guide
      ..strokeWidth = 1;
    final double ty = (1 - target) * size.height;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, ty), Offset(x + 4, ty), guidePaint);
    }
    if (nowMs > t0 && nowMs < t1) {
      final double nx = (nowMs - t0) / span * size.width;
      canvas.drawLine(Offset(nx, 0), Offset(nx, size.height), guidePaint);
    }
    final int n = math.max(2, (curve.length * progress).round());
    final Path path = Path()
      ..moveTo(
        pos(curve[0].atMs, curve[0].r).dx,
        pos(curve[0].atMs, curve[0].r).dy,
      );
    for (int i = 1; i < n && i < curve.length; i++) {
      final Offset p = pos(curve[i].atMs, curve[i].r);
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.progress != progress ||
      old.curve != curve ||
      old.line != line ||
      old.target != target;
}

// ---------------------------------------------------------------- 手机详情页

/// 手机上点卡片进的全屏详情页：同三页，左右切换上一张 / 下一张（行按页向原生会话取）。
class SrsBrowseDetailPage extends ConsumerStatefulWidget {
  const SrsBrowseDetailPage({
    super.key,
    required this.result,
    required this.initialIndex,
    required this.onSaveField,
    required this.onSaveTags,
    required this.onOpenEditor,
    required this.actionsFor,
    required this.revision,
  });

  final SrsBrowseResult result;
  final int initialIndex;
  final SrsBrowseSaveField onSaveField;
  final SrsBrowseSaveTags onSaveTags;
  final Future<void> Function(String noteId) onOpenEditor;

  /// 第 i 行的底部动作（暂停 / 旗标 / 更多）。
  final SrsBrowseInspectorActions Function(SrsBrowseRow row) actionsFor;

  /// 浏览页写入后递增（这里据此重读卡面 / 历史）。
  final ValueListenable<int> revision;

  @override
  ConsumerState<SrsBrowseDetailPage> createState() =>
      _SrsBrowseDetailPageState();
}

class _SrsBrowseDetailPageState extends ConsumerState<SrsBrowseDetailPage> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'srs-browse-detail');
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    canOwn: (FocusReclaimCause cause) =>
        mounted && (ModalRoute.of(context)?.isCurrent ?? false),
  );
  late int _index = widget.initialIndex.clamp(0, widget.result.length - 1);
  final SrsCardLookupController _lookupCtl = SrsCardLookupController();
  bool _showAnswer = false;
  SrsBrowseInspectorTab _tab = SrsBrowseInspectorTab.preview;

  @override
  void initState() {
    super.initState();
    widget.revision.addListener(_onRevision);
  }

  @override
  void dispose() {
    widget.revision.removeListener(_onRevision);
    _lookupCtl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onRevision() {
    if (mounted) setState(() {});
  }

  void _go(int delta) {
    final int next = _index + delta;
    if (next < 0 || next >= widget.result.length) return;
    setState(() {
      _index = next;
      _showAnswer = false;
    });
    if (widget.result.rowAt(next) == null) {
      srsRunLogged('SrsBrowseDetail.rows', () async {
        await widget.result.ensure(next, next + 1);
        if (mounted) setState(() {});
      });
    }
  }

  void _command(SrsPreviewCommand c) {
    switch (c) {
      case SrsPreviewCommand.flip:
        setState(() => _showAnswer = !_showAnswer);
      case SrsPreviewCommand.previous:
        _go(-1);
      case SrsPreviewCommand.next:
        _go(1);
      case SrsPreviewCommand.undo:
        break;
      case SrsPreviewCommand.escape:
        unawaited(Navigator.of(context).maybePop());
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final KeyEventResult? lookup = _lookupCtl.guardKey(event);
    if (lookup != null) return lookup;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard kb = HardwareKeyboard.instance;
    if (kb.isControlPressed || kb.isMetaPressed || kb.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final SrsPreviewCommand? c = switch (event.logicalKey) {
      LogicalKeyboardKey.space ||
      LogicalKeyboardKey.enter ||
      LogicalKeyboardKey.numpadEnter ||
      LogicalKeyboardKey.gameButtonA => SrsPreviewCommand.flip,
      LogicalKeyboardKey.arrowLeft => SrsPreviewCommand.previous,
      LogicalKeyboardKey.arrowRight => SrsPreviewCommand.next,
      _ => null,
    };
    if (c == null) return KeyEventResult.ignored;
    _command(c);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool apple = isGlassDesign(context);
    final SrsBrowseRow? item = widget.result.rowAt(_index);
    final String title = item == null || item.sortText.isEmpty
        ? t.srs_browse_preview
        : item.sortText;
    final String position = '${_index + 1} / ${widget.result.length}';
    final NavigatorState? navigator = Navigator.maybeOf(context);
    final List<FushiToolbarItem> nav = <FushiToolbarItem>[
      FushiToolbarItem(
        key: const ValueKey<String>('srs-detail-prev'),
        icon: FushiIcons.chevronLeft,
        label: t.srs_browse_preview_prev,
        onPressed: _index > 0 ? () => _go(-1) : null,
      ),
      FushiToolbarItem(
        key: const ValueKey<String>('srs-detail-next'),
        icon: FushiIcons.chevronRight,
        label: t.srs_browse_preview_next,
        onPressed: _index < widget.result.length - 1 ? () => _go(1) : null,
      ),
    ];
    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKey,
      child: FushiPageScaffold(
        title: title,
        subtitle: position,
        actions: apple
            ? <Widget>[
                for (final FushiToolbarItem i in nav)
                  FushiIconButton(
                    key: i.key,
                    icon: i.icon,
                    tooltip: i.label,
                    enabled: i.onPressed != null,
                    onTap: i.onPressed,
                  ),
              ]
            : const <Widget>[],
        header: apple
            ? null
            : Padding(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.gap,
                ),
                child: FushiFloatingTopBar(
                  title: title,
                  subtitle: position,
                  leading: <FushiToolbarItem>[
                    if (navigator != null && navigator.canPop())
                      FushiToolbarItem(
                        icon: FushiIcons.back,
                        label: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        onPressed: () => unawaited(navigator.maybePop()),
                      ),
                  ],
                  actions: <List<FushiToolbarItem>>[nav],
                ),
              ),
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              tokens.spacing.gap,
            ),
            child: item == null
                ? const FushiLoadingView()
                : SrsBrowseInspector(
                    row: item,
                    revision: widget.revision.value,
                    tab: _tab,
                    onTabChanged: (SrsBrowseInspectorTab v) =>
                        setState(() => _tab = v),
                    showAnswer: _showAnswer,
                    position: position,
                    hasPrevious: _index > 0,
                    hasNext: _index < widget.result.length - 1,
                    onCommand: _command,
                    onSaveField: widget.onSaveField,
                    onSaveTags: widget.onSaveTags,
                    onOpenEditor: (String noteId) => srsRunLogged(
                      'SrsBrowseDetail.edit',
                      () => _focusOwnership.guardOverlay(
                        () => widget.onOpenEditor(noteId),
                      ),
                    ),
                    actions: widget.actionsFor(item),
                    lookup: _lookupCtl,
                    onLookupClosed: () => _focusOwnership.reclaim(
                      FocusReclaimCause.overlayClosed,
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
