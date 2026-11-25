part of 'update_checker.dart';

// 版本号 / 通道 / 发布序号的纯比较逻辑（「远端是不是更新」「这个 tag 属于哪条通道」）。
// 从 update_checker_release.dart 拆出：release part 留 UpdateChecker 门面 + 选版 +
// 镜像清单，这里只做无 I/O 的版本判定，两边共享同一 library 私有作用域。

@visibleForTesting
String? normalizeReleaseVersionTag(String tag) {
  final String normalized = tag.trim().replaceFirst(RegExp(r'^[vV]'), '');
  if (!_looksLikeVersion(normalized)) return null;
  return _stripBuildMetadata(normalized);
}

/// 是否为**应用版本** release：tag 能被 [normalizeReleaseVersionTag] 解析成版本号、且不是草稿。
///
/// 与 [releaseMatchesUpdateChannel] 的第一道闸是同一条判据（它在此之上再分通道）。同一个
/// GitHub 仓库里还挂着只放资产、不是 app 版本的 release——`vendored-binaries`（预编译第三方
/// 二进制，`tool/vendored_binaries.json`）、`flutter-engine-*`（引擎补丁产物）、模型 onnx、
/// rolling 等——它们的 tag 不是版本号，检查更新从不会选中它们，「查看更新日志」页也不能列出。
bool isAppVersionRelease(Map<String, dynamic> release) {
  if (release['draft'] == true) return false;
  final Object? tag = release['tag_name'];
  return tag is String && normalizeReleaseVersionTag(tag) != null;
}

@visibleForTesting
bool releaseMatchesUpdateChannel(
  Map<String, dynamic> release,
  UpdateChannel channel,
) {
  if (!isAppVersionRelease(release)) return false;
  final String tag = release['tag_name'] as String;
  final String version = normalizeReleaseVersionTag(tag)!;
  final bool prerelease = release['prerelease'] == true;
  return switch (channel) {
    UpdateChannel.stable => !prerelease && _prereleasePart(version) == null,
    UpdateChannel.beta =>
      prerelease && _releaseTagMatchesChannel(tag, UpdateChannel.beta),
    UpdateChannel.debug =>
      prerelease && _releaseTagMatchesChannel(tag, UpdateChannel.debug),
  };
}

/// BUG-846 嵌套合集准入的 release 过滤：[release] 本身所属通道被用户 [channel] 的嵌套
/// 合集接纳即合格（越激进通道合集越大）。与 [releaseMatchesUpdateChannel]（精确同通道）
/// 区别：后者只接纳恰好本通道，供 [_fetchStableRelease] 校验「这确实是 stable」等精确用途；
/// 本函数供选择/过滤阶段判「属于本通道合集」，复用精确判据不新造 pattern。
@visibleForTesting
bool releaseEligibleForChannel(
  Map<String, dynamic> release,
  UpdateChannel channel,
) {
  for (final UpdateChannel track in _channelsAdmittedBy(channel)) {
    if (releaseMatchesUpdateChannel(release, track)) return true;
  }
  return false;
}

/// TODO-1024 / BUG-479：通道感知的「远端 [tag] 是否比本地 [current] 新」公开判定，供
/// 缓存优先的乐观反馈（手动「检查更新」据缓存 tag 立刻分流「发现新版」/「已是最新」）。
/// 薄包 [isUpdateVersionNewer]（后者 `@visibleForTesting`，仅本库/测试内可用）。
bool updateTagIsNewerThanCurrent(
  String tag,
  String current,
  UpdateChannel channel, {
  int? remoteSeq,
  int? localSeq,
}) => isUpdateVersionNewer(
  tag,
  current,
  channel,
  remoteSeq: remoteSeq,
  localSeq: localSeq,
);

/// **纯函数**：取版本的 release sequence（= `git rev-list --count HEAD`，三通道同一把尺）。
/// 预发布串 `-beta.<seq>` / `-debug.<seq>` 的尾段数字**就是** seq（CI `TAG=v${VERSION}-<ch>.${SEQ}`）；
/// 正式版无预发布段，seq 由 [explicitSeq]（manifest 顶层 `releaseSequence` / 本机 versionCode 反解）
/// 提供。都取不到 → null（同基无法判先后 → 调用方保守不更新，绝不 churn）。
int? _releaseSeqOf(String version, int? explicitSeq) {
  final String? pre = _prereleasePart(_stripBuildMetadata(version));
  if (pre != null) {
    final int? seq = int.tryParse(pre.split('.').last);
    if (seq != null) return seq;
  }
  return explicitSeq;
}

