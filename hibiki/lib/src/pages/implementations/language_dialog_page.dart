import 'package:flutter/material.dart';
import 'package:spaces/spaces.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/utils.dart';

/// Dialog for changing the app locale.
class LanguageDialogPage extends BasePage {
  const LanguageDialogPage({super.key});

  @override
  BasePageState createState() => _LanguageDialogPageState();
}

class _LanguageDialogPageState extends BasePageState<LanguageDialogPage> {
  final ScrollController _contentScrollController = ScrollController();

  @override
  void dispose() {
    _contentScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      contentPadding: MediaQuery.of(context).orientation == Orientation.portrait
          ? Spacing.of(context).insets.exceptBottom.big
          : Spacing.of(context).insets.exceptBottom.normal,
      content: buildContent(),
      actions: [buildCloseButton()],
    );
  }

  Widget buildCloseButton() {
    return TextButton(
      child: Text(t.dialog_close),
      onPressed: () => Navigator.pop(context),
    );
  }

  Widget buildContent() {
    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thumbVisibility: true,
        thickness: 3,
        controller: _contentScrollController,
        child: SingleChildScrollView(
          controller: _contentScrollController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: Spacing.of(context).insets.onlyLeft.small,
                child: Text(
                  t.app_locale,
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.unselectedWidgetColor,
                  ),
                ),
              ),
              JidoujishoDropdown<String>(
                options: JidoujishoLocalisations.localeNames.keys.toList(),
                initialOption: appModel.appLocale.toLanguageTag(),
                generateLabel: (languageTag) =>
                    JidoujishoLocalisations.localeNames[languageTag]!,
                onChanged: (languageTag) {
                  appModel.setAppLocale(languageTag!);
                  setState(() {});
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
