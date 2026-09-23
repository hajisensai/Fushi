import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/pages/implementations/game_stream_settings_sheet.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi/src/sync/game_stream_touch.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

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

/// Physical controller button → on-screen pad button, so a paired gamepad
/// drives the same mapping (and key rebinding) as the touch pad.
GameStreamVirtualButton? gameStreamPadButtonFor(
  LogicalKeyboardKey key,
) => switch (key) {
  LogicalKeyboardKey.gameButtonA => GameStreamVirtualButton.confirm,
  LogicalKeyboardKey.gameButtonB => GameStreamVirtualButton.cancel,
  LogicalKeyboardKey.gameButtonLeft1 => GameStreamVirtualButton.shoulderLeft,
  LogicalKeyboardKey.gameButtonRight1 => GameStreamVirtualButton.shoulderRight,
  LogicalKeyboardKey.gameButtonStart ||
  LogicalKeyboardKey.gameButtonSelect => GameStreamVirtualButton.menu,
  _ => null,
};

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

  static const Key videoKey = ValueKey<String>('game-stream-video');
  static const Key transcriptKey = ValueKey<String>('game-stream-transcript');
  static const Key transcriptTextKey = ValueKey<String>(
    'game-stream-transcript-text',
  );
  static const Key dictionaryKey = ValueKey<String>('game-stream-dictionary');
  static const Key statsKey = ValueKey<String>('game-stream-stats');
  static const Key cursorKey = ValueKey<String>('game-stream-cursor');
  static const Key keyboardKey = ValueKey<String>('game-stream-keyboard');

  @override
  State<GameStreamPage> createState() => _GameStreamPageState();
}

