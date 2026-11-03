import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle_transcript_text.dart';
import 'package:fushi/src/models/game_stream_button_profile.dart';
import 'package:fushi/src/models/game_stream_lookup_layout.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/pages/implementations/game_stream_line_font_fit.dart';
import 'package:fushi/src/sync/game_stream_companion_bridge.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// What the companion panel shows, as last pushed by the stream page.
///
/// Holds no state of its own: every host message replaces what it had.
class GameStreamCompanionController extends ChangeNotifier {
  GameStreamCompanionController({
    required Future<void> Function(String raw) send,
  }) {
    link = GameStreamCompanionLink(send: send, onHostMessage: _apply);
    resources = GameStreamCompanionResources(link);
  }

  late final GameStreamCompanionLink link;
  late final GameStreamCompanionResources resources;

  GameStreamCompanionState _state = const GameStreamCompanionState();
  GameStreamCompanionState get state => _state;

  DictionarySearchResult? _result;
  DictionarySearchResult? get result => _result;
  int _revision = -1;

  final StreamController<GameStreamCompanionDictionaryCommand> _commands =
      StreamController<GameStreamCompanionDictionaryCommand>.broadcast();

  /// Controller buttons aimed at the dictionary.
  Stream<GameStreamCompanionDictionaryCommand> get commands => _commands.stream;

  void _apply(GameStreamCompanionHostMessage message) {
    switch (message) {
      case GameStreamCompanionState():
        if (message == _state) return;
        _state = message;
        notifyListeners();
      case GameStreamCompanionResult():
        if (message.revision == _revision) return;
        _revision = message.revision;
        resources.updateStyles(message.dictionaryStyles);
        final String? json = message.resultJson;
        _result = json == null
            ? null
            : (DictionarySearchResult.fromJson(json)
                ..popupJson = message.popupJson);
        notifyListeners();
      case GameStreamCompanionCommand():
        _commands.add(message.command);
      case GameStreamCompanionReply():
        // Replies are matched to their requests by the link.
        break;
    }
  }

  @override
  void dispose() {
    link.close();
    unawaited(_commands.close());
    super.dispose();
  }
}

/// The lookup panel on the second display: the current line (tap a word to
/// look it up), the dictionary, the mine status and which mode the
/// controller is in. Everything it does goes back to the stream page.
class GameStreamCompanionPage extends StatefulWidget {
  const GameStreamCompanionPage({
    required this.controller,
    this.dictionaryReady = true,
    super.key,
  });

  final GameStreamCompanionController controller;

  /// False while this engine's dictionary setup is still loading; the
  /// dictionary area shows a spinner until then.
  final bool dictionaryReady;

  static const Key modeChipKey = ValueKey<String>('game-stream-companion-mode');
  static const Key lineTextKey = ValueKey<String>('game-stream-companion-line');
  static const Key outlineKey = ValueKey<String>(
    'game-stream-companion-outline',
  );
  static const Key dictionaryKey = ValueKey<String>(
    'game-stream-companion-dictionary',
  );

  @override
  State<GameStreamCompanionPage> createState() =>
      _GameStreamCompanionPageState();
}

class _GameStreamCompanionPageState extends State<GameStreamCompanionPage> {
  final GlobalKey<DictionaryPopupWebViewState> _dictionaryKey =
      GlobalKey<DictionaryPopupWebViewState>();
  StreamSubscription<GameStreamCompanionDictionaryCommand>? _commands;

