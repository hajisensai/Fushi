/// 「本版新内容」：升级后首页出一次卡片，点开看这次更新多了什么。
///
/// 只记两件事（设备本地偏好，见 `kWhatsNewSeenVersionPrefKey`）：本机最近一次
/// **看过**的版本（含 release sequence），以及首页卡片在哪个版本上被关掉。判定是
/// 纯函数 [whatsNewStatusFor]；内容（调试包 = 流水线里的 PR 标题，正式 / 预发布 =
/// GitHub release 正文）由 `WhatsNewPage` 进页时现取，首页不为它发网络请求。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/misc/update_checker.dart' show isVersionNewer;

/// 首页该怎么露出「本版新内容」。
enum WhatsNewStage {
  /// 没有新内容（还没定基线 / 版本没变 / 降级）。
  none,

  /// 首页卡片可见。
  card,

  /// 卡片被关掉了，但还没打开看过：首页顶栏留一个入口，看过才消失。
  entry,
}

/// 一次「从 [fromVersion] 更新到 [toVersion]」的待看状态。
@immutable
class WhatsNewStatus {
  const WhatsNewStatus({
    required this.stage,
    required this.fromVersion,
    required this.fromSeq,
    required this.toVersion,
    required this.toSeq,
  });

  static const WhatsNewStatus none = WhatsNewStatus(
    stage: WhatsNewStage.none,
    fromVersion: '',
    fromSeq: 0,
    toVersion: '',
    toSeq: null,
  );

  final WhatsNewStage stage;
  final String fromVersion;

  /// 0 = 未知。
  final int fromSeq;
  final String toVersion;
  final int? toSeq;

  bool get pending => stage != WhatsNewStage.none;
}

/// 纯判定：本机跑着 [runningVersion]，上次看过 [seenVersion]（空串 = 没有基线），
/// 卡片在 [dismissedVersion] 上被关过。
WhatsNewStatus whatsNewStatusFor({
  required String runningVersion,
  required int? runningSeq,
  required String seenVersion,
  required int seenSeq,
  required String dismissedVersion,
}) {
  if (seenVersion.isEmpty || runningVersion.isEmpty) return WhatsNewStatus.none;
  if (!isVersionNewer(runningVersion, seenVersion)) return WhatsNewStatus.none;
  return WhatsNewStatus(
    stage: dismissedVersion == runningVersion
        ? WhatsNewStage.entry
        : WhatsNewStage.card,
    fromVersion: seenVersion,
    fromSeq: seenSeq,
    toVersion: runningVersion,
    toSeq: runningSeq,
  );
}

/// 首页卡片 / 顶栏入口 / 新内容页共用的状态。由 `AppModel.whatsNew` 持有一份。
class WhatsNewController extends ChangeNotifier {
  WhatsNewController({
    required PreferencesRepository Function() prefs,
    required this.runningVersion,
    required this.runningSeq,
  }) : _prefsOf = prefs;

  /// 每次现取：AppModel 换库（Profile / 迁移）时偏好仓库会换实例。
  final PreferencesRepository Function() _prefsOf;
  PreferencesRepository get _prefs => _prefsOf();
  final String runningVersion;
  final int? runningSeq;

  WhatsNewStatus get status => whatsNewStatusFor(
    runningVersion: runningVersion,
    runningSeq: runningSeq,
    seenVersion: _prefs.whatsNewSeenVersion,
    seenSeq: _prefs.whatsNewSeenSeq,
    dismissedVersion: _prefs.whatsNewCardDismissedVersion,
  );

  /// 首页首次构建时调：还没有基线（新装 / 这个功能之前的版本升上来）就把当前
  /// 版本记成「看过」，不对新装用户弹「新内容」；降级回旧包时同样把基线拉回来，
  /// 免得之后升回原版本时什么都不提示。
  Future<void> ensureBaseline() async {
    final String seen = _prefs.whatsNewSeenVersion;
    if (runningVersion.isEmpty) return;
    if (seen.isNotEmpty && !isVersionNewer(seen, runningVersion)) return;
    await _prefs.setWhatsNewSeen(version: runningVersion, seq: runningSeq ?? 0);
    notifyListeners();
  }

  /// 首页卡片的「✕」：卡片收起，顶栏入口留着直到打开看过。
  Future<void> dismissCard() async {
    await _prefs.setWhatsNewCardDismissedVersion(runningVersion);
    notifyListeners();
  }

  /// 打开新内容页即算看过：卡片和顶栏入口都消失。
  Future<void> markSeen() async {
    await _prefs.setWhatsNewSeen(version: runningVersion, seq: runningSeq ?? 0);
    notifyListeners();
  }
}
