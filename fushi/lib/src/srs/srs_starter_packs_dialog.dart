/// 复习（SRS）「入门卡组」对话框：列出内置清单里的预置卡组（来源 / 许可 / 卡数 / 体积），
/// 点「下载并导入」走 [SrsStarterPackController]（判重、进度、取消），下完进后台导入队列。
///
/// 入口：空牌组卡片的「入门卡组」按钮、牌组列表「导入」的来源选择。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/starter/srs_starter_packs.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_starter_pack_controller.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart';
import 'package:fushi/src/utils/components/fushi_animated_size.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 清单 → 展示顺序：默认内容语言的包排前（没设置就按语言、名字）。
List<SrsStarterPack> srsStarterPacksFor(String defaultContentLanguage) {
  final String primary = defaultContentLanguage.split('-').first;
  return sortSrsStarterPacks(
    kSrsStarterPacks,
    preferredLanguages: <String>[if (primary.isNotEmpty) primary],
  );
}

/// 许可一行的文字。
String srsStarterLicenseLabel(SrsStarterPack pack) => t.srs_starter_license(
  license: pack.license == kSrsStarterLicenseUnspecified
      ? t.srs_starter_license_unspecified
      : pack.license,
);

/// 「添加」结果 → 提示（开始导入的提示由导入队列自己弹，这里不重复）。
void showSrsStarterInstallToast(
  SrsStarterInstallResult result,
  SrsStarterPackState state,
) {
  switch (result) {
    case SrsStarterInstallResult.started:
      FushiToast.show(msg: t.srs_import_background_started);
    case SrsStarterInstallResult.alreadyInstalled:
      FushiToast.show(msg: t.srs_starter_already_added);
    case SrsStarterInstallResult.failed:
      FushiToast.show(
        msg: t.srs_starter_failed(error: '${state.error ?? ''}'),
        severity: ToastSeverity.error,
      );
    case SrsStarterInstallResult.busy:
    case SrsStarterInstallResult.cancelled:
      break;
  }
}

/// 打开「入门卡组」对话框。
Future<void> openSrsStarterPacks(BuildContext context, WidgetRef ref) {
  final List<SrsStarterPack> packs = srsStarterPacksFor(
    ref.read(appProvider).defaultContentLanguage,
  );
  final SrsStarterPackController controller = ref.read(
    srsStarterPackControllerProvider,
  );
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.cloudDownload),
      title: Text(t.srs_starter_title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(t.srs_starter_body),
              const SizedBox(height: 12),
              if (packs.isEmpty)
                Text(t.srs_starter_empty)
              else
                FushiEntranceScope(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int i = 0; i < packs.length; i++)
                        FushiStaggeredEntrance(
                          key: ValueKey<String>(
                            'srs-starter-entry-${packs[i].id}',
                          ),
                          index: i,
                          child: FushiGroupedListItem(
                            index: i,
                            count: packs.length,
                            child: SrsStarterPackRow(
                              pack: packs[i],
                              controller: controller,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_close,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    ),
  );
}

/// 一个预置包一行：名称 + 状态 / 语言 · 卡数 · 体积 / 来源 / 许可 / 进度 / 动作。
class SrsStarterPackRow extends StatelessWidget {
  const SrsStarterPackRow({
    super.key,
    required this.pack,
    required this.controller,
  });

  final SrsStarterPack pack;
  final SrsStarterPackController controller;

  Future<void> _install() async {
    final SrsStarterInstallResult result = await controller.install(pack);
    showSrsStarterInstallToast(result, controller.stateOf(pack.id));
  }

  Widget _action(SrsStarterPackState state) {
    return switch (state.phase) {
      SrsStarterPackPhase.downloading => FushiPressScale(
        child: FushiTextButton.icon(
          key: ValueKey<String>('srs-starter-cancel-${pack.id}'),
          onPressed: () => controller.cancel(pack.id),
          icon: const FushiIcon(FushiIcons.close, size: 18),
          label: Text(t.cancel),
        ),
      ),
      SrsStarterPackPhase.importing => FushiTag(
        key: ValueKey<String>('srs-starter-importing-${pack.id}'),
        text: t.srs_starter_importing,
        icon: FushiIcons.downloading,
        tone: FushiTagTone.accent,
        dense: true,
      ),
      SrsStarterPackPhase.idle || SrsStarterPackPhase.failed => FushiPressScale(
        child: FushiFilledButton.icon(
          key: ValueKey<String>('srs-starter-add-${pack.id}'),
          onPressed: _install,
          icon: const FushiIcon(FushiIcons.download, size: 18),
          label: Text(t.srs_starter_add),
        ),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final FushiMotionScheme motion = context.fushiMotion;
    final TextStyle secondary = type.bodyMedium.copyWith(
      color: cs.onSurfaceVariant,
    );
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, Widget? _) {
        final SrsStarterPackState state = controller.stateOf(pack.id);
        return Padding(
          key: ValueKey<String>('srs-starter-row-${pack.id}'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                pack.name,
                style: type.titleMediumEmphasized,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                t.srs_starter_meta(
                  language: contentLanguageLabelOf(pack.language),
                  cards: pack.cardCount,
                  size: FushiByteFormat.bytes(pack.sizeBytes),
                ),
                style: secondary,
              ),
              Text(
                t.srs_starter_source(
                  source: pack.source,
                  version: pack.version,
                ),
                style: secondary,
              ),
              Text(srsStarterLicenseLabel(pack), style: secondary),
              FushiAnimatedSize(
                duration: motion.spatialDefault.duration,
                curve: motion.spatialDefault.curve,
                alignment: Alignment.topCenter,
                child: switch (state.phase) {
                  SrsStarterPackPhase.downloading => Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        FushiLinearProgressIndicator(value: state.fraction),
                        const SizedBox(height: 6),
                        Text(
                          t.srs_starter_downloading(
                            received: FushiByteFormat.bytes(state.received),
                            total: FushiByteFormat.bytes(state.total),
                          ),
                          style: type.bodySmall.tabular.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SrsStarterPackPhase.failed => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      t.srs_starter_failed(error: '${state.error ?? ''}'),
                      style: type.bodySmall.copyWith(color: cs.error),
                    ),
                  ),
                  _ => const SizedBox(width: double.infinity),
                },
              ),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: _action(state),
              ),
            ],
          ),
        );
      },
    );
  }
}
