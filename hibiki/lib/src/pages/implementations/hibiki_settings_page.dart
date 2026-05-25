import 'package:flutter/material.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/cupertino_settings_renderer.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_home_page.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki/src/utils/spacing.dart';

// ─── Dialog version (used inside the reader) ─────────────────────────────────

class HibikiSettingsDialogPage extends BasePage {
  const HibikiSettingsDialogPage({super.key});

  @override
  BasePageState createState() => _HibikiSettingsDialogPageState();
}

class _HibikiSettingsDialogPageState extends BasePageState {
  final ScrollController _contentScrollController = ScrollController();

  @override
  void dispose() {
    _contentScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return adaptiveAlertDialog(
      context: context,
      contentPadding: MediaQuery.of(context).orientation == Orientation.portrait
          ? Spacing.of(context).insets.exceptBottom.big
          : Spacing.of(context).insets.exceptBottom.normal.copyWith(
                left: Spacing.of(context).spaces.semiBig,
                right: Spacing.of(context).spaces.semiBig,
              ),
      actionsPadding: Spacing.of(context).insets.exceptBottom.normal.copyWith(
            left: Spacing.of(context).spaces.normal,
            right: Spacing.of(context).spaces.normal,
            bottom: Spacing.of(context).spaces.normal,
            top: Spacing.of(context).spaces.extraSmall,
          ),
      content: _buildContent(),
      actions: [
        adaptiveDialogAction(
          context: context,
          child: Text(t.dialog_close),
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _buildContent() {
    final SettingsContext settingsContext = SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (mounted) setState(() {});
      },
    );
    final SettingsDestination destination = buildReaderQuickSettingsDestination(
      settingsContext,
    );
    final bool cupertino = isCupertinoPlatform(context);
    final SettingsRenderer renderer = cupertino
        ? const CupertinoSettingsRenderer()
        : const MaterialSettingsRenderer();
    final Widget detailContent = renderer.buildDetailContent(
      settingsContext: settingsContext,
      destination: destination,
      scrollController: cupertino ? null : _contentScrollController,
      shrinkWrap: !cupertino,
    );

    return SizedBox(
      width: double.maxFinite,
      child: RawScrollbar(
        thickness: 3,
        thumbVisibility: true,
        controller: _contentScrollController,
        child: PrimaryScrollController(
          controller: _contentScrollController,
          child: cupertino
              ? SingleChildScrollView(
                  controller: _contentScrollController,
                  child: detailContent,
                )
              : detailContent,
        ),
      ),
    );
  }
}

// ─── Full-page version (home "调整" tab) ──────────────────────────────────────

class HibikiSettingsContent extends StatelessWidget {
  const HibikiSettingsContent({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsHomePage(embedded: true);
  }
}
