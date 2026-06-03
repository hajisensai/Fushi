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
import 'package:hibiki/utils.dart';

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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 560,
      maxHeightFactor: 0.86,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.reader_settings_section,
        scrollable: true,
        bodyPadding: EdgeInsets.zero,
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: _buildContent(),
        footer: Align(
          alignment: Alignment.centerRight,
          child: adaptiveDialogAction(
            context: context,
            child: Text(t.dialog_close),
            onPressed: () => Navigator.pop(context),
          ),
        ),
      ),
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
      // 两个渲染器的详情都已是可滚动 ListView（BUG-009 R1）。在此弹窗里统一收缩
      // 到内容高：material 由 ListView 自身(controller=_contentScrollController)
      // 滚动，cupertino 由下方外层 SingleChildScrollView 滚动；shrinkWrap 避免
      // ListView 落在无界高度（cupertino 的 SingleChildScrollView）处崩。
      shrinkWrap: true,
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
  const HibikiSettingsContent({super.key, this.onBack});

  /// 非空时在设置页头左侧显示返回箭头（宽屏隐藏图标侧栏的全屏设置场景）。
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return SettingsHomePage(embedded: true, onBack: onBack);
  }
}
