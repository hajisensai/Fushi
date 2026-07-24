import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import 'package:hibiki/src/lookup/global_lookup_controller.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_playback.dart';
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

  /// 当前行语音正在试听（浮窗「重播」按钮高亮）。
  bool _replaying = false;
  Timer? _replayResetTimer;

  /// 已推给 native 的语音控件状态，避免每轮 sync 都发一次 channel 调用。
  bool _pushedReplaying = false;
  bool _pushedRecapturing = false;
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
  bool get isReplaying => _replaying;
  bool get isRecapturing => _session.isRecapturing;

  /// 试听兜底复位上限：资源原件（OGG/WAV）时长未知时按它把按钮高亮收回，
  /// 与实时台词列表的行内试听同一上限。
  static const int _replayMaxMs = 15000;

  Future<void> start({required AppModel appModel}) async {
    if (_started || !isSupported) return;
    _started = true;
    _appModel = appModel;
    // 给会话控制器接上 DB：galgame hook 会话据此把游戏时长/字数落 activity_events
    // （首页「游戏」活动的唯一写入方）。惰性解析——flush 时 App 尚未初始化完
    // （或测试替身无 DB）则返回 null 跳过本次落库，不在 start 急切解引用 late 字段。
    _session.attachActivityDatabase(
      () => appModel.isInitialised ? appModel.database : null,
    );
    _loadPreferences(appModel);
    GalHookTextOverlayChannel.setEventHandlers(
      onLookupText: _onLookupText,
      onToggleFollow: toggleFollowing,
      onTogglePassThrough: togglePassThrough,
      onToggleTransparency: toggleTransparency,
      onOpenWorkbench: openWorkbench,
      onClose: closeForCurrentSession,
      onReplayVoice: replayCurrentLine,
      onRecaptureVoice: recaptureCurrentLine,
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
      // 新会话：上一局的试听计时不能把高亮留在新浮窗上。
      _replayResetTimer?.cancel();
      _replayResetTimer = null;
      _replaying = false;
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
        // 浮窗收起后试听高亮无处可显示，本地状态跟着收——否则下次 show 会把一个
        // 早已播完的试听态推给新窗口。
        _replayResetTimer?.cancel();
        _replayResetTimer = null;
        _replaying = false;
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
      // native 在 show 里把语音控件复位（见 flutter_window.cpp），本地镜像跟着复位，
      // 否则下一次 _syncVoiceState 会认为「已经推过了」而不再推。
      _pushedReplaying = false;
      _pushedRecapturing = false;
      if (_visible) _displayedLineId = latest.id;
      notifyListeners();
      await _syncVoiceState();
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
    // 补录窗口可能由 session 侧超时自行收束：每轮都比对一次，浮窗上的「录音中」
    // 高亮才不会停在已结束的状态上。
    await _syncVoiceState();
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

  /// 浮窗「重播」：试听当前显示行已配的语音；正在试听时再点即停止。
  /// 只读既有配对结果（资源原件直接播，PCM/loopback 冻结切片拼 WAV），不改行状态。
  Future<void> replayCurrentLine() async {
    if (!_started) return;
    if (_replaying) {
      await _stopReplay();
      return;
    }
    final String? lineId = _displayedLineId;
    if (lineId == null) {
      HibikiToast.show(msg: t.game_hook_line_unavailable);
      return;
    }
    final GalTrackPreview? preview =
        await _session.exportLineAudioPreview(lineId);
    if (preview == null) {
      HibikiToast.show(msg: t.game_line_preview_failed);
      return;
    }
    if (!await DesktopAudioPlayback.playFile(preview.filePath)) {
      HibikiToast.show(msg: t.game_line_preview_failed);
      return;
    }
    _replaying = true;
    _replayResetTimer?.cancel();
    _replayResetTimer = Timer(
      Duration(
        milliseconds:
            preview.durationMs > 0 ? preview.durationMs + 300 : _replayMaxMs,
      ),
      () {
        _replaying = false;
        unawaited(_syncVoiceState());
        notifyListeners();
      },
    );
    await _syncVoiceState();
    notifyListeners();
  }

  Future<void> _stopReplay() async {
    _replayResetTimer?.cancel();
    _replayResetTimer = null;
    _replaying = false;
    await DesktopAudioPlayback.stop();
    await _syncVoiceState();
    notifyListeners();
  }

  /// 浮窗「重播并录音」：为当前显示行开一段补录窗口——用户随后在游戏里重播这句
  /// 语音（回退/重听），窗口内录到的系统声音就绑定到这一行，覆盖此前配错或缺失的
  /// 语音。正在补录时再点即立刻收束。
  Future<void> recaptureCurrentLine() async {
    if (!_started) return;
    if (_session.isRecapturing) {
      final bool saved = await _session.finishLineRecapture();
      HibikiToast.show(
        msg: saved ? t.game_hook_recapture_saved : t.game_hook_recapture_empty,
      );
      await _syncVoiceState();
      notifyListeners();
      return;
    }
    final String? lineId = _displayedLineId;
    if (lineId == null) {
      HibikiToast.show(msg: t.game_hook_line_unavailable);
      return;
    }
    final bool started = await _session.startLineRecapture(lineId);
    HibikiToast.show(
      msg: started
          ? t.game_hook_recapture_started
          : t.game_hook_recapture_unavailable,
    );
    await _syncVoiceState();
    notifyListeners();
  }

  /// 把语音控件状态推给浮窗（只在变化时发 channel 调用）。补录窗口也可能由 session
  /// 侧超时自行收束，所以每轮 sync 都比对一次。
  Future<void> _syncVoiceState() async {
    final bool replaying = _replaying;
    final bool recapturing = _session.isRecapturing;
    if (replaying == _pushedReplaying && recapturing == _pushedRecapturing) {
      return;
    }
    _pushedReplaying = replaying;
    _pushedRecapturing = recapturing;
    await GalHookTextOverlayChannel.setVoiceState(
      replaying: replaying,
      recapturing: recapturing,
    );
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
