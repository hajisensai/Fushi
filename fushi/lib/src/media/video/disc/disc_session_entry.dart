import 'package:fushi_core/fushi_core.dart' show VideoBookRow;
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/video/bluray/bluray_menu_info.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show blurayDiscRootForPlaylistPath;
import 'package:path/path.dart' as p;

/// One physical disc inside a library entry (a collection or a standalone work).
///
/// A disc collection stores one member per selected MPLS; several members can
/// share one disc root, and a multi-disc box set has several roots. [book] is
/// the member the disc session is opened with: the most recently played one on
/// this disc, otherwise the first in library order.
class DiscRef {
  const DiscRef({
    required this.rootPath,
    required this.book,
    required this.lastPlayedAt,
  });

  final String rootPath;
  final VideoBookRow book;

  /// Latest `lastPlayedAt` among this disc's members (milliseconds), or null
  /// when none of them was ever played.
  final int? lastPlayedAt;

  /// The disc directory name (`Disc 2`), which is what the user sees on the
  /// box and in the source folder.
  String get label => p.basename(rootPath);
}

/// The disc roots behind [members], sorted by disc number / directory name
/// (natural order, so `Disc 10` sorts after `Disc 2`).
///
/// This is the single place the app asks "which discs does this entry have";
/// it maps a member path to its disc root with the engine's pure path rule.
List<DiscRef> collectDiscRefs(Iterable<VideoBookRow> members) {
  final Map<String, List<VideoBookRow>> byRoot = <String, List<VideoBookRow>>{};
  for (final VideoBookRow book in members) {
    final String? root = blurayDiscRootForPlaylistPath(book.videoPath);
    if (root == null) continue;
    byRoot.putIfAbsent(root, () => <VideoBookRow>[]).add(book);
  }
  final List<DiscRef> discs = <DiscRef>[
    for (final MapEntry<String, List<VideoBookRow>> entry in byRoot.entries)
      _discRefFor(entry.key, entry.value),
  ];
  discs.sort((DiscRef a, DiscRef b) {
    final int byName = naturalCompare(a.label, b.label);
    return byName != 0 ? byName : a.rootPath.compareTo(b.rootPath);
  });
  return discs;
}

DiscRef _discRefFor(String root, List<VideoBookRow> books) {
  VideoBookRow chosen = books.first;
  int? latest;
  for (final VideoBookRow book in books) {
    final int? played = book.lastPlayedAt;
    if (played != null && (latest == null || played > latest)) {
      latest = played;
      chosen = book;
    }
  }
  return DiscRef(rootPath: root, book: chosen, lastPlayedAt: latest);
}

/// The disc a one-tap "play disc" opens: the most recently watched one, else
/// the first disc of the set.
DiscRef? preferredDisc(List<DiscRef> discs) {
  DiscRef? best;
  for (final DiscRef disc in discs) {
    final int? played = disc.lastPlayedAt;
    if (played == null) continue;
    if (best == null || played > best.lastPlayedAt!) best = disc;
  }
  return best ?? (discs.isEmpty ? null : discs.first);
}

/// Why a disc's authored menu cannot be opened here. The disc label stays
/// (it is a file-structure fact); this is a runtime capability.
enum DiscMenuUnavailableReason {
  /// The disc lives on an interconnect peer. libbluray needs a local file
  /// system, so menus of remote discs cannot run yet.
  remote,

  /// A BD-J (Java) menu on Android / iOS: those packages ship no JVM.
  mobileBdj,

  /// A BD-J menu on a desktop build that ships no installable BD-J component.
  missingBdjComponent,
}

/// The platform facts the menu capability depends on.
enum DiscMenuPlatform { windows, macos, linux, android, ios }

/// Pure capability rule. HDMV menus work on every platform that ships the
/// navigation-capable player; BD-J needs Java:
///
/// - Android / iOS never run BD-J (no JVM in the package) — say so.
/// - Windows ships an optional private component; when the installer is part
///   of this build the session itself offers to install it, so it is not a
///   blocker. Without the installer the component is genuinely missing.
/// - macOS / Linux use a system Java runtime; whether it exists is only known
///   when libbluray starts, so the session tries and reports a real failure.
DiscMenuUnavailableReason? resolveDiscMenuAvailability({
  required bool local,
  required bool requiresJava,
  required DiscMenuPlatform platform,
  required bool bdjComponentInstallable,
}) {
  if (!local) return DiscMenuUnavailableReason.remote;
  if (!requiresJava) return null;
  return switch (platform) {
    DiscMenuPlatform.android ||
    DiscMenuPlatform.ios => DiscMenuUnavailableReason.mobileBdj,
    DiscMenuPlatform.windows =>
      bdjComponentInstallable
          ? null
          : DiscMenuUnavailableReason.missingBdjComponent,
    DiscMenuPlatform.macos || DiscMenuPlatform.linux => null,
  };
}

/// Reads the disc index (no video decoding) and applies
/// [resolveDiscMenuAvailability]. An unreadable index is not a capability
/// verdict: the session reports the real open failure instead.
Future<DiscMenuUnavailableReason?> probeDiscMenuAvailability({
  required String rootPath,
  required DiscMenuPlatform platform,
  required bool bdjComponentInstallable,
  Future<BlurayMenuInfo?> Function(String root) readMenuInfo =
      readBlurayMenuInfo,
}) async {
  final BlurayMenuInfo? info = await readMenuInfo(rootPath);
  return resolveDiscMenuAvailability(
    local: true,
    requiresJava: info?.requiresJava ?? false,
    platform: platform,
    bdjComponentInstallable: bdjComponentInstallable,
  );
}

/// What the detail page's primary button does for a disc entry.
enum DiscPrimaryKind {
  /// Open the authored disc menu ("播放原盘").
  playDisc,

  /// Plain playback of the main title, with an optional reason subtitle.
  playTitle,
}

/// Primary-button decision for a disc entry. [openMenuByDefault] is the
/// "原盘默认进入菜单" setting: off means the user wants the title directly.
DiscPrimaryKind resolveDiscPrimaryKind({
  required bool hasDisc,
  required bool openMenuByDefault,
  required DiscMenuUnavailableReason? unavailable,
}) {
  if (!hasDisc || !openMenuByDefault || unavailable != null) {
    return DiscPrimaryKind.playTitle;
  }
  return DiscPrimaryKind.playDisc;
}

/// `1:02:03` / `12:34` for the "continue watching xx:xx" secondary button.
String formatDiscResumePosition(int positionMs) {
  final int totalSeconds = positionMs ~/ 1000;
  final int hours = totalSeconds ~/ 3600;
  final int minutes = (totalSeconds % 3600) ~/ 60;
  final int seconds = totalSeconds % 60;
  final String ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:$ss';
  }
  return '$minutes:$ss';
}
