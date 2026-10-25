import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/bluray/bluray_menu_info.dart';
import 'package:path/path.dart' as p;

VideoBookRow _book(String uid, String path, {int? playedAt}) => VideoBookRow(
  bookUid: uid,
  title: uid,
  videoPath: path,
  lastPositionMs: 0,
  lastPlayedAt: playedAt,
  currentEpisode: 0,
  delayMs: 0,
);

String _mpls(String disc, String name) =>
    p.join('/box', disc, 'BDMV', 'PLAYLIST', '$name.mpls');

void main() {
  group('collectDiscRefs', () {
    test('groups members per disc root and sorts by disc number', () {
      final List<DiscRef> discs = collectDiscRefs(<VideoBookRow>[
        _book('a', _mpls('Disc 10', '00001')),
        _book('b', _mpls('Disc 2', '00001')),
        _book('c', _mpls('Disc 2', '00800')),
        _book('d', '/box/extra.mkv'),
        _book('e', _mpls('Disc 1', '00002')),
      ]);
      expect(
        discs.map((DiscRef d) => d.label).toList(),
        <String>['Disc 1', 'Disc 2', 'Disc 10'],
        reason: 'natural order: Disc 10 after Disc 2; plain files are no disc',
      );
      expect(discs[1].rootPath, p.normalize(p.join('/box', 'Disc 2')));
    });

    test('each disc opens with its most recently played member', () {
      final List<DiscRef> discs = collectDiscRefs(<VideoBookRow>[
        _book('main', _mpls('Disc 1', '00001'), playedAt: 100),
        _book('bonus', _mpls('Disc 1', '00800'), playedAt: 300),
        _book('never', _mpls('Disc 2', '00001')),
      ]);
      expect(discs.first.book.bookUid, 'bonus');
      expect(discs.first.lastPlayedAt, 300);
      expect(discs.last.book.bookUid, 'never');
      expect(discs.last.lastPlayedAt, isNull);
    });
  });

  group('preferredDisc', () {
    test('picks the most recently watched disc, else the first', () {
      final List<DiscRef> discs = collectDiscRefs(<VideoBookRow>[
        _book('one', _mpls('Disc 1', '00001'), playedAt: 10),
        _book('two', _mpls('Disc 2', '00001'), playedAt: 50),
        _book('three', _mpls('Disc 3', '00001')),
      ]);
      expect(preferredDisc(discs)!.label, 'Disc 2');
      final List<DiscRef> fresh = collectDiscRefs(<VideoBookRow>[
        _book('x', _mpls('Disc 2', '00001')),
        _book('y', _mpls('Disc 1', '00001')),
      ]);
      expect(preferredDisc(fresh)!.label, 'Disc 1');
      expect(preferredDisc(const <DiscRef>[]), isNull);
    });
  });

  group('resolveDiscMenuAvailability', () {
    DiscMenuUnavailableReason? resolve({
      bool local = true,
      bool java = false,
      DiscMenuPlatform platform = DiscMenuPlatform.windows,
      bool installable = true,
    }) => resolveDiscMenuAvailability(
      local: local,
      requiresJava: java,
      platform: platform,
      bdjComponentInstallable: installable,
    );

    test('remote discs cannot open menus anywhere', () {
      for (final DiscMenuPlatform platform in DiscMenuPlatform.values) {
        expect(
          resolve(local: false, platform: platform),
          DiscMenuUnavailableReason.remote,
        );
      }
    });

    test('HDMV menus open on every platform', () {
      for (final DiscMenuPlatform platform in DiscMenuPlatform.values) {
        expect(resolve(platform: platform, installable: false), isNull);
      }
    });

    test('BD-J is refused on Android / iOS only', () {
      expect(
        resolve(java: true, platform: DiscMenuPlatform.android),
        DiscMenuUnavailableReason.mobileBdj,
      );
      expect(
        resolve(java: true, platform: DiscMenuPlatform.ios),
        DiscMenuUnavailableReason.mobileBdj,
      );
      expect(resolve(java: true, platform: DiscMenuPlatform.macos), isNull);
      expect(resolve(java: true, platform: DiscMenuPlatform.linux), isNull);
    });

    test('Windows BD-J needs the installable component', () {
      expect(resolve(java: true), isNull);
      expect(
        resolve(java: true, installable: false),
        DiscMenuUnavailableReason.missingBdjComponent,
      );
    });

    test(
      'probe reads the index; an unreadable index is not a verdict',
      () async {
        Future<BlurayMenuInfo?> bdj(String _) async => const BlurayMenuInfo(
          hasFirstPlay: true,
          hasTopMenu: true,
          requiresJava: true,
          titleCount: 1,
        );
        Future<BlurayMenuInfo?> unreadable(String _) async => null;
        expect(
          await probeDiscMenuAvailability(
            rootPath: '/box/Disc 1',
            platform: DiscMenuPlatform.android,
            bdjComponentInstallable: false,
            readMenuInfo: bdj,
          ),
          DiscMenuUnavailableReason.mobileBdj,
        );
        expect(
          await probeDiscMenuAvailability(
            rootPath: '/box/Disc 1',
            platform: DiscMenuPlatform.android,
            bdjComponentInstallable: false,
            readMenuInfo: unreadable,
          ),
          isNull,
        );
      },
    );
  });

  group('resolveDiscPrimaryKind', () {
    test('disc entries play the disc by default', () {
      expect(
        resolveDiscPrimaryKind(
          hasDisc: true,
          openMenuByDefault: true,
          unavailable: null,
        ),
        DiscPrimaryKind.playDisc,
      );
    });

    test('falls back to plain play for each unavailable reason', () {
      for (final DiscMenuUnavailableReason reason
          in DiscMenuUnavailableReason.values) {
        expect(
          resolveDiscPrimaryKind(
            hasDisc: true,
            openMenuByDefault: true,
            unavailable: reason,
          ),
          DiscPrimaryKind.playTitle,
          reason: '$reason',
        );
      }
    });

    test('the "open menu by default" setting off plays the title', () {
      expect(
        resolveDiscPrimaryKind(
          hasDisc: true,
          openMenuByDefault: false,
          unavailable: null,
        ),
        DiscPrimaryKind.playTitle,
      );
      expect(
        resolveDiscPrimaryKind(
          hasDisc: false,
          openMenuByDefault: true,
          unavailable: null,
        ),
        DiscPrimaryKind.playTitle,
      );
    });
  });

  test('formatDiscResumePosition', () {
    expect(formatDiscResumePosition(0), '0:00');
    expect(formatDiscResumePosition(754000), '12:34');
    expect(formatDiscResumePosition(3723000), '1:02:03');
  });
}