@visibleForTesting
bool isUpdateVersionNewer(
  String remote,
  String local,
  UpdateChannel channel, {
  // BUG-846「谁后用谁」：跨轨全序比较用的 release sequence。远端正式版无预发布串带不了 seq，
  // 靠 [remoteSeq]（manifest 顶层）；本机正式版靠 [localSeq]（versionCode 反解）。预发布串自带。
  int? remoteSeq,
  int? localSeq,
}) {
  final String remoteVersion = _stripBuildMetadata(remote.trim());
  final String localVersion = _stripBuildMetadata(local.trim());

  // BUG-846 嵌套合集准入：越激进的通道合集越大——stable 只收 stable；beta 收
  // {stable,beta}；debug 收 {stable,beta,debug}。远端版本所属轨道若不在本通道合集里，
  // 一律不是更新（让 beta/debug 用户能收到更新的正式版/更高基版本，永不掉队）。
  if (!_channelAdmitsVersion(remoteVersion, channel)) return false;

  // 两侧 release sequence 都已知：按序号「谁后构建谁赢」，**先于基版本**（BUG-846 正式↔调试
  // 来回更新根治）。序号跨三通道同尺（都是 git rev-list --count HEAD），而 Android versionCode
  // 就由它导出——序号更低的包系统拒装（「无法降级安装」）。基版本不再单调代表构建先后：
  // 从 main 发的正式版 3.0.1（seq 19816）基版本高于 develop 的 3.0.0-debug.20320，构建却更早，
  // 旧的「高基永远更新」把它推给调试版用户、装不上（2026-10-22 实测）。
  final int? rSeq = _releaseSeqOf(remoteVersion, remoteSeq);
  final int? lSeq = _releaseSeqOf(localVersion, localSeq);
  if (rSeq != null && lSeq != null) return rSeq > lSeq;

  // 任一侧序号未知：只能退回基版本比较，高基视为更新。
  final int baseCompare = _compareBaseVersion(remoteVersion, localVersion);
  if (baseCompare != 0) return baseCompare > 0;

  // 任一侧序号未知（如正式版仅走 302 拿不到 seq，或本机构建号缺失）：同基无法判先后 →
  // 保守不更新。绝不在无法证实「远端更晚」时把用户在同基的两个轨道间来回推；等基版本上升
  // （上面 baseCompare>0）再更新。fail-open：不误升。
  return false;
}

/// BUG-846 嵌套合集：用户通道 [channel] 能接纳的所有轨道（含更保守的轨道），从最保守
/// 到本通道。「合集逐渐变大」——stable→[stable]；beta→[stable,beta]；
/// debug→[stable,beta,debug]。同时驱动拉取阶段的合集并集与准入判定。
List<UpdateChannel> _channelsAdmittedBy(UpdateChannel channel) {
  return switch (channel) {
    UpdateChannel.stable => const <UpdateChannel>[UpdateChannel.stable],
    UpdateChannel.beta => const <UpdateChannel>[
      UpdateChannel.stable,
      UpdateChannel.beta,
    ],
    UpdateChannel.debug => const <UpdateChannel>[
      UpdateChannel.stable,
      UpdateChannel.beta,
      UpdateChannel.debug,
    ],
  };
}

/// [version] 所属轨道在 [channel] 合集里的位置：越接近用户自己的通道越大（用户通道
/// 本身最大），供同一次构建多轨并列时的选包平局判定。
int _trackRank(String version, UpdateChannel channel) =>
    _channelsAdmittedBy(channel).indexOf(channelForUpdateVersion(version));

/// BUG-846：远端 [version] 所属轨道是否被 [channel] 的嵌套合集接纳。轨道由
/// [channelForUpdateVersion] 推断（正式版 → stable，`-beta.N`/`-debug.N` → 对应轨），
/// 与既有判据同一套 pattern，不新造。
bool _channelAdmitsVersion(String version, UpdateChannel channel) {
  return _channelsAdmittedBy(
    channel,
  ).contains(channelForUpdateVersion(version));
}

