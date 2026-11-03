import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/texthooker_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:material_ui/material_ui.dart';

/// 非 Windows 桌面 games 模块的两个视图。
enum GameStreamClientSection { stream, texthooker }

typedef GameStreamClientSectionBuilder =
    Widget Function(BuildContext context, Widget navigation);

/// 非 Windows 桌面（Linux / macOS）的 games 模块：串流库 + 外部 texthooker 台词。
///
/// 这些平台没有 galgame hook，但外部 WebSocket texthooker（LunaTranslator /
/// Textractor / mpv）照样能把台词推进 `TexthookerService`；这里给它一个看台词、点词
/// 查词的页面。台词页是 [TexthookerPage] 的嵌入模式，hook 注入 / 捕获 / 窗口绑定
/// 控件由 `GamesModuleForm.supportsHookCapture` 在页内隐藏。台词页首次进入才创建，
/// 之后用 [IndexedStack] 保活，切回串流库不丢滚动与选中状态。
class GameStreamClientPage extends StatefulWidget {
  const GameStreamClientPage({
    required this.streamBuilder,
    this.texthookerBuilder,
    super.key,
  });

  /// 串流库视图；测试可注入桩。
  final GameStreamClientSectionBuilder streamBuilder;

  /// 台词视图；缺省为嵌入模式的 [TexthookerPage]。
  final GameStreamClientSectionBuilder? texthookerBuilder;

  static const Key sectionTabsKey = ValueKey<String>(
    'game-stream-client-sections',
  );
  static const Key streamKey = ValueKey<String>('game-stream-client-stream');
  static const Key texthookerKey = ValueKey<String>(
    'game-stream-client-texthooker',
  );

  @override
  State<GameStreamClientPage> createState() => _GameStreamClientPageState();
}

class _GameStreamClientPageState extends State<GameStreamClientPage> {
  GameStreamClientSection _section = GameStreamClientSection.stream;
  bool _texthookerVisited = false;

  Widget _buildNavigation(BuildContext context) {
    return KeyedSubtree(
      key: GameStreamClientPage.sectionTabsKey,
      child: adaptiveSegmentedButton<GameStreamClientSection>(
        context: context,
        segments: <ButtonSegment<GameStreamClientSection>>[
          ButtonSegment<GameStreamClientSection>(
            value: GameStreamClientSection.stream,
            label: Text(t.game_stream_tab),
          ),
          ButtonSegment<GameStreamClientSection>(
            value: GameStreamClientSection.texthooker,
            label: Text(t.texthooker),
          ),
        ],
        selected: <GameStreamClientSection>{_section},
        onSelectionChanged: (Set<GameStreamClientSection> next) {
          setState(() {
            _section = next.first;
            if (_section == GameStreamClientSection.texthooker) {
              _texthookerVisited = true;
            }
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget navigation = _buildNavigation(context);
    final GameStreamClientSectionBuilder texthooker =
        widget.texthookerBuilder ??
        (BuildContext context, Widget navigation) =>
            TexthookerPage(embedded: true, navigation: navigation);
    return IndexedStack(
      index: _section.index,
      children: <Widget>[
        KeyedSubtree(
          key: GameStreamClientPage.streamKey,
          child: widget.streamBuilder(context, navigation),
        ),
        KeyedSubtree(
          key: GameStreamClientPage.texthookerKey,
          child: _texthookerVisited
              ? texthooker(context, navigation)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
