/// AI 库管家的自动路径（spec `docs/specs/2026-11-18-ai-library-curator-design.md` §9）：
/// 入库 / 扫描后去抖跑一趟。**默认关**（用户 2026-11-26）：只有用户自己打开
/// `library_curate_auto` 后才自动跑，默认只有手动触发。
///
/// 触发点是各库页重载 / 来源扫描（[scheduleAutomaticLibraryCurate]），它们只表示
/// 「库可能变了」——书架连阅读进度、合集变化都会重载。真正的「有没有新内容」由
/// 编排器的 [LibraryCurator.runAuto] 按库变化戳判断，没有就什么都不做（BUG-5531）。
///
/// **这是 import 叶子**：只依赖引擎，不 import `package:fushi` 的任何文件——
/// `AppModel` 与库整理 runner（都在 app 的 import 大环里）要 import 它，它再往回
/// 依赖就会把自己拖进大环（`test/build/import_cycle_guard_test.dart`）。编排器本身
/// （要用操作目录、AI 工具箱）由 `library_curate_host.dart` 组装，经
/// [registerLibraryCuratorProvider] 在根组件登记操作上下文时注入进来。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_engine/ai/ai_library_organize_assistant.dart';
import 'package:fushi_engine/ai/ai_media_link_assistant.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/ai/ai_video_identity_assistant.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/library_curate/library_curator.dart';

/// 各步自己的 AI 指派此刻是否可用（AI 模块关了全按没指派算）。
LibraryCurateAiAvailability libraryCurateAiOf(
  AiSettingsSource prefs, {
  required bool aiModuleEnabled,
}) => aiModuleEnabled
    ? (
        organize: resolveLibraryOrganizeAiProvider(prefs) != null,
        videoIdentify:
            PreferencesAiVideoIdentityAdvisor(prefs).capabilityKey != null,
        mediaLinks: resolveMediaLinkAiProvider(prefs) != null,
      )
    : kLibraryCurateNoAi;

LibraryCurator? Function()? _curatorProvider;

/// 根组件登记操作上下文时注入「拿进程级编排器」的函数（`main.dart`）。
void registerLibraryCuratorProvider(LibraryCurator? Function()? provider) =>
    _curatorProvider = provider;

/// 进程级编排器；根组件还没登记时为 null。
LibraryCurator? appLibraryCurator() => _curatorProvider?.call();

final StreamController<LibraryCurateRun> _appRunFinished =
    StreamController<LibraryCurateRun>.broadcast();
StreamSubscription<LibraryCurateRun>? _relaySub;
LibraryCurator? _relayed;

/// 进程级「库管家一趟结束」（含单条重试、撤销）。始终跟着**当前**编排器：编排器
/// 重建（操作上下文换了）后由 [relayLibraryCuratorRuns] 改挂新实例，订阅方不用
/// 重订，也不会在编排器还没建出来时漏订。
Stream<LibraryCurateRun> get appLibraryCuratorRunFinished =>
    _appRunFinished.stream;

/// 编排器建出 / 换掉时调（`library_curate_host.dart`）：把它的 `runFinished` 转进
/// [appLibraryCuratorRunFinished]，旧实例的转发同时取消。
void relayLibraryCuratorRuns(LibraryCurator? curator) {
  if (identical(curator, _relayed)) return;
  _relayed = curator;
  unawaited(_relaySub?.cancel());
  _relaySub = curator?.runFinished.listen(_appRunFinished.add);
}

/// 自动路径的装配（主进程 `AppModel.initialise()` 里装一次；弹窗 / 悬浮词典进程
/// 不装 = 自动路径什么都不做）。
class LibraryCurateAutoHost {
  const LibraryCurateAutoHost({
    required this.settings,
    required this.autoOn,
    required this.aiModuleEnabled,
    this.curator = appLibraryCurator,
  });

  /// AI 指派（偏好仓库）。
  final AiSettingsSource settings;

  /// 偏好 `library_curate_auto`（默认关，用户自己打开才自动跑）。
  final bool Function() autoOn;
  final bool Function() aiModuleEnabled;

  /// 拿编排器（为 null：这一次不跑）。
  final LibraryCurator? Function() curator;
}

