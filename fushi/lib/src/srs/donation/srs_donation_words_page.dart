/// 捐赠词表预览：会随包保留词头 + 读音的单词，可搜索、逐词排除（勾掉 = 这条笔记的词头 / 读音也清空）。
library;

import 'dart:async';

import 'package:fushi_engine/srs/apkg/srs_donation_export.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/srs/srs_navigation.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_toolbar.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 打开词表；每次勾选变化都回调 [onChanged]（调用方负责落偏好）。
Future<void> openSrsDonationWordsPage(
  BuildContext context, {
  required List<SrsDonationWord> words,
  required Set<String> excluded,
  required ValueChanged<Set<String>> onChanged,
}) => srsPushPage<void>(
  context,
  (_) => SrsDonationWordsPage(
    words: words,
    excluded: excluded,
    onChanged: onChanged,
  ),
);

/// 按搜索词过滤（词头或读音包含，大小写不敏感）。
List<SrsDonationWord> srsDonationFilterWords(
  List<SrsDonationWord> words,
  String query,
) {
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) return words;
  return <SrsDonationWord>[
    for (final SrsDonationWord w in words)
      if (w.headword.toLowerCase().contains(q) ||
          (w.reading?.toLowerCase().contains(q) ?? false))
        w,
  ];
}

class SrsDonationWordsPage extends StatefulWidget {
  const SrsDonationWordsPage({
    super.key,
    required this.words,
    required this.excluded,
    required this.onChanged,
  });

  final List<SrsDonationWord> words;
  final Set<String> excluded;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<SrsDonationWordsPage> createState() => _SrsDonationWordsPageState();
}

class _SrsDonationWordsPageState extends State<SrsDonationWordsPage> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode();
  late Set<String> _excluded = <String>{...widget.excluded};
  late List<SrsDonationWord> _shown = widget.words;

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _filter(String q) =>
      setState(() => _shown = srsDonationFilterWords(widget.words, q));

  void _toggle(SrsDonationWord w) {
    setState(() {
      _excluded = <String>{..._excluded};
      if (!_excluded.remove(w.noteId)) _excluded.add(w.noteId);
    });
    widget.onChanged(_excluded);
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    return FushiPageScaffold(
      title: t.srs_donation_words_preview,
      masthead: true,
      header: apple ? null : _buildTopBar(context),
      body: Builder(builder: _buildBody),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final NavigatorState? navigator = Navigator.maybeOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.gap,
      ),
      child: FushiFloatingTopBar(
        title: t.srs_donation_words_preview,
        leading: <FushiToolbarItem>[
          if (navigator != null && navigator.canPop())
            FushiToolbarItem(
              icon: FushiIcons.back,
              label: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: () => unawaited(navigator.maybePop()),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double top = tokens.spacing.gap + MediaQuery.paddingOf(context).top;
    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: tokens.spacing.page),
            child: FushiSearchField(
              fieldKey: const ValueKey<String>('srs-donation-words-search'),
              controller: _query,
              focusNode: _queryFocus,
              hintText: t.srs_donation_words_search,
              onChanged: _filter,
              onSubmitted: _filter,
              onClear: () => _filter(''),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              tokens.spacing.page,
              tokens.spacing.gap,
              tokens.spacing.page,
              0,
            ),
            child: Text(
              t.srs_donation_words_summary(
                n: widget.words.length,
                excluded: widget.words
                    .where((SrsDonationWord w) => _excluded.contains(w.noteId))
                    .length,
              ),
              key: const ValueKey<String>('srs-donation-words-count'),
            ),
          ),
          Expanded(
            child: _shown.isEmpty
                ? Center(
                    child: FushiPlaceholderMessage(
                      icon: FushiIcons.search,
                      message: t.srs_donation_words_empty,
                    ),
                  )
                : FushiEntranceScope(
                    child: ListView.builder(
                      padding: withBottomSafeInset(
                        context,
                        EdgeInsets.symmetric(
                          horizontal: tokens.spacing.page,
                          vertical: tokens.spacing.gap,
                        ),
                      ),
                      itemCount: _shown.length,
                      itemBuilder: fushiStaggeredItemBuilder(
                        (BuildContext context, int i) => _row(_shown[i]),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(SrsDonationWord w) {
    final bool kept = !_excluded.contains(w.noteId);
    final String? reading = w.reading;
    return FushiListItem(
      key: ValueKey<String>('srs-donation-word-${w.noteId}'),
      density: FushiListDensity.compact,
      title: Text(w.headword),
      subtitle: reading == null ? null : Text(reading),
      trailing: FushiCheckbox(
        value: kept,
        semanticLabel: w.headword,
        onChanged: (bool? _) => _toggle(w),
      ),
      onTap: () => _toggle(w),
    );
  }
}
