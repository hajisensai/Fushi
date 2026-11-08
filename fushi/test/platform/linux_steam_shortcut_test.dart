import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:fushi/src/platform/desktop/binary_vdf.dart';
import 'package:fushi/src/platform/desktop/linux_steam_shortcut.dart';

/// One shortcuts.vdf entry the way Steam writes it, for a game that is not
/// Fushi: every type the format has.
VdfMap _otherGame() => VdfMap(<VdfEntry>[
  const VdfEntry('appid', VdfInt32(-1234567)),
  const VdfEntry('AppName', 'Some Game ゲーム'),
  const VdfEntry('Exe', '"/opt/game/run.sh"'),
  const VdfEntry('LastPlayTime', VdfInt32(1700000000)),
  const VdfEntry('ratio', VdfFloat32(0x3FC00000)),
  VdfEntry('big', VdfUint64(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]))),
  VdfEntry('tags', VdfMap(<VdfEntry>[const VdfEntry('0', 'favorite')])),
]);

Uint8List _shortcutsFile(List<VdfMap> games) => serializeBinaryVdf(
  VdfMap(<VdfEntry>[
    VdfEntry(
      'shortcuts',
      VdfMap(<VdfEntry>[
        for (int i = 0; i < games.length; i++) VdfEntry('$i', games[i]),
      ]),
    ),
  ]),
);

Uint8List _iconPng() => img.encodePng(
  img.fill(
    img.Image(width: 64, height: 64, numChannels: 4),
    color: img.ColorRgba8(200, 80, 120, 255),
  ),
);