  GameStreamCompanionController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _commands = _controller.commands.listen(_runCommand);
  }

  @override
  void didUpdateWidget(GameStreamCompanionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      unawaited(_commands?.cancel());
      _commands = _controller.commands.listen(_runCommand);
    }
  }

  @override
  void dispose() {
    unawaited(_commands?.cancel());
    super.dispose();
  }

  Future<void> _runCommand(GameStreamCompanionDictionaryCommand command) async {
    final DictionaryPopupWebViewState? dictionary = _dictionaryKey.currentState;
    if (dictionary == null) return;
    switch (command) {
      case GameStreamCompanionDictionaryCommand.entryNext:
        await dictionary.focusEntryMove(true);
      case GameStreamCompanionDictionaryCommand.entryPrevious:
        await dictionary.focusEntryMove(false);
      case GameStreamCompanionDictionaryCommand.mineFirstVisible:
        await dictionary.mineFirstVisibleEntry();
      case GameStreamCompanionDictionaryCommand.playFirstVisibleAudio:
        await dictionary.playFirstVisibleAudio();
    }
  }

  void _send(GameStreamCompanionMessage message) =>
      unawaited(_controller.link.send(message));

  Future<MinePopupResult> _mine(Map<String, String> fields) async {
    final GameStreamCompanionMineOutcome outcome = await _controller.link.mine(
      fields,
    );
    return switch (outcome) {
      GameStreamCompanionMineOutcome.ok => const MinePopupResult(
        ankiConnect: true,
      ),
      GameStreamCompanionMineOutcome.duplicate => MinePopupResult.failed(
        const MineOutcome(MineResult.duplicate),
      ),
      GameStreamCompanionMineOutcome.error => MinePopupResult.failed(
        const MineOutcome(MineResult.error),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (BuildContext context, Widget? _) {
            final GameStreamCompanionState state = _controller.state;
            final bool lookupMode = state.mode == GameStreamInputMode.lookup;
            final FushiSpringSpec spring = context.fushiMotion.effectsDefault;
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) =>
                      _buildColumn(theme, state, box.maxHeight),
                ),
                // Lookup mode outlines the panel in the accent color, as the
                // inline rail does: the buttons are here now.
                IgnorePointer(
                  child: AnimatedContainer(
                    key: GameStreamCompanionPage.outlineKey,
                    duration: spring.duration,
                    curve: spring.curve,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: lookupMode
                            ? theme.colorScheme.primary
                            : theme.colorScheme.primary.withValues(alpha: 0),
                        width: 3,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildColumn(
    ThemeData theme,
    GameStreamCompanionState state,
    double height,
  ) {
    // The bottom screen of a handheld is nearly square: the line gets a bit
    // over a third, the dictionary the rest.
    final double lineHeight = (height * 0.38).clamp(96, 320).toDouble();
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiStaggeredEntrance(index: 0, child: _buildHeader(theme, state)),
          SizedBox(
            height: lineHeight,
            child: FushiStaggeredEntrance(
              index: 1,
              child: _buildLine(theme, state, lineHeight),
            ),
          ),
          const FushiDividerControl(height: 1),
          Expanded(
            key: GameStreamCompanionPage.dictionaryKey,
            child: FushiStaggeredEntrance(
              index: 2,
              child: _buildDictionary(theme, state),
            ),
          ),
          if (state.mineMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                state.mineMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: state.mineFailed
                      ? fushiStatusColor(context, FushiStatusTone.error)
                      : fushiAccentForeground(context),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, GameStreamCompanionState state) {
    final bool lookupMode = state.mode == GameStreamInputMode.lookup;
    final FushiSpringSpec spring = context.fushiMotion.effectsDefault;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: <Widget>[
          Expanded(
            child: AnimatedSwitcher(
              duration: spring.duration,
              switchInCurve: spring.curve,
              switchOutCurve: spring.curve,
              child: Text(
                lookupMode
                    ? t.game_stream_lookup_mode_hint
                    : t.game_stream_line,
                key: ValueKey<bool>(lookupMode),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: lookupMode
                    ? theme.textTheme.bodySmall?.copyWith(
                        color: fushiNeutralSecondaryForeground(context),
                      )
                    : context.fushiType.titleSmallEmphasized,
              ),
            ),
          ),
          if (state.controllerUsed)
            AnimatedSwitcher(
              duration: spring.duration,
              switchInCurve: spring.curve,
              switchOutCurve: spring.curve,
              child: FushiPressScale(
                key: ValueKey<GameStreamInputMode>(state.mode),
                child: FushiFilterChip(
                  key: GameStreamCompanionPage.modeChipKey,
                  tooltip: t.game_stream_action_lookup_mode_toggle,
                  showCheckmark: false,
                  selected: lookupMode,
                  avatar: Icon(
                    lookupMode ? FushiIcons.search : FushiIcons.games,
                    size: 18,
                  ),
                  label: Text(
                    lookupMode
                        ? t.game_stream_lookup_mode
                        : t.game_stream_game_mode,
                  ),
                  onSelected: (_) => _send(
                    GameStreamCompanionSetMode(
                      lookupMode
                          ? GameStreamInputMode.game
                          : GameStreamInputMode.lookup,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLine(
    ThemeData theme,
    GameStreamCompanionState state,
    double lineHeight,
  ) {
    final String? lineId = state.lineId;
    final String? text = state.lineText;
    if (lineId == null || text == null) {
      return Center(
        child: Text(
          t.game_stream_line_empty,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: fushiNeutralSecondaryForeground(context),
          ),
        ),
      );
    }
    final bool lookupMode = state.mode == GameStreamInputMode.lookup;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => _buildLineRow(
        theme,
        state,
        lineId,
        text,
        lookupMode,
        box,
        lineHeight,
      ),
    );
  }

  /// The line grows to fill its area, like the inline rail's line (a short
  /// line at the proportional size left most of the bottom screen empty).
  double _lineFontSize(String text, BoxConstraints box, double lineHeight) {
    final ThemeData theme = Theme.of(context);
    return gameStreamFitLineFontSize(
      text: text,
      styleFor: (double size) => subtitleTranscriptTextStyle(
        fontSize: size,
        selected: true,
        fontFamily: theme.textTheme.bodyMedium?.fontFamily,
      ),
      width:
          box.maxWidth -
          kSubtitleRowPaddingLeft -
          kSubtitleRowPaddingRight -
          kSubtitleRowScrollbarGutter -
          _copyActionExtent,
      height: lineHeight - kSubtitleRowPaddingVertical - _lineScrollPadding * 2,
      floor: GameStreamLookupLayout.fontSizeFor(lineHeight),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    );
  }

  Widget _buildLineRow(
    ThemeData theme,
    GameStreamCompanionState state,
    String lineId,
    String text,
    bool lookupMode,
    BoxConstraints box,
    double lineHeight,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: _lineScrollPadding),
      child: SubtitleTranscriptRow(
        colorScheme: theme.colorScheme,
        selected: true,
        text: SubtitleTranscriptText(
          key: ValueKey<String>('game-stream-companion-line-$lineId'),
          textKey: GameStreamCompanionPage.lineTextKey,
          text: text,
          style: subtitleTranscriptTextStyle(
            fontSize: _lineFontSize(text, box, lineHeight),
            selected: true,
            fontFamily: theme.textTheme.bodyMedium?.fontFamily,
            color: SubtitleTranscriptRow.textColorOf(
              context,
              theme.colorScheme,
              selected: true,
            ),
          ),
          keyboardLookup: true,
          caret: lookupMode ? state.caret : null,
          lookupHighlight: lookupMode ? state.highlight : null,
          onLookup: (int index, Rect anchor) =>
              _send(GameStreamCompanionLookupAt(lineId: lineId, index: index)),
        ),
        trailing: SubtitleTranscriptAction(
          icon: FushiIcons.copy,
          tooltip: t.copy,
          color: SubtitleTranscriptRow.secondaryColorOf(
            context,
            theme.colorScheme,
            selected: true,
          ),
          size: _copyIconSize,
          onPressed: () =>
              unawaited(Clipboard.setData(ClipboardData(text: text))),
        ),
      ),
    );
  }

  Widget _buildDictionary(ThemeData theme, GameStreamCompanionState state) {
    final DictionarySearchResult? result = _controller.result;
    if (!widget.dictionaryReady || result == null) {
      return Center(
        child: !widget.dictionaryReady || state.searching
            ? const FushiCircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  state.error ?? t.game_stream_lookup_hint,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: fushiNeutralSecondaryForeground(context),
                  ),
                ),
              ),
      );
    }
    return DictionaryPopupLayer(
      result: result,
      webViewKey: _dictionaryKey,
      // Styles come with the result; media and audio are fetched by the
      // stream page, which holds the host connection.
      resourceSource: _controller.resources,
      isSearching: state.searching,
      isDark: theme.brightness == Brightness.dark,
      showBorder: false,
      swipeDismissible: false,
      enableSwipeToClose: false,
      // The panel's lifetime belongs to the stream page.
      onDismiss: () {},
      onTextSelected: (String text, Rect rect, List<FushiRubySpan> rubySpans) =>
          _send(GameStreamCompanionLookupText(text)),
      onLinkClick: (String text, Rect rect) =>
          _send(GameStreamCompanionLookupText(text)),
      onMineEntry: _mine,
      onDuplicateCheck: _controller.link.isDuplicate,
    );
  }
}

/// The line row's copy action: icon plus its 2px padding on both sides.
const double _copyIconSize = 16;
const double _copyActionExtent = _copyIconSize + 4;

/// Vertical padding around the scrollable line.
const double _lineScrollPadding = 4;
