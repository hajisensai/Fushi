import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_chips.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// 拍板台 Um72dWD9Cz（方案 B）：查词浮层「查不到」时，把查询词拆成可点的词块、
/// 外加「修改」输入框，让 OCR 多框进的词（`an vnusual case`）与认错的字（u→v）
/// 都能在浮层里就地自救，不用退回原文重选。
///
/// 只在查不到时出现（以及从这里点进去的结果页上方留一行词块，便于连续换词）；
/// 查得到的浮层不变，不加设置开关。各入口（阅读器 / PDF / 漫画 OCR / 视频 /
/// 首页词典 / 独立查词窗）共用 `DictionaryPopupLayer`，改一处全都生效。

/// 把一批 CJK 片段切成词：与 [texts] 等长、按序对应，每段各自切分。
typedef LookupRefineTokenizer =
    Future<List<List<String>>> Function(List<String> texts);

/// 单个查询词最多拆出的词块数：漫画 / PDF OCR 偶尔框进整行，块太多就成了一堵墙。
const int kLookupRefineMaxChips = 24;

/// 「一个词」的字符：字母（含 CJK、长音符、々）、数字、组合附加符；英文里夹在两个
/// 字母之间的撇号 / 连字符（`don't`、`well-known`）算词内。其余（空白、标点、符号）
/// 都是分隔。
final RegExp _refineRunRegExp = RegExp(
  r"[\p{L}\p{N}\p{M}]+(?:['’\-][\p{L}\p{N}\p{M}]+)*",
  unicode: true,
);

/// 含假名 / 汉字的片段要再交给词典切分；纯拉丁 / 数字的片段按空格拆完就是词。
final RegExp _cjkRegExp = RegExp(
  r'[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}ー々〆ヶ]',
  unicode: true,
);

/// 查询词按空白 / 标点拆成的片段（不做词典切分），按出现顺序。
List<String> lookupRefineRuns(String query) => <String>[
  for (final RegExpMatch m in _refineRunRegExp.allMatches(query)) m[0]!,
];

/// 默认切分器：词典最长匹配（[JapaneseLanguage.textsToWordsWithReadingsInBackground]，
/// 与字幕逐词步进 / texthooker 同一套切分，原生一次调用、在后台 isolate 跑）。
/// 这不是形态素分词器——切出来的每一段就是查词引擎从该位置能匹配到的最长词条，
/// 引擎未就绪时退化成逐码元。
Future<List<List<String>>> defaultLookupRefineTokenizer(
  List<String> texts,
) async {
  final List<List<({String text, String reading})>> segmented =
      await JapaneseLanguage.instance.textsToWordsWithReadingsInBackground(
        texts,
      );
  return <List<String>>[
    for (final List<({String text, String reading})> words in segmented)
      <String>[for (final ({String text, String reading}) w in words) w.text],
  ];
}

/// 把 [query] 拆成可点的词块：先按空白 / 标点拆片段，含 CJK 的片段再用 [tokenizer]
/// 切成词（切出来的标点碎片丢弃）。去重、保序，最多 [kLookupRefineMaxChips] 块。
///
/// 切分器失败（引擎退役 / 原生报错）时该片段整段当一块，不让空态因此丢掉词块。
Future<List<String>> lookupRefineChips(
  String query, {
  LookupRefineTokenizer tokenizer = defaultLookupRefineTokenizer,
}) async {
  final List<String> runs = lookupRefineRuns(query);
  final List<String> cjkRuns = <String>[
    for (final String run in runs)
      if (_cjkRegExp.hasMatch(run)) run,
  ];
  List<List<String>>? segmented;
  if (cjkRuns.isNotEmpty) {
    try {
      segmented = await tokenizer(cjkRuns);
      if (segmented.length != cjkRuns.length) segmented = null;
    } on Object {
      segmented = null;
    }
  }
  final List<String> chips = <String>[];
  final Set<String> seen = <String>{};
  void add(String chip) {
    if (chips.length >= kLookupRefineMaxChips) return;
    if (chip.isEmpty || !seen.add(chip)) return;
    chips.add(chip);
  }

  int cjkIndex = 0;
  for (final String run in runs) {
    if (!_cjkRegExp.hasMatch(run)) {
      add(run);
      continue;
    }
    final List<String>? words = segmented?[cjkIndex];
    cjkIndex++;
    if (words == null) {
      add(run);
      continue;
    }
    for (final String word in words) {
      // 切分器保留了原文里的一切字符；词块只留有「词字符」的片段。
      for (final String piece in lookupRefineRuns(word)) {
        add(piece);
      }
    }
  }
  return chips;
}

/// 查不到时的词块 + 修改面板。
///
/// - [compact] 为 false：空态里的整块（词块居中折行，下方一颗「修改」）。
/// - [compact] 为 true：结果页上方的一行（横向滚动），点进来的那个词高亮。
///
/// 点词块 → [onQuery]`(词块, source)`：宿主在同一层原地换词，词块来源仍是 [source]，
/// 所以结果页上方还能接着点别的词。「修改」展开成输入框（预填 [source]），提交 →
/// [onQuery]`(改后的词, 改后的词)`：改后的词成为新的词块来源。
class LookupRefinePanel extends StatefulWidget {
  const LookupRefinePanel({
    required this.source,
    required this.currentTerm,
    required this.onQuery,
    super.key,
    this.compact = false,
    this.tokenizer = defaultLookupRefineTokenizer,
  });

