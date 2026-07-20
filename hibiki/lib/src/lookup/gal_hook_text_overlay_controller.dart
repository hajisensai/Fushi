import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import 'package:hibiki/src/lookup/global_lookup_controller.dart';
import 'package:hibiki/src/mining/gal_hook_mining_coordinator.dart';
import 'package:hibiki/src/mining/gal_hook_session_controller.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/home_game_page.dart';
import 'package:hibiki/src/pages/implementations/home_page.dart';
import 'package:hibiki/src/platform/gal_hook_text_overlay_channel.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';
import 'package:hibiki/utils.dart';

typedef GalHookPreferenceReader = Object? Function(
  String key, {
  required Object? defaultValue,
});
typedef GalHookPreferenceWriter = Future<void> Function(
  String key,
  Object? value,
);

/// App 级 Windows Hook 台词浮窗控制器。
class GalHookTextOverlayController extends ChangeNotifier {
  GalHookTextOverlayController._({
    GalHookSessionController? session,
    GalHookMiningCoordinator? miningCoordinator,
    GalHookPreferenceReader? preferenceReader,
    GalHookPreferenceWriter? preferenceWriter,
  })  : _session = session ?? GalHookSessionController.instance,
        _miningCoordinator =
            miningCoordinator ?? GalHookMiningCoordinator.instance,
        _preferenceReader = preferenceReader,
        _preferenceWriter = preferenceWriter;

  static final GalHookTextOverlayController instance =
      GalHookTextOverlayController._();

  @visibleForTesting
  GalHookTextOverlayController.test({
    required GalHookSessionController session,
    GalHookMiningCoordinator? miningCoordinator,
    GalHookPreferenceReader? preferenceReader,
    GalHookPreferenceWriter? preferenceWriter,
  }) : this._(
          session: session,
          miningCoordinator: miningCoordinator,
          preferenceReader: preferenceReader,
          preferenceWriter: preferenceWriter,
        );

  static const String _rectPreferenceKey = 'gal_hook_text_window_rect';
  static const String _opacityPreferenceKey = 'gal_hook_text_window_bg_opacity';
  static const double _defaultOpacity = 0.88;

  final GalHookSessionController _session;
  final GalHookMiningCoordinator _miningCoordinator;
  final GalHookPreferenceReader? _preferenceReader;
  final GalHookPreferenceWriter? _preferenceWriter;

  AppModel? _appModel;
  bool _started = false;
  bool _visible = false;
  bool _following = true;
  bool _passThrough = false;
  bool _locked = false;
  bool _suppressedForSession = false;
  bool _syncing = false;
  bool _syncAgain = false;
  int? _sessionKey;
  String? _displayedLineId;
  double _opacity = _defaultOpacity;
  double _lastNonZeroOpacity = _defaultOpacity;
  GalHookTextWindowRect? _savedRect;

  static bool get isSupported =>
      GalHookTextOverlayChannel.supportsCurrentPlatform;

  bool get isVisible => _visible;
  bool get isFollowing => _following;
  bool get isPassThrough => _passThrough;
  bool get isLocked => _locked;
  bool get isSuppressedForSession => _suppressedForSession;
  String? get displayedLineId => _displayedLineId;

  Future<void> start({required AppModel appModel}) async {
    if (_started || !isSupported) return;
    _started = true;
    _appModel = appModel;
    _loadPreferences(appModel);
    GalHookTextOverlayChannel.setEventHandlers(
      onLookupText: _onLookupText,
      onToggleFollow: toggleFollowing,
      onTogglePassThrough: togglePassThrough,
      onToggleTransparency: toggleTransparency,
      onOpenWorkbench: openWorkbench,
      onClose: closeForCurrentSession,
      onLockChanged: _onLockChanged,
      onBoundsChanged: _onBoundsChanged,
    );
    _session.addListener(_scheduleSync);
    _scheduleSync();
  }

  @visibleForTesting
  Future<void> stopForTesting() async {
    if (!_started) return;
    _session.removeListener(_scheduleSync);
    GalHookTextOverlayChannel.clearEventHandlers();
    await GalHookTextOverlayChannel.hide();
    _started = false;
    _visible = false;
  }