/// **纯函数（BUG-846「谁后用谁」）**：本机安装版本的 release sequence，供跨轨全序比较。
///
/// beta/debug 包版本串已带 `-<channel>.<seq>` → 直接取尾号；无后缀 `X.Y.Z`（正式版包 / 本地
/// `flutter build`）→ 用平台构建号 [buildNumber]（Android versionCode / 桌面 raw build number）
/// 反解（[_releaseSequenceFromPlatformBuildNumber]）。取不到 → null（同基无法判先后 → 保守）。
///
/// **不再**把无后缀正式版伪造成 `<base>-<channel>.<seq>` 串（旧 `effectiveCurrentVersionFor…`
/// 的做法）——那会把真正的正式版安装误标成本通道预发布轨，触发正式↔调试来回更新（BUG-846
/// 乒乓根因）。现在只提取序号、不改轨道标签，正式版仍是正式版。
///
/// 生产调用点：[scheduleCheck] 内部（网络路径）+ 设置页手动检查的缓存乐观比较路径。
int? currentReleaseSequence({
  required String version,
  required String? buildNumber,
}) {
  return _releaseSeqOf(
    _stripBuildMetadata(version.trim()),
    _releaseSequenceFromPlatformBuildNumber(buildNumber),
  );
}

/// **纯函数（BUG-457）**：从平台构建号还原 CI release sequence（= `git rev-list --count HEAD`）。
///
/// * Android release APK 的 versionCode = `versionCodeBase(1e9) + 100*seq + abiOffset`
///   （见 `android/app/build.gradle` TODO-414），故 `>= 1e9` 时反解 `(code-1e9)~/100`，
///   并校验 abiOffset ∈ [0,3]（现有 ABI 分片偏移）以防误解非 CI 构建号。
/// * 桌面构建把原始 Flutter build number（= seq）直接透出，`< 1e9` 时原样返回。
///
/// 非数字 / 非正 / abiOffset 越界 → 返 null（调用方 fail-open 回退无还原，绝不误升）。
int? _releaseSequenceFromPlatformBuildNumber(String? buildNumber) {
  final int? parsed = int.tryParse(buildNumber?.trim() ?? '');
  if (parsed == null || parsed <= 0) return null;

  const int androidVersionCodeBase = 1000000000;
  if (parsed < androidVersionCodeBase) return parsed;

  final int adjusted = parsed - androidVersionCodeBase;
  final int abiOffset = adjusted % 100;
  if (abiOffset > 3) return null;
  final int releaseSequence = adjusted ~/ 100;
  return releaseSequence > 0 ? releaseSequence : null;
}

bool isVersionNewer(String remote, String local) {
  final String remoteVersion = _stripBuildMetadata(remote.trim());
  final String localVersion = _stripBuildMetadata(local.trim());
  final int baseCompare = _compareBaseVersion(remoteVersion, localVersion);
  if (baseCompare != 0) return baseCompare > 0;

  final String? remotePrerelease = _prereleasePart(remoteVersion);
  final String? localPrerelease = _prereleasePart(localVersion);
  if (remotePrerelease == null && localPrerelease != null) return true;
  if (remotePrerelease == null || localPrerelease == null) return false;
  return _comparePrerelease(remotePrerelease, localPrerelease) > 0;
}

/// BUG-846「谁后用谁」候选新旧比较（供合集并集选择排序，非「是否更新」判定）：`>0` 表示
/// [a] 比 [b] 更新。两侧 release sequence（`git rev-list --count HEAD`，三通道同尺）都已知时
/// 按序号降序——正式版 seq 由 [seqA]/[seqB]（manifest 顶层 releaseSequence）提供，预发布 seq 即
/// 版本串尾号；任一侧缺序号（正式版 302 回退无 seq）才按基版本降序，同基视为并列（稳定排序保原序）。
/// 与 [isUpdateVersionNewer] 同尺，消除「排序偏预发布轨 vs 判据偏正式版」不一致这个乒乓根源。
int _compareReleaseRecency(String a, String b, {int? seqA, int? seqB}) {
  final String va = _stripBuildMetadata(a.trim());
  final String vb = _stripBuildMetadata(b.trim());
  // 与 [isUpdateVersionNewer] 同序：序号都已知时序号主导，缺序号才看基版本。
  final int? ra = _releaseSeqOf(va, seqA);
  final int? rb = _releaseSeqOf(vb, seqB);
  if (ra != null && rb != null) return ra.compareTo(rb);
  return _compareBaseVersion(va, vb);
}

