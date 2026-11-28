import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/pages/base_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_home_page.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_scrollbar.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

// ─── Dialog version (used inside the reader) ─────────────────────────────────

class FushiSettingsDialogPage extends BasePage {
  const FushiSettingsDialogPage({super.key});

  @override
  BasePageState createState() => _FushiSettingsDialogPageState();
}

class _FushiSettingsDialogPageState extends BasePageState
    with SettingsContextHost {
  final ScrollController _contentScrollController = ScrollController();

  @override
  void dispose() {
    _contentScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      // BUG-1546：560 窄弹窗与兄弟快捷设置弹窗（阅读器外观 sheet 等）不同宽，
      // 桌面大窗口下挤成窄条；统一对齐 kFushiSettingsDialogMaxWidth（900）。
      maxWidth: kFushiSettingsDialogMaxWidth,
      maxHeightFactor: 0.86,
      insetPadding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.card,
      ),
      scrollable: false,
      child: FushiModalSheetFrame(
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
    final SettingsContext settingsContext = createSettingsContext(
      appModel: appModel,
      ref: ref,
    );
    final SettingsDestination destination = buildReaderQuickSettingsDestination(
      settingsContext,
    );
    final SettingsRenderer renderer = resolveSettingsRenderer(context);
    final Widget detailContent = renderer.buildDetailContent(
      settingsContext: settingsContext,
      destination: destination,
      scrollController: _contentScrollController,
      // 渲染器的详情是可滚动 ListView（BUG-009 R1），由 ListView 自身
      // （controller=_contentScrollController）滚动；在此弹窗里收缩到内容高。
      shrinkWrap: true,
    );

    return SizedBox(
      width: double.maxFinite,
      child: FushiScrollbar(
        controller: _contentScrollController,
        child: PrimaryScrollController(
          controller: _contentScrollController,
          child: detailContent,
        ),
      ),
    );
  }
}

// ─── Full-page version (home "调整" tab) ──────────────────────────────────────

class FushiSettingsContent extends StatelessWidget {
  const FushiSettingsContent({super.key});

  @override
  Widget build(BuildContext context) {
    return const SettingsHomePage(embedded: true);
  }
}
