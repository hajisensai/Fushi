/// 系统 OCR 模型配置弹窗（BUG-2906）。
///
/// 识别报「模型未就绪」时，只丢一句提示是死胡同——用户不知道模型归谁管、该去哪配。
/// 这里把它变成可操作的一步：先查状态，缺模型就请 Google Play 服务立即下载；Play
/// 服务本身有问题的，能修的给系统修复入口，修不了的如实说。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiDialogHeroIcon, FushiHeroTone;
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 弹出系统 OCR 模型配置。弹窗打开时自己查一次状态。
Future<void> showSystemOcrSetupDialog(
  BuildContext context, {
  required String language,
  SystemOcrModelSetup setup = const MethodChannelSystemOcr(),
}) => showAppDialog<void>(
  context: context,
  builder: (BuildContext context) =>
      SystemOcrSetupDialog(language: language, setup: setup),
);

/// 弹窗所处的阶段。
enum SystemOcrSetupPhase {
  checking,
  missing,
  downloading,
  ready,
  failed,
  playServicesResolvable,
  playServicesUnavailable,
}

/// 由模型状态得出弹窗阶段。
SystemOcrSetupPhase systemOcrSetupPhaseFor(SystemOcrModelStatus status) =>
    switch (status) {
      SystemOcrModelStatus.ready => SystemOcrSetupPhase.ready,
      SystemOcrModelStatus.missing => SystemOcrSetupPhase.missing,
      SystemOcrModelStatus.playServicesResolvable =>
        SystemOcrSetupPhase.playServicesResolvable,
      SystemOcrModelStatus.playServicesUnavailable =>
        SystemOcrSetupPhase.playServicesUnavailable,
    };

class SystemOcrSetupDialog extends StatefulWidget {
  const SystemOcrSetupDialog({
    super.key,
    required this.language,
    required this.setup,
  });

  final String language;
  final SystemOcrModelSetup setup;

  @override
  State<SystemOcrSetupDialog> createState() => _SystemOcrSetupDialogState();
}

class _SystemOcrSetupDialogState extends State<SystemOcrSetupDialog> {
  SystemOcrSetupPhase _phase = SystemOcrSetupPhase.checking;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  void _set(SystemOcrSetupPhase phase, [String error = '']) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _error = error;
    });
  }

  Future<void> _check() async {
    _set(SystemOcrSetupPhase.checking);
    try {
      final SystemOcrModelStatus status = await widget.setup.modelStatus(
        widget.language,
      );
      _set(systemOcrSetupPhaseFor(status));
    } catch (error) {
      _set(SystemOcrSetupPhase.failed, _describe(error));
    }
  }

  Future<void> _download() async {
    _set(SystemOcrSetupPhase.downloading);
    try {
      await widget.setup.installModel(widget.language);
      _set(SystemOcrSetupPhase.ready);
    } catch (error) {
      _set(SystemOcrSetupPhase.failed, _describe(error));
    }
  }

  Future<void> _fixPlayServices() async {
    await widget.setup.resolvePlayServices();
    // 不管系统对话框怎么收场，以重新查到的状态为准。
    await _check();
  }

  static String _describe(Object error) => error is PlatformException
      ? (error.message ?? error.code)
      : error.toString();

  @override
  Widget build(BuildContext context) {
    final bool busy =
        _phase == SystemOcrSetupPhase.checking ||
        _phase == SystemOcrSetupPhase.downloading;
    final String message = switch (_phase) {
      SystemOcrSetupPhase.checking => t.ocr_system_model_checking,
      SystemOcrSetupPhase.missing => t.ocr_system_model_missing,
      SystemOcrSetupPhase.downloading => t.ocr_system_model_downloading,
      SystemOcrSetupPhase.ready => t.ocr_system_model_ready,
      SystemOcrSetupPhase.failed => t.ocr_system_model_failed(error: _error),
      SystemOcrSetupPhase.playServicesResolvable =>
        t.ocr_system_model_play_services_resolvable,
      SystemOcrSetupPhase.playServicesUnavailable =>
        t.ocr_system_model_play_services_unavailable,
    };
    final Widget? primary = switch (_phase) {
      SystemOcrSetupPhase.missing => FushiFilledButton(
        key: const ValueKey<String>('system_ocr_setup_download'),
        onPressed: () => unawaited(_download()),
        child: Text(t.ocr_system_model_download),
      ),
      SystemOcrSetupPhase.failed => FushiFilledButton(
        key: const ValueKey<String>('system_ocr_setup_retry'),
        onPressed: () => unawaited(_check()),
        child: Text(t.retry),
      ),
      SystemOcrSetupPhase.playServicesResolvable => FushiFilledButton(
        key: const ValueKey<String>('system_ocr_setup_fix_play_services'),
        onPressed: () => unawaited(_fixPlayServices()),
        child: Text(t.ocr_system_model_play_services_fix),
      ),
      _ => null,
    };
    final _StatusTone tone = switch (_phase) {
      SystemOcrSetupPhase.ready => _StatusTone.success,
      SystemOcrSetupPhase.failed ||
      SystemOcrSetupPhase.playServicesUnavailable => _StatusTone.error,
      SystemOcrSetupPhase.missing ||
      SystemOcrSetupPhase.playServicesResolvable => _StatusTone.attention,
      _ => _StatusTone.neutral,
    };
    return FushiAlertDialog(
      // M3E：饼干形 hero 图标按阶段换色（错误 = errorContainer）。
      icon: FushiDialogHeroIcon(
        icon: FushiIcons.ocr,
        tone: tone == _StatusTone.error
            ? FushiHeroTone.destructive
            : (tone == _StatusTone.success
                  ? FushiHeroTone.primary
                  : FushiHeroTone.neutral),
      ),
      title: Text(t.ocr_system_model_title),
      content: _StatusBlock(tone: tone, busy: busy, message: message),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_close),
        ),
        if (primary != null) primary,
      ],
    );
  }
}

