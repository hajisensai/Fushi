import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi/src/platform/desktop/binary_vdf.dart';

/// "Add to Steam" for the Linux build: adds Fushi to the Steam library as a
/// non-Steam game, with library artwork, so it can be started in Steam Deck
/// Game Mode next to a game (Game Mode screen OCR: linux/runner/
/// gamescope_overlay.h).
///
/// What it writes, per Steam account (`userdata/<account>/config/`):
///   - `shortcuts.vdf`: one entry for Fushi; an earlier Fushi entry is
///     replaced, every other entry is kept byte for byte. The file as it was
///     before Fushi first touched it is kept as `shortcuts.vdf.fushi-backup`.
///   - `grid/<appid>p.png`, `<appid>.png`, `<appid>_hero.png`,
///     `<appid>_logo.png`: library artwork.
/// and one launcher script ([launcherPath]) that the entry starts.
///
/// Steam reads shortcuts when it starts: the entry shows up after Steam
/// restarts (switching between Desktop and Game Mode restarts it).
class LinuxSteamShortcut {
  LinuxSteamShortcut({
    required this.home,
    required this.launchCommand,
    this.appName = 'Fushi',
  });

  /// The shortcut for this Fushi process: the Flatpak (`FLATPAK_ID`) or the
  /// executable it runs from.
  factory LinuxSteamShortcut.forThisProcess() {
    final String home = Platform.environment['HOME'] ?? '';
    final String? flatpakId = Platform.environment['FLATPAK_ID'];
    final bool flatpak =
        flatpakId != null &&
        flatpakId.isNotEmpty &&
        File('/.flatpak-info').existsSync();
    return LinuxSteamShortcut(
      home: home,
      launchCommand: flatpak
          ? <String>['flatpak', 'run', flatpakId]
          : <String>[Platform.resolvedExecutable],
    );
  }

  /// The user's home folder (the host's: Flatpak keeps HOME).
  final String home;

  /// The command that starts Fushi, without arguments.
  final List<String> launchCommand;

  final String appName;

  /// The script the library entry starts. Under the home folder so the host's
  /// Steam can run it (a Flatpak's own data folder is not on the host path).
  String get launcherPath =>
      p.join(home, '.local', 'share', 'app.fushi.reader', 'steam', 'launch.sh');

  String get _iconPath => p.join(p.dirname(launcherPath), 'icon.png');

  /// `Exe` as Steam stores it (quoted).
  String get exeField => '"$launcherPath"';

  /// Steam's id for a non-Steam game: CRC-32 of exe + name, top bit set.
  /// Artwork files are named after it.
  int get appId => computeShortcutAppId(exeField, appName);

  /// Steam's install folders that exist under [home], without duplicates
  /// (`~/.steam/steam` is usually a link to `~/.local/share/Steam`).
  List<Directory> steamRoots() {
    final Set<String> seen = <String>{};
    final List<Directory> roots = <Directory>[];
    for (final String candidate in <String>[
      p.join(home, '.local', 'share', 'Steam'),
      p.join(home, '.steam', 'steam'),
      p.join(home, '.steam', 'root'),
    ]) {
      final Directory dir = Directory(candidate);
      if (!dir.existsSync()) continue;
      final String real = dir.resolveSymbolicLinksSync();
      if (seen.add(real)) roots.add(Directory(real));
    }
    return roots;
  }

  /// `userdata/<account>/config` of every Steam account that has signed in on
  /// this machine (account 0 is Steam's anonymous placeholder).
  List<Directory> accountConfigDirs() {
    final List<Directory> dirs = <Directory>[];
    for (final Directory root in steamRoots()) {
      final Directory userdata = Directory(p.join(root.path, 'userdata'));
      if (!userdata.existsSync()) continue;
      for (final FileSystemEntity account in userdata.listSync()) {
        final String name = p.basename(account.path);
        if (account is! Directory || name == '0') continue;
        if (int.tryParse(name) == null) continue;
        dirs.add(Directory(p.join(account.path, 'config')));
      }
    }
    dirs.sort((Directory a, Directory b) => a.path.compareTo(b.path));
    return dirs;
  }

