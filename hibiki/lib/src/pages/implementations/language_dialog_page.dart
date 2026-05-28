import 'package:flutter/material.dart';
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.76,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.options_language,
        leadingIcon: Icons.language_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: buildContent(),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [buildCloseButton()],
        ),
      ),
    );
  }

  Widget buildCloseButton() {
    return adaptiveDialogAction(
      context: context,
      child: Text(t.dialog_close),
      onPressed: () => Navigator.pop(context),
    );
  }

  Widget buildContent() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
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
                padding: EdgeInsets.only(left: tokens.spacing.gap),
                child: Text(
                  t.app_locale,
                  style: tokens.type.sectionLabel.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              HibikiDropdown<String>(
                options: HibikiLocalisations.localeNames.keys.toList(),
                initialOption: appModel.appLocale.toLanguageTag(),
                generateLabel: (languageTag) =>
                    HibikiLocalisations.localeNames[languageTag]!,
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
