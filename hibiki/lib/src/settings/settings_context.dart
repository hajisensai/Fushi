import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/video_settings_host.dart';

class SettingsContext {
  const SettingsContext({
    required this.context,
    required this.appModel,
    required this.ref,
    required this.readerSource,
    required this.refresh,
    this.video,
  });

  final BuildContext context;
  final AppModel appModel;
  final WidgetRef ref;
  final ReaderHibikiSource readerSource;
  final VoidCallback refresh;

  /// 视频播放上下文能力槽；null = 不在视频播放页（全局设置）。
  final VideoSettingsHost? video;

  ReaderSettings? get readerSettings => ReaderHibikiSource.readerSettings;
}

/// 设置宿主（State）统一构造 [SettingsContext] 的入口：readerSource 恒为单例、
/// refresh 恒为「mounted 时 setState」——四个宿主此前逐字重复这段样板。
/// [beforeRefresh] 在 setState 前执行额外联动（如阅读器面板主题行的
/// `_syncThemeSelection`）。
mixin SettingsContextHost<T extends StatefulWidget> on State<T> {
  SettingsContext createSettingsContext({
    required AppModel appModel,
    required WidgetRef ref,
    VoidCallback? beforeRefresh,
    VideoSettingsHost? video,
  }) {
    return SettingsContext(
      context: context,
      appModel: appModel,
      ref: ref,
      readerSource: ReaderHibikiSource.instance,
      refresh: () {
        if (!mounted) return;
        beforeRefresh?.call();
        setState(() {});
      },
      video: video,
    );
  }
}