  /// Adds (or refreshes) Fushi in every Steam account. [iconPng] is Fushi's
  /// app icon, used for the artwork.
  Future<SteamShortcutReport> install({required Uint8List iconPng}) async {
    final List<Directory> accounts = accountConfigDirs();
    if (accounts.isEmpty) {
      return const SteamShortcutReport(
        outcome: SteamShortcutOutcome.steamNotFound,
      );
    }
    final int id = appId;
    await _writeLauncher(id);
    final SteamArtwork art = await Isolate.run(
      () => SteamArtwork.render(iconPng, appName),
    );
    await File(_iconPath).writeAsBytes(art.icon, flush: true);

    int added = 0;
    int updated = 0;
    final List<String> failures = <String>[];
    for (final Directory config in accounts) {
      try {
        final bool replaced = await _installInto(config, id);
        if (replaced) {
          updated++;
        } else {
          added++;
        }
        await _writeArtwork(config, id, art);
      } on Object catch (error) {
        failures.add('${p.basename(p.dirname(config.path))}: $error');
      }
    }
    if (added + updated == 0) {
      return SteamShortcutReport(
        outcome: SteamShortcutOutcome.failed,
        failures: failures,
      );
    }
    return SteamShortcutReport(
      outcome: SteamShortcutOutcome.added,
      accounts: added + updated,
      replaced: updated,
      failures: failures,
    );
  }

  /// Writes Fushi's entry into one account. True when an earlier Fushi entry
  /// was replaced.
  Future<bool> _installInto(Directory config, int id) async {
    final File file = File(p.join(config.path, 'shortcuts.vdf'));
    VdfMap root;
    if (file.existsSync()) {
      // A file that cannot be fully read throws here and is left untouched.
      root = parseBinaryVdf(await file.readAsBytes());
      final File backup = File('${file.path}.fushi-backup');
      if (!backup.existsSync()) await file.copy(backup.path);
    } else {
      root = VdfMap();
      await config.create(recursive: true);
    }
    VdfMap? shortcuts = root['shortcuts'] as VdfMap?;
    if (shortcuts == null) {
      shortcuts = VdfMap();
      root.set('shortcuts', shortcuts);
    }
    final int before = shortcuts.entries.length;
    // An entry added by hand ("Add a Non-Steam Game") also starts Fushi, but
    // without the Game Mode launcher: one working entry replaces it.
    shortcuts.entries.removeWhere(
      (VdfEntry entry) => _isOurs(entry.value, id) || _startsFushi(entry.value),
    );
    final bool replaced = shortcuts.entries.length != before;
    shortcuts.entries.add(VdfEntry('', _entry(id)));
    // Entries are keyed "0", "1", ... in order.
    for (int i = 0; i < shortcuts.entries.length; i++) {
      shortcuts.entries[i] = VdfEntry('$i', shortcuts.entries[i].value);
    }
    await _writeAtomically(file, serializeBinaryVdf(root));
    return replaced;
  }

  bool _isOurs(Object value, int id) {
    if (value is! VdfMap) return false;
    final Object? appid = value['appid'];
    if (appid is VdfInt32 && appid.unsigned == id) return true;
    return value['exe'] == exeField;
  }

  /// A hand-added entry that starts this Fushi: its exe or launch options
  /// name the Flatpak app id, or its exe is this executable.
  bool _startsFushi(Object value) {
    if (value is! VdfMap) return false;
    final String exe = '${value['exe'] ?? ''}';
    final String options = '${value['LaunchOptions'] ?? ''}';
    final bool flatpak = launchCommand.first == 'flatpak';
    final String marker = flatpak ? launchCommand.last : launchCommand.first;
    if (flatpak) {
      return exe.contains(marker) || options.contains(marker);
    }
    return exe == marker || exe == '"$marker"';
  }

  /// Whether any Steam account has Fushi's own entry (one written by
  /// [install]; a hand-added entry does not count).
  bool isInstalled() {
    final int id = appId;
    for (final Directory config in accountConfigDirs()) {
      final File file = File(p.join(config.path, 'shortcuts.vdf'));
      if (!file.existsSync()) continue;
      try {
        final VdfMap? shortcuts =
            parseBinaryVdf(file.readAsBytesSync())['shortcuts'] as VdfMap?;
        if (shortcuts != null &&
            shortcuts.entries.any((VdfEntry e) => _isOurs(e.value, id))) {
          return true;
        }
      } on FormatException {
        continue;
      }
    }
    return false;
  }

