import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_engine/sync/game_stream/game_stream_protocol.dart';

class GameStreamPage extends StatefulWidget {
  const GameStreamPage({
    required this.sessionId,
    required this.clientId,
    required this.inputComposer,
    this.lookupController,
    this.receiver,
    this.videoPlaceholder,
    super.key,
  });

  final String sessionId;
  final String clientId;
  final GameStreamInputComposer inputComposer;
  final GameStreamLookupController? lookupController;
  final FushiGameStreamReceiver? receiver;
  final Widget? videoPlaceholder;

  static const Key videoKey = ValueKey<String>('game-stream-video');
  static const Key transcriptKey = ValueKey<String>('game-stream-transcript');
  static const Key transcriptTextKey = ValueKey<String>(
    'game-stream-transcript-text',
  );
  static const Key dictionaryKey = ValueKey<String>('game-stream-dictionary');

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
  int? _activePointer;
  Offset _lastPointerPosition = Offset.zero;
  ({Rect bounds, Rect content})? _pointerGeometry;
  GameStreamInputComposer? _pointerComposer;

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
    if (!mounted || _activePointer == null) return;
    if (_pointerGeometry != _currentPointerGeometry()) {
      unawaited(_releasePointer());
    }
  }

  void _schedulePointerGeometryCheck() {
    if (_activePointer != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        _releasePointerIfLayoutChanged,
      );
    }
  }

  Future<void> _releasePointer() async {
    final GameStreamInputComposer? composer = _pointerComposer;
    if (_activePointer == null || composer == null) return;
    final Offset position = _lastPointerPosition;
    // Clear synchronously: cancellation, metrics and disposal can arrive in the
    // same frame and must emit exactly one release to the original session.
    _activePointer = null;
    _pointerComposer = null;
    _pointerGeometry = null;
    await composer.pointer(
      action: GameStreamInputAction.up,
      normalized: position,
    );
  }

  Future<void> _sendPointer(
    PointerEvent event,
    GameStreamInputAction action,
  ) async {
    if (action == GameStreamInputAction.down) {
      if (_activePointer != null) return;
    } else if (event.pointer != _activePointer) {
      return;
    }
    final ({Rect bounds, Rect content})? geometry = _currentPointerGeometry();
    if (geometry == null) {
      await _releasePointer();
      return;
    }
    if (action != GameStreamInputAction.down && geometry != _pointerGeometry) {
      await _releasePointer();
      return;
    }
    final RenderBox? box =
        _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final Offset local = box.globalToLocal(event.position);
    _lastPointerPosition = GameStreamPointerMapper(
      geometry.content.size,
    ).normalize(local - geometry.content.topLeft);
    if (action == GameStreamInputAction.down) {
      _activePointer = event.pointer;
      _pointerComposer = widget.inputComposer;
      _pointerGeometry = geometry;
    }
    if (action == GameStreamInputAction.up) {
      await _releasePointer();
    } else {
      await _pointerComposer!.pointer(
        action: action,
        normalized: _lastPointerPosition,
      );
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
    if (controller == null || controller.currentLine == null) {
      return MinePopupResult.failed(const MineOutcome(MineResult.error));
    }
    try {
      final GameStreamMineResult? result = await controller.mine(fields);
      if (mounted) {
        setState(() {
          _mineFailed = result?.ok != true;
          _mineMessage = result?.ok == true
              ? result?.detail == 'sentence_audio_missing'
                    ? t.game_card_sentence_audio_missing
                    : t.game_stream_mine_success
              : '${t.game_stream_mine_failed}: ${result?.message ?? ''}';
        });
      }
      return result?.ok == true
          ? const MinePopupResult(ankiConnect: true)
          : MinePopupResult.failed(const MineOutcome(MineResult.error));
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
                      ListTile(
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

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
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
                                  : t.game_stream_input_rejected,
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
                    child: BackButton(
                      color: Colors.white,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  Align(
                    alignment: Alignment.topRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
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
      ),
    );
  }

  Widget _buildVideoSurface(ThemeData theme) {
    return Listener(
      key: _videoKey,
      onPointerDown: (PointerDownEvent event) =>
          unawaited(_sendPointer(event, GameStreamInputAction.down)),
      onPointerMove: (PointerMoveEvent event) =>
          unawaited(_sendPointer(event, GameStreamInputAction.move)),
      onPointerUp: (PointerUpEvent event) =>
          unawaited(_sendPointer(event, GameStreamInputAction.up)),
      onPointerCancel: (PointerCancelEvent event) {
        if (event.pointer == _activePointer) unawaited(_releasePointer());
      },
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
                                    line.lineId) {
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