String _stripBuildMetadata(String version) => version.split('+').first;

bool _looksLikeVersion(String version) => RegExp(
  r'^\d+(?:\.\d+)*(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?(?:\+[0-9A-Za-z][0-9A-Za-z.-]*)?$',
).hasMatch(version);

String _basePart(String version) =>
    _stripBuildMetadata(version).split('-').first;

String? _prereleasePart(String version) {
  final String stripped = _stripBuildMetadata(version);
  final int hyphen = stripped.indexOf('-');
  if (hyphen < 0 || hyphen == stripped.length - 1) return null;
  return stripped.substring(hyphen + 1);
}

List<int> _baseSegments(String version) => _basePart(version)
    .split('.')
    .map((String part) => int.tryParse(part) ?? 0)
    .toList(growable: false);

int _compareBaseVersion(String remote, String local) {
  final List<int> r = _baseSegments(remote);
  final List<int> l = _baseSegments(local);
  final int len = r.length > l.length ? r.length : l.length;
  for (int i = 0; i < len; i++) {
    final int rv = i < r.length ? r[i] : 0;
    final int lv = i < l.length ? l[i] : 0;
    if (rv != lv) return rv.compareTo(lv);
  }
  return 0;
}

/// **纯函数（TODO-1123 / BUG-539）**：从版本串推断它属于哪个更新通道，供下载 404 后
/// 「重取本通道 manifest」的 re-resolve 使用（下载路径不再显式携带 channel）。
///
/// debug 预发布形如 `1.0.1-debug.6421`、beta 形如 `1.0.1-beta.3`，否则视为 stable。
/// 与 [_versionBelongsToChannel] / [releaseMatchesUpdateChannel] 的通道判定同一套 pattern，
/// 不新造判据。反馈修复进度（`feedback_fix_progress.dart`）也用它判本机构建属于哪个通道。
UpdateChannel channelForUpdateVersion(String version) {
  if (_versionBelongsToChannel(version, UpdateChannel.debug)) {
    return UpdateChannel.debug;
  }
  if (_versionBelongsToChannel(version, UpdateChannel.beta)) {
    return UpdateChannel.beta;
  }
  return UpdateChannel.stable;
}

bool _versionBelongsToChannel(String version, UpdateChannel channel) {
  final String normalized = _stripBuildMetadata(version.trim());
  return switch (channel) {
    UpdateChannel.beta => _kBetaVersionPattern.hasMatch(normalized),
    UpdateChannel.debug => _kDebugVersionPattern.hasMatch(normalized),
    UpdateChannel.stable => false,
  };
}

bool _releaseTagMatchesChannel(String tag, UpdateChannel channel) {
  final String normalized = tag.trim();
  return switch (channel) {
    UpdateChannel.beta => _kBetaReleaseTagPattern.hasMatch(normalized),
    UpdateChannel.debug => _kDebugReleaseTagPattern.hasMatch(normalized),
    UpdateChannel.stable => false,
  };
}

int _comparePrerelease(String remote, String local) {
  final List<String> r = remote.split('.');
  final List<String> l = local.split('.');
  final int len = r.length > l.length ? r.length : l.length;
  for (int i = 0; i < len; i++) {
    if (i >= r.length) return -1;
    if (i >= l.length) return 1;
    final int part = _comparePrereleasePart(r[i], l[i]);
    if (part != 0) return part;
  }
  return 0;
}

int _comparePrereleasePart(String remote, String local) {
  final int? ri = int.tryParse(remote);
  final int? li = int.tryParse(local);
  if (ri != null && li != null) return ri.compareTo(li);
  if (ri != null) return -1;
  if (li != null) return 1;
  return remote.compareTo(local);
}