  /// Removes Fushi's own entry, its artwork and the launcher. Other entries
  /// (a hand-added Fushi entry included) are kept byte for byte.
  Future<SteamShortcutReport> uninstall() async {
    final int id = appId;
    int removed = 0;
    final List<String> failures = <String>[];
    for (final Directory config in accountConfigDirs()) {
      final File file = File(p.join(config.path, 'shortcuts.vdf'));
      try {
        if (file.existsSync()) {
          final VdfMap root = parseBinaryVdf(await file.readAsBytes());
          final VdfMap? shortcuts = root['shortcuts'] as VdfMap?;
          if (shortcuts != null) {
            final int before = shortcuts.entries.length;
            shortcuts.entries.removeWhere(
              (VdfEntry entry) => _isOurs(entry.value, id),
            );
            if (shortcuts.entries.length != before) {
              for (int i = 0; i < shortcuts.entries.length; i++) {
                shortcuts.entries[i] = VdfEntry(
                  '$i',
                  shortcuts.entries[i].value,
                );
              }
              await _writeAtomically(file, serializeBinaryVdf(root));
              removed++;
            }
          }
        }
        for (final String name in _artworkNames(id)) {
          final File art = File(p.join(config.path, 'grid', name));
          if (art.existsSync()) await art.delete();
        }
      } on Object catch (error) {
        failures.add('${p.basename(p.dirname(config.path))}: $error');
      }
    }
    final Directory launcher = File(launcherPath).parent;
    if (launcher.existsSync()) await launcher.delete(recursive: true);
    if (removed == 0 && failures.isNotEmpty) {
      return SteamShortcutReport(
        outcome: SteamShortcutOutcome.failed,
        failures: failures,
      );
    }
    return SteamShortcutReport(
      outcome: SteamShortcutOutcome.removed,
      accounts: removed,
      failures: failures,
    );
  }

  static List<String> _artworkNames(int id) => <String>[
    '${id}p.png',
    '$id.png',
    '${id}_hero.png',
    '${id}_logo.png',
  ];

  VdfMap _entry(int id) => VdfMap(<VdfEntry>[
    VdfEntry('appid', VdfInt32(id.toSigned(32))),
    VdfEntry('AppName', appName),
    VdfEntry('Exe', exeField),
    VdfEntry('StartDir', '"${p.dirname(launcherPath)}"'),
    VdfEntry('icon', _iconPath),
    const VdfEntry('ShortcutPath', ''),
    const VdfEntry('LaunchOptions', ''),
    const VdfEntry('IsHidden', VdfInt32(0)),
    const VdfEntry('AllowDesktopConfig', VdfInt32(1)),
    const VdfEntry('AllowOverlay', VdfInt32(1)),
    const VdfEntry('OpenVR', VdfInt32(0)),
    const VdfEntry('Devkit', VdfInt32(0)),
    const VdfEntry('DevkitGameID', ''),
    const VdfEntry('DevkitOverrideAppID', VdfInt32(0)),
    const VdfEntry('LastPlayTime', VdfInt32(0)),
    const VdfEntry('FlatpakAppID', ''),
    VdfEntry('tags', VdfMap()),
  ]);

  Future<void> _writeLauncher(int id) async {
    final File file = File(launcherPath);
    await file.parent.create(recursive: true);
    await file.writeAsString(launcherScript(id), flush: true);
    // Steam runs it directly. (Unit tests also run this on Windows, which has
    // no executable bit.)
    if (Platform.isWindows) return;
    final ProcessResult chmod = await Process.run('chmod', <String>[
      '755',
      file.path,
    ]);
    if (chmod.exitCode != 0) {
      throw FileSystemException('chmod failed: ${chmod.stderr}', file.path);
    }
  }

  /// The launcher script for app id [id].
  String launcherScript(int id) {
    final String command = <String>[
      if (launchCommand.first == 'flatpak') ...<String>[
        'flatpak',
        'run',
        '--env=FUSHI_STEAM_APPID=$id',
        ...launchCommand.skip(2),
      ] else
        ...launchCommand,
    ].map(_shellQuote).join(' ');
    return '#!/bin/sh\n'
        '# Starts Fushi from its Steam library entry. Written by Fushi\n'
        '# (Settings > Appearance > Add to Steam); adding it again rewrites it.\n'
        '#\n'
        '# Steam Deck Game Mode: Gamescope only draws overlays from its first X\n'
        '# display, and Fushi tags its window with this entry\'s app id so Steam\n'
        '# can switch to it. Game Mode is detected through X, so GTK must not\n'
        '# pick Wayland.\n'
        'if [ -n "\$GAMESCOPE_WAYLAND_DISPLAY" ]; then\n'
        '  export DISPLAY=:0\n'
        '  export GDK_BACKEND=x11\n'
        'fi\n'
        '# Steam\'s overlay library is for games, not for Fushi.\n'
        'unset LD_PRELOAD\n'
        'export FUSHI_STEAM_APPID=$id\n'
        'exec $command "\$@"\n';
  }

