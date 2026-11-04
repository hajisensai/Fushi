import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/models/game_stream_lookup_layout.dart';
import 'package:fushi/src/pages/implementations/game_stream_line_font_fit.dart';
import 'package:fushi/src/pages/implementations/game_stream_settings_sheet.dart';
import 'package:fushi/src/platform/game_stream_companion_display_channel.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_companion_bridge.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi/src/sync/game_stream_touch.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isGlassDesign;
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_resource_source.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/fushi_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_desktop_title_bar.dart'
    show FushiTitleBarColorScope, fushiTitleBarColorsOn;
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// Receiver-side wording for a host mine result. The host only sends stable
/// detail codes (its raw failure text stays on the host), so every outcome a
/// user can hit gets an actionable localized sentence here.
String gameStreamMineMessage(GameStreamMineResult? result) {
  if (result == null) return t.game_stream_mine_failed;
  if (result.ok) {
    return result.detail == 'sentence_audio_missing'
        ? t.game_card_sentence_audio_missing
        : t.game_stream_mine_success;
  }
  return switch (result.detail) {
    'duplicate' => t.game_stream_mine_duplicate,
    'line_snapshot_missing' => t.game_stream_mine_snapshot_missing,
    'line_expired' || 'sentence_mismatch' => t.game_stream_mine_line_expired,
    'audio_fallback_disabled' => t.game_stream_mine_audio_fallback_disabled,
    'capture_failed' => t.game_stream_mine_capture_failed,
    _ => t.game_stream_mine_host_error,
  };
}

/// Host key name (runner `ResolveVirtualKey`, case-insensitive) for a physical
/// or Bluetooth keyboard key; null for keys the host cannot inject.
String? gameStreamHostKeyName(LogicalKeyboardKey key) {
  final int id = key.keyId;
  if (id >= LogicalKeyboardKey.keyA.keyId &&
      id <= LogicalKeyboardKey.keyZ.keyId) {
    return String.fromCharCode(0x41 + id - LogicalKeyboardKey.keyA.keyId);
  }
  if (id >= LogicalKeyboardKey.digit0.keyId &&
      id <= LogicalKeyboardKey.digit9.keyId) {
    return String.fromCharCode(0x30 + id - LogicalKeyboardKey.digit0.keyId);
  }
  const List<LogicalKeyboardKey> functionKeys = <LogicalKeyboardKey>[
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  ];
  final int function = functionKeys.indexOf(key);
  if (function >= 0) return 'F${function + 1}';
  return switch (key) {
    LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 'Enter',
    LogicalKeyboardKey.escape => 'Escape',
    LogicalKeyboardKey.space => 'Space',
    LogicalKeyboardKey.tab => 'Tab',
    LogicalKeyboardKey.backspace => 'Backspace',
    LogicalKeyboardKey.arrowUp => 'Up',
    LogicalKeyboardKey.arrowDown => 'Down',
    LogicalKeyboardKey.arrowLeft => 'Left',
    LogicalKeyboardKey.arrowRight => 'Right',
    LogicalKeyboardKey.shiftLeft || LogicalKeyboardKey.shiftRight => 'Shift',
    LogicalKeyboardKey.controlLeft ||
    LogicalKeyboardKey.controlRight => 'Control',
    LogicalKeyboardKey.altLeft || LogicalKeyboardKey.altRight => 'Alt',
    _ => null,
  };
}

/// Where D-pad right moves the lookup-mode cursor (graphemes). Right after a
/// lookup at [lookupStart] that matched [matchedLength] graphemes, it jumps
/// past the matched word to the next one; otherwise it steps one grapheme.
/// Never past the line's last grapheme.
int gameStreamLookupCaretRight({
  required int caret,
  required int? lookupStart,
  required int matchedLength,
  required int lineLength,
}) {
  if (lineLength <= 0) return 0;
  final int next = matchedLength > 0 && caret == lookupStart
      ? caret + matchedLength
      : caret + 1;
  return next.clamp(0, lineLength - 1);
}

class GameStreamPage extends StatefulWidget {
  const GameStreamPage({
    required this.sessionId,
    required this.clientId,
    required this.inputComposer,
    this.lookupController,
    this.receiver,
    this.videoPlaceholder,
    this.session,
    this.settings = const GameStreamVideoSettings(),
    this.onSettingsChanged,
    this.lookupLayout = const GameStreamLookupLayout(),
    this.onLookupLayoutChanged,
    this.buttonProfile = const GameStreamButtonProfile(),
    this.onButtonProfileChanged,
    this.companionDisplay,
    this.secondScreen = GameStreamSecondScreen.auto,
    this.onSecondScreenChanged,
    super.key,
  });

  final String sessionId;
  final String clientId;
  final GameStreamInputComposer inputComposer;
  final GameStreamLookupController? lookupController;
  final FushiGameStreamReceiver? receiver;
  final Widget? videoPlaceholder;

  /// Joined session; its [GameStreamSession.features] gate newer input kinds.
  final GameStreamSession? session;

  /// Parameters this receiver asked for (persisted by the caller).
  final GameStreamVideoSettings settings;

  /// Persists a settings change made from the in-stream panel.
  final ValueChanged<GameStreamVideoSettings>? onSettingsChanged;

  /// Lookup rail geometry the user last chose on this device (persisted by
  /// the caller).
  final GameStreamLookupLayout lookupLayout;

  /// Persists a rail resize once the drag (or key press) that made it ends.
  final ValueChanged<GameStreamLookupLayout>? onLookupLayoutChanged;

  /// What each physical controller button does (persisted by the caller).
  final GameStreamButtonProfile buttonProfile;

  /// Persists a change made in the controls sheet.
  final ValueChanged<GameStreamButtonProfile>? onButtonProfileChanged;

  /// The second display, where the lookup panel goes while one is connected
  /// (null where the platform has none). The caller owns and disposes it.
  final GameStreamCompanionDisplay? companionDisplay;

  /// Whether to use a second display (persisted by the caller).
  final GameStreamSecondScreen secondScreen;

  /// Persists a change made in the controls sheet.
  final ValueChanged<GameStreamSecondScreen>? onSecondScreenChanged;

  static const Key videoKey = ValueKey<String>('game-stream-video');
  static const Key secondScreenKey = ValueKey<String>(
    'game-stream-second-screen',
  );
  static const Key modeChipKey = ValueKey<String>('game-stream-mode-chip');
  static const Key lookupModeHintKey = ValueKey<String>(
    'game-stream-lookup-mode-hint',
  );
  static const Key lookupModeOutlineKey = ValueKey<String>(
    'game-stream-lookup-mode-outline',
  );
  static const Key transcriptKey = ValueKey<String>('game-stream-transcript');
  static const Key transcriptTextKey = ValueKey<String>(
    'game-stream-transcript-text',
  );
  static const Key dictionaryKey = ValueKey<String>('game-stream-dictionary');
  static const Key statsKey = ValueKey<String>('game-stream-stats');
  static const Key cursorKey = ValueKey<String>('game-stream-cursor');
  static const Key keyboardKey = ValueKey<String>('game-stream-keyboard');
  static const Key lineResizeHandleKey = ValueKey<String>(
    'game-stream-line-resize-handle',
  );
  static const Key railResizeHandleKey = ValueKey<String>(
    'game-stream-rail-resize-handle',
  );
  static const Key compactRailResizeHandleKey = ValueKey<String>(
    'game-stream-compact-rail-resize-handle',
  );

  @override
  State<GameStreamPage> createState() => _GameStreamPageState();
}

bool get _isDesktopPlatform => switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.macOS ||
  TargetPlatform.linux => true,
  _ => false,
};

