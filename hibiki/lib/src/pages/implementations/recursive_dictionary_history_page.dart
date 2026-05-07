import 'package:flutter/material.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/utils.dart';

/// The page shown to view a result in dictionary history.
class RecursiveDictionaryHistoryPage extends BasePage {
  /// Create an instance of this page.
  const RecursiveDictionaryHistoryPage({
    required this.result,
    super.key,
  });

  /// The result made from a dictionary database search.
  final DictionarySearchResult result;

  @override
  BasePageState<RecursiveDictionaryHistoryPage> createState() =>
      _RecursiveDictionaryHistoryPageState();
}

class _RecursiveDictionaryHistoryPageState
    extends BasePageState<RecursiveDictionaryHistoryPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Theme.of(context).colorScheme.background,
      appBar: buildAppBar(),
      body: SafeArea(
        child: DictionaryPopupWebView(
          result: widget.result,
          onTextSelected: (text, _, __) {
            onSearch(text);
          },
        ),
      ),
    );
  }

  Widget buildTitle() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: JidoujishoMarquee(
            text: widget.result.searchTerm.replaceAll('\n', ' '),
            style: TextStyle(
              fontSize: textTheme.titleMedium?.fontSize,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  PreferredSizeWidget? buildAppBar() {
    return AppBar(
      leading: buildBackButton(),
      title: buildTitle(),
      titleSpacing: 8,
    );
  }

  Widget buildBackButton() {
    return JidoujishoIconButton(
      tooltip: t.back,
      icon: Icons.arrow_back,
      onTap: () {
        Navigator.pop(context);
      },
    );
  }
}
