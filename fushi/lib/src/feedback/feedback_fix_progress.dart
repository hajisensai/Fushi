// 反馈修复的「发布进度」：服务端只告诉我们修复 commit 已进了哪些通道 / 平台的哪个构建
// （FeedbackFix.releases，由 CI 回填），这里按用户当前更新通道 + 本机平台 + 本机版本
// 算出该给反馈人看哪句话、给哪个按钮。规则真相源：docs/specs/2026-10-08-feedback.md。
//
// 版本比较一律复用更新器的判据（channelForUpdateVersion / updateTagIsNewerThanCurrent），
// 不另写一套：同一个版本串在「检查更新」和这里必须得出同一个先后。

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/updates/app_update_check.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';

/// 「正在打包」的窗口：debug 通道每次 push 都出包，标记后这段时间内还没回填多半是在构建。
const Duration kFeedbackFixBuildingWindow = Duration(hours: 3);

/// 修复对本机的进度（[feedbackFixProgress] 的结果）。
sealed class FeedbackFixProgress {
  const FeedbackFixProgress();
}

/// 修复不需要更新 App（例如只改了服务端）。
class FeedbackFixNoUpdateNeeded extends FeedbackFixProgress {
  const FeedbackFixNoUpdateNeeded();
}

/// 本机正在跑的构建已包含修复。
class FeedbackFixInstalled extends FeedbackFixProgress {
  const FeedbackFixInstalled(this.version);

  /// 本机构建所属通道里第一个包含修复的版本。
  final String version;
}

/// 用户当前通道能收到的构建里已有包含修复的，本机还没装（给「检查更新」）。
class FeedbackFixUpdateAvailable extends FeedbackFixProgress {
  const FeedbackFixUpdateAvailable(this.version);

  final String version;
}

/// 只有比用户当前通道更快的通道发布了（给「切换到 [channel] 通道」）。
class FeedbackFixFasterChannelOnly extends FeedbackFixProgress {
  const FeedbackFixFasterChannelOnly({
    required this.current,
    required this.channel,
    required this.version,
  });

  /// 用户当前的更新通道（stable / beta）。
  final UpdateChannel current;

  /// 已发布的更快通道（beta / debug）。
  final UpdateChannel channel;
  final String version;
}

/// 本机平台不在官方发布回填范围内（[kFeedbackReleasePlatforms] 之外，例如只能源码构建的
/// Linux）：没有任何构建会回填它，说「等待下个版本」会让反馈人永远等下去。
class FeedbackFixPlatformNotTracked extends FeedbackFixProgress {
  const FeedbackFixPlatformNotTracked();
}

/// 还没有任何本平台构建包含修复。
class FeedbackFixPending extends FeedbackFixProgress {
  const FeedbackFixPending({required this.channel, required this.building});

  /// 用户当前的更新通道（文案里 stable 说「等待下个正式版」）。
  final UpdateChannel channel;

  /// debug 通道且刚标记不久：CI 多半正在打包。
  final bool building;
}

/// 官方发布 workflow 会回填的平台（`release.yml`：android；`release-desktop.yml`：
/// windows / macos / ios，各自的 `PLATFORM:`）。Linux App 只能从源码构建，CI 不出包，
/// 没有任何回填——不在这里。键与 `Platform.operatingSystem` 同形；与 workflow 的一致性
/// 由 `test/feedback/feedback_fix_progress_test.dart` 钉死。
const Set<String> kFeedbackReleasePlatforms = <String>{
  'android',
  'windows',
  'macos',
  'ios',
};

/// **纯函数**：[operatingSystem]（`Platform.operatingSystem` 口径）在发布回填里的键；
/// 不在 [kFeedbackReleasePlatforms] 里返回 null（没有任何构建会回填它）。
String? feedbackPlatformKeyFor(String operatingSystem) =>
    kFeedbackReleasePlatforms.contains(operatingSystem)
    ? operatingSystem
    : null;

/// 本机平台在发布回填里的键（[feedbackPlatformKeyFor]）。
String? feedbackPlatformKey() =>
    feedbackPlatformKeyFor(Platform.operatingSystem);

/// 用户在 [channel] 下能收到哪些通道的构建（与更新器的嵌套合集同一口径：越激进的通道
/// 合集越大），自己的通道排第一。
List<UpdateChannel> _admittedBy(UpdateChannel channel) => switch (channel) {
  UpdateChannel.stable => const <UpdateChannel>[UpdateChannel.stable],
  UpdateChannel.beta => const <UpdateChannel>[
    UpdateChannel.beta,
    UpdateChannel.stable,
  ],
  UpdateChannel.debug => const <UpdateChannel>[
    UpdateChannel.debug,
    UpdateChannel.beta,
    UpdateChannel.stable,
  ],
};