  /// 词块来源：最初查不到的那串查询词（或用户改过后的那串）。
  final String source;

  /// 本层此刻查的词；与之相等的词块画成选中态，再点它不重查。
  final String currentTerm;

  /// 宿主的原地换词入口：`(要查的词, 词块来源)`。
  final void Function(String query, String refineSource) onQuery;

  final bool compact;

  final LookupRefineTokenizer tokenizer;

  @override
  State<LookupRefinePanel> createState() => _LookupRefinePanelState();
}

class _LookupRefinePanelState extends State<LookupRefinePanel> {
  List<String>? _chips;
  int _chipsGeneration = 0;
  bool _editing = false;
  late final TextEditingController _controller = TextEditingController(
    text: widget.source,
  );
  final FocusNode _focusNode = FocusNode(debugLabel: 'LookupRefineField');

  @override
  void initState() {
    super.initState();
    _loadChips();
  }

  @override
  void didUpdateWidget(LookupRefinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _editing = false;
      _controller.text = widget.source;
      _loadChips();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _loadChips() {
    final int generation = ++_chipsGeneration;
    final String source = widget.source;
    _chips = null;
    unawaited(
      lookupRefineChips(source, tokenizer: widget.tokenizer).then((
        List<String> chips,
      ) {
        // 切分往返期间来源换了（原地跳到了别的词）：旧结果作废。
        if (!mounted || generation != _chipsGeneration) return;
        setState(() => _chips = chips);
      }),
    );
  }

  void _pick(String chip) {
    if (chip == widget.currentTerm.trim()) return;
    widget.onQuery(chip, widget.source);
  }

  void _submit(String text) {
    final String query = text.trim();
    if (query.isEmpty) return;
    setState(() => _editing = false);
    widget.onQuery(query, query);
  }

  void _startEditing() {
    _controller
      ..text = widget.source
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.source.length,
      );
    setState(() => _editing = true);
  }

  @override
  Widget build(BuildContext context) {
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    // 关动效（减少动态 / 墨水屏 / 测试）时 duration 归零：SDK AnimatedSize 零时长
    // 会在自己的 performLayout 里同步 markNeedsLayout 触发断言，统一走 FushiAnimatedSize。
    return FushiAnimatedSize(
      duration: duration,
      curve: FushiMotion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: FushiMotion.enter,
        switchOutCurve: FushiMotion.exit,
        child: _editing ? _buildField(context) : _buildChips(context),
      ),
    );
  }

  Widget _buildField(BuildContext context) {
    return Padding(
      key: const ValueKey<String>('lookup-refine-field'),
      padding: widget.compact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : EdgeInsets.zero,
      child: FushiSearchField(
        controller: _controller,
        focusNode: _focusNode,
        hintText: t.dictionary_popup_refine_field_hint,
        autofocus: true,
        onChanged: (String _) {},
        onSubmitted: _submit,
        trailing: <Widget>[
          FushiIconButton(
            key: const ValueKey<String>('lookup-refine-submit'),
            icon: FushiIcons.search,
            tooltip: t.dictionary_popup_refine_search,
            onTap: () => _submit(_controller.text),
          ),
        ],
      ),
    );
  }

  Widget _buildChips(BuildContext context) {
    final List<String> chips = _chips ?? const <String>[];
    final String current = widget.currentTerm.trim();
    final List<Widget> children = <Widget>[
      for (int i = 0; i < chips.length; i++)
        FushiStaggeredEntrance(
          index: i,
          child: FushiPressScale(
            child: FushiChoiceChip(
              key: ValueKey<String>('lookup-refine-chip-${chips[i]}'),
              label: Text(chips[i]),
              selected: chips[i] == current,
              showCheckmark: false,
              tooltip: chips[i],
              onSelected: (bool _) => _pick(chips[i]),
            ),
          ),
        ),
      FushiStaggeredEntrance(
        index: chips.length,
        child: FushiPressScale(
          child: FushiActionChip(
            key: const ValueKey<String>('lookup-refine-edit'),
            label: t.dictionary_popup_refine_edit,
            icon: FushiIcons.edit,
            onPressed: _startEditing,
          ),
        ),
      ),
    ];
    final Widget body = widget.compact
        // 桌面端默认 dragDevices 不含鼠标，横向词块条要显式放开拖动。
        ? HorizontalDragScrollable(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: <Widget>[
                  for (final Widget child in children)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: child,
                    ),
                ],
              ),
            ),
          )
        : Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: children,
          );
    return FushiEntranceScope(
      key: const ValueKey<String>('lookup-refine-chips'),
      // 词块切完才算一屏：切分回来那一刻重开进场窗口，词块错峰出现。
      replayKey: _chips == null ? null : widget.source,
      child: body,
    );
  }
}