enum _StatusTone { neutral, attention, success, error }

/// 当前阶段的状态块：M3E tonal 色块（检查中 / 下载中 = 中性，缺模型 / 可修复 =
/// tertiaryContainer，就绪 = primaryContainer，失败 = errorContainer），阶段切换时
/// 底色走 effects 弹簧过渡、高度走 spatial 弹簧；左侧是进度环或语义图标。
class _StatusBlock extends StatelessWidget {
  const _StatusBlock({
    required this.tone,
    required this.busy,
    required this.message,
  });

  final _StatusTone tone;
  final bool busy;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool glass = isGlassDesign(context);
    final (Color bg, Color fg) = glass
        ? (Colors.transparent, cs.onSurface)
        : switch (tone) {
            _StatusTone.neutral => (
              cs.secondaryContainer,
              cs.onSecondaryContainer,
            ),
            _StatusTone.attention => (
              cs.tertiaryContainer,
              cs.onTertiaryContainer,
            ),
            _StatusTone.success => (cs.primaryContainer, cs.onPrimaryContainer),
            _StatusTone.error => (cs.errorContainer, cs.onErrorContainer),
          };
    final IconData icon = switch (tone) {
      _StatusTone.success => FushiIcons.success,
      _StatusTone.error => FushiIcons.error,
      _StatusTone.attention => FushiIcons.download,
      _StatusTone.neutral => FushiIcons.info,
    };
    final FushiMotionScheme motion = context.fushiMotion;
    return AnimatedSize(
      duration: motion.spatialDefault.duration,
      curve: motion.spatialDefault.curve,
      alignment: Alignment.topCenter,
      child: AnimatedContainer(
        duration: motion.effectsDefault.duration,
        curve: motion.effectsDefault.curve,
        padding: glass ? EdgeInsets.zero : const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: FushiM3eShape.cardRadius,
        ),
        child: Row(
          children: <Widget>[
            if (busy)
              const SizedBox.square(
                dimension: 24,
                child: FushiCircularProgressIndicator(strokeWidth: 3),
              )
            else
              FushiIcon(icon, size: 24, color: fg),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                message,
                key: const ValueKey<String>('system_ocr_setup_message'),
                style: TextStyle(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