void main() {
  group('binary VDF', () {
    test('round-trips every value type byte for byte', () {
      final Uint8List bytes = _shortcutsFile(<VdfMap>[_otherGame()]);
      expect(serializeBinaryVdf(parseBinaryVdf(bytes)), bytes);
    });

    test('reads keys case-insensitively', () {
      final VdfMap game =
          parseBinaryVdf(_shortcutsFile(<VdfMap>[_otherGame()]))['shortcuts']!
              as VdfMap;
      final VdfMap first = game['0']! as VdfMap;
      expect(first['appname'], 'Some Game ゲーム');
      expect((first['APPID']! as VdfInt32).unsigned, 0xFFED2979);
    });

    test('refuses types it cannot round-trip', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0x05, 0x6B, 0x00, 0x00, 0x00, 0x08, //
      ]);
      expect(() => parseBinaryVdf(bytes), throwsFormatException);
    });

    test('refuses a truncated file', () {
      final Uint8List bytes = _shortcutsFile(<VdfMap>[_otherGame()]);
      expect(
        () => parseBinaryVdf(Uint8List.sublistView(bytes, 0, bytes.length - 6)),
        throwsFormatException,
      );
    });
  });

  test('app id is Steam\'s CRC-32 of quoted exe + name with the top bit', () {
    // Reference value from zlib.crc32.
    expect(
      computeShortcutAppId(
        '"/home/u/.local/share/app.fushi.reader/steam/launch.sh"',
        'Fushi',
      ),
      3916706603,
    );
  });

  group('install', () {
    late Directory home;
    late LinuxSteamShortcut shortcut;

    Directory account(String id) => Directory(
      p.join(home.path, '.local', 'share', 'Steam', 'userdata', id, 'config'),
    );

    setUp(() {
      home = Directory.systemTemp.createTempSync('fushi_steam_');
      shortcut = LinuxSteamShortcut(
        home: home.path,
        launchCommand: const <String>['flatpak', 'run', 'app.fushi.reader'],
      );
    });

    tearDown(() => home.deleteSync(recursive: true));

    test('no Steam folder: nothing is written', () async {
      final SteamShortcutReport report = await shortcut.install(
        iconPng: _iconPng(),
      );
      expect(report.outcome, SteamShortcutOutcome.steamNotFound);
      expect(File(shortcut.launcherPath).existsSync(), isFalse);
    });

    test(
      'adds Fushi next to existing shortcuts and keeps them intact',
      () async {
        final Directory config = account('123')..createSync(recursive: true);
        account('0').createSync(recursive: true);
        final File vdf = File(p.join(config.path, 'shortcuts.vdf'));
        final Uint8List original = _shortcutsFile(<VdfMap>[_otherGame()]);
        vdf.writeAsBytesSync(original);

        final SteamShortcutReport report = await shortcut.install(
          iconPng: _iconPng(),
        );

        expect(report.outcome, SteamShortcutOutcome.added);
        expect(report.accounts, 1);
        expect(report.replaced, 0);
        // Steam's anonymous account 0 is left alone.
        expect(
          File(p.join(account('0').path, 'shortcuts.vdf')).existsSync(),
          isFalse,
        );
        expect(File('${vdf.path}.fushi-backup').readAsBytesSync(), original);

        final VdfMap shortcuts =
            parseBinaryVdf(vdf.readAsBytesSync())['shortcuts']! as VdfMap;
        expect(shortcuts.entries.map((VdfEntry e) => e.key), <String>[
          '0',
          '1',
        ]);
        // The other game serializes exactly as before.
        expect(
          serializeBinaryVdf(VdfMap(<VdfEntry>[shortcuts.entries[0]])),
          serializeBinaryVdf(VdfMap(<VdfEntry>[VdfEntry('0', _otherGame())])),
        );
        final VdfMap fushi = shortcuts.entries[1].value as VdfMap;
        expect(fushi['AppName'], 'Fushi');
        expect(fushi['Exe'], '"${shortcut.launcherPath}"');
        expect((fushi['appid']! as VdfInt32).unsigned, shortcut.appId);

        final String grid = p.join(config.path, 'grid');
        for (final String name in <String>[
          '${shortcut.appId}p.png',
          '${shortcut.appId}.png',
          '${shortcut.appId}_hero.png',
          '${shortcut.appId}_logo.png',
        ]) {
          expect(File(p.join(grid, name)).existsSync(), isTrue, reason: name);
        }
        final img.Image portrait = img.decodePng(
          File(p.join(grid, '${shortcut.appId}p.png')).readAsBytesSync(),
        )!;
        expect(<int>[portrait.width, portrait.height], <int>[600, 900]);
      },
    );

    test(
      'adding again replaces the Fushi entry instead of duplicating it',
      () async {
        final Directory config = account('123')..createSync(recursive: true);
        final File vdf = File(p.join(config.path, 'shortcuts.vdf'));
        final Uint8List original = _shortcutsFile(<VdfMap>[_otherGame()]);
        vdf.writeAsBytesSync(original);

        await shortcut.install(iconPng: _iconPng());
        final SteamShortcutReport again = await shortcut.install(
          iconPng: _iconPng(),
        );

        expect(again.replaced, 1);
        final VdfMap shortcuts =
            parseBinaryVdf(vdf.readAsBytesSync())['shortcuts']! as VdfMap;
        expect(shortcuts.entries, hasLength(2));
        // The backup is the file before Fushi first touched it.
        expect(File('${vdf.path}.fushi-backup').readAsBytesSync(), original);
      },
    );

    test('creates shortcuts.vdf for an account that has none', () async {
      account('456').createSync(recursive: true);
      final SteamShortcutReport report = await shortcut.install(
        iconPng: _iconPng(),
      );
      expect(report.accounts, 1);
      final VdfMap shortcuts =
          parseBinaryVdf(
                File(
                  p.join(account('456').path, 'shortcuts.vdf'),
                ).readAsBytesSync(),
              )['shortcuts']!
              as VdfMap;
      expect(shortcuts.entries.single.key, '0');
    });

    test('an unreadable shortcuts.vdf is left untouched', () async {
      final Directory config = account('789')..createSync(recursive: true);
      final File vdf = File(p.join(config.path, 'shortcuts.vdf'));
      final Uint8List garbage = Uint8List.fromList(<int>[0x05, 0x41, 0x00]);
      vdf.writeAsBytesSync(garbage);

      final SteamShortcutReport report = await shortcut.install(
        iconPng: _iconPng(),
      );

      expect(report.outcome, SteamShortcutOutcome.failed);
      expect(report.failures.single, startsWith('789:'));
      expect(vdf.readAsBytesSync(), garbage);
    });
  });

  group('hand-added entries and removal', () {
    late Directory home;
    late LinuxSteamShortcut shortcut;
    late File vdf;

    VdfMap handAdded() => VdfMap(<VdfEntry>[
      const VdfEntry('appid', VdfInt32(-99)),
      const VdfEntry('AppName', 'Fushi'),
      const VdfEntry('Exe', '"flatpak"'),
      const VdfEntry(
        'LaunchOptions',
        '"run" "--branch=master" "--command=fushi" "app.fushi.reader"',
      ),
    ]);

    VdfMap shortcutsOf() =>
        parseBinaryVdf(vdf.readAsBytesSync())['shortcuts']! as VdfMap;

    setUp(() {
      home = Directory.systemTemp.createTempSync('fushi_steam_');
      shortcut = LinuxSteamShortcut(
        home: home.path,
        launchCommand: const <String>['flatpak', 'run', 'app.fushi.reader'],
      );
      final Directory config = Directory(
        p.join(
          home.path,
          '.local',
          'share',
          'Steam',
          'userdata',
          '5',
          'config',
        ),
      )..createSync(recursive: true);
      vdf = File(p.join(config.path, 'shortcuts.vdf'));
    });

    tearDown(() => home.deleteSync(recursive: true));

    test('a hand-added Fushi entry is replaced, not duplicated', () async {
      vdf.writeAsBytesSync(_shortcutsFile(<VdfMap>[_otherGame(), handAdded()]));
      // A hand-added entry is not Fushi's own: the row still offers "Add".
      expect(shortcut.isInstalled(), isFalse);

      final SteamShortcutReport report = await shortcut.install(
        iconPng: _iconPng(),
      );

      expect(report.replaced, 1);
      final VdfMap shortcuts = shortcutsOf();
      expect(shortcuts.entries, hasLength(2));
      expect(
        (shortcuts.entries[1].value as VdfMap)['Exe'],
        '"${shortcut.launcherPath}"',
      );
      expect(shortcut.isInstalled(), isTrue);
    });

    test(
      'remove deletes only Fushi\'s own entry, artwork and launcher',
      () async {
        vdf.writeAsBytesSync(_shortcutsFile(<VdfMap>[_otherGame()]));
        await shortcut.install(iconPng: _iconPng());
        final String grid = p.join(vdf.parent.path, 'grid');
        expect(
          File(p.join(grid, '${shortcut.appId}p.png')).existsSync(),
          isTrue,
        );

        final SteamShortcutReport report = await shortcut.uninstall();

        expect(report.outcome, SteamShortcutOutcome.removed);
        expect(report.accounts, 1);
        expect(shortcut.isInstalled(), isFalse);
        // The other game is back exactly as it was.
        expect(vdf.readAsBytesSync(), _shortcutsFile(<VdfMap>[_otherGame()]));
        expect(
          File(p.join(grid, '${shortcut.appId}p.png')).existsSync(),
          isFalse,
        );
        expect(File(shortcut.launcherPath).existsSync(), isFalse);
      },
    );
  });

  group('launcher script', () {
    test('Flatpak: Game Mode display, app id, no preload', () {
      final LinuxSteamShortcut shortcut = LinuxSteamShortcut(
        home: '/home/u',
        launchCommand: const <String>['flatpak', 'run', 'app.fushi.reader'],
      );
      final String script = shortcut.launcherScript(42);
      expect(script, startsWith('#!/bin/sh\n'));
      expect(
        script,
        contains(
          'if [ -n "\$GAMESCOPE_WAYLAND_DISPLAY" ]; then\n'
          '  export DISPLAY=:0\n'
          '  export GDK_BACKEND=x11\n'
          'fi\n',
        ),
      );
      expect(script, contains('unset LD_PRELOAD\n'));
      expect(
        script,
        contains(
          'exec flatpak run --env=FUSHI_STEAM_APPID=42 app.fushi.reader "\$@"\n',
        ),
      );
    });

    test('plain build: runs the executable, quoted when needed', () {
      final LinuxSteamShortcut shortcut = LinuxSteamShortcut(
        home: '/home/u',
        launchCommand: const <String>["/opt/My Apps/fushi's/fushi"],
      );
      final String script = shortcut.launcherScript(7);
      expect(script, contains('export FUSHI_STEAM_APPID=7\n'));
      expect(
        script,
        contains("exec '/opt/My Apps/fushi'\\''s/fushi' \"\$@\"\n"),
      );
    });
  });
}