class _GameStreamPageState extends State<GameStreamPage>
    with WidgetsBindingObserver {
  final GlobalKey _videoKey = GlobalKey();
  GameStreamLookupController? _lookupController;
  bool _controlsVisible = true;
  bool _lookupVisible = true;
  bool _mineFailed = false;
  final GlobalKey<DictionaryPopupWebViewState> _dictionaryKey =
      GlobalKey<DictionaryPopupWebViewState>();
  String? _mineMessage;
  final Map<GameStreamVirtualButton, String> _keyBindings =
      <GameStreamVirtualButton, String>{};
  final Set<GameStreamVirtualButton> _heldButtons = <GameStreamVirtualButton>{};
  GameStreamTouchInterpreter? _touch;
  ({Rect bounds, Rect content})? _pointerGeometry;
  GameStreamInputComposer? _pointerComposer;
  GameStreamTouchMode _touchMode = GameStreamTouchMode.direct;
  Offset _trackpadCursor = const Offset(.5, .5);
  late GameStreamVideoSettings _settings = widget.settings;
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

  static final List<String> _allowedKeys = <String>[
    'Enter',
    'Escape',
    'Space',
    'Up',
    'Down',
    'Left',
    'Right',
    for (int code = 65; code <= 90; code++) String.fromCharCode(code),
    for (int number = 1; number <= 12; number++) 'F$number',
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lookupController = widget.lookupController;
    _lookupController?.addListener(_onLookupChanged);
    widget.receiver?.addListener(_onReceiverChanged);
    widget.receiver?.renderer.addListener(_schedulePointerGeometryCheck);
    widget.inputComposer.addListener(_onReceiverChanged);
  }

  @override
  void didUpdateWidget(GameStreamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputComposer != widget.inputComposer) {
      unawaited(_releasePointer());
      oldWidget.inputComposer.removeListener(_onReceiverChanged);
      widget.inputComposer.addListener(_onReceiverChanged);
    }
    if (oldWidget.lookupController != widget.lookupController) {
      oldWidget.lookupController?.removeListener(_onLookupChanged);
      _lookupController = widget.lookupController;
      _lookupController?.addListener(_onLookupChanged);
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
    _lookupController?.removeListener(_onLookupChanged);
    widget.receiver?.removeListener(_onReceiverChanged);
    widget.receiver?.renderer.removeListener(_schedulePointerGeometryCheck);
    widget.inputComposer.removeListener(_onReceiverChanged);
    _statsTimer?.cancel();
    _videoFocus.dispose();
    _keyboardFocus.dispose();
    _keyboardText.dispose();
    super.dispose();
  }

  void _onLookupChanged() {
    if (mounted) setState(() {});
  }

  void _onReceiverChanged() {
    final FushiGameStreamReceiver? receiver = widget.receiver;
    if (receiver != null &&
        (receiver.backgrounded ||
            receiver.state != GameStreamReceiverState.connected)) {
      unawaited(_releasePointer());
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
    if (!mounted || _touch == null) return;
    if (_pointerGeometry != _currentPointerGeometry()) {
      unawaited(_releasePointer());
    }
  }

  void _schedulePointerGeometryCheck() {
    if (_touch != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        _releasePointerIfLayoutChanged,
      );
    }
  }

  Future<void> _releasePointer() async {
    final GameStreamTouchInterpreter? touch = _touch;
    final GameStreamInputComposer? composer = _pointerComposer;
    if (touch == null || composer == null) return;
    // Clear synchronously: cancellation, metrics and disposal can arrive in the
    // same frame and must emit exactly one release to the original session.
    _touch = null;
    _pointerComposer = null;
    _pointerGeometry = null;
    await _dispatchPointer(touch.cancel(), composer);
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

  Future<void> _sendButton(
    GameStreamVirtualButton button,
    GameStreamInputAction action,
  ) {
    if (action == GameStreamInputAction.down) _heldButtons.add(button);
    if (action == GameStreamInputAction.up) _heldButtons.remove(button);
    final String? key = _keyBindings[button];
    if (key != null) return widget.inputComposer.key(key: key, action: action);
    return widget.inputComposer.gamepad(button: button, action: action);
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

  Future<void> _configureKeys() async {
    // A held control must retain its down/up mapping until it is released.
    if (_heldButtons.isNotEmpty) return;
    final bool restoreLookup = _lookupVisible;
    setState(() => _lookupVisible = false);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (BuildContext context) => StatefulBuilder(
          builder: (BuildContext context, StateSetter updateSheet) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.7,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  Text(
                    t.game_stream_keys,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(t.game_stream_keys_hint),
                  for (final GameStreamVirtualButton button
                      in GameStreamVirtualButton.values)
                    if (button != GameStreamVirtualButton.menu)
                      FushiListItem(
                        title: Text(_buttonLabel(button)),
                        trailing: DropdownButton<String>(
                          key: ValueKey<String>(
                            'game-stream-binding-${button.name}',
                          ),
                          value: _keyBindings[button] ?? '',
                          items: <DropdownMenuItem<String>>[
                            DropdownMenuItem<String>(
                              value: '',
                              child: Text(t.game_stream_key_default),
                            ),
                            for (final String key in _allowedKeys)
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
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _lookupVisible = restoreLookup);
    }
  }

  /// Physical controller buttons always drive the pad; keyboard keys are sent
  /// to the host only while the video itself holds focus, so typing into the
  /// transcript or popup never leaks into the game.
  KeyEventResult _onHardwareKey(FocusNode node, KeyEvent event) {
    final bool down = event is KeyDownEvent;
    final bool up = event is KeyUpEvent;
    final GameStreamVirtualButton? button = gameStreamPadButtonFor(
      event.logicalKey,
    );
    if (button != null) {
      if (down) unawaited(_sendButton(button, GameStreamInputAction.down));
      if (up) unawaited(_sendButton(button, GameStreamInputAction.up));
      return KeyEventResult.handled;
    }
    if (FocusManager.instance.primaryFocus != _videoFocus) {
      return KeyEventResult.ignored;
    }
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
    final bool restoreLookup = _lookupVisible;
    setState(() => _lookupVisible = false);
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
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(t.game_stream_settings_capped)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text('${t.game_stream_settings_apply_failed}: $error'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _lookupVisible = restoreLookup);
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
    'window_minimized' || 'window_hidden' => t.game_stream_input_window_hidden,
    _ => '${t.game_stream_input_failed} ($reason)',
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(onKeyEvent: _onHardwareKey, child: _buildBody(theme)),
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
                      child: Material(
                        color: theme.colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            widget.receiver?.error != null
                                ? '${t.game_stream_disconnected}: ${widget.receiver!.error}'
                                : _rejectionMessage(
                                    widget.inputComposer.lastRejectionReason,
                                  ),
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (_controlsVisible) _buildGamepadOverlay(theme),
                Align(
                  alignment: Alignment.topLeft,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      BackButton(
                        color: Colors.white,
                        onPressed: () => Navigator.of(context).maybePop(),
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
                    child: TextField(
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        tooltip: t.game_stream_settings_title,
                        color: Colors.white,
                        icon: const Icon(Icons.settings_outlined),
                        onPressed: _openSettings,
                      ),
                      FushiOverflowMenu<_StreamMenuAction>(
                        tooltip: t.game_stream_more,
                        iconWidget: const Icon(
                          Icons.more_vert,
                          color: Colors.white,
                        ),
                        onSelected: _onOverflowAction,
                        items: <PopupMenuEntry<_StreamMenuAction>>[
                          FushiPopupMenuItem<_StreamMenuAction>(
                            value: _StreamMenuAction.touchMode,
                            icon: _touchMode == GameStreamTouchMode.direct
                                ? Icons.mouse_outlined
                                : Icons.touch_app_outlined,
                            label: _touchMode == GameStreamTouchMode.direct
                                ? t.game_stream_touch_trackpad
                                : t.game_stream_touch_direct,
                          ),
                          FushiPopupMenuItem<_StreamMenuAction>(
                            value: _StreamMenuAction.keyboard,
                            icon: Icons.keyboard_outlined,
                            label: t.game_stream_keyboard,
                          ),
                          FushiPopupMenuItem<_StreamMenuAction>(
                            value: _StreamMenuAction.stats,
                            icon: Icons.speed_outlined,
                            label: _statsVisible
                                ? t.game_stream_stats_hide
                                : t.game_stream_stats_show,
                          ),
                          FushiPopupMenuItem<_StreamMenuAction>(
                            value: _StreamMenuAction.audio,
                            icon: _settings.audio
                                ? Icons.volume_off_outlined
                                : Icons.volume_up_outlined,
                            label: _settings.audio
                                ? t.game_stream_audio_mute
                                : t.game_stream_audio_unmute,
                          ),
                        ],
                      ),
                      IconButton(
                        tooltip: t.game_stream_keys,
                        color: Colors.white,
                        icon: const Icon(Icons.tune),
                        onPressed: _configureKeys,
                      ),
                      IconButton(
                        tooltip: t.game_stream_lookup_toggle,
                        color: Colors.white,
                        icon: Icon(
                          _lookupVisible
                              ? Icons.menu_book
                              : Icons.menu_book_outlined,
                        ),
                        onPressed: () =>
                            setState(() => _lookupVisible = !_lookupVisible),
                      ),
                      IconButton(
                        tooltip: t.game_stream_controls_toggle,
                        color: Colors.white,
                        icon: Icon(
                          _controlsVisible
                              ? Icons.gamepad
                              : Icons.gamepad_outlined,
                        ),
                        onPressed: () => setState(
                          () => _controlsVisible = !_controlsVisible,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
          final Widget lookup = compact
              ? SizedBox(
                  height: math.min(360, constraints.maxHeight * 0.5),
                  child: _buildLookupRail(theme, compact: true),
                )
              : _buildLookupRail(theme);
          return compact
              ? Column(children: <Widget>[video, if (_lookupVisible) lookup])
              : Row(children: <Widget>[video, if (_lookupVisible) lookup]);
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
          decoration: const BoxDecoration(color: Color(0xAA000000)),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Text(
              lines.isEmpty ? t.game_stream_video_waiting : lines.join('\n'),
              style: theme.textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
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
        unawaited(_sendPointer(event, GameStreamInputAction.down));
      },
      onPointerMove: (PointerMoveEvent event) =>
          unawaited(_sendPointer(event, GameStreamInputAction.move)),
      onPointerUp: (PointerUpEvent event) =>
          unawaited(_sendPointer(event, GameStreamInputAction.up)),
      onPointerCancel: (PointerCancelEvent event) =>
          unawaited(_releasePointer()),
      child: Container(
        key: GameStreamPage.videoKey,
        color: Colors.black,
        alignment: Alignment.center,
        child: widget.receiver == null
            ? (widget.videoPlaceholder ??
                  Text(
                    t.game_stream_video_waiting,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ))
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
                    Center(
                      child: Text(
                        t.game_stream_video_waiting,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white70,
                        ),
                      ),
                    ),
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

  Widget _buildLookupRail(ThemeData theme, {bool compact = false}) {
    final GameStreamLookupController? controller = _lookupController;
    final GameStreamTextEvent? line = controller?.currentLine;
    final DictionarySearchResult? result = controller?.result;
    return Material(
      color: theme.colorScheme.surface,
      child: SizedBox(
        width: compact ? double.infinity : 360,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: compact ? 150 : 240),
              child: SingleChildScrollView(
                child: Column(
                  key: GameStreamPage.transcriptKey,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        t.game_stream_line,
                        style: theme.textTheme.labelLarge,
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
                            fontSize: 14,
                            selected: true,
                            fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                          keyboardLookup: true,
                          onLookup: (int index, Rect anchor) {
                            final ({int start, String term}) span =
                                subtitleTranscriptLookupSpan(line.text, index);
                            if (span.start < 0 ||
                                controller?.currentLine?.lineId !=
                                    line.lineId ||
                                controller?.currentLine?.text != line.text) {
                              return;
                            }
                            unawaited(
                              controller?.lookup(
                                span.term,
                                displayTerm: line.text.characters.elementAt(
                                  span.start,
                                ),
                              ),
                            );
                          },
                        ),
                        trailing: SubtitleTranscriptAction(
                          icon: Icons.content_copy_outlined,
                          tooltip: t.copy,
                          color: theme.colorScheme.onPrimaryContainer,
                          size: 16,
                          onPressed: () => unawaited(
                            Clipboard.setData(ClipboardData(text: line.text)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              key: GameStreamPage.dictionaryKey,
              child: controller == null || result == null
                  ? Center(
                      child: controller?.searching == true
                          ? const CircularProgressIndicator()
                          : Text(
                              controller?.error ?? t.game_stream_lookup_hint,
                            ),
                    )
                  : DictionaryPopupLayer(
                      result: result,
                      webViewKey: _dictionaryKey,
                      isSearching: controller.searching,
                      isDark: theme.brightness == Brightness.dark,
                      showBorder: false,
                      swipeDismissible: false,
                      enableSwipeToClose: false,
                      onDismiss: () => setState(() => _lookupVisible = false),
                      onTextSelected: (String text, Rect rect) =>
                          unawaited(controller.lookup(text)),
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
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
          ],
        ),
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
      child: Icon(icon, color: Colors.white),
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

  void _syncPressed() {
    final bool pressed = _pointers.isNotEmpty || _keys.isNotEmpty;
    if (pressed == _pressed) return;
    _pressed = pressed;
    unawaited(pressed ? widget.onDown() : widget.onUp());
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
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
              border: Border.all(
                color: _focused ? Colors.white : Colors.white54,
                width: _focused ? 2 : 1,
              ),
            ),
            child: SizedBox(
              width: 58,
              height: 58,
              child: Center(child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

enum _StreamMenuAction { touchMode, keyboard, stats, audio }

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
