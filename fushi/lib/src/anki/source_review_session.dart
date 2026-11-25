import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/anki/anki_mined_card_action_sheet.dart';
import 'package:fushi/src/anki/remote_mining_anki_repository.dart';
import 'package:fushi/src/anki/source_review_draft_store.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/anki/source_review_controls.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// Reading state and note edits have independent lifetimes. Continuing reading
/// never turns an edit of the source note into creation of another note.
class SourceReviewSession extends ChangeNotifier {
  SourceReviewSession({
    required this.link,
    required this.repository,
    required this.draftStore,
    this.onReturnToReading,
  });

  final CardSourceLink link;
  final BaseAnkiRepository repository;
  final SourceReviewDraftStore draftStore;
  final Future<void> Function()? onReturnToReading;
  bool _isReview = true;
  bool _busy = false;
  bool _disposed = false;
  bool _hasDraft = false;
  Future<void>? _draftLoad;
  BuildContext? _context;

  bool get isReview => _isReview;
  bool get busy => _busy;
  bool get hasDraft => _hasDraft;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _context = null;
    super.dispose();
  }

  void continueReading() {
    if (!_isReview || _busy) return;
    _isReview = false;
    _notify();
  }

  Future<void> returnToReading(VoidCallback fallback) async {
    if (_busy) return;
    _busy = true;
    _notify();
    try {
      final Future<void> Function()? restore = onReturnToReading;
      if (restore == null) {
        fallback();
      } else {
        await restore();
      }
    } finally {
      _busy = false;
      _notify();
    }
  }

  void attachContext(BuildContext context) {
    _context = context;
    _draftLoad ??= _refreshDraft();
  }

  Future<void> _refreshDraft() async {
    try {
      _hasDraft = await draftStore.read(link.sourceId) != null;
    } catch (_) {
      // An unreadable draft must not be silently replaced by a new edit.
      _hasDraft = true;
    }
    _notify();
  }

  String? get _peerUrl => repository is RemoteMiningAnkiRepository
      ? (repository as RemoteMiningAnkiRepository).sourcePeerUrl(link.sourceId)
      : null;

  String? get _peerIdentity => repository is RemoteMiningAnkiRepository
      ? (repository as RemoteMiningAnkiRepository).sourcePeerIdentity(
          link.sourceId,
        )
      : null;

  void _message(String message) {
    final BuildContext? ui = _context;
    if (ui != null && ui.mounted) {
      ScaffoldMessenger.of(
        ui,
      ).showSnackBar(FushiSnackBar(content: Text(message)));
    }
  }

  Future<AnkiSourceNote> _readOriginal() async {
    final AnkiSourceNote? original = await repository.readSourceNote(
      link.sourceId,
    );
    if (original == null) throw StateError(t.card_source_review_missing);
    return original;
  }

  Future<bool> _canStartEdit() async {
    await _refreshDraft();
    if (_hasDraft) _message(t.card_source_review_draft_existing);
    return !_hasDraft;
  }

  /// Save the exact candidate and its comparison base before touching Anki.
  /// On uncertainty retain this draft; never retry or roll back automatically.
  Future<void> _patch(
    AnkiSourceNote original,
    Map<String, String> fields,
  ) async {
    await draftStore.savePatch(
      original: original,
      fields: fields,
      peerUrl: _peerUrl,
      peerIdentity: _peerIdentity,
    );
    _hasDraft = true;
    await repository.patchSourceNote(original: original, fields: fields);
    await draftStore.delete(link.sourceId);
    _hasDraft = false;
  }

  Future<MineOutcome> _reviewMining(SourceReviewMiningDraft mining) async {
    final AnkiSourceNote original = await _readOriginal();
    // Persist the selected peer before media preparation. A failed request can
    // subsequently resume only against this same paired device.
    final SourceReviewDraft saved = await draftStore.saveMining(
      link: mining.link,
      rawPayloadJson: mining.rawPayloadJson,
      context: mining.context,
      peerUrl: _peerUrl,
      peerIdentity: _peerIdentity,
    );
    final Map<String, String> candidate = await repository
        .prepareSourceNoteFields(
          rawPayloadJson: saved.mining!.rawPayloadJson,
          context: saved.mining!.context,
        );
    return _reviewFields(original, candidate);
  }

  Future<MineOutcome> _reviewFields(
    AnkiSourceNote original,
    Map<String, String> candidate,
  ) async {
    final BuildContext? ui = _context;
    if (ui == null || !ui.mounted) {
      return MineOutcome.failure(t.card_source_review_draft_saved);
    }
    final Map<String, String>? selected = await showAnkiSourceNoteChanges(
      context: ui,
      original: original.fields,
      candidate: candidate,
    );
    if (selected == null || selected.isEmpty) {
      // Cancelling the preview does not discard work; the explicit discard
      // action remains available in the banner.
      return MineOutcome.failure(t.card_source_review_draft_saved);
    }
    await _patch(original, selected);
    return MineOutcome.success(noteId: original.noteId);
  }

  Future<MineOutcome> mine({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    if (_busy) return MineOutcome.failure(t.card_source_review_failed);
    _busy = true;
    _notify();
    try {
      if (!await _canStartEdit()) {
        return MineOutcome.failure(t.card_source_review_draft_existing);
      }
      final CardSourceLink fixed =
          context.sourceLink?.withSourceId(link.sourceId) ?? link;
      // Copy temporary audio/images before the caller's finally cleans them up.
      Future<SourceReviewDraft> retain() async {
        final SourceReviewDraft saved = await draftStore.saveMining(
          link: fixed,
          rawPayloadJson: rawPayloadJson,
          context: context.withSourceLink(fixed),
          peerUrl: _peerUrl,
          peerIdentity: _peerIdentity,
        );
        _hasDraft = true;
        return saved;
      }

      // BUG-4232: ask for the original before persisting anything. A backend
      // that could not answer (offline peer, Anki closed) leaves an uncertain
      // state, so the work is kept as a resumable draft. A definitive "no such
      // note" can never be resumed against the same link, so it must not
      // leave a draft that blocks every later edit of this source.
      final AnkiSourceNote? original;
      try {
        original = await repository.readSourceNote(link.sourceId);
      } catch (error, stackTrace) {
        await retain();
        return MineOutcome.failure(
          t.card_source_review_draft_saved,
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (original == null) {
        return MineOutcome.failure(t.card_source_review_missing);
      }
      final SourceReviewDraft saved = await retain();
      final Map<String, String> candidate = await repository
          .prepareSourceNoteFields(
            rawPayloadJson: saved.mining!.rawPayloadJson,
            context: saved.mining!.context,
          );
      return await _reviewFields(original, candidate);
    } catch (error, stackTrace) {
      return MineOutcome.failure(
        _hasDraft
            ? t.card_source_review_draft_saved
            : t.card_source_review_failed,
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> resumeDraft() async {
    if (_busy) return;
    _busy = true;
    _notify();
    try {
      final SourceReviewDraft? draft = await draftStore.read(link.sourceId);
      if (draft == null) {
        _hasDraft = false;
        return;
      }
      if (draft.peerUrl != null) {
        final BaseAnkiRepository target = repository;
        if (target is! RemoteMiningAnkiRepository) {
          throw StateError('The draft belongs to a paired device');
        }
        final String? pairingIdentity = draft.peerIdentity;
        if (pairingIdentity == null) {
          throw StateError('The saved draft has no verified pairing identity');
        }
        await target.bindSourcePeer(
          link.sourceId,
          draft.peerUrl!,
          pairingIdentity: pairingIdentity,
        );
      } else if (draft.patch != null &&
          repository is RemoteMiningAnkiRepository) {
        throw StateError('The draft belongs to local Anki');
      }
      if (draft.patch != null) {
        final AnkiSourceNote current = await _readOriginal();
        if (current.noteId != draft.patch!.original.noteId) {
          throw StateError('The original note was replaced');
        }
        // Compare the current note to the saved candidate again. The user must
        // explicitly choose fields against the fresh snapshot before saving.
        await _reviewFields(current, draft.patch!.fields);
      } else if (draft.mining != null) {
        await _reviewMining(draft.mining!);
      } else {
        throw StateError('Empty source draft');
      }
      _message(
        _hasDraft
            ? t.card_source_review_draft_saved
            : t.card_source_review_saved,
      );
    } catch (_) {
      _message(t.card_source_review_draft_saved);
    } finally {
      _busy = false;
      _notify();
    }
  }

  Future<void> discardDraft() async {
    if (_busy) return;
    final BuildContext? ui = _context;
    if (ui == null || !ui.mounted) return;
    _busy = true;
    _notify();
    try {
      final bool discard = await showFushiConfirmDialog(
        context: ui,
        title: t.card_source_review_draft_discard,
        icon: FushiIcons.delete,
        cancelLabel: MaterialLocalizations.of(ui).cancelButtonLabel,
        confirmLabel: t.card_source_review_draft_discard,
        destructive: true,
      );
      if (discard) {
        await draftStore.delete(link.sourceId);
        _hasDraft = false;
      }
    } catch (_) {
      _message(t.card_source_review_failed);
    } finally {
      _busy = false;
      _notify();
    }
  }
}

class SourceReviewScope extends InheritedNotifier<SourceReviewSession> {
  const SourceReviewScope({
    super.key,
    required SourceReviewSession session,
    required super.child,
  }) : super(notifier: session);
  static SourceReviewSession? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SourceReviewScope>()?.notifier;
  static SourceReviewSession? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<SourceReviewScope>()?.notifier;
}

class SourceReviewBanner extends StatelessWidget {
  const SourceReviewBanner({
    super.key,
    required this.session,
    required this.onReturn,
    this.runHidden,
  });
  final SourceReviewSession session;
  final VoidCallback onReturn;
  final LookupPopupHiddenRunner? runHidden;

  Future<void> _runDialog(Future<void> Function() body) async {
    if (runHidden != null) {
      await runHidden!<void>(body);
    } else {
      await body();
    }
  }

  /// Material 3 的 compact height 窗口类（高 < 480dp，即横屏手机）：纵向空间稀缺，
  /// 横幅把标题和按钮并成单行；更高的窗口保持「标题一行 + 按钮一行」。
  static const double compactHeightBreakpoint = 480;

  /// 单行横幅的内容高（不含系统顶 inset）＝按钮的 48dp 命中区。
  static const double compactContentHeight = 48;

  /// 两行横幅的内容高上限（不含系统顶 inset）：上下各 4 + 标题至多两行 + 48dp 按钮行。
  static const double regularContentHeight = 100;

  /// 单行布局里标题至少留的宽度；按钮条按内容取宽，只在挤占这一截时才横向滚动。
  static const double _compactTitleMinWidth = 96;
  static const double _compactGap = 8;

  /// 窗口 [windowSize] 下横幅是否并成单行（M3 compact height）。
  static bool isCompactHeight(Size windowSize) =>
      windowSize.height < compactHeightBreakpoint;

  /// 把横幅放进固定高槽位的页面（阅读器）按这个值预留内容高，与横幅自己的
  /// 单行 / 两行判断同源——不能另写一个与窗口高无关的常数。
  static double reservedContentHeight(Size windowSize) =>
      isCompactHeight(windowSize) ? compactContentHeight : regularContentHeight;

  @override
  Widget build(BuildContext context) {
    session.attachContext(context);
    final bool isVideo = session.link.kind == CardSourceKind.video;
    final bool compact = isCompactHeight(MediaQuery.sizeOf(context));
    return SourceReviewControls(
      child: ListenableBuilder(
        listenable: session,
        builder: (BuildContext context, Widget? child) {
          final Widget title = Text(
            isVideo
                ? (session.isReview
                      ? t.card_source_review_video_title
                      : t.card_source_review_video_watching)
                : (session.isReview
                      ? t.card_source_review_title
                      : t.card_source_review_source),
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
          );
          final Widget buttons = _buildButtons(isVideo);
          return Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: compact ? 0 : 4,
                ),
                child: compact
                    // 单行：按钮条按内容取宽（有草稿时四颗按钮也优先摆全），标题拿剩下
                    // 的宽度并省略；只有按钮多到挤占标题保底宽度时按钮条才横向滚动。
                    // 两者都不会把这一行撑高。
                    ? LayoutBuilder(
                        builder:
                            (BuildContext context, BoxConstraints constraints) {
                              final double buttonsMaxWidth =
                                  (constraints.maxWidth -
                                          _compactTitleMinWidth -
                                          _compactGap)
                                      .clamp(0.0, constraints.maxWidth);
                              return SizedBox(
                                height: compactContentHeight,
                                child: Row(
                                  children: <Widget>[
                                    Expanded(child: title),
                                    const SizedBox(width: _compactGap),
                                    ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: buttonsMaxWidth,
                                      ),
                                      child: buttons,
                                    ),
                                  ],
                                ),
                              );
                            },
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[title, buttons],
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildButtons(bool isVideo) {
    // 桌面端默认 dragDevices 不含鼠标，横向按钮条要显式放开拖动。
    return HorizontalDragScrollable(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            if (session.hasDraft) ...<Widget>[
              FushiTextButton(
                onPressed: session.busy
                    ? null
                    : () => _runDialog(session.resumeDraft),
                child: Text(t.card_source_review_draft_resume),
              ),
              FushiTextButton(
                onPressed: session.busy
                    ? null
                    : () => _runDialog(session.discardDraft),
                child: Text(t.card_source_review_draft_discard),
              ),
            ],
            FushiTextButton(
              onPressed: session.busy
                  ? null
                  : () => session.returnToReading(onReturn),
              child: Text(
                isVideo
                    ? t.card_source_review_video_return
                    : t.card_source_review_return,
              ),
            ),
            if (session.isReview)
              FushiTextButton(
                onPressed: session.busy ? null : session.continueReading,
                child: Text(
                  isVideo
                      ? t.card_source_review_video_continue
                      : t.card_source_review_continue,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
