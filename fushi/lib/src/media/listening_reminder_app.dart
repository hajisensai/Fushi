/// 连续收听提醒的装配：「谁在播」取音乐会话 / 有声书会话 / 打开着的视频页（与第二块屏
/// 的「正在播放」同一组来源），到点时应用在前台 → 应用内对话框（继续听 / 暂停播放 /
/// 关闭提醒），不在前台（后台听书、桌面最小化）→ 系统通知（权限没给就静默）。
/// 计时口径与调度见 `listening_reminder.dart`。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/listening_reminder.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/second_screen/companion/modules/video_companion_now_playing.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 一个播放器对提醒暴露的两件事：在不在出声、怎么暂停。
class ListeningReminderPlayer {
  const ListeningReminderPlayer({required this.isPlaying, required this.pause});

  final bool Function() isPlaying;
  final Future<void> Function() pause;
}

/// 应用里会出声的播放器：音乐会话、有声书会话、最上层打开着的视频页（与第二块屏的
/// 「正在播放」同一组来源）。
class ListeningReminderPlayers {
  const ListeningReminderPlayers(this.players);

  /// 从 AppModel 的进程级会话 + 视频页登记表取（每次现取：会话里的控制器会换）。
  factory ListeningReminderPlayers.of(
    AppModel app, {
    CompanionVideoPlaybackRegistry? video,
  }) {
    final CompanionVideoPlaybackRegistry registry =
        video ?? companionVideoPlayback;
    return ListeningReminderPlayers(<ListeningReminderPlayer>[
      ListeningReminderPlayer(
        isPlaying: () => app.musicSession.engine.isPlaying,
        pause: () => app.musicSession.engine.pause(),
      ),
      ListeningReminderPlayer(
        isPlaying: () => app.audiobookSession.controller?.isPlaying ?? false,
        pause: () async => app.audiobookSession.controller?.pause(),
      ),
      ListeningReminderPlayer(
        isPlaying: () => registry.current?.playing() ?? false,
        pause: () async => registry.current?.toggle(),
      ),
    ]);
  }

  final List<ListeningReminderPlayer> players;

  bool get anyPlaying =>
      players.any((ListeningReminderPlayer p) => p.isPlaying());

  /// 暂停所有在播的播放器（对话框「暂停播放」）；没在播的不碰（视频只有切换口）。
  Future<void> pauseAll() async {
    for (final ListeningReminderPlayer p in players) {
      if (p.isPlaying()) await p.pause();
    }
  }
}

/// 对话框里用户选了什么。
enum ListeningReminderChoice { keepListening, pause, turnOff }

/// 应用级提醒服务。在主 app 首页就绪后 `start()`（main.dart），弹窗词典等别的入口
/// 不经这里。
final Provider<ListeningReminderService> listeningReminderProvider =
    Provider<ListeningReminderService>((Ref ref) {
      final AppModel app = ref.read(appProvider);
      final ListeningReminderPlayers players = ListeningReminderPlayers.of(app);
      final ListeningReminderService service = ListeningReminderService(
        enabled: () => app.listeningReminderEnabled,
        threshold: () => Duration(minutes: app.listeningReminderMinutes),
        isPlaying: () => players.anyPlaying,
        onReminder: () => _deliverListeningReminder(app, players),
        settings: app.prefsRepo,
      );
      ref.onDispose(service.dispose);
      return service;
    });

bool _dialogOpen = false;

Future<void> _deliverListeningReminder(
  AppModel app,
  ListeningReminderPlayers players,
) async {
  final int minutes = app.listeningReminderMinutes;
  final bool foreground =
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  final BuildContext? context = app.navigatorKey.currentContext;
  if (foreground && context != null && context.mounted) {
    // 上一条还没关就不叠第二个框。
    if (_dialogOpen) return;
    _dialogOpen = true;
    try {
      final ListeningReminderChoice? choice = await showListeningReminderDialog(
        context,
        minutes: minutes,
      );
      await applyListeningReminderChoice(
        choice,
        players: players,
        turnOff: () => app.setListeningReminderEnabled(value: false),
      );
    } finally {
      _dialogOpen = false;
    }
    return;
  }
  await postListeningReminderNotification(app.systemNotifier, minutes: minutes);
}

/// 执行对话框的选择（关掉 / 点遮罩 = 继续听）。
Future<void> applyListeningReminderChoice(
  ListeningReminderChoice? choice, {
  required ListeningReminderPlayers players,
  required Future<void> Function() turnOff,
}) async {
  switch (choice) {
    case ListeningReminderChoice.pause:
      await players.pauseAll();
    case ListeningReminderChoice.turnOff:
      await turnOff();
    case ListeningReminderChoice.keepListening:
    case null:
      return;
  }
}

/// 应用不在前台时的系统通知。通知后端没就绪 / 没权限就不发（不在这里申请权限：
/// 权限只在用户打开开关时申请，见设置项）。
Future<void> postListeningReminderNotification(
  UpdateNotifier notifier, {
  required int minutes,
}) async {
  if (!await notifier.ensureReady()) return;
  if (!await notifier.hasPermission()) return;
  await notifier.notify(
    UpdateNotification(
      id: kListeningReminderNotificationId,
      title: t.listening_reminder_notice_title,
      body: t.listening_reminder_notice_body(minutes: minutes),
      payload: kListeningReminderNotificationPayload,
      grouped: false,
    ),
  );
}

/// 应用内提醒对话框。
Future<ListeningReminderChoice?> showListeningReminderDialog(
  BuildContext context, {
  required int minutes,
}) {
  return showAppDialog<ListeningReminderChoice>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      icon: const FushiDialogHeroIcon(
        icon: FushiIcons.audiobook,
        tone: FushiHeroTone.neutral,
      ),
      title: Text(t.listening_reminder_notice_title),
      content: Text(t.listening_reminder_notice_body(minutes: minutes)),
      actions: <Widget>[
        FushiDialogAction(
          label: t.listening_reminder_action_turn_off,
          onPressed: () =>
              Navigator.of(dialogContext).pop(ListeningReminderChoice.turnOff),
        ),
        FushiDialogAction(
          label: t.listening_reminder_action_pause,
          onPressed: () =>
              Navigator.of(dialogContext).pop(ListeningReminderChoice.pause),
        ),
        FushiDialogAction(
          label: t.listening_reminder_action_continue,
          kind: FushiDialogActionKind.primary,
          autofocus: true,
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(ListeningReminderChoice.keepListening),
        ),
      ],
    ),
  );
}

/// 用户在设置里打开提醒：顺带申请通知权限（后台收听时靠系统通知提醒）。这是用户的
/// 显式动作，可以弹系统权限框（BUG-2498 的口径）。
Future<void> enableListeningReminder(
  AppModel app, {
  required bool value,
}) async {
  await app.setListeningReminderEnabled(value: value);
  if (!value) return;
  final UpdateNotifier notifier = app.systemNotifier;
  if (!await notifier.ensureReady()) return;
  if (await notifier.hasPermission()) return;
  await notifier.requestPermission();
}