LibraryCurateAutoHost? _autoHost;
Timer? _debounce;

/// 去抖：连续导入 / 扫描合成一趟（与旧的自动整理同一形态）。
const Duration kLibraryCurateAutoDebounce = Duration(seconds: 30);

void installLibraryCurateAutomatic(LibraryCurateAutoHost? host) {
  _autoHost = host;
  _debounce?.cancel();
  _debounce = null;
}

/// 自动路径此刻接管入库后的自动任务吗：装了宿主且开关开着（默认关）。接管时旧的
/// 「导入后自动整理」不再单独跑——库管家第一阶段就是同一个整理（两套自动任务不
/// 重复跑）。
bool libraryCurateAutoOwnsTriggers() =>
    _autoHost != null && _autoHost!.autoOn();

/// spec §9：开关开着也只对已经配了提供商的用户生效——三步一个 AI 都没指派时自动
/// 路径什么都不跑。
bool _autoEnabled(LibraryCurateAutoHost? host) {
  if (host == null || !host.autoOn()) return false;
  final LibraryCurateAiAvailability ai = libraryCurateAiOf(
    host.settings,
    aiModuleEnabled: host.aiModuleEnabled(),
  );
  return ai.organize || ai.videoIdentify || ai.mediaLinks;
}

/// 流水线之后的 AI 助手自动复查（spec `docs/specs/2026-11-22-ai-library-agent-design.md`
/// §7）。实现（`library_agent_review.dart`）要用操作上下文、在 import 大环外，经
/// [registerLibraryAgentAutoReviewer] 注入。
abstract interface class LibraryAgentAutoReviewer {
  /// 开关开着、AI 模块开着、「AI 助手」指派了提供商。
  bool get enabled;

  /// 复查一次（内部判断增量 / 全库 / 不必跑；失败自己记日志，不抛）。
  Future<void> review();
}

LibraryAgentAutoReviewer? Function()? _reviewerProvider;

/// 根组件登记操作上下文时注入（`main.dart`）。
void registerLibraryAgentAutoReviewer(
  LibraryAgentAutoReviewer? Function()? provider,
) => _reviewerProvider = provider;

LibraryAgentAutoReviewer? _reviewer() {
  final LibraryAgentAutoReviewer? r = _reviewerProvider?.call();
  return r != null && r.enabled ? r : null;
}

/// 入库 / 来源扫描 / 库页加载后调：去抖后跑一趟（只看上一趟之后的新条目），再交 AI
/// 助手复查。不阻塞调用方。
void scheduleAutomaticLibraryCurate() {
  if (!_autoEnabled(_autoHost) && _reviewer() == null) return;
  _debounce?.cancel();
  _debounce = Timer(
    kLibraryCurateAutoDebounce,
    () => unawaited(runAutomaticLibraryCurate()),
  );
}

/// 跑一趟自动路径（去抖到点后调；测试直接调）：先跑库管家流水线（便宜、证据硬的
/// 部分），再交 AI 助手复查（全局判断）。手动整理正在跑时这一次整体跳过，下一次
/// 触发再来（复查要看到流水线的结果）。流水线没跑、没有新内容（[LibraryCurator.
/// runAuto] 返回 null）或没跑成时返回 null。失败只记日志（自动路径没人看着）。
@visibleForTesting
Future<LibraryCurateRun?> runAutomaticLibraryCurate() async {
  _debounce = null;
  final LibraryCurateAutoHost? host = _autoHost;
  LibraryCurateRun? run;
  if (_autoEnabled(host)) {
    final LibraryCurator? curator = host!.curator();
    if (curator == null) return null;
    if (curator.isRunning) return null;
    try {
      run = await curator.runAuto();
    } on LibraryCurateBusy {
      return null;
    } on Object catch (error, stack) {
      engineLog.log('libraryCurate.automatic', error, stack);
    }
  }
  final LibraryAgentAutoReviewer? reviewer = _reviewer();
  if (reviewer != null) {
    try {
      await reviewer.review();
    } on Object catch (error, stack) {
      engineLog.log('libraryAgentReview.automatic', error, stack);
    }
  }
  return run;
}

@visibleForTesting
bool get debugLibraryCurateAutoScheduled => _debounce != null;