  Future<void> _writeArtwork(Directory config, int id, SteamArtwork art) async {
    final Directory grid = Directory(p.join(config.path, 'grid'));
    await grid.create(recursive: true);
    final List<String> names = _artworkNames(id);
    final List<Uint8List> images = <Uint8List>[
      art.portrait,
      art.wide,
      art.hero,
      art.logo,
    ];
    for (int i = 0; i < names.length; i++) {
      await File(p.join(grid.path, names[i])).writeAsBytes(images[i]);
    }
  }

  static Future<void> _writeAtomically(File file, Uint8List bytes) async {
    final File temp = File('${file.path}.fushi-tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  static String _shellQuote(String word) {
    if (RegExp(r'^[A-Za-z0-9_./=:+-]+$').hasMatch(word)) return word;
    return "'${word.replaceAll("'", "'\\''")}'";
  }
}

/// Steam's app id for a non-Steam game: CRC-32 of the quoted exe followed by
/// the name, with the top bit set.
int computeShortcutAppId(String exeField, String appName) =>
    (getCrc32(utf8.encode('$exeField$appName')) | 0x80000000) & 0xFFFFFFFF;

enum SteamShortcutOutcome { added, removed, steamNotFound, failed }

class SteamShortcutReport {
  const SteamShortcutReport({
    required this.outcome,
    this.accounts = 0,
    this.replaced = 0,
    this.failures = const <String>[],
  });

  final SteamShortcutOutcome outcome;

  /// Steam accounts that now have the entry ([SteamShortcutOutcome.added]) or
  /// no longer have it ([SteamShortcutOutcome.removed]).
  final int accounts;

  /// Of those, accounts where an earlier Fushi entry (Fushi's own or a
  /// hand-added one) was replaced.
  final int replaced;

  /// One line per account that could not be written.
  final List<String> failures;
}

/// Library artwork drawn from the app icon (PNG bytes).
class SteamArtwork {
  const SteamArtwork({
    required this.portrait,
    required this.wide,
    required this.hero,
    required this.logo,
    required this.icon,
  });

  /// Capsule 600x900, wide capsule 920x430, hero 1920x620, logo and icon.
  final Uint8List portrait;
  final Uint8List wide;
  final Uint8List hero;
  final Uint8List logo;
  final Uint8List icon;

  static final img.ColorRgba8 _background = img.ColorRgba8(
    0x1D,
    0x1B,
    0x20,
    255,
  );
  static final img.ColorRgba8 _text = img.ColorRgba8(0xF4, 0xEF, 0xF4, 255);

  static SteamArtwork render(Uint8List iconPng, String name) {
    final img.Image? decoded = img.decodePng(iconPng);
    if (decoded == null) {
      throw const FormatException('app icon is not a PNG');
    }
    final img.Image icon = decoded.convert(numChannels: 4);

    img.Image canvas(int width, int height) => img.fill(
      img.Image(width: width, height: height, numChannels: 4),
      color: _background,
    );

    img.Image place(img.Image target, int size, int centerX, int centerY) {
      final img.Image scaled = img.copyResize(
        icon,
        width: size,
        height: size,
        interpolation: img.Interpolation.cubic,
      );
      return img.compositeImage(
        target,
        scaled,
        dstX: centerX - size ~/ 2,
        dstY: centerY - size ~/ 2,
      );
    }

    void label(img.Image target, int centerX, int top) {
      final img.BitmapFont font = img.arial48;
      int width = 0;
      for (final int code in name.codeUnits) {
        width += font.characters[code]?.xAdvance ?? font.size ~/ 2;
      }
      img.drawString(
        target,
        name,
        font: font,
        x: centerX - width ~/ 2,
        y: top,
        color: _text,
      );
    }

    final img.Image portrait = place(canvas(600, 900), 360, 300, 400);
    label(portrait, 300, 620);
    final img.Image wide = place(canvas(920, 430), 240, 460, 190);
    label(wide, 460, 330);
    final img.Image hero = place(canvas(1920, 620), 360, 960, 310);
    final img.Image logo = img.copyResize(icon, width: 512, height: 512);
    final img.Image smallIcon = img.copyResize(icon, width: 256, height: 256);

    return SteamArtwork(
      portrait: img.encodePng(portrait),
      wide: img.encodePng(wide),
      hero: img.encodePng(hero),
      logo: img.encodePng(logo),
      icon: img.encodePng(smallIcon),
    );
  }
}