class _GameStreamPageState extends State<GameStreamPage>
    with WidgetsBindingObserver {
  final GlobalKey _videoKey = GlobalKey();
  GameStreamLookupController? _lookupController;
  // The on-screen pad stands in for missing buttons on a touch screen; a
  // desktop has a keyboard and mouse, so it starts hidden there.
  bool _controlsVisible = !_isDesktopPlatform;

  /// The user wants the lookup panel shown. Change it only through
  /// [_setLookupVisible]: hiding the panel also leaves lookup mode.
  bool _lookupVisible = true;

  /// A modal sheet is up and the panel (its WebView) steps aside meanwhile.
  /// Separate from [_lookupVisible] so a sheet never changes what the user
  /// chose, nor the input mode.
  bool _lookupSuspended = false;

  /// The panel is on screen.
  bool get _lookupShown => _lookupVisible && !_lookupSuspended;

  /// Where controller buttons go (see [GameStreamInputMode]).
  GameStreamInputMode _inputMode = GameStreamInputMode.game;

  /// Set by the first controller button press: only then does a tap on the
  /// line enter lookup mode and the mode chip appear. A touch-only phone
  /// never sees controller hints.
  bool _controllerUsed = false;

  /// Lookup-mode cursor in the current line, in graphemes.
  int _lookupCaret = 0;

  /// Where the last lookup started (graphemes), so D-pad right can jump past
  /// the matched word; null before any lookup on this line.
  int? _lookupStart;

  /// The line [_lookupCaret] belongs to; a different line resets the cursor.
  ({String lineId, String text})? _caretLine;
  bool _mineFailed = false;
  final GlobalKey<DictionaryPopupWebViewState> _dictionaryKey =
      GlobalKey<DictionaryPopupWebViewState>();
  String? _mineMessage;
  final Map<GameStreamVirtualButton, String> _keyBindings =
      <GameStreamVirtualButton, String>{};

  /// Every local input holding something down on the host (an on-screen pad
  /// [GameStreamVirtualButton] or a [GameStreamPhysicalButton]), with the host
  /// output its press resolved to; the release undoes exactly that output.
  final Map<Object, _HostOutput> _heldSources = <Object, _HostOutput>{};

  /// How many local inputs hold each host output. Two buttons mapped to the
  /// same output (Start and Select both on menu, or the on-screen confirm
  /// while A is down) send one down and one up: the host output is lifted
  /// only when the last of them is released.
  final Map<_HostOutput, int> _outputHolds = <_HostOutput, int>{};
  late GameStreamButtonProfile _buttonProfile = widget.buttonProfile;
  late GameStreamSecondScreen _secondScreen = widget.secondScreen;

  /// The lookup panel is up on the second display: the video takes the whole
  /// page and the inline rail is gone.
  bool _companionActive = false;
  bool _companionStarted = false;

  /// Display the panel was asked onto; null when none was.
  int? _companionDisplayId;

  /// The on-screen pad's visibility before the panel moved to the second
  /// display (which hides it); restored when the panel comes back.
  bool? _controlsBeforeCompanion;
  StreamSubscription<GameStreamCompanionMessage>? _companionMessages;
  GameStreamCompanionState? _sentCompanionState;
  bool _companionResultSent = false;
  DictionarySearchResult? _sentCompanionResult;
  Map<String, String>? _sentCompanionStyles;
  int _companionRevision = 0;
  bool _companionSyncScheduled = false;

  /// Physical buttons currently down, with the action their press started:
  /// the release must undo that action even if the profile changed meanwhile.
  /// (What that action holds on the host is in [_heldSources].)
  final Map<GameStreamPhysicalButton, GameStreamButtonAction> _heldPhysical =
      <GameStreamPhysicalButton, GameStreamButtonAction>{};
  GameStreamTouchInterpreter? _touch;
  GameStreamMouseInterpreter? _mouse;
  ({Rect bounds, Rect content})? _mouseGeometry;
  bool _mouseMoveInFlight = false;

  /// After a forced release the user's finger may still be on the button. The
  /// rest of that press is dropped until every button is up; otherwise the
  /// next drag event would look like a fresh press and click the game.
  bool _mouseAwaitingRelease = false;
  Offset? _queuedMouseMove;
  ({Rect bounds, Rect content})? _pointerGeometry;
  GameStreamInputComposer? _pointerComposer;
  GameStreamTouchMode _touchMode = GameStreamTouchMode.direct;
  Offset _trackpadCursor = const Offset(.5, .5);
  late GameStreamVideoSettings _settings = widget.settings;
  late GameStreamLookupLayout _lookupLayout = widget.lookupLayout;
  late GameStreamLookupLayout _committedLookupLayout = widget.lookupLayout;

  /// Last laid-out body width / rail height: the bounds a resize drag clamps
  /// against, so a drag past the limit does not bank invisible distance.
  double _bodyWidth = 0;
  double _bodyHeight = 0;
  double _railHeight = 0;
  bool _statsVisible = false;
  GameStreamStatsSample? _stats;
  Timer? _statsTimer;
  final FocusNode _videoFocus = FocusNode(debugLabel: 'game-stream-video');
  final FocusNode _keyboardFocus = FocusNode(debugLabel: 'game-stream-keys');
  final TextEditingController _keyboardText = TextEditingController(
    text: _keyboardSentinel,
  );

  /// The soft keyboard field always holds one invisible character so a
  /// backspace is observable as the text becoming empty.
  static const String _keyboardSentinel = '\u200b';

  bool _supports(String feature) => widget.session?.supports(feature) ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lookupController = widget.lookupController;
    _lookupController?.addListener(_onLookupChanged);
    _caretLine = _currentCaretLine();
    widget.receiver?.addListener(_onReceiverChanged);
    widget.receiver?.renderer.addListener(_schedulePointerGeometryCheck);
    widget.inputComposer.addListener(_onReceiverChanged);
    unawaited(_startCompanion());
  }

  @override
  void didUpdateWidget(GameStreamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputComposer != widget.inputComposer ||
        oldWidget.receiver != widget.receiver) {
      // Held buttons belong to the session that saw their downs: lift them
      // there, never on the new one.
      unawaited(_releaseHeldInputs(oldWidget.inputComposer));
    }
    if (oldWidget.inputComposer != widget.inputComposer) {
      unawaited(_releasePointer());
      oldWidget.inputComposer.removeListener(_onReceiverChanged);
      widget.inputComposer.addListener(_onReceiverChanged);
    }
    if (oldWidget.lookupController != widget.lookupController) {
      oldWidget.lookupController?.removeListener(_onLookupChanged);
      _lookupController = widget.lookupController;
      _lookupController?.addListener(_onLookupChanged);
      _onLookupChanged();
    }
    if (oldWidget.receiver != widget.receiver) {
      unawaited(_releasePointer());
      oldWidget.receiver?.removeListener(_onReceiverChanged);
      oldWidget.receiver?.renderer.removeListener(
        _schedulePointerGeometryCheck,
      );
      widget.receiver?.addListener(_onReceiverChanged);
      widget.receiver?.renderer.addListener(_schedulePointerGeometryCheck);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releasePointer());
    unawaited(_releaseHeldInputs());
    _lookupController?.removeListener(_onLookupChanged);
    widget.receiver?.removeListener(_onReceiverChanged);
    widget.receiver?.renderer.removeListener(_schedulePointerGeometryCheck);
    widget.inputComposer.removeListener(_onReceiverChanged);
    _stopCompanion();
    _statsTimer?.cancel();
    _videoFocus.dispose();
    _keyboardFocus.dispose();
    _keyboardText.dispose();
    super.dispose();
  }

  // ---- Second display -----------------------------------------------------

  Future<void> _startCompanion() async {
    final GameStreamCompanionDisplay? display = widget.companionDisplay;
    if (display == null) return;
    display.displays.addListener(_placeCompanion);
    display.attached.addListener(_onCompanionAttached);
    display.resets.addListener(_onCompanionReset);
    _companionMessages = display.messages.listen(_onCompanionMessage);
    try {
      await display.start();
    } catch (error, stack) {
      // No second display support on this device build: stay single-screen.
      ErrorLogService.instance.log(
        'GameStreamPage.startCompanion',
        error,
        stack,
      );
      return;
    }
    if (!mounted) return;
    _companionStarted = true;
    _placeCompanion();
  }

  void _stopCompanion() {
    final GameStreamCompanionDisplay? display = widget.companionDisplay;
    if (display == null) return;
    display.displays.removeListener(_placeCompanion);
    display.attached.removeListener(_onCompanionAttached);
    display.resets.removeListener(_onCompanionReset);
    unawaited(_companionMessages?.cancel());
    if (_companionDisplayId != null) unawaited(display.dismiss());
    _companionDisplayId = null;
  }

  /// Puts the panel on the first second display when the setting allows it,
  /// or takes it down when it does not (or the display went away).
  void _placeCompanion() {
    final GameStreamCompanionDisplay? display = widget.companionDisplay;
    if (display == null || !_companionStarted || !mounted) return;
    final List<GameStreamCompanionDisplayInfo> displays =
        display.displays.value;
    final int? target =
        _secondScreen == GameStreamSecondScreen.auto && displays.isNotEmpty
        ? displays.first.id
        : null;
    if (target == _companionDisplayId) return;
    _companionDisplayId = target;
    unawaited(
      _runCompanionCall(
        'place',
        target == null ? display.dismiss() : display.show(target),
        // The call did not reach the platform side (its Activity was being
        // recreated): nothing was placed, so the next display update places
        // it again.
        onFailed: () {
          if (_companionDisplayId == target) _companionDisplayId = null;
        },
      ),
    );
  }

  Future<void> _runCompanionCall(
    String what,
    Future<void> call, {
    VoidCallback? onFailed,
  }) async {
    try {
      await call;
    } catch (error, stack) {
      onFailed?.call();
      ErrorLogService.instance.log(
        'GameStreamPage.companion.$what',
        error,
        stack,
      );
    }
  }

  void _onCompanionAttached() {
    final bool active = widget.companionDisplay?.attached.value ?? false;
    if (!mounted || active == _companionActive) return;
    _sentCompanionState = null;
    _companionResultSent = false;
    // The panel is gone (closed, crashed, replaced, or the Activity holding
    // it was recreated): nothing is up on that display any more. Forget it,
    // so placing it again from the current displays and setting launches a
    // new one (a no-op when that panel is already on its way).
    if (!active) _companionDisplayId = null;
    setState(() {
      _companionActive = active;
      if (active) {
        // The top screen is the game: no pad over it unless asked for.
        _controlsBeforeCompanion = _controlsVisible;
        _controlsVisible = false;
      } else {
        _controlsVisible = _controlsBeforeCompanion ?? _controlsVisible;
        _controlsBeforeCompanion = null;
      }
    });
    if (!active) _placeCompanion();
  }

  /// The platform side was replaced: whatever was placed on the old one is
  /// gone, also a panel that was launched but never came up (it has no
  /// attached edge to report). Forget it unconditionally and place again on
  /// the new one; a show the new side already has is a no-op there.
  void _onCompanionReset() {
    if (!mounted) return;
    _companionDisplayId = null;
    _placeCompanion();
  }

  void _setSecondScreen(GameStreamSecondScreen value) {
    if (value == _secondScreen) return;
    setState(() => _secondScreen = value);
    widget.onSecondScreenChanged?.call(value);
    _placeCompanion();
  }

  /// What the panel shows; compared with the last one sent after each build.
  GameStreamCompanionState _companionState() {
    final GameStreamLookupController? controller = _lookupController;
    final GameStreamTextEvent? line = controller?.currentLine;
    final bool lookupMode = _inputMode == GameStreamInputMode.lookup;
    final int matched = _matchedLength;
    return GameStreamCompanionState(
      lineId: line?.lineId,
      lineText: line?.text,
      caret: lookupMode && line != null ? _lookupCaret : null,
      highlightStart: matched > 0 ? _lookupStart : null,
      highlightCount: matched > 0 ? matched : null,
      mode: _inputMode,
      controllerUsed: _controllerUsed,
      searching: controller?.searching ?? false,
      error: controller?.error,
      mineMessage: _mineMessage,
      mineFailed: _mineFailed,
    );
  }

  void _scheduleCompanionSync() {
    if (!_companionActive || _companionSyncScheduled) return;
    _companionSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _companionSyncScheduled = false;
      _syncCompanion();
    });
  }

  /// Sends the panel whatever changed since the last push: the light state
  /// on any change, the result only when it (or its styles) changed.
  void _syncCompanion() {
    final GameStreamCompanionDisplay? display = widget.companionDisplay;
    if (display == null || !_companionActive || !mounted) return;
    final GameStreamCompanionState state = _companionState();
    if (state != _sentCompanionState) {
      _sentCompanionState = state;
      unawaited(
        _runCompanionCall(
          'state',
          display.send(state),
          // Not delivered: the panel does not have it, the next sync resends.
          onFailed: () {
            if (identical(_sentCompanionState, state)) {
              _sentCompanionState = null;
            }
          },
        ),
      );
    }
    final GameStreamLookupController? controller = _lookupController;
    final DictionarySearchResult? result = controller?.result;
    final Map<String, String> styles =
        result?.remoteDictionaryStyles ??
        controller?.popupResources?.dictionaryStyles ??
        const <String, String>{};
    if (_companionResultSent &&
        identical(result, _sentCompanionResult) &&
        identical(styles, _sentCompanionStyles)) {
      return;
    }
    _companionResultSent = true;
    _sentCompanionResult = result;
    _sentCompanionStyles = styles;
    final int revision = ++_companionRevision;
    unawaited(
      _runCompanionCall(
        'result',
        display.send(
          GameStreamCompanionResult(
            revision: revision,
            resultJson: result?.toJson(),
            popupJson: result?.popupJson,
            dictionaryStyles: styles,
          ),
        ),
        onFailed: () {
          if (revision == _companionRevision) _companionResultSent = false;
        },
      ),
    );
  }

  Future<void> _onCompanionMessage(GameStreamCompanionMessage message) async {
    if (!mounted) return;
    final GameStreamLookupController? controller = _lookupController;
    switch (message) {
      case GameStreamCompanionReady():
        // A fresh panel: send everything again.
        _sentCompanionState = null;
        _companionResultSent = false;
        _syncCompanion();
      case GameStreamCompanionLookupAt(:final String lineId, :final int index):
        final GameStreamTextEvent? line = controller?.currentLine;
        if (line == null || line.lineId != lineId) return;
        _lookupAt(line, index);
        // Toggle + touch, as on the inline rail.
        if (_controllerUsed) _setInputMode(GameStreamInputMode.lookup);
      case GameStreamCompanionLookupText(:final String text):
        unawaited(controller?.lookup(text));
      case GameStreamCompanionSetMode(:final GameStreamInputMode mode):
        _setInputMode(mode);
      case GameStreamCompanionRequest():
        await _answerCompanion(message);
    }
  }

  Future<void> _answerCompanion(GameStreamCompanionRequest request) async {
    final GameStreamCompanionDisplay? display = widget.companionDisplay;
    if (display == null) return;
    final GameStreamLookupController? controller = _lookupController;
    final DictionaryPopupResourceSource? resources = controller?.popupResources;
    Object? value;
    try {
      value = switch (request) {
        GameStreamCompanionMineRequest(:final Map<String, String> fields) =>
          _mineOutcomeOf(await _mine(fields)).name,
        GameStreamCompanionDuplicateRequest(
          :final String expression,
          :final String reading,
        ) =>
          await controller?.isDuplicate(expression, reading) ?? false,
        GameStreamCompanionMediaRequest(
          :final String dictionary,
          :final String path,
        ) =>
          encodeGameStreamCompanionMedia(
            await resources?.mediaFile(dictionary, path),
          ),
        GameStreamCompanionAudioRequest(
          :final String expression,
          :final String reading,
        ) =>
          await resources?.wordAudioRef(expression, reading),
      };
    } catch (error, stack) {
      // The panel still gets an answer (missing media, no audio, a failed
      // card) so its request does not hang; the cause goes to the log.
      ErrorLogService.instance.log(
        'GameStreamPage.companionRequest',
        error,
        stack,
      );
      value = request is GameStreamCompanionMineRequest
          ? GameStreamCompanionMineOutcome.error.name
          : null;
    }
    await _runCompanionCall(
      'reply',
      display.send(GameStreamCompanionReply(id: request.id, value: value)),
    );
  }

  static GameStreamCompanionMineOutcome _mineOutcomeOf(
    MinePopupResult result,
  ) => result.ankiConnect
      ? GameStreamCompanionMineOutcome.ok
      : result.duplicate
      ? GameStreamCompanionMineOutcome.duplicate
      : GameStreamCompanionMineOutcome.error;

  /// The current line as [_caretLine] tracks it.
  ({String lineId, String text})? _currentCaretLine() {
    final GameStreamTextEvent? line = _lookupController?.currentLine;
    return line == null ? null : (lineId: line.lineId, text: line.text);
  }

  void _onLookupChanged() {
    final ({String lineId, String text})? current = _currentCaretLine();
    if (current != _caretLine) {
      _caretLine = current;
      _lookupCaret = 0;
      _lookupStart = null;
    }
    if (mounted) setState(() {});
  }

  /// Widens the rail by [delta] (negative narrows), within this body's limits.
  void _resizeRail(double delta) {
    final double current = _lookupLayout.effectiveRailWidth(_bodyWidth);
    final double next = (current + delta).clamp(
      GameStreamLookupLayout.minRailWidth,
      GameStreamLookupLayout.railWidthLimit(_bodyWidth),
    );
    if (next == current) return;
    setState(() => _lookupLayout = _lookupLayout.copyWith(railWidth: next));
  }

  /// Grows the narrow-layout panel under the video by [delta] (negative
  /// shrinks), within this body's limits.
  void _resizeCompactRail(double delta) {
    // Too short for both minimums (soft keyboard up): the split is fixed, and
    // a drag here must not overwrite the stored height with the minimum.
    if (!GameStreamLookupLayout.compactRailResizable(_bodyHeight)) return;
    final double current = _lookupLayout.effectiveCompactRailHeight(
      _bodyHeight,
    );
    final double next = (current + delta).clamp(
      GameStreamLookupLayout.minCompactRailHeight,
      GameStreamLookupLayout.compactRailHeightLimit(_bodyHeight),
    );
    if (next == current) return;
    setState(
      () => _lookupLayout = _lookupLayout.copyWith(compactRailHeight: next),
    );
  }

  /// Grows the line area by [delta] (negative shrinks), within this rail's
  /// limits. The line text zooms with it.
  void _resizeLine(double delta) {
    final double current = _lookupLayout.effectiveLineHeight(_railHeight);
    final double next = (current + delta).clamp(
      GameStreamLookupLayout.minLineHeight,
      GameStreamLookupLayout.lineHeightLimit(_railHeight),
    );
    if (next == current) return;
    setState(() => _lookupLayout = _lookupLayout.copyWith(lineHeight: next));
  }

  void _commitLookupLayout() {
    if (_lookupLayout == _committedLookupLayout) return;
    _committedLookupLayout = _lookupLayout;
    widget.onLookupLayoutChanged?.call(_lookupLayout);
  }

  void _onReceiverChanged() {
    final FushiGameStreamReceiver? receiver = widget.receiver;
    if (receiver != null &&
        (receiver.backgrounded ||
            receiver.state != GameStreamReceiverState.connected)) {
      unawaited(_releasePointer());
      unawaited(_releaseHeldInputs());
    }
    if (mounted) setState(() {});
  }

  @override
  void didChangeMetrics() {
    // Android handles rotation in the existing Activity. It need not pause the
    // receiver, so releasing only on an app lifecycle transition is insufficient.
    unawaited(_releasePointer());
  }

  ({Rect bounds, Rect content})? _currentPointerGeometry() {
    final RenderBox? box =
        _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final Size contentSize = _videoContentSize(box.size);
    return (
      bounds: Rect.fromPoints(
        box.localToGlobal(Offset.zero),
        box.localToGlobal(box.size.bottomRight(Offset.zero)),
      ),
      content: Rect.fromCenter(
        center: box.size.center(Offset.zero),
        width: contentSize.width,
        height: contentSize.height,
      ),
    );
  }

  void _releasePointerIfLayoutChanged(Duration _) {
    if (!mounted) return;
    final ({Rect bounds, Rect content})? geometry = _currentPointerGeometry();
    if ((_touch != null && _pointerGeometry != geometry) ||
        (_mouse?.active == true && _mouseGeometry != geometry)) {
      unawaited(_releasePointer());
    }
  }

  void _schedulePointerGeometryCheck() {
    if (_touch != null || _mouse?.active == true) {
      WidgetsBinding.instance.addPostFrameCallback(
        _releasePointerIfLayoutChanged,
      );
    }
  }

  Future<void> _releasePointer() async {
    // Clear synchronously: cancellation, metrics and disposal can arrive in the
    // same frame and must emit exactly one release to the original session.
    final GameStreamTouchInterpreter? touch = _touch;
    final GameStreamInputComposer? composer = _pointerComposer;
    _touch = null;
    _pointerComposer = null;
    _pointerGeometry = null;
    // _releaseMouse also detaches its state before its first await.
    final Future<void> mouse = _releaseMouse();
    if (touch != null && composer != null) {
      await _dispatchPointer(touch.cancel(), composer);
    }
    await mouse;
  }

  Future<void> _sendPointer(
    PointerEvent event,
    GameStreamInputAction action,
  ) async {
    final ({Rect bounds, Rect content})? geometry = _currentPointerGeometry();
    if (action == GameStreamInputAction.down) {
      if (geometry == null) return;
      if (_touch == null) {
        _touch = GameStreamTouchInterpreter(
          mode: _touchMode,
          rightClickSupported: _supports(GameStreamFeature.pointerButtons),
          wheelSupported: _supports(GameStreamFeature.wheel),
          initialCursor: _trackpadCursor,
        );
        _pointerComposer = widget.inputComposer;
        _pointerGeometry = geometry;
      } else if (geometry != _pointerGeometry) {
        await _releasePointer();
        return;
      }
    } else {
      if (_touch == null) return;
      if (geometry == null || geometry != _pointerGeometry) {
        await _releasePointer();
        return;
      }
    }
    final RenderBox? box =
        _videoKey.currentContext?.findRenderObject() as RenderBox?;
    final GameStreamTouchInterpreter? touch = _touch;
    final GameStreamInputComposer? composer = _pointerComposer;
    if (box == null || touch == null || composer == null) return;
    final Offset local = box.globalToLocal(event.position);
    final Offset normalized = GameStreamPointerMapper(
      geometry.content.size,
    ).normalize(local - geometry.content.topLeft);
    final Size scale = geometry.content.size;
    final List<GameStreamPointerCommand> commands = switch (action) {
      GameStreamInputAction.down => touch.down(
        event.pointer,
        normalized,
        event.timeStamp,
        pixelScale: scale,
      ),
      GameStreamInputAction.move => touch.move(
        event.pointer,
        normalized,
        event.timeStamp,
        pixelScale: scale,
      ),
      _ => touch.up(
        event.pointer,
        normalized,
        event.timeStamp,
        pixelScale: scale,
      ),
    };
    if (_touchMode == GameStreamTouchMode.trackpad &&
        touch.cursor != _trackpadCursor) {
      setState(() => _trackpadCursor = touch.cursor);
    }
    if (!touch.active) {
      // Gesture finished: the next touch starts a fresh interpreter.
      _touch = null;
      _pointerComposer = null;
      _pointerGeometry = null;
    }
    await _dispatchPointer(commands, composer);
  }

  static bool _isMouse(PointerEvent event) =>
      event.kind == PointerDeviceKind.mouse;

  /// Hovering is spontaneous, so it is only sent while input can reach the
  /// host; otherwise every move would come back as a rejected ack.
  bool get _canHover {
    final FushiGameStreamReceiver? receiver = widget.receiver;
    return receiver != null &&
        !receiver.backgrounded &&
        receiver.state == GameStreamReceiverState.connected;
  }

  Offset? _normalizeMouse(
    PointerEvent event,
    ({Rect bounds, Rect content}) geometry,
  ) {
    final RenderBox? box =
        _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    return GameStreamPointerMapper(
      geometry.content.size,
    ).normalize(box.globalToLocal(event.position) - geometry.content.topLeft);
  }

  GameStreamMouseInterpreter _mouseFor(({Rect bounds, Rect content}) geometry) {
    _mouseGeometry = geometry;
    return _mouse ??= GameStreamMouseInterpreter(
      extraButtonsSupported: _supports(GameStreamFeature.pointerButtons),
      wheelSupported: _supports(GameStreamFeature.wheel),
    );
  }

  /// Desktop mouse press / release / drag / hover: buttons map to themselves.
  Future<void> _sendMouse(PointerEvent event) async {
    if (_mouseAwaitingRelease) {
      if (event.buttons == 0) _mouseAwaitingRelease = false;
      return;
    }
    final ({Rect bounds, Rect content})? geometry = _currentPointerGeometry();
    if (geometry == null) return;
    // A held button whose video moved under it cannot be continued.
    if (_mouse?.active == true && geometry != _mouseGeometry) {
      await _releaseMouse();
      return;
    }
    final Offset? normalized = _normalizeMouse(event, geometry);
    if (normalized == null) return;
    await _dispatchMouse(_mouseFor(geometry).update(normalized, event.buttons));
  }

  /// Logical pixels one physical wheel detent arrives as. The desktop
  /// embedders disagree: Windows reports WHEEL_DELTA as 100 physical pixels,
  /// macOS one line as 40, Linux 53. Counting detents per platform keeps one
  /// detent = one host notch (a VN advances or backs up one line), while a
  /// high-resolution wheel's small deltas still add up instead of each
  /// becoming a whole notch.
  double _wheelDetentPixels() => switch (defaultTargetPlatform) {
    TargetPlatform.windows => 100 / MediaQuery.devicePixelRatioOf(context),
    TargetPlatform.macOS => 40,
    _ => 53,
  };

  Future<void> _scrollMouse(
    PointerEvent event,
    Offset delta, {
    double step = GameStreamMouseInterpreter.scrollStep,
  }) async {
    final ({Rect bounds, Rect content})? geometry = _currentPointerGeometry();
    if (geometry == null) return;
    final Offset? normalized = _normalizeMouse(event, geometry);
    if (normalized == null) return;
    await _dispatchMouse(
      _mouseFor(geometry).scroll(normalized, delta, step: step),
    );
  }

  Future<void> _releaseMouse() async {
    final GameStreamMouseInterpreter? mouse = _mouse;
    if (mouse == null) return;
    if (mouse.active) _mouseAwaitingRelease = true;
    _mouse = null;
    _mouseGeometry = null;
    _queuedMouseMove = null;
    await _dispatchPointer(mouse.cancel(), widget.inputComposer);
  }

  /// Moves are positional, so only the newest matters: one is in flight at a
  /// time and the latest waiting position replaces the rest. Each input waits
  /// for the host's ack, and a mouse reports motion far faster than that. A
  /// button event carries its own position, so it drops a waiting move rather
  /// than letting the older position land after the press.
  Future<void> _dispatchMouse(List<GameStreamPointerCommand> commands) async {
    final GameStreamInputComposer composer = widget.inputComposer;
    final bool moveOnly =
        commands.length == 1 &&
        commands.single.action == GameStreamInputAction.move;
    if (!moveOnly) {
      _queuedMouseMove = null;
      await _dispatchPointer(commands, composer);
      return;
    }
    if (_mouseMoveInFlight) {
      _queuedMouseMove = commands.single.position;
      return;
    }
    _mouseMoveInFlight = true;
    try {
      Offset? next = commands.single.position;
      while (next != null) {
        _queuedMouseMove = null;
        await composer.pointer(
          action: GameStreamInputAction.move,
          normalized: next,
        );
        next = _queuedMouseMove;
      }
    } finally {
      _mouseMoveInFlight = false;
    }
  }

  Future<void> _dispatchPointer(
    List<GameStreamPointerCommand> commands,
    GameStreamInputComposer composer,
  ) async {
    for (final GameStreamPointerCommand command in commands) {
      if (command.action == GameStreamInputAction.wheel) {
        await composer.wheel(
          normalized: command.position,
          dx: command.dx,
          dy: command.dy,
        );
      } else {
        await composer.pointer(
          action: command.action,
          normalized: command.position,
          button: command.button ?? 'left',
        );
      }
    }
  }

  Size _videoContentSize(Size boxSize) {
    final RTCVideoRenderer? renderer = widget.receiver?.renderer;
    final int width = renderer?.videoWidth ?? 0;
    final int height = renderer?.videoHeight ?? 0;
    if (width <= 0 || height <= 0) return boxSize;
    final double scale = math.min(
      boxSize.width / width,
      boxSize.height / height,
    );
    return Size(width * scale, height * scale);
  }

  Future<MinePopupResult> _mine(Map<String, String> fields) async {
    final GameStreamLookupController? controller = _lookupController;
    // The popup shows the result of `resultLine`; a newer Hook line may be
    // current by now, and that is fine — the card is for the looked-up line.
    if (controller == null || controller.resultLine == null) {
      return MinePopupResult.failed(const MineOutcome(MineResult.error));
    }
    try {
      final GameStreamMineResult? result = await controller.mine(fields);
      final bool duplicate = result?.detail == 'duplicate';
      if (mounted) {
        setState(() {
          _mineFailed = result?.ok != true;
          _mineMessage = gameStreamMineMessage(result);
        });
      }
      return result?.ok == true
          ? const MinePopupResult(ankiConnect: true)
          : MinePopupResult.failed(
              MineOutcome(duplicate ? MineResult.duplicate : MineResult.error),
            );
    } catch (error) {
      if (mounted) {
        setState(() {
          _mineFailed = true;
          _mineMessage = '${t.game_stream_mine_failed}: $error';
        });
      }
      return MinePopupResult.failed(const MineOutcome(MineResult.error));
    }
  }

  /// The on-screen pad.
  Future<void> _sendButton(
    GameStreamVirtualButton button,
    GameStreamInputAction action,
  ) => action == GameStreamInputAction.down
      ? _hold(button, _padOutput(button))
      : _release(button);

  /// What pressing pad [button] holds on the host: its keyboard binding when
  /// it has one, the gamepad button otherwise.
  _HostOutput _padOutput(GameStreamVirtualButton button) {
    final String? key = _keyBindings[button];
    return key == null ? _HostOutput.pad(button) : _HostOutput.key(key);
  }

  /// Where host pointer actions from a button land: wherever the host cursor
  /// last went (any pointer path), the middle of the picture before that.
  Offset _hostCursor(GameStreamInputComposer composer) =>
      composer.lastPointerPosition ?? _trackpadCursor;

  /// [source] presses [output]; the host sees a down only when nothing else
  /// already holds it.
  Future<void> _hold(Object source, _HostOutput output) async {
    if (_heldSources.containsKey(source)) return;
    _heldSources[source] = output;
    final int holds = (_outputHolds[output] ?? 0) + 1;
    _outputHolds[output] = holds;
    if (holds > 1) return;
    await _sendOutput(output, GameStreamInputAction.down, widget.inputComposer);
  }

  /// [source] lets go; the host sees the up only when it held the last hold.
  Future<void> _release(Object source) async {
    final _HostOutput? output = _heldSources.remove(source);
    if (output == null) return;
    final int holds = (_outputHolds[output] ?? 1) - 1;
    if (holds > 0) {
      _outputHolds[output] = holds;
      return;
    }
    _outputHolds.remove(output);
    await _sendOutput(output, GameStreamInputAction.up, widget.inputComposer);
  }

  /// Lifts everything held (backgrounding, a dropped connection, lookup mode,
  /// disposal) on [composer], the session that saw the downs. Cleared before
  /// the first await, so a second call sends nothing twice.
  Future<void> _releaseHeldInputs([GameStreamInputComposer? composer]) async {
    final GameStreamInputComposer target = composer ?? widget.inputComposer;
    final List<_HostOutput> held = _outputHolds.keys.toList();
    _heldSources.clear();
    _outputHolds.clear();
    _heldPhysical.clear();
    for (final _HostOutput output in held) {
      await _sendOutput(output, GameStreamInputAction.up, target);
    }
  }

  Future<void> _sendOutput(
    _HostOutput output,
    GameStreamInputAction phase,
    GameStreamInputComposer composer,
  ) async {
    switch (output) {
      case _HostOutput(:final GameStreamVirtualButton pad?):
        await composer.gamepad(button: pad, action: phase);
      case _HostOutput(:final String key?):
        await composer.key(key: key, action: phase);
      case _HostOutput(:final String pointer?):
        final Offset at = _hostCursor(composer);
        // Nothing has placed the host cursor yet: put it where the press
        // lands first, as a mouse would have.
        if (phase == GameStreamInputAction.down &&
            composer.lastPointerPosition == null) {
          await composer.pointer(
            action: GameStreamInputAction.move,
            normalized: at,
          );
        }
        await composer.pointer(action: phase, normalized: at, button: pointer);
      case _HostOutput():
        return;
    }
  }

  String _buttonLabel(GameStreamVirtualButton button) => switch (button) {
    GameStreamVirtualButton.up => '↑',
    GameStreamVirtualButton.down => '↓',
    GameStreamVirtualButton.left => '←',
    GameStreamVirtualButton.right => '→',
    GameStreamVirtualButton.confirm => 'A',
    GameStreamVirtualButton.cancel => 'B',
    GameStreamVirtualButton.shoulderLeft => 'L',
    GameStreamVirtualButton.shoulderRight => 'R',
    GameStreamVirtualButton.menu => 'Menu',
  };

  /// 按键映射行的行首图标：方向键 = 手柄、其余（A/B/L/R）= 键盘按键。
  static IconData _bindingIcon(GameStreamVirtualButton button) =>
      switch (button) {
        GameStreamVirtualButton.up ||
        GameStreamVirtualButton.down ||
        GameStreamVirtualButton.left ||
        GameStreamVirtualButton.right => FushiIcons.games,
        _ => FushiIcons.keyboard,
      };

  static String _physicalLabel(GameStreamPhysicalButton button) =>
      switch (button) {
        GameStreamPhysicalButton.dpadUp => '↑',
        GameStreamPhysicalButton.dpadDown => '↓',
        GameStreamPhysicalButton.dpadLeft => '←',
        GameStreamPhysicalButton.dpadRight => '→',
        GameStreamPhysicalButton.a => 'A',
        GameStreamPhysicalButton.b => 'B',
        GameStreamPhysicalButton.x => 'X',
        GameStreamPhysicalButton.y => 'Y',
        GameStreamPhysicalButton.l1 => 'L1',
        GameStreamPhysicalButton.r1 => 'R1',
        GameStreamPhysicalButton.l2 => 'L2',
        GameStreamPhysicalButton.r2 => 'R2',
        GameStreamPhysicalButton.l3 => 'L3',
        GameStreamPhysicalButton.r3 => 'R3',
        GameStreamPhysicalButton.start => 'Start',
        GameStreamPhysicalButton.select => 'Select',
      };

  String _actionLabel(GameStreamButtonAction action) => switch (action) {
    GameStreamPadAction(:final GameStreamVirtualButton button) =>
      t.game_stream_action_pad(button: _buttonLabel(button)),
    GameStreamHostKeyAction(:final String key) => t.game_stream_action_key(
      key: key,
    ),
    GameStreamMouseButtonAction(:final GameStreamMouseAction mouse) =>
      switch (mouse) {
        GameStreamMouseAction.leftClick => t.game_stream_action_left_click,
        GameStreamMouseAction.rightClick => t.game_stream_action_right_click,
        GameStreamMouseAction.middleClick => t.game_stream_action_middle_click,
        GameStreamMouseAction.wheelUp => t.game_stream_action_wheel_up,
        GameStreamMouseAction.wheelDown => t.game_stream_action_wheel_down,
      },
    GameStreamAppAction(:final GameStreamReceiverAction action) =>
      switch (action) {
        GameStreamReceiverAction.toggleLookupPanel =>
          t.game_stream_action_lookup_panel_toggle,
        GameStreamReceiverAction.toggleOnScreenPad =>
          t.game_stream_action_on_screen_pad_toggle,
        GameStreamReceiverAction.toggleLookupMode =>
          t.game_stream_action_lookup_mode_toggle,
      },
    GameStreamNoAction() => t.game_stream_action_none,
  };

  /// Every action a controller button can take on this host, in menu order.
  /// Mouse actions the host does not support are left out.
  List<GameStreamButtonAction> get _availableButtonActions =>
      <GameStreamButtonAction>[
        const GameStreamNoAction(),
        for (final GameStreamVirtualButton button
            in GameStreamVirtualButton.values)
          GameStreamPadAction(button),
        for (final GameStreamMouseAction mouse in GameStreamMouseAction.values)
          if (_canRun(GameStreamMouseButtonAction(mouse)))
            GameStreamMouseButtonAction(mouse),
        for (final GameStreamReceiverAction action
            in GameStreamReceiverAction.values)
          GameStreamAppAction(action),
        for (final String key in GameStreamHostKeyAction.keys)
          GameStreamHostKeyAction(key),
      ];

  void _updateButtonProfile(GameStreamButtonProfile next) {
    if (next == _buttonProfile) return;
    setState(() => _buttonProfile = next);
    widget.onButtonProfileChanged?.call(next);
  }

  Widget _keysSectionHeader(BuildContext context, String label) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  Widget _controllerButtonRow(
    GameStreamPhysicalButton button,
    List<GameStreamButtonAction> actions,
    StateSetter updateSheet,
  ) {
    final GameStreamButtonAction current = _buttonProfile.actionFor(button);
    // A saved action this host cannot run (e.g. right click on an older
    // host) still shows, so the row never displays a choice it does not list.
    final List<GameStreamButtonAction> items = <GameStreamButtonAction>[
      ...actions,
      if (!actions.contains(current)) current,
    ];
    return FushiListItem(
      key: ValueKey<String>('game-stream-controller-${button.name}'),
      leading: FushiListLeadingIcon(
        FushiIcons.games,
        tone: _buttonProfile.isCustomized(button)
            ? FushiCardTone.primary
            : FushiCardTone.secondary,
      ),
      title: Text(_physicalLabel(button)),
      // The dropdown is as wide as its longest label unless capped; long
      // labels (and longer translations) end in an ellipsis instead of
      // overflowing the row on a narrow phone.
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _controllerActionMaxWidth),
        child: FushiDropdownButton<String>(
          key: ValueKey<String>('game-stream-controller-action-${button.name}'),
          isExpanded: true,
          value: current.toWire(),
          items: <DropdownMenuItem<String>>[
            for (final GameStreamButtonAction action in items)
              DropdownMenuItem<String>(
                value: action.toWire(),
                child: Text(
                  _actionLabel(action),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (String? wire) {
            final GameStreamButtonAction? action =
                GameStreamButtonAction.tryParse(wire);
            if (action == null) return;
            updateSheet(
              () => _updateButtonProfile(
                _buttonProfile.withAction(button, action),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _configureKeys() async {
    // A held control must retain its down/up mapping until it is released.
    if (_heldSources.isNotEmpty || _heldPhysical.isNotEmpty) return;
    setState(() => _lookupSuspended = true);
    try {
      await adaptiveModalSheet<void>(
        context: context,
        builder: (BuildContext context) => StatefulBuilder(
          builder: (BuildContext context, StateSetter updateSheet) =>
              // M3E 底部弹层：共享弹层框（标题 + 说明）。上组是屏幕手柄（仅本次
              // 会话），下组是实体手柄按键（保存在本设备），行尾下拉选动作。
              FushiModalSheetFrame(
                title: t.game_stream_keys,
                subtitle: t.game_stream_keys_scope_hint,
                leadingIcon: FushiIcons.games,
                maxHeightFactor: 0.8,
                body: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  children: <Widget>[
                    if (widget.companionDisplay != null) ...<Widget>[
                      _keysSectionHeader(
                        context,
                        t.game_stream_second_screen_section,
                      ),
                      AdaptiveSettingsSegmentedRow<GameStreamSecondScreen>(
                        key: GameStreamPage.secondScreenKey,
                        title: t.game_stream_second_screen,
                        subtitle: t.game_stream_second_screen_hint,
                        segments: <ButtonSegment<GameStreamSecondScreen>>[
                          ButtonSegment<GameStreamSecondScreen>(
                            value: GameStreamSecondScreen.auto,
                            label: Text(t.game_stream_second_screen_auto),
                          ),
                          ButtonSegment<GameStreamSecondScreen>(
                            value: GameStreamSecondScreen.off,
                            label: Text(t.game_stream_second_screen_off),
                          ),
                        ],
                        selected: _secondScreen,
                        onChanged: (GameStreamSecondScreen value) =>
                            updateSheet(() => _setSecondScreen(value)),
                      ),
                    ],
                    _keysSectionHeader(context, t.game_stream_keys_pad_section),
                    FushiGroupedList(
                      children: <Widget>[
                        for (final GameStreamVirtualButton button
                            in GameStreamVirtualButton.values)
                          if (button != GameStreamVirtualButton.menu)
                            FushiListItem(
                              leading: FushiListLeadingIcon(
                                _bindingIcon(button),
                                tone: _keyBindings.containsKey(button)
                                    ? FushiCardTone.primary
                                    : FushiCardTone.secondary,
                              ),
                              title: Text(_buttonLabel(button)),
                              trailing: FushiDropdownButton<String>(
                                key: ValueKey<String>(
                                  'game-stream-binding-${button.name}',
                                ),
                                value: _keyBindings[button] ?? '',
                                items: <DropdownMenuItem<String>>[
                                  DropdownMenuItem<String>(
                                    value: '',
                                    child: Text(t.game_stream_key_default),
                                  ),
                                  for (final String key
                                      in GameStreamHostKeyAction.keys)
                                    DropdownMenuItem<String>(
                                      value: key,
                                      child: Text(key),
                                    ),
                                ],
                                onChanged: (String? key) => updateSheet(() {
                                  if (key == null || key.isEmpty) {
                                    _keyBindings.remove(button);
                                  } else {
                                    _keyBindings[button] = key;
                                  }
                                }),
                              ),
                            ),
                      ],
                    ),
                    _keysSectionHeader(
                      context,
                      t.game_stream_keys_controller_section,
                    ),
                    FushiGroupedList(
                      children: <Widget>[
                        for (final GameStreamPhysicalButton button
                            in GameStreamPhysicalButton.values)
                          _controllerButtonRow(
                            button,
                            _availableButtonActions,
                            updateSheet,
                          ),
                      ],
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FushiTextButton(
                          key: const ValueKey<String>(
                            'game-stream-controller-reset',
                          ),
                          onPressed: _buttonProfile.overrides.isEmpty
                              ? null
                              : () => updateSheet(
                                  () => _updateButtonProfile(
                                    const GameStreamButtonProfile(),
                                  ),
                                ),
                          child: Text(t.game_stream_keys_controller_reset),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
        ),
      );
    } finally {
      if (mounted) setState(() => _lookupSuspended = false);
    }
  }

  /// Physical controller buttons always run their profile action; keyboard
  /// keys are sent to the host only while the video itself holds focus, so
  /// typing into the transcript or popup never leaks into the game.
  ///
  /// Android reports a controller D-pad as arrow keys. Those count as the
  /// D-pad when Android names a controller as their source; arrows from a
  /// keyboard keep moving focus (the transcript cursor) unless the video
  /// holds focus.
  KeyEventResult _onHardwareKey(FocusNode node, KeyEvent event) {
    final bool down = event is KeyDownEvent;
    final bool up = event is KeyUpEvent;
    final bool videoFocused = FocusManager.instance.primaryFocus == _videoFocus;
    final bool lookupMode = _inputMode == GameStreamInputMode.lookup;
    // In lookup mode every arrow that reaches the page is the D-pad: a
    // focused line or text field handles its own arrows before they bubble
    // up here, and the game gets no arrows in this mode anyway.
    final GameStreamPhysicalButton? physical =
        GameStreamPhysicalButton.gameButtonFor(event.logicalKey) ??
        (lookupMode || _isControllerSource(event.deviceType)
            ? GameStreamPhysicalButton.dpadFor(event.logicalKey)
            : null);
    if (physical != null) {
      // The mode chip appears with the first controller press, not with
      // whatever rebuild happens next.
      if (!_controllerUsed) setState(() => _controllerUsed = true);
      if (lookupMode) {
        if (down || (event is KeyRepeatEvent && physical.isDpad)) {
          unawaited(_onLookupButton(physical));
        }
        return KeyEventResult.handled;
      }
      if (down) unawaited(_pressPhysical(physical));
      if (up) unawaited(_releasePhysical(physical));
      return KeyEventResult.handled;
    }
    if (!videoFocused) return KeyEventResult.ignored;
    final String? key = gameStreamHostKeyName(event.logicalKey);
    if (key == null) return KeyEventResult.ignored;
    if (down || up) {
      unawaited(
        widget.inputComposer.key(
          key: key,
          action: down ? GameStreamInputAction.down : GameStreamInputAction.up,
        ),
      );
    }
    return KeyEventResult.handled;
  }

  static bool _isControllerSource(KeyEventDeviceType type) => switch (type) {
    KeyEventDeviceType.gamepad ||
    KeyEventDeviceType.joystick ||
    KeyEventDeviceType.directionalPad => true,
    _ => false,
  };

  Future<void> _pressPhysical(GameStreamPhysicalButton button) async {
    // Key repeat arrives as repeated downs on some controllers; the first
    // press already holds the action.
    if (_heldPhysical.containsKey(button)) return;
    final GameStreamButtonAction action = _buttonProfile.actionFor(button);
    _heldPhysical[button] = action;
    await _runButtonAction(action, GameStreamInputAction.down, button);
  }

  Future<void> _releasePhysical(GameStreamPhysicalButton button) async {
    final GameStreamButtonAction? action = _heldPhysical.remove(button);
    if (action == null) return;
    await _runButtonAction(action, GameStreamInputAction.up, button);
  }

  /// Whether this host can perform [action] (newer pointer kinds are gated
  /// by the session's features).
  bool _canRun(GameStreamButtonAction action) => switch (action) {
    GameStreamMouseButtonAction(:final GameStreamMouseAction mouse) =>
      mouse.isWheel
          ? _supports(GameStreamFeature.wheel)
          : mouse == GameStreamMouseAction.leftClick ||
                _supports(GameStreamFeature.pointerButtons),
    _ => true,
  };

  /// Runs (down) or undoes (up) [action] for the physical button [source].
  Future<void> _runButtonAction(
    GameStreamButtonAction action,
    GameStreamInputAction phase,
    GameStreamPhysicalButton source,
  ) async {
    final bool down = phase == GameStreamInputAction.down;
    if (!down) {
      // Whatever the press held (nothing for wheel / app / none actions).
      await _release(source);
      return;
    }
    if (!_canRun(action)) return;
    switch (action) {
      case GameStreamPadAction(:final GameStreamVirtualButton button):
        await _hold(source, _padOutput(button));
      case GameStreamHostKeyAction(:final String key):
        await _hold(source, _HostOutput.key(key));
      case GameStreamMouseButtonAction(:final GameStreamMouseAction mouse):
        final String? pointer = mouse.pointerButton;
        if (pointer != null) {
          await _hold(source, _HostOutput.pointer(pointer));
          return;
        }
        final GameStreamInputComposer composer = widget.inputComposer;
        await composer.wheel(
          normalized: _hostCursor(composer),
          dy: mouse.wheelNotches,
        );
      case GameStreamAppAction(:final GameStreamReceiverAction action):
        if (!mounted) return;
        switch (action) {
          case GameStreamReceiverAction.toggleLookupPanel:
            _setLookupVisible(!_lookupVisible);
          case GameStreamReceiverAction.toggleOnScreenPad:
            setState(() => _controlsVisible = !_controlsVisible);
          case GameStreamReceiverAction.toggleLookupMode:
            _setInputMode(GameStreamInputMode.lookup);
        }
      case GameStreamNoAction():
        return;
    }
  }

  /// Shows or hides the lookup panel. Lookup mode lives in the panel (its
  /// chip, hint and outline), so hiding it goes back to the game: buttons
  /// must never be swallowed by a mode nothing on screen shows.
  void _setLookupVisible(bool visible) {
    if (!mounted || visible == _lookupVisible) return;
    setState(() {
      _lookupVisible = visible;
      if (!visible) _inputMode = GameStreamInputMode.game;
    });
  }

  /// Switches where controller buttons go. Entering lookup mode lifts every
  /// button still held for the game (a held Control must not keep skipping)
  /// and shows the lookup panel.
  void _setInputMode(GameStreamInputMode mode) {
    if (!mounted || mode == _inputMode) return;
    if (mode == GameStreamInputMode.lookup) {
      unawaited(_releaseHeldInputs());
    }
    setState(() {
      _inputMode = mode;
      if (mode == GameStreamInputMode.lookup) _lookupVisible = true;
    });
  }

  /// Graphemes in the current line (0 without one).
  int get _lineLength =>
      _lookupController?.currentLine?.text.characters.length ?? 0;

  /// Grapheme length of the word the last lookup matched at [_lookupStart];
  /// 0 when there is no match for the current line.
  int get _matchedLength {
    final GameStreamLookupController? controller = _lookupController;
    final GameStreamTextEvent? line = controller?.currentLine;
    final String? term = controller?.selectedTerm;
    if (_lookupStart == null ||
        controller?.result == null ||
        line == null ||
        term == null ||
        controller?.resultLine?.lineId != line.lineId ||
        controller?.resultLine?.text != line.text) {
      return 0;
    }
    return term.characters.length;
  }

  void _moveLookupCaret(int to) {
    final int length = _lineLength;
    if (length == 0) return;
    setState(() => _lookupCaret = to.clamp(0, length - 1));
  }

  /// Looks up the word starting at grapheme [index] of the current [line]
  /// (the host matches the longest dictionary word from there).
  void _lookupAt(GameStreamTextEvent line, int index) {
    final GameStreamLookupController? controller = _lookupController;
    final ({int start, String term}) span = subtitleTranscriptLookupSpan(
      line.text,
      index,
    );
    if (span.start < 0 ||
        controller?.currentLine?.lineId != line.lineId ||
        controller?.currentLine?.text != line.text) {
      return;
    }
    // The query starts at span.start (a Latin word's first letter, past
    // leading blanks), so the highlight and D-pad right count from there too.
    setState(() {
      _lookupCaret = span.start;
      _lookupStart = span.start;
    });
    unawaited(
      controller?.lookup(
        span.term,
        displayTerm: line.text.characters.elementAt(span.start),
      ),
    );
  }

  /// One controller button in lookup mode. The button the profile uses to
  /// switch modes (Select by default) and B go back to the game.
  Future<void> _onLookupButton(GameStreamPhysicalButton button) async {
    if (_buttonProfile.actionFor(button) ==
        const GameStreamAppAction(GameStreamReceiverAction.toggleLookupMode)) {
      _setInputMode(GameStreamInputMode.game);
      return;
    }
    final DictionaryPopupWebViewState? dictionary = _dictionaryKey.currentState;
    // The dictionary lives in the panel on the second display while it is up.
    final GameStreamCompanionDictionaryCommand? companionCommand =
        _companionActive
        ? switch (button) {
            GameStreamPhysicalButton.dpadUp =>
              GameStreamCompanionDictionaryCommand.entryPrevious,
            GameStreamPhysicalButton.dpadDown =>
              GameStreamCompanionDictionaryCommand.entryNext,
            GameStreamPhysicalButton.y =>
              GameStreamCompanionDictionaryCommand.mineFirstVisible,
            GameStreamPhysicalButton.x =>
              GameStreamCompanionDictionaryCommand.playFirstVisibleAudio,
            _ => null,
          }
        : null;
    if (companionCommand != null) {
      final GameStreamCompanionDisplay? display = widget.companionDisplay;
      if (display != null) {
        await _runCompanionCall(
          'command',
          display.send(GameStreamCompanionCommand(companionCommand)),
        );
      }
      return;
    }
    switch (button) {
      case GameStreamPhysicalButton.dpadLeft:
        _moveLookupCaret(_lookupCaret - 1);
      case GameStreamPhysicalButton.dpadRight:
        _moveLookupCaret(
          gameStreamLookupCaretRight(
            caret: _lookupCaret,
            lookupStart: _lookupStart,
            matchedLength: _matchedLength,
            lineLength: _lineLength,
          ),
        );
      case GameStreamPhysicalButton.dpadUp:
        await dictionary?.focusEntryMove(false);
      case GameStreamPhysicalButton.dpadDown:
        await dictionary?.focusEntryMove(true);
      case GameStreamPhysicalButton.a:
        final GameStreamTextEvent? line = _lookupController?.currentLine;
        if (line != null && _lineLength > 0) _lookupAt(line, _lookupCaret);
      case GameStreamPhysicalButton.y:
        await dictionary?.mineFirstVisibleEntry();
      case GameStreamPhysicalButton.x:
        await dictionary?.playFirstVisibleAudio();
      case GameStreamPhysicalButton.l1:
        _moveLookupCaret(0);
      case GameStreamPhysicalButton.r1:
        _moveLookupCaret(_lineLength - 1);
      case GameStreamPhysicalButton.b:
        _setInputMode(GameStreamInputMode.game);
      case GameStreamPhysicalButton.l2 ||
          GameStreamPhysicalButton.r2 ||
          GameStreamPhysicalButton.l3 ||
          GameStreamPhysicalButton.r3 ||
          GameStreamPhysicalButton.start ||
          GameStreamPhysicalButton.select:
        return;
    }
  }

  /// Soft keyboard: every typed ASCII letter/digit/space becomes a key tap;
  /// removing the sentinel is a backspace. Other characters (IME
  /// composition) cannot be injected as window keys and are dropped.
  void _onSoftKeyboardChanged(String value) {
    final List<String> taps = <String>[];
    if (!value.contains(_keyboardSentinel)) {
      taps.add('Backspace');
    }
    for (final int unit in value.replaceAll(_keyboardSentinel, '').codeUnits) {
      final String char = String.fromCharCode(unit);
      if (char == ' ') {
        taps.add('Space');
      } else if (RegExp(r'^[A-Za-z0-9]$').hasMatch(char)) {
        taps.add(char.toUpperCase());
      }
    }
    _keyboardText.value = const TextEditingValue(
      text: _keyboardSentinel,
      selection: TextSelection.collapsed(offset: 1),
    );
    unawaited(_tapKeys(taps));
  }

  Future<void> _tapKeys(List<String> keys) async {
    for (final String key in keys) {
      await widget.inputComposer.key(
        key: key,
        action: GameStreamInputAction.down,
      );
      await widget.inputComposer.key(
        key: key,
        action: GameStreamInputAction.up,
      );
    }
  }

  void _toggleKeyboard() {
    if (_keyboardFocus.hasFocus) {
      _keyboardFocus.unfocus();
    } else {
      _keyboardFocus.requestFocus();
    }
  }

  void _toggleStats() {
    setState(() => _statsVisible = !_statsVisible);
    _statsTimer?.cancel();
    _statsTimer = null;
    if (!_statsVisible) return;
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      final GameStreamStatsSample? sample = await widget.receiver
          ?.sampleStats();
      if (mounted && _statsVisible) setState(() => _stats = sample);
    });
  }

  Future<void> _toggleTouchMode() async {
    await _releasePointer();
    setState(() {
      _touchMode = _touchMode == GameStreamTouchMode.direct
          ? GameStreamTouchMode.trackpad
          : GameStreamTouchMode.direct;
    });
  }

  void _toggleAudio() {
    final GameStreamVideoSettings next = _settings.copyWith(
      audio: !_settings.audio,
    );
    setState(() => _settings = next);
    widget.receiver?.setAudioEnabled(next.audio);
    widget.onSettingsChanged?.call(next);
  }

  Future<void> _openSettings() async {
    setState(() => _lookupSuspended = true);
    try {
      final GameStreamVideoSettings? next = await showGameStreamSettingsSheet(
        context,
        initial: _settings,
      );
      if (next == null || !mounted) return;
      setState(() => _settings = next);
      widget.onSettingsChanged?.call(next);
      if (!_supports(GameStreamFeature.videoSettings)) {
        widget.receiver?.setAudioEnabled(next.audio);
        return;
      }
      final GameStreamVideoSettings? applied = await widget.receiver
          ?.updateSettings(next);
      if (!mounted || applied == null) return;
      // Resolution/fps can only go down from the host's capture ceiling;
      // tell the user when their request was capped.
      if (applied.maxHeight < next.maxHeight || applied.maxFps < next.maxFps) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          FushiSnackBar(content: Text(t.game_stream_settings_capped)),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          FushiSnackBar(
            content: Text('${t.game_stream_settings_apply_failed}: $error'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _lookupSuspended = false);
    }
  }

  void _onOverflowAction(_StreamMenuAction action) {
    switch (action) {
      case _StreamMenuAction.touchMode:
        unawaited(_toggleTouchMode());
      case _StreamMenuAction.keyboard:
        _toggleKeyboard();
      case _StreamMenuAction.stats:
        _toggleStats();
      case _StreamMenuAction.audio:
        _toggleAudio();
    }
  }

  String _rejectionMessage(String? reason) => switch (reason) {
    'window_not_foreground' ||
    'window_activation_timeout' => t.game_stream_input_rejected,
    'unsupported_native_pointer' => t.game_stream_input_pointer_unsupported,
    // A host whose game takes native controller input (SGRE) refuses keyboard
    // keys; say so instead of a raw reason code.
    'unsupported_native_key' => t.game_stream_input_key_unsupported,
    'window_minimized' || 'window_hidden' => t.game_stream_input_window_hidden,
    _ => '${t.game_stream_input_failed} ($reason)',
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    _scheduleCompanionSync();
    // 串流页整页黑底：桌面自绘顶栏（挂在 Navigator 外、只认根主题 surface）
    // 跟着变黑，否则画面顶上压一条浅色带。
    return FushiTitleBarColorScope(
      colors: fushiTitleBarColorsOn(Colors.black),
      child: Scaffold(
        backgroundColor: Colors.black,
        // Autofocus: controller buttons must reach the game as soon as the
        // stream opens, before anything inside the page was tapped. Kept out
        // of traversal so Tab / D-pad focus moves skip this wrapper.
        body: Focus(
          autofocus: true,
          skipTraversal: true,
          onKeyEvent: _onHardwareKey,
          child: _buildBody(theme),
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _schedulePointerGeometryCheck();
          final bool compact = constraints.maxWidth < 700;
          final Widget video = Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildVideoSurface(theme),
                if (widget.receiver?.error != null ||
                    widget.inputComposer.lastRejectionReason != null)
                  Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 52),
                      // M3E：浮在画面上的 error 饱和色块（图标 + 文案），
                      // 不再是贴边色条；Apple 落到系统红淡染。
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: FushiM3eShape.cardRadius,
                            // Apple 的淡染提示条贴在画面上，不带 M3 投影。
                            boxShadow: isGlassDesign(context)
                                ? null
                                : fushiM3eCardShadow(context, 1),
                          ),
                          child: FushiCard(
                            tone: FushiCardTone.error,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const FushiIcon(FushiIcons.warning, size: 20),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    widget.receiver?.error != null
                                        ? '${t.game_stream_disconnected}: ${widget.receiver!.error}'
                                        : _rejectionMessage(
                                            widget
                                                .inputComposer
                                                .lastRejectionReason,
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_controlsVisible) _buildGamepadOverlay(theme),
                // With the panel on the second display, this screen still
                // says which mode the buttons are in.
                if (_companionActive && _controllerUsed)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: _buildModeChip(theme),
                    ),
                  ),
                Align(
                  alignment: Alignment.topLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      // 返回钮与右上工具栏同一形态（悬浮工具栏 / Apple 玻璃
                      // 圆钮），不再是直接压在画面上的裸白色箭头——画面亮时
                      // 白箭头会消失。
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: FushiToolbar(
                          floating: true,
                          children: <Widget>[
                            FushiIconButtonControl(
                              tooltip: t.back,
                              icon: const FushiIcon(FushiIcons.back),
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                          ],
                        ),
                      ),
                      if (_statsVisible) _buildStatsOverlay(theme),
                    ],
                  ),
                ),
                // Off-screen-size text field that owns the soft keyboard.
                Positioned(
                  left: 0,
                  bottom: 0,
                  width: 1,
                  height: 1,
                  child: Opacity(
                    opacity: 0,
                    child: FushiTextFieldControl(
                      key: GameStreamPage.keyboardKey,
                      focusNode: _keyboardFocus,
                      controller: _keyboardText,
                      autocorrect: false,
                      enableSuggestions: false,
                      keyboardType: TextInputType.visiblePassword,
                      onChanged: _onSoftKeyboardChanged,
                      onSubmitted: (_) {
                        unawaited(_tapKeys(<String>['Enter']));
                        _keyboardFocus.requestFocus();
                      },
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.topRight,
                  // 悬浮工具栏（M3 Expressive floating toolbar / Apple 玻璃胶囊组）：
                  // 自带底色与阴影，图标不再写死白色去扛串流画面的对比度。
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: FushiToolbar(
                      floating: true,
                      groups: <List<Widget>>[
                        <Widget>[
                          FushiIconButtonControl(
                            tooltip: t.game_stream_settings_title,
                            icon: const FushiIcon(FushiIcons.settingsGear),
                            onPressed: _openSettings,
                          ),
                          FushiOverflowMenu<_StreamMenuAction>(
                            tooltip: t.game_stream_more,
                            iconWidget: const FushiIcon(FushiIcons.more),
                            onSelected: _onOverflowAction,
                            items: <PopupMenuEntry<_StreamMenuAction>>[
                              FushiPopupMenuItem<_StreamMenuAction>(
                                value: _StreamMenuAction.touchMode,
                                icon: _touchMode == GameStreamTouchMode.direct
                                    ? FushiIcons.mouse
                                    : FushiIcons.touch,
                                label: _touchMode == GameStreamTouchMode.direct
                                    ? t.game_stream_touch_trackpad
                                    : t.game_stream_touch_direct,
                              ),
                              FushiPopupMenuItem<_StreamMenuAction>(
                                value: _StreamMenuAction.keyboard,
                                icon: FushiIcons.keyboard,
                                label: t.game_stream_keyboard,
                              ),
                              FushiPopupMenuItem<_StreamMenuAction>(
                                value: _StreamMenuAction.stats,
                                icon: FushiIcons.speed,
                                label: _statsVisible
                                    ? t.game_stream_stats_hide
                                    : t.game_stream_stats_show,
                              ),
                              FushiPopupMenuItem<_StreamMenuAction>(
                                value: _StreamMenuAction.audio,
                                icon: _settings.audio
                                    ? FushiIcons.volumeOff
                                    : FushiIcons.volumeUp,
                                label: _settings.audio
                                    ? t.game_stream_audio_mute
                                    : t.game_stream_audio_unmute,
                              ),
                            ],
                          ),
                        ],
                        <Widget>[
                          FushiIconButtonControl(
                            tooltip: t.game_stream_keys,
                            icon: const FushiIcon(FushiIcons.settings),
                            onPressed: _configureKeys,
                          ),
                          if (!_companionActive)
                            FushiIconButtonControl(
                              tooltip: t.game_stream_lookup_toggle,
                              icon: FushiIcon(
                                FushiIcons.resolve(
                                  FushiIcons.dictionary,
                                  filled: _lookupVisible,
                                ),
                              ),
                              onPressed: () =>
                                  _setLookupVisible(!_lookupVisible),
                            ),
                          FushiIconButtonControl(
                            tooltip: t.game_stream_controls_toggle,
                            icon: FushiIcon(
                              FushiIcons.resolve(
                                FushiIcons.games,
                                filled: _controlsVisible,
                              ),
                            ),
                            onPressed: () => setState(
                              () => _controlsVisible = !_controlsVisible,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
          if (_companionActive) {
            // The lookup panel is on the second display: all video here.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[video],
            );
          }
          if (compact) {
            // Video and panel share what the boundary strip leaves.
            _bodyHeight = constraints.maxHeight - _railEdgeWidth;
            final double panelHeight = _lookupLayout.effectiveCompactRailHeight(
              _bodyHeight,
            );
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    video,
                    if (_lookupShown) ...<Widget>[
                      // Full-width edge: grab the boundary anywhere with a
                      // mouse.
                      SizedBox(
                        height: _railEdgeWidth,
                        child: _ResizeHandle(
                          axis: Axis.vertical,
                          semanticLabel: t.game_stream_panel_resize,
                          showGrip: false,
                          focusable: false,
                          onDelta: (double delta) => _resizeCompactRail(-delta),
                          onEnd: _commitLookupLayout,
                        ),
                      ),
                      SizedBox(
                        height: panelHeight,
                        child: _buildLookupRail(theme),
                      ),
                    ],
                  ],
                ),
                // Visible grip with a 48dp touch target straddling the edge,
                // as a centred band so the video's bottom strip still reaches
                // the game beside it.
                if (_lookupShown)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom:
                        panelHeight + _railEdgeWidth / 2 - _resizeHitExtent / 2,
                    height: _resizeHitExtent,
                    child: Center(
                      child: SizedBox(
                        width: _railGripBand,
                        child: _ResizeHandle(
                          key: GameStreamPage.compactRailResizeHandleKey,
                          axis: Axis.vertical,
                          semanticLabel: t.game_stream_panel_resize,
                          onDelta: (double delta) => _resizeCompactRail(-delta),
                          onEnd: _commitLookupLayout,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          }
          // Video and rail share what the boundary strip leaves.
          _bodyWidth = constraints.maxWidth - _railEdgeWidth;
          final double railWidth = _lookupLayout.effectiveRailWidth(_bodyWidth);
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  video,
                  if (_lookupShown) ...<Widget>[
                    // Full-height edge: grab the boundary anywhere with a mouse.
                    SizedBox(
                      width: _railEdgeWidth,
                      child: _ResizeHandle(
                        axis: Axis.horizontal,
                        semanticLabel: t.game_stream_rail_resize,
                        showGrip: false,
                        focusable: false,
                        onDelta: (double delta) => _resizeRail(-delta),
                        onEnd: _commitLookupLayout,
                      ),
                    ),
                    SizedBox(width: railWidth, child: _buildLookupRail(theme)),
                  ],
                ],
              ),
              // Visible grip with a 48dp touch target straddling the edge.
              // Only a band, not the full height: the strip it overlaps on
              // the video side would otherwise stop reaching the game.
              if (_lookupShown)
                Positioned(
                  right: railWidth + _railEdgeWidth / 2 - _resizeHitExtent / 2,
                  width: _resizeHitExtent,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: SizedBox(
                      height: _railGripBand,
                      child: _ResizeHandle(
                        key: GameStreamPage.railResizeHandleKey,
                        axis: Axis.horizontal,
                        semanticLabel: t.game_stream_rail_resize,
                        onDelta: (double delta) => _resizeRail(-delta),
                        onEnd: _commitLookupLayout,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatsOverlay(ThemeData theme) {
    final GameStreamStatsSample? stats = _stats;
    final GameStreamVideoSettings? effective = widget.session?.settings;
    final List<String> lines = <String>[
      if (stats?.width != null && stats?.height != null)
        '${stats!.width}×${stats.height}'
            '${stats.framesPerSecond == null ? '' : ' @ ${stats.framesPerSecond!.toStringAsFixed(0)} fps'}',
      if (stats?.bitrateKbps != null)
        '${(stats!.bitrateKbps! / 1000).toStringAsFixed(1)} Mbps',
      if (stats?.codec != null)
        '${stats!.codec}${stats.decoder == null ? '' : ' · ${stats.decoder}'}',
      if (stats?.roundTripMs != null) 'RTT ${stats!.roundTripMs} ms',
      if (stats?.jitterMs != null) 'Jitter ${stats!.jitterMs} ms',
      if (stats?.lossPercent != null)
        '${t.game_stream_stats_loss} ${stats!.lossPercent!.toStringAsFixed(1)}%',
      if (stats?.framesDropped != null)
        '${t.game_stream_stats_dropped} ${stats!.framesDropped}',
      if (effective != null)
        '${t.game_stream_stats_target} ${effective.maxHeight}p'
            '${effective.maxFps} · '
            '${(effective.bitrateKbps / 1000).toStringAsFixed(1)} Mbps',
      if (widget.receiver?.codecNote != null)
        t.game_stream_stats_codec_fallback,
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: IgnorePointer(
        child: DecoratedBox(
          key: GameStreamPage.statsKey,
          // 画面上的 HUD 保持深色半透明（任何画面亮度下白字都可读），
          // 圆角与浮层统一，不再是直角黑块。
          decoration: const BoxDecoration(
            color: Color(0xAA000000),
            borderRadius: FushiM3eShape.smallRadius,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              lines.isEmpty ? t.game_stream_video_waiting : lines.join('\n'),
              style: context.fushiType.labelMedium.tabular.copyWith(
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoSurface(ThemeData theme) {
    return Focus(focusNode: _videoFocus, child: _buildVideoListener(theme));
  }

  Widget _buildVideoListener(ThemeData theme) {
    return Listener(
      key: _videoKey,
      onPointerDown: (PointerDownEvent event) {
        // Hardware keyboard keys go to the game while the video is focused.
        if (!_keyboardFocus.hasFocus) _videoFocus.requestFocus();
        unawaited(
          _isMouse(event)
              ? _sendMouse(event)
              : _sendPointer(event, GameStreamInputAction.down),
        );
      },
      onPointerMove: (PointerMoveEvent event) => unawaited(
        _isMouse(event)
            ? _sendMouse(event)
            : _sendPointer(event, GameStreamInputAction.move),
      ),
      onPointerUp: (PointerUpEvent event) => unawaited(
        _isMouse(event)
            ? _sendMouse(event)
            : _sendPointer(event, GameStreamInputAction.up),
      ),
      onPointerHover: (PointerHoverEvent event) {
        if (_isMouse(event) && _canHover) unawaited(_sendMouse(event));
      },
      onPointerSignal: (PointerSignalEvent event) {
        if (event is! PointerScrollEvent) return;
        GestureBinding.instance.pointerSignalResolver.register(
          event,
          (PointerSignalEvent event) => unawaited(
            _scrollMouse(
              event,
              (event as PointerScrollEvent).scrollDelta,
              step: _wheelDetentPixels(),
            ),
          ),
        );
      },
      // Trackpad two-finger pan: content follows the fingers (natural
      // scrolling), the opposite sign of a wheel delta.
      onPointerPanZoomUpdate: (PointerPanZoomUpdateEvent event) =>
          unawaited(_scrollMouse(event, -event.panDelta)),
      onPointerCancel: (PointerCancelEvent event) =>
          unawaited(_releasePointer()),
      child: Container(
        key: GameStreamPage.videoKey,
        color: Colors.black,
        alignment: Alignment.center,
        child: widget.receiver == null
            ? (widget.videoPlaceholder ?? const _VideoWaiting())
            : Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  RTCVideoView(
                    widget.receiver!.renderer,
                    objectFit:
                        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                  ),
                  if (_touchMode == GameStreamTouchMode.trackpad)
                    IgnorePointer(
                      child: CustomPaint(
                        key: GameStreamPage.cursorKey,
                        painter: _TrackpadCursorPainter(
                          cursor: _trackpadCursor,
                          contentSize: _videoContentSize,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  if (!widget.receiver!.ready)
                    const Center(child: _VideoWaiting()),
                ],
              ),
      ),
    );
  }

  Widget _buildGamepadOverlay(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              _PadButton(
                label: 'L',
                button: GameStreamVirtualButton.shoulderLeft,
                onButton: _sendButton,
              ),
              _PadButton(
                label: 'R',
                button: GameStreamVirtualButton.shoulderRight,
                onButton: _sendButton,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              _DPad(onButton: _sendButton),
              Row(
                children: <Widget>[
                  _PadButton(
                    label: 'B',
                    button: GameStreamVirtualButton.cancel,
                    onButton: _sendButton,
                  ),
                  const SizedBox(width: 14),
                  _PadButton(
                    label: 'A',
                    button: GameStreamVirtualButton.confirm,
                    onButton: _sendButton,
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLookupRail(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surface,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          _railHeight = constraints.maxHeight;
          final double lineHeight = _lookupLayout.effectiveLineHeight(
            constraints.maxHeight,
          );
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              _buildLookupRailContent(theme, lineHeight),
              // 48dp touch target centred on the gap under the line area.
              Positioned(
                left: 0,
                right: 0,
                top: lineHeight + _lineGapHeight / 2 - _resizeHitExtent / 2,
                height: _resizeHitExtent,
                child: _ResizeHandle(
                  key: GameStreamPage.lineResizeHandleKey,
                  axis: Axis.vertical,
                  semanticLabel: t.game_stream_line_resize,
                  onDelta: _resizeLine,
                  onEnd: _commitLookupLayout,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// The current line's font size in a line area [area] big: the largest size
  /// at which the whole line fits under the area's title (feedback
  /// eXmW0_Kjer), floored at the proportional [GameStreamLookupLayout.fontSizeFor].
  double _fittedLineFontSize(
    BuildContext context,
    ThemeData theme,
    String text,
    Size area,
  ) {
    final double floor = GameStreamLookupLayout.fontSizeFor(area.height);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final TextDirection direction = Directionality.of(context);
    final TextPainter title = TextPainter(
      text: TextSpan(
        text: t.game_stream_line,
        style: context.fushiType.titleSmallEmphasized,
      ),
      textScaler: scaler,
      textDirection: direction,
    )..layout(maxWidth: math.max(0, area.width - 24));
    final double titleHeight = title.height + 24;
    title.dispose();
    return gameStreamFitLineFontSize(
      text: text,
      styleFor: (double size) => subtitleTranscriptTextStyle(
        fontSize: size,
        selected: true,
        fontFamily: theme.textTheme.bodyMedium?.fontFamily,
      ),
      width:
          area.width -
          kSubtitleRowPaddingLeft -
          kSubtitleRowPaddingRight -
          kSubtitleRowScrollbarGutter -
          _lineCopyActionExtent,
      height:
          area.height -
          titleHeight -
          kSubtitleRowPaddingVertical -
          _lineAreaBottomPadding,
      floor: floor,
      textScaler: scaler,
      textDirection: direction,
    );
  }

  /// Which mode the controller buttons are in; tapping it switches modes.
  Widget _buildModeChip(ThemeData theme) {
    final bool lookupMode = _inputMode == GameStreamInputMode.lookup;
    final FushiSpringSpec spring = context.fushiMotion.effectsDefault;
    return AnimatedSwitcher(
      duration: spring.duration,
      switchInCurve: spring.curve,
      switchOutCurve: spring.curve,
      child: FushiPressScale(
        key: ValueKey<GameStreamInputMode>(_inputMode),
        child: FushiFilterChip(
          key: GameStreamPage.modeChipKey,
          tooltip: t.game_stream_action_lookup_mode_toggle,
          showCheckmark: false,
          selected: lookupMode,
          avatar: Icon(
            lookupMode ? FushiIcons.search : FushiIcons.games,
            size: 18,
          ),
          label: Text(
            lookupMode ? t.game_stream_lookup_mode : t.game_stream_game_mode,
          ),
          onSelected: (_) => _setInputMode(
            lookupMode ? GameStreamInputMode.game : GameStreamInputMode.lookup,
          ),
        ),
      ),
    );
  }

  Widget _buildLookupRailContent(ThemeData theme, double lineHeight) {
    final GameStreamLookupController? controller = _lookupController;
    final GameStreamTextEvent? line = controller?.currentLine;
    final DictionarySearchResult? result = controller?.result;
    final bool lookupMode = _inputMode == GameStreamInputMode.lookup;
    final FushiSpringSpec spring = context.fushiMotion.effectsDefault;
    // Lookup mode outlines the panel in the accent color: the buttons are
    // here now, not in the game.
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _buildLookupRailColumn(theme, lineHeight, controller, line, result),
        IgnorePointer(
          child: AnimatedContainer(
            key: GameStreamPage.lookupModeOutlineKey,
            duration: spring.duration,
            curve: spring.curve,
            decoration: BoxDecoration(
              border: Border.all(
                color: lookupMode
                    ? theme.colorScheme.primary
                    : theme.colorScheme.primary.withValues(alpha: 0),
                width: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLookupRailColumn(
    ThemeData theme,
    double lineHeight,
    GameStreamLookupController? controller,
    GameStreamTextEvent? line,
    DictionarySearchResult? result,
  ) {
    final bool lookupMode = _inputMode == GameStreamInputMode.lookup;
    final FushiSpringSpec spring = context.fushiMotion.effectsDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: lineHeight,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final double fontSize = line == null
                  ? GameStreamLookupLayout.fontSizeFor(lineHeight)
                  : _fittedLineFontSize(
                      context,
                      theme,
                      line.text,
                      Size(box.maxWidth, lineHeight),
                    );
              return SingleChildScrollView(
                // The resize handle's touch target reaches this far up into the
                // area; keep the last line of text clear of it.
                padding: const EdgeInsets.only(bottom: _lineAreaBottomPadding),
                child: Column(
                  key: GameStreamPage.transcriptKey,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              t.game_stream_line,
                              style: context.fushiType.titleSmallEmphasized,
                            ),
                          ),
                          if (_controllerUsed) _buildModeChip(theme),
                        ],
                      ),
                    ),
                    // Grows / shrinks with the mode instead of jumping the
                    // line below it.
                    FushiAnimatedSize(
                      duration: spring.duration,
                      curve: spring.curve,
                      alignment: AlignmentDirectional.topStart,
                      child: AnimatedSwitcher(
                        duration: spring.duration,
                        switchInCurve: spring.curve,
                        switchOutCurve: spring.curve,
                        child: lookupMode
                            ? Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  4,
                                ),
                                child: Text(
                                  t.game_stream_lookup_mode_hint,
                                  key: GameStreamPage.lookupModeHintKey,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: fushiNeutralSecondaryForeground(
                                      context,
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ),
                    if (line == null)
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(t.game_stream_line_empty),
                      )
                    else
                      SubtitleTranscriptRow(
                        colorScheme: theme.colorScheme,
                        selected: true,
                        text: SubtitleTranscriptText(
                          key: ValueKey<String>(
                            'game-stream-line-${line.lineId}',
                          ),
                          textKey: GameStreamPage.transcriptTextKey,
                          text: line.text,
                          style: subtitleTranscriptTextStyle(
                            fontSize: fontSize,
                            selected: true,
                            fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                            color: SubtitleTranscriptRow.textColorOf(
                              context,
                              theme.colorScheme,
                              selected: true,
                            ),
                          ),
                          keyboardLookup: true,
                          caret: lookupMode ? _lookupCaret : null,
                          lookupHighlight: lookupMode && _matchedLength > 0
                              ? (start: _lookupStart!, count: _matchedLength)
                              : null,
                          onLookup: (int index, Rect anchor) {
                            _lookupAt(line, index);
                            // Toggle + touch: with a controller in hand, a
                            // tapped word hands the buttons to the lookup.
                            if (_controllerUsed) {
                              _setInputMode(GameStreamInputMode.lookup);
                            }
                          },
                        ),
                        trailing: SubtitleTranscriptAction(
                          icon: FushiIcons.copy,
                          tooltip: t.copy,
                          color: SubtitleTranscriptRow.secondaryColorOf(
                            context,
                            theme.colorScheme,
                            selected: true,
                          ),
                          size: _lineCopyIconSize,
                          onPressed: () => unawaited(
                            Clipboard.setData(ClipboardData(text: line.text)),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(
          height: _lineGapHeight,
          child: Center(child: FushiDividerControl(height: 1)),
        ),
        Expanded(
          key: GameStreamPage.dictionaryKey,
          child: controller == null || result == null
              ? Center(
                  child: controller?.searching == true
                      ? const FushiCircularProgressIndicator()
                      : Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            controller?.error ?? t.game_stream_lookup_hint,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: fushiNeutralSecondaryForeground(context),
                            ),
                          ),
                        ),
                )
              : DictionaryPopupLayer(
                  result: result,
                  webViewKey: _dictionaryKey,
                  // BUG-3425：结果来自 host，样式 / 媒体 / 发音也取自 host。
                  resourceSource: controller.popupResources,
                  isSearching: controller.searching,
                  isDark: theme.brightness == Brightness.dark,
                  showBorder: false,
                  swipeDismissible: false,
                  enableSwipeToClose: false,
                  onDismiss: () => _setLookupVisible(false),
                  onTextSelected:
                      (
                        String text,
                        Rect rect,
                        List<FushiRubySpan> rubySpans,
                        String _,
                      ) => unawaited(controller.lookup(text)),
                  onLinkClick: (String text, Rect rect) =>
                      unawaited(controller.lookup(text)),
                  onMineEntry: _mine,
                  onDuplicateCheck: controller.isDuplicate,
                ),
        ),
        if (_mineMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _mineMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _mineFailed
                    ? fushiStatusColor(context, FushiStatusTone.error)
                    : fushiAccentForeground(context),
              ),
            ),
          ),
      ],
    );
  }
}

/// One thing a local input holds down on the host: a gamepad button, a
/// keyboard key or a pointer button. Exactly one field is set.
@immutable
class _HostOutput {
  const _HostOutput.pad(GameStreamVirtualButton this.pad)
    : key = null,
      pointer = null;
  const _HostOutput.key(String this.key) : pad = null, pointer = null;
  const _HostOutput.pointer(String this.pointer) : pad = null, key = null;

  final GameStreamVirtualButton? pad;
  final String? key;
  final String? pointer;

  @override
  bool operator ==(Object other) =>
      other is _HostOutput &&
      other.pad == pad &&
      other.key == key &&
      other.pointer == pointer;

  @override
  int get hashCode => Object.hash(pad, key, pointer);
}

/// Width of the always-visible boundary strip between video and rail.
const double _railEdgeWidth = 8;

/// Widest a controller button's action dropdown gets in the controls sheet.
const double _controllerActionMaxWidth = 220;

/// Height of the gap under the line area that carries its resize grip.
const double _lineGapHeight = 16;

/// Touch target across a resize handle's drag axis (Material minimum).
const double _resizeHitExtent = 48;

/// The resize handle's touch target reaches this far up into the line area;
/// the line text keeps clear of it.
const double _lineAreaBottomPadding = _resizeHitExtent / 2 - _lineGapHeight / 2;

/// The line row's copy action: icon plus its 2px padding on both sides.
const double _lineCopyIconSize = 16;
const double _lineCopyActionExtent = _lineCopyIconSize + 4;

/// Length of the rail grip's 48dp-wide touch band along the edge.
const double _railGripBand = 160;

/// A drag handle that resizes a pane along [axis]: a pill grip, the matching
/// resize cursor under a mouse, and arrow keys while focused (Up/Left shrink
/// the measured coordinate, Down/Right grow it — same sign as a drag).
///
/// Reports raw deltas along [axis]; the caller decides which way is "bigger".
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    required this.axis,
    required this.semanticLabel,
    required this.onDelta,
    required this.onEnd,
    this.showGrip = true,
    this.focusable = true,
    super.key,
  });

  final Axis axis;
  final String semanticLabel;
  final ValueChanged<double> onDelta;
  final VoidCallback onEnd;
  final bool showGrip;
  final bool focusable;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;
  bool _dragging = false;
  bool _focused = false;

  bool get _vertical => widget.axis == Axis.vertical;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    const double step = GameStreamLookupLayout.keyboardStep;
    final double? delta = _vertical
        ? (key == LogicalKeyboardKey.arrowUp
              ? -step
              : key == LogicalKeyboardKey.arrowDown
              ? step
              : null)
        : (key == LogicalKeyboardKey.arrowLeft
              ? -step
              : key == LogicalKeyboardKey.arrowRight
              ? step
              : null);
    if (delta == null) return KeyEventResult.ignored;
    widget.onDelta(delta);
    widget.onEnd();
    return KeyEventResult.handled;
  }

  void _start() => setState(() => _dragging = true);

  void _end() {
    setState(() => _dragging = false);
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool active = _hovered || _dragging || _focused;
    final double length = active ? 64 : 48;
    final double thickness = active ? 6 : 5;
    Widget child = widget.showGrip
        ? Center(
            child: AnimatedContainer(
              duration: fushiMotionDuration(context, FushiMotion.short),
              curve: FushiMotion.standard,
              width: _vertical ? length : thickness,
              height: _vertical ? thickness : length,
              decoration: BoxDecoration(
                color: active ? scheme.primary : scheme.onSurfaceVariant,
                borderRadius: BorderRadius.circular(thickness),
              ),
            ),
          )
        : ColoredBox(
            color: active
                ? scheme.primary.withValues(alpha: 0.5)
                : scheme.outlineVariant,
          );
    child = GestureDetector(
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onVerticalDragStart: _vertical ? (_) => _start() : null,
      onVerticalDragUpdate: _vertical
          ? (DragUpdateDetails details) => widget.onDelta(details.delta.dy)
          : null,
      onVerticalDragEnd: _vertical ? (_) => _end() : null,
      onVerticalDragCancel: _vertical ? _end : null,
      onHorizontalDragStart: _vertical ? null : (_) => _start(),
      onHorizontalDragUpdate: _vertical
          ? null
          : (DragUpdateDetails details) => widget.onDelta(details.delta.dx),
      onHorizontalDragEnd: _vertical ? null : (_) => _end(),
      onHorizontalDragCancel: _vertical ? null : _end,
      child: child,
    );
    child = MouseRegion(
      cursor: _vertical
          ? SystemMouseCursors.resizeUpDown
          : SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: child,
    );
    if (!widget.focusable) return ExcludeSemantics(child: child);
    return Semantics(
      label: widget.semanticLabel,
      child: Focus(
        onFocusChange: (bool focused) => setState(() => _focused = focused),
        onKeyEvent: _onKey,
        child: child,
      ),
    );
  }
}

class _DPad extends StatelessWidget {
  const _DPad({required this.onButton});

  final Future<void> Function(
    GameStreamVirtualButton button,
    GameStreamInputAction action,
  )
  onButton;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 148,
      height: 148,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Align(
            alignment: Alignment.topCenter,
            child: _IconPadButton(
              icon: Icons.keyboard_arrow_up,
              button: GameStreamVirtualButton.up,
              onButton: onButton,
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _IconPadButton(
              icon: Icons.keyboard_arrow_down,
              button: GameStreamVirtualButton.down,
              onButton: onButton,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _IconPadButton(
              icon: Icons.keyboard_arrow_left,
              button: GameStreamVirtualButton.left,
              onButton: onButton,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _IconPadButton(
              icon: Icons.keyboard_arrow_right,
              button: GameStreamVirtualButton.right,
              onButton: onButton,
            ),
          ),
        ],
      ),
    );
  }
}

class _IconPadButton extends StatelessWidget {
  const _IconPadButton({
    required this.icon,
    required this.button,
    required this.onButton,
  });

  final IconData icon;
  final GameStreamVirtualButton button;
  final Future<void> Function(
    GameStreamVirtualButton button,
    GameStreamInputAction action,
  )
  onButton;

  @override
  Widget build(BuildContext context) {
    return _PadShell(
      onDown: () => onButton(button, GameStreamInputAction.down),
      onUp: () => onButton(button, GameStreamInputAction.up),
      child: FushiIcon(icon, color: Colors.white),
    );
  }
}

class _PadButton extends StatelessWidget {
  const _PadButton({
    required this.label,
    required this.button,
    required this.onButton,
  });

  final String label;
  final GameStreamVirtualButton button;
  final Future<void> Function(
    GameStreamVirtualButton button,
    GameStreamInputAction action,
  )
  onButton;

  @override
  Widget build(BuildContext context) {
    return _PadShell(
      onDown: () => onButton(button, GameStreamInputAction.down),
      onUp: () => onButton(button, GameStreamInputAction.up),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _PadShell extends StatefulWidget {
  const _PadShell({
    required this.child,
    required this.onDown,
    required this.onUp,
  });

  final Widget child;
  final Future<void> Function() onDown;
  final Future<void> Function() onUp;

  @override
  State<_PadShell> createState() => _PadShellState();
}

class _PadShellState extends State<_PadShell> {
  final Set<int> _pointers = <int>{};
  final Set<LogicalKeyboardKey> _keys = <LogicalKeyboardKey>{};
  bool _pressed = false;
  bool _focused = false;
  bool _disposing = false;

  void _syncPressed() {
    final bool pressed = _pointers.isNotEmpty || _keys.isNotEmpty;
    if (pressed == _pressed) return;
    _pressed = pressed;
    unawaited(pressed ? widget.onDown() : widget.onUp());
    // 视觉反馈（按下收缩 + 形变）只在活着的时候重建；dispose 里的释放只发 up。
    if (!_disposing && mounted) setState(() {});
  }

  void _release() {
    _keys.clear();
    _pointers.clear();
    _syncPressed();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _keys.add(event.logicalKey);
    if (event is KeyUpEvent) _keys.remove(event.logicalKey);
    _syncPressed();
    return KeyEventResult.handled;
  }

  Future<void> _activate() async {
    if (_pressed) return;
    await widget.onDown();
    await widget.onUp();
  }

  @override
  void dispose() {
    _disposing = true;
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    return Focus(
      onKeyEvent: _onKey,
      onFocusChange: (bool focused) {
        if (!focused) _release();
        setState(() => _focused = focused);
      },
      child: Semantics(
        button: true,
        onTap: () => unawaited(_activate()),
        child: Listener(
          onPointerDown: (PointerDownEvent event) {
            _pointers.add(event.pointer);
            _syncPressed();
          },
          onPointerUp: (PointerUpEvent event) {
            _pointers.remove(event.pointer);
            _syncPressed();
          },
          onPointerCancel: (PointerCancelEvent event) {
            _pointers.remove(event.pointer);
            _syncPressed();
          },
          // M3E 按压：spring 收缩 + 圆 → 方圆角形变，底色提亮；画面上的
          // 按钮保持深色半透明底（任何画面亮度下都看得清）。
          child: AnimatedScale(
            scale: _pressed ? 0.9 : 1,
            duration: motion.spatialFast.duration,
            curve: motion.spatialFast.curve,
            child: AnimatedContainer(
              width: 58,
              height: 58,
              duration: motion.effectsFast.duration,
              curve: motion.effectsFast.curve,
              decoration: BoxDecoration(
                color: _pressed
                    ? Colors.white.withValues(alpha: 0.32)
                    : Colors.black.withValues(alpha: 0.45),
                borderRadius: _pressed
                    ? FushiM3eShape.cardRadius
                    : const BorderRadius.all(Radius.circular(29)),
                border: Border.all(
                  color: _focused ? Colors.white : Colors.white54,
                  width: _focused ? 2 : 1,
                ),
              ),
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

enum _StreamMenuAction { touchMode, keyboard, stats, audio }

/// 等待首帧：状态文案 + 一条波浪进度（M3E 不定进度），压在黑底画面中央。
class _VideoWaiting extends StatelessWidget {
  const _VideoWaiting();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t.game_stream_video_waiting,
          textAlign: TextAlign.center,
          style: context.fushiType.titleMediumEmphasized.copyWith(
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 16),
        const SizedBox(width: 180, child: FushiLinearProgressIndicator()),
      ],
    );
  }
}

/// Trackpad-mode cursor drawn over the contained video picture.
class _TrackpadCursorPainter extends CustomPainter {
  _TrackpadCursorPainter({
    required this.cursor,
    required this.contentSize,
    required this.color,
  });

  final Offset cursor;
  final Size Function(Size boxSize) contentSize;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Size content = contentSize(size);
    final Offset origin = Offset(
      (size.width - content.width) / 2,
      (size.height - content.height) / 2,
    );
    final Offset point =
        origin + Offset(cursor.dx * content.width, cursor.dy * content.height);
    canvas
      ..drawCircle(point, 9, Paint()..color = const Color(0xCC000000))
      ..drawCircle(point, 6, Paint()..color = color)
      ..drawCircle(
        point,
        9,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
  }

  @override
  bool shouldRepaint(_TrackpadCursorPainter oldDelegate) =>
      oldDelegate.cursor != cursor || oldDelegate.color != color;
}
