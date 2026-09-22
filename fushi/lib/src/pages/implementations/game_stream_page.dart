import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/game_stream_receiver.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
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
  static const Key dictionaryKey = ValueKey<String>('game-stream-dictionary');

  @override
  State<GameStreamPage> createState() => _GameStreamPageState();
}

class _GameStreamPageState extends State<GameStreamPage> {
  final GlobalKey _videoKey = GlobalKey();
  GameStreamLookupController? _lookupController;
  bool _controlsVisible = true;
  String? _mineMessage;

  @override
  void initState() {
    super.initState();
    _lookupController = widget.lookupController;
    _lookupController?.addListener(_onLookupChanged);
    widget.receiver?.addListener(_onReceiverChanged);
  }

  @override
  void didUpdateWidget(GameStreamPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lookupController != widget.lookupController) {
      oldWidget.lookupController?.removeListener(_onLookupChanged);
      _lookupController = widget.lookupController;
      _lookupController?.addListener(_onLookupChanged);
    }
    if (oldWidget.receiver != widget.receiver) {
      oldWidget.receiver?.removeListener(_onReceiverChanged);
      widget.receiver?.addListener(_onReceiverChanged);
    }
  }

  @override
  void dispose() {
    _lookupController?.removeListener(_onLookupChanged);
    widget.receiver?.removeListener(_onReceiverChanged);
    super.dispose();
  }

  void _onLookupChanged() {
    if (mounted) setState(() {});
  }

  void _onReceiverChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _sendPointer(
    PointerEvent event,
    GameStreamInputAction action,
  ) async {
    final RenderBox? box =
        _videoKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final Offset local = box.globalToLocal(event.position);
    final Size contentSize = _videoContentSize(box.size);
    final Rect contentRect = Rect.fromCenter(
      center: box.size.center(Offset.zero),
      width: contentSize.width,
      height: contentSize.height,
    );
    final Offset normalized = GameStreamPointerMapper(
      contentRect.size,
    ).normalize(local - contentRect.topLeft);
    await widget.inputComposer.pointer(action: action, normalized: normalized);
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

  Future<void> _mine(DictionaryEntry entry) async {
    final GameStreamLookupController? controller = _lookupController;
    final GameStreamTextEvent? line = controller?.currentLine;
    if (controller == null || line == null) return;
    try {
      final GameStreamMineResult? result = await controller
          .mine(<String, String>{
            'expression': entry.word,
            'term': entry.word,
            'reading': entry.reading,
            'glossary': entry.plainMeaning,
            'meaning': entry.plainMeaning,
            'sentence': line.text,
          });
      if (!mounted) return;
      setState(
        () => _mineMessage = result?.ok == true
            ? '已请求主机制作卡片'
            : (result?.message ?? '主机制卡失败'),
      );
    } catch (error) {
      if (mounted) setState(() => _mineMessage = '主机制卡失败：$error');
    }
  }

  Future<void> _sendButton(
    GameStreamVirtualButton button,
    GameStreamInputAction action,
  ) {
    return widget.inputComposer.gamepad(button: button, action: action);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool compact = constraints.maxWidth < 700;
            final Widget video = Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  _buildVideoSurface(theme),
                  if (widget.receiver?.error != null)
                    Align(
                      alignment: Alignment.topCenter,
                      child: Material(
                        color: Colors.red.withValues(alpha: 0.85),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            '串流连接中断：${widget.receiver!.error}',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  if (widget.receiver?.error != null)
                    Align(
                      alignment: Alignment.topCenter,
                      child: Material(
                        color: Colors.red.withValues(alpha: 0.85),
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            '串流连接中断：${widget.receiver!.error}',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  if (_controlsVisible) _buildGamepadOverlay(theme),
                  Align(
                    alignment: Alignment.topRight,
                    child: IconButton(
                      tooltip: _controlsVisible ? 'Hide controls' : 'Controls',
                      color: Colors.white,
                      icon: Icon(
                        _controlsVisible
                            ? Icons.gamepad
                            : Icons.gamepad_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _controlsVisible = !_controlsVisible),
                    ),
                  ),
                ],
              ),
            );
            final Widget lookup = compact
                ? SizedBox(
                    height: 280,
                    child: _buildLookupRail(theme, compact: true),
                  )
                : _buildLookupRail(theme);
            return compact
                ? Column(children: <Widget>[video, lookup])
                : Row(children: <Widget>[video, lookup]);
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
      child: Container(
        key: GameStreamPage.videoKey,
        color: Colors.black,
        alignment: Alignment.center,
        child: widget.receiver == null
            ? (widget.videoPlaceholder ??
                  Text(
                    'Waiting for game video',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white70,
                    ),
                  ))
            : RTCVideoView(
                widget.receiver!.renderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
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
            Padding(
              key: GameStreamPage.transcriptKey,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('Current line', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SelectableText(
                    line?.text ?? 'No hook text yet',
                    style: theme.textTheme.bodyLarge,
                    onSelectionChanged: (TextSelection selection, _) {
                      final String? text = line?.text;
                      if (text == null || selection.isCollapsed) return;
                      final String selected = selection.textInside(text).trim();
                      if (selected.isNotEmpty) {
                        unawaited(controller?.lookup(selected));
                      }
                    },
                  ),
                  if (line?.thread != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      line!.thread!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              key: GameStreamPage.dictionaryKey,
              child: _DictionaryPane(
                searching: controller?.searching ?? false,
                selectedTerm: controller?.selectedTerm,
                result: result,
                error: controller?.error,
                onMine: result == null || controller == null
                    ? null
                    : (DictionaryEntry entry) => _mine(entry),
                onLookup: controller == null
                    ? null
                    : (String term) => controller.lookup(term),
              ),
            ),
            if (_mineMessage != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _mineMessage!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _mineMessage!.contains('失败')
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

class _PadShell extends StatelessWidget {
  const _PadShell({
    required this.child,
    required this.onDown,
    required this.onUp,
  });

  final Widget child;
  final Future<void> Function() onDown;
  final Future<void> Function() onUp;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => unawaited(onDown()),
      onPointerUp: (_) => unawaited(onUp()),
      onPointerCancel: (_) => unawaited(onUp()),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white54),
        ),
        child: SizedBox(width: 58, height: 58, child: Center(child: child)),
      ),
    );
  }
}

class _DictionaryPane extends StatelessWidget {
  const _DictionaryPane({
    required this.searching,
    required this.selectedTerm,
    required this.result,
    required this.error,
    required this.onMine,
    required this.onLookup,
  });

  final bool searching;
  final String? selectedTerm;
  final DictionarySearchResult? result;
  final String? error;
  final Future<void> Function(DictionaryEntry entry)? onMine;
  final Future<void> Function(String term)? onLookup;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    }
    final DictionarySearchResult? current = result;
    if (current == null) {
      return Center(
        child: Text(
          selectedTerm == null ? 'Select text to look up' : 'No result',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: current.entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final DictionaryEntry entry = current.entries[index];
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        entry.reading.isEmpty
                            ? entry.word
                            : '${entry.word}  ${entry.reading}',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                    if (onMine != null)
                      IconButton(
                        tooltip: 'Mine on host',
                        icon: const Icon(Icons.add_card_outlined),
                        onPressed: () => unawaited(onMine!(entry)),
                      ),
                  ],
                ),
                if (entry.dictionaryName.isNotEmpty)
                  Text(
                    entry.dictionaryName,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 8),
                SelectableText(
                  entry.plainMeaning,
                  onSelectionChanged: (TextSelection selection, _) {
                    if (selection.isCollapsed || onLookup == null) return;
                    final String term = selection
                        .textInside(entry.plainMeaning)
                        .trim();
                    if (term.isNotEmpty) unawaited(onLookup!(term));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