  void _loadPreferences(AppModel appModel) {
    Object? read(String key, Object? fallback) => _preferenceReader != null
        ? _preferenceReader(key, defaultValue: fallback)
        : appModel.prefsRepo.getPref(key, defaultValue: fallback);
    final Object? storedOpacity = read(_opacityPreferenceKey, _defaultOpacity);
    final double stored =
        storedOpacity is num ? storedOpacity.toDouble() : _defaultOpacity;
    _opacity = stored.clamp(0.0, 1.0);
    if (_opacity > 0) _lastNonZeroOpacity = _opacity;
    final Object? storedRect = read(_rectPreferenceKey, '');
    final String encoded = storedRect is String ? storedRect : '';
    if (encoded.isEmpty) return;
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is Map) {
        _savedRect = GalHookTextWindowRect.fromMap(
          decoded.cast<Object?, Object?>(),
        );
      }
    } catch (_) {
      _savedRect = null;
    }
  }

  void _scheduleSync() {
    if (!_started) return;
    _syncAgain = true;
    if (_syncing) return;
    _syncing = true;
    unawaited(_drainSync());
  }

  Future<void> _drainSync() async {
    try {
      while (_syncAgain) {
        _syncAgain = false;
        await _syncFromSession();
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _syncFromSession() async {
    final GalHookSessionState state = _session.state;
    final int? nextSessionKey = state.sessionStartedAt?.microsecondsSinceEpoch;
    if (nextSessionKey != null && nextSessionKey != _sessionKey) {
      _sessionKey = nextSessionKey;
      _suppressedForSession = false;
      _following = true;
      _passThrough = false;
      _locked = false;
      _displayedLineId = null;
      await GalHookTextOverlayChannel.setFollowing(true);
      await GalHookTextOverlayChannel.setPassThrough(false);
      await GalHookTextOverlayChannel.setLocked(false);
      notifyListeners();
    }

    final bool active = state.externalWindowMode &&
        nextSessionKey != null &&
        state.phase != GalHookSessionPhase.idle &&
        state.phase != GalHookSessionPhase.stopping &&
        state.phase != GalHookSessionPhase.error;
    if (!active) {
      if (_visible) {
        await GalHookTextOverlayChannel.hide();
        _visible = false;
        notifyListeners();
      }
      if (nextSessionKey == null) _sessionKey = null;
      return;
    }
    if (_suppressedForSession) return;

    final List<TexthookerLineEntry> lines = _session.selectedSessionLines;
    if (lines.isEmpty) return;
    final TexthookerLineEntry latest = lines.last;
    if (!_visible) {
      await GalHookTextOverlayChannel.updateText(
        lineId: latest.id,
        text: latest.text,
      );
      _visible = await GalHookTextOverlayChannel.show(
        rect: _savedRect,
        bgColor: _backgroundColor,
        following: _following,
        passThrough: _passThrough,
        locked: _locked,
      );
      if (_visible) _displayedLineId = latest.id;
      notifyListeners();
      return;
    }
    if (_following && latest.id != _displayedLineId) {
      await GalHookTextOverlayChannel.updateText(
        lineId: latest.id,
        text: latest.text,
      );
      _displayedLineId = latest.id;
      notifyListeners();
    }
  }

  int get _backgroundColor {
    final int alpha = (_opacity.clamp(0.0, 1.0) * 255).round();
    return alpha << 24;
  }

  Future<void> showManually() async {
    if (!_started) return;
    _suppressedForSession = false;
    _visible = false;
    notifyListeners();
    _scheduleSync();
  }

  Future<void> closeForCurrentSession() async {
    if (!_started) return;
    _suppressedForSession = true;
    await GalHookTextOverlayChannel.hide();
    _visible = false;
    notifyListeners();
  }

  Future<void> toggleFollowing() async {
    _following = !_following;
    await GalHookTextOverlayChannel.setFollowing(_following);
    notifyListeners();
    if (_following) _scheduleSync();
  }

  Future<void> togglePassThrough() async {
    _passThrough = !_passThrough;
    await GalHookTextOverlayChannel.setPassThrough(_passThrough);
    notifyListeners();
  }

  Future<void> toggleTransparency() async {
    if (_opacity > 0) {
      _lastNonZeroOpacity = _opacity;
      _opacity = 0;
    } else {
      _opacity =
          _lastNonZeroOpacity > 0 ? _lastNonZeroOpacity : _defaultOpacity;
    }
    final AppModel? model = _appModel;
    if (model != null) {
      if (_preferenceWriter != null) {
        await _preferenceWriter(_opacityPreferenceKey, _opacity);
      } else {
        await model.prefsRepo.setPref(_opacityPreferenceKey, _opacity);
      }
    }
    await GalHookTextOverlayChannel.updateStyle(bgColor: _backgroundColor);
    notifyListeners();
  }

  Future<void> _onLockChanged(bool locked) async {
    _locked = locked;
    notifyListeners();
  }

  Future<void> _onBoundsChanged(GalHookTextWindowRect rect) async {
    _savedRect = rect;
    final AppModel? model = _appModel;
    if (model != null) {
      final String value = jsonEncode(rect.toMap());
      if (_preferenceWriter != null) {
        await _preferenceWriter(_rectPreferenceKey, value);
      } else {
        await model.prefsRepo.setPref(_rectPreferenceKey, value);
      }
    }
  }

  Future<void> openWorkbench() async {
    homeShellTabNotifier.value = HomeTab.games;
    gameSectionNotifier.value = GameSection.monitor;
    await DesktopLookupService.instance.bringMainWindowToFront();
  }

  Future<void> _onLookupText(
    String lineId,
    String text,
    int index,
  ) async {
    final AppModel? model = _appModel;
    final TexthookerLineEntry? entry = _session.entryById(lineId);
    if (model == null ||
        entry == null ||
        entry.text != text ||
        !_session.isLineInCurrentSession(entry)) {
      HibikiToast.show(msg: t.game_hook_line_unavailable);
      return;
    }
    final String term = model.targetLanguage
        .wordFromIndex(text: entry.text, index: index)
        .trim();
    if (term.isEmpty) return;
    await GlobalLookupController.instance.lookupText(
      term,
      sentence: entry.text,
      miningHandler: ({
        required Map<String, String> fields,
        int? updateNoteId,
      }) =>
          _mineFromLookup(
        lineId: entry.id,
        fields: fields,
        updateNoteId: updateNoteId,
      ),
    );
  }

  Future<Map<String, Object?>> _mineFromLookup({
    required String lineId,
    required Map<String, String> fields,
    required int? updateNoteId,
  }) async {
    final AppModel? model = _appModel;
    if (model == null) {
      return const <String, Object?>{
        'ankiConnect': false,
        'noteId': null,
      };
    }
    HibikiToast.showMine(
      msg: t.card_mining_pending,
      status: MineToastStatus.pending,
    );
    final BaseAnkiRepository repo =
        model.platformServices.createAnkiRepository();
    final GalHookMiningResult result = await _miningCoordinator.mineLine(
      lineId: lineId,
      fields: fields,
      compression: MiningMediaCompression.resolve(
        imageTier: model.miningImageQuality,
        audioTier: model.miningAudioQuality,
      ),
      repo: repo,
      updateNoteId: updateNoteId,
    );
    if (result.aborted) {
      HibikiToast.showMine(
        msg:
            '${t.external_window_capture_failed}：${result.failureReason ?? ''}',
        status: MineToastStatus.failed,
      );
      return result.toPopupReply();
    }
    final MineOutcome outcome = result.outcome!;
    final String deckName = outcome.result == MineResult.success
        ? (await repo.loadSettings()).selectedDeckName ?? ''
        : '';
    final described = describeMineOutcome(
      outcome,
      deckName: deckName,
      overwrite: updateNoteId != null,
    );
    HibikiToast.showMine(msg: described.message, status: described.status);
    if (result.sentenceAudioMissing) {
      HibikiToast.show(msg: t.game_card_sentence_audio_missing);
    }
    if (result.unmappedTokens.isNotEmpty) {
      HibikiToast.show(
        msg: '${t.game_card_mapping_missing}: '
            '${result.unmappedTokens.join(', ')}',
      );
    }
    return result.toPopupReply();
  }
}