/// 比 [channel] 更快的通道，最快的在前。
List<UpdateChannel> _fasterThan(UpdateChannel channel) => switch (channel) {
  UpdateChannel.stable => const <UpdateChannel>[
    UpdateChannel.debug,
    UpdateChannel.beta,
  ],
  UpdateChannel.beta => const <UpdateChannel>[UpdateChannel.debug],
  UpdateChannel.debug => const <UpdateChannel>[],
};

/// [fix] 在 [channel] / [platform] 下的发布；版本串不属于该通道的条目当没有
/// （跨通道的版本串不互相比较，CI 写错了也不能把调试版当正式版用）。
FeedbackRelease? _releaseIn(
  FeedbackFix fix,
  UpdateChannel channel,
  String platform,
) {
  final FeedbackRelease? r = fix.release(channel.name, platform);
  if (r == null || channelForUpdateVersion(r.version) != channel) return null;
  return r;
}

/// **纯函数**：[fix] 对本机意味着什么。
///
/// * [channel]：用户当前选的更新通道（[appUpdateChannelOf]）。
/// * [platform]：[feedbackPlatformKey]；null 表示本平台没有构建回填
///   （→ [FeedbackFixPlatformNotTracked]，不说「等待下个版本」）。
/// * [localVersion]：本机构建版本（[resolveCurrentAppVersion] 口径）；null / 空串表示
///   未知，此时不判「已包含」。本机构建属于哪个通道由它的版本串决定，只和该通道的
///   那条发布比较。
/// * [now]：毫秒时刻。
FeedbackFixProgress feedbackFixProgress(
  FeedbackFix fix, {
  required UpdateChannel channel,
  required String? platform,
  required String? localVersion,
  required int now,
}) {
  if (fix.scope == FeedbackFixScope.none) {
    return const FeedbackFixNoUpdateNeeded();
  }
  if (platform == null) return const FeedbackFixPlatformNotTracked();
  final String local = localVersion?.trim() ?? '';
  if (local.isNotEmpty) {
    final UpdateChannel localChannel = channelForUpdateVersion(local);
    final FeedbackRelease? own = _releaseIn(fix, localChannel, platform);
    if (own != null &&
        !updateTagIsNewerThanCurrent(own.version, local, localChannel)) {
      return FeedbackFixInstalled(own.version);
    }
  }
  for (final UpdateChannel c in _admittedBy(channel)) {
    final FeedbackRelease? r = _releaseIn(fix, c, platform);
    if (r != null) return FeedbackFixUpdateAvailable(r.version);
  }
  for (final UpdateChannel c in _fasterThan(channel)) {
    final FeedbackRelease? r = _releaseIn(fix, c, platform);
    if (r != null) {
      return FeedbackFixFasterChannelOnly(
        current: channel,
        channel: c,
        version: r.version,
      );
    }
  }
  return FeedbackFixPending(
    channel: channel,
    building:
        channel == UpdateChannel.debug &&
        // 本机时钟比服务端慢时差值为负，也算刚标记。
        now - fix.at < kFeedbackFixBuildingWindow.inMilliseconds,
  );
}

/// 反馈页算进度、执行「检查更新」/「切换通道」需要的本机环境。页面测试覆盖
/// [feedbackFixEnvironmentProvider] 注入假环境，不用起真 AppModel。
class FeedbackFixEnvironment {
  const FeedbackFixEnvironment({
    required this.channel,
    required this.platform,
    required this.localVersion,
    required this.canSwitchChannel,
    required this.checkForUpdate,
    required this.switchChannel,
  });

  /// 现取（切换通道后要立刻反映）。
  final UpdateChannel Function() channel;
  final String? platform;
  final String? localVersion;

  /// 本平台能不能在设置里切换更新通道。
  final bool canSwitchChannel;

  /// 手动「检查更新」（与设置页同一个入口）。
  final Future<void> Function(BuildContext context) checkForUpdate;

  /// 写入更新通道（与设置页同一条写入路径 [applyUpdateChannel]）。确认框由页面先问。
  final Future<void> Function(UpdateChannel channel) switchChannel;

  FeedbackFixProgress progress(FeedbackFix fix, {DateTime? now}) =>
      feedbackFixProgress(
        fix,
        channel: channel(),
        platform: platform,
        localVersion: localVersion,
        now: (now ?? DateTime.now()).millisecondsSinceEpoch,
      );
}

final Provider<FeedbackFixEnvironment> feedbackFixEnvironmentProvider =
    Provider<FeedbackFixEnvironment>((Ref ref) {
      final AppModel app = ref.read(appProvider);
      return FeedbackFixEnvironment(
        channel: () => appUpdateChannelOf(app),
        platform: feedbackPlatformKey(),
        localVersion: resolveCurrentAppVersion(app.packageInfo.version),
        canSwitchChannel: platformSupportsUpdateCheck(),
        checkForUpdate: (BuildContext context) =>
            checkAppUpdateNow(context, app),
        switchChannel: (UpdateChannel channel) =>
            applyUpdateChannel(app, channel.name),
      );
    });
