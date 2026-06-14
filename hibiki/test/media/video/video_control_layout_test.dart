import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';

void main() {
  // TODO-274 phase 0: data model foundation for full 9-slot drag customization.
  // These tests pin the new VideoControlLayout model and, critically, the lossless
  // v1->v2 migration that upgrades existing users config without data loss.
  group('VideoControlSlot enum', () {
    test('has exactly the 9 documented slots', () {
      expect(VideoControlSlot.values, hasLength(9));
      expect(VideoControlSlot.values, <VideoControlSlot>[
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomCenter,
        VideoControlSlot.bottomRight,
        VideoControlSlot.screenLeft,
        VideoControlSlot.screenRight,
        VideoControlSlot.topLeft,
        VideoControlSlot.topCenter,
        VideoControlSlot.topRight,
        VideoControlSlot.hidden,
      ]);
    });

    test('only hidden is off-player; storage round-trips', () {
      for (final VideoControlSlot slot in VideoControlSlot.values) {
        expect(slot.isOnPlayer, slot != VideoControlSlot.hidden);
        expect(VideoControlSlot.fromStorage(slot.storageValue), slot);
      }
      expect(VideoControlSlot.fromStorage('nope'), isNull);
    });
  });

  group('VideoControlItem button library', () {
    test('catalogs both transport keys and learning keys', () {
      for (final VideoControlButton legacy in VideoControlButton.values) {
        final VideoControlItem? item = VideoControlItem.fromLegacy(legacy);
        expect(item, isNotNull,
            reason: 'missing item for legacy ${legacy.name}');
        expect(item!.legacyButton, legacy);
      }
      for (final VideoControlItem t in <VideoControlItem>[
        VideoControlItem.playPause,
        VideoControlItem.seekBackward,
        VideoControlItem.seekForward,
        VideoControlItem.previousCue,
        VideoControlItem.nextCue,
        VideoControlItem.volume,
        VideoControlItem.fullscreen,
        VideoControlItem.screenshot,
        VideoControlItem.subtitleTrack,
        VideoControlItem.audioTrack,
        VideoControlItem.episodeList,
        VideoControlItem.title,
        VideoControlItem.positionIndicator,
      ]) {
        expect(VideoControlItem.values, contains(t));
        expect(t.legacyButton, isNull,
            reason: 'transport keys have no legacy peer');
      }
    });

    test('special-render and pinned flags are set on the right items', () {
      const Set<VideoControlItem> special = <VideoControlItem>{
        VideoControlItem.playPause,
        VideoControlItem.volume,
        VideoControlItem.title,
        VideoControlItem.positionIndicator,
      };
      const Set<VideoControlItem> pinned = <VideoControlItem>{
        VideoControlItem.settings,
        VideoControlItem.playPause,
      };
      for (final VideoControlItem item in VideoControlItem.values) {
        expect(item.isSpecialRender, special.contains(item),
            reason: 'isSpecialRender mismatch for ${item.name}');
        expect(item.pinnedRequired, pinned.contains(item),
            reason: 'pinnedRequired mismatch for ${item.name}');
        expect(VideoControlItem.fromStorage(item.storageValue), item);
      }
      expect(VideoControlItem.fromStorage('nope'), isNull);
    });
  });

  group('VideoControlLayout per-slot ordered model', () {
    test('defaults: favorite buttons land in bottomRight (user decision)', () {
      final VideoControlLayout d = VideoControlLayout.defaults;
      expect(d.slotOf(VideoControlItem.favoriteSentence),
          VideoControlSlot.bottomRight);
      expect(d.slotOf(VideoControlItem.favoriteSentences),
          VideoControlSlot.bottomRight);
      expect(
          d.slotOf(VideoControlItem.playPause), VideoControlSlot.bottomCenter);
      expect(d.slotOf(VideoControlItem.title), VideoControlSlot.topCenter);
      expect(d.slotOf(VideoControlItem.subtitleList),
          VideoControlSlot.screenRight);
    });

    test('every button is placed in exactly one slot (no loss, no dup)', () {
      final VideoControlLayout d = VideoControlLayout.defaults;
      final List<VideoControlItem> seen = <VideoControlItem>[];
      for (final VideoControlSlot slot in VideoControlSlot.values) {
        seen.addAll(d.itemsIn(slot));
      }
      expect(seen.toSet(), VideoControlItem.values.toSet());
      expect(seen, hasLength(VideoControlItem.values.length));
    });

    test('moveItem reorders within a slot and across slots', () {
      VideoControlLayout layout = VideoControlLayout.defaults;
      layout = layout.moveItem(
        VideoControlItem.speed,
        VideoControlSlot.bottomLeft,
        index: 0,
      );
      expect(
          layout.slotOf(VideoControlItem.speed), VideoControlSlot.bottomLeft);
      expect(layout.itemsIn(VideoControlSlot.bottomLeft).first,
          VideoControlItem.speed);
      expect(layout.itemsIn(VideoControlSlot.bottomRight),
          isNot(contains(VideoControlItem.speed)));
    });

    test('moveItem to hidden hides a non-required button', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .moveItem(VideoControlItem.speed, VideoControlSlot.hidden);
      expect(layout.isOnPlayer(VideoControlItem.speed), isFalse);
      expect(layout.hiddenItems, contains(VideoControlItem.speed));
    });
  });

  group('required-button guard (settings / playPause cannot hide)', () {
    test('moveItem refuses to hide settings or playPause', () {
      final VideoControlLayout base = VideoControlLayout.defaults;
      final VideoControlLayout afterSettings =
          base.moveItem(VideoControlItem.settings, VideoControlSlot.hidden);
      expect(afterSettings.isOnPlayer(VideoControlItem.settings), isTrue);
      expect(afterSettings.hiddenItems,
          isNot(contains(VideoControlItem.settings)));

      final VideoControlLayout afterPlay =
          base.moveItem(VideoControlItem.playPause, VideoControlSlot.hidden);
      expect(afterPlay.isOnPlayer(VideoControlItem.playPause), isTrue);
      expect(
          afterPlay.hiddenItems, isNot(contains(VideoControlItem.playPause)));
    });

    test('decoding a layout that hides a required key bounces it back', () {
      final String blob = jsonEncode(<String, Object>{
        'version': 2,
        'slots': <String, List<String>>{
          'hidden': <String>['settings', 'playPause'],
        },
      });
      final VideoControlLayout layout = VideoControlLayout.decode(blob);
      expect(layout.isOnPlayer(VideoControlItem.settings), isTrue);
      expect(layout.isOnPlayer(VideoControlItem.playPause), isTrue);
    });
  });

  group('encode/decode round-trip (v2)', () {
    test('preserves per-slot order through a round trip', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .moveItem(VideoControlItem.speed, VideoControlSlot.topLeft, index: 0)
          .moveItem(VideoControlItem.fullscreen, VideoControlSlot.topLeft,
              index: 0);
      final String encoded = layout.encode();
      expect(encoded, contains('version'));
      final VideoControlLayout decoded = VideoControlLayout.decode(encoded);
      expect(decoded, layout);
      expect(decoded.itemsIn(VideoControlSlot.topLeft), <VideoControlItem>[
        VideoControlItem.fullscreen,
        VideoControlItem.speed
      ]);
    });

    test('bad / empty storage falls back to defaults without throwing', () {
      expect(
          VideoControlLayout.decode('{not json}'), VideoControlLayout.defaults);
      expect(VideoControlLayout.decode(''), VideoControlLayout.defaults);
      expect(VideoControlLayout.decode('[]'), VideoControlLayout.defaults);
    });

    test('decode backfills buttons missing from a partial v2 blob', () {
      final String blob = jsonEncode(<String, Object>{
        'version': 2,
        'slots': <String, List<String>>{
          'topLeft': <String>['speed'],
        },
      });
      final VideoControlLayout layout = VideoControlLayout.decode(blob);
      expect(layout.slotOf(VideoControlItem.speed), VideoControlSlot.topLeft);
      expect(layout.slotOf(VideoControlItem.playPause),
          VideoControlSlot.bottomCenter);
      final List<VideoControlItem> seen = <VideoControlItem>[];
      for (final VideoControlSlot slot in VideoControlSlot.values) {
        seen.addAll(layout.itemsIn(slot));
      }
      expect(seen.toSet(), VideoControlItem.values.toSet());
    });
  });

  group('v1 -> v2 migration (backward compatibility iron rule)', () {
    String legacyV1(Map<VideoControlButton, VideoControlPlacement> placements) {
      VideoControlCustomization c = VideoControlCustomization.defaults;
      placements.forEach((VideoControlButton b, VideoControlPlacement p) {
        c = c.copyWithPlacement(b, p);
      });
      return c.encode();
    }

    test('legacy bottom maps to bottomRight', () {
      final VideoControlLayout migrated = VideoControlLayout.decode(
        legacyV1(<VideoControlButton, VideoControlPlacement>{
          VideoControlButton.speed: VideoControlPlacement.bottom,
        }),
      );
      expect(migrated.slotOf(VideoControlItem.speed),
          VideoControlSlot.bottomRight);
    });

    test('legacy rightRail maps to screenRight', () {
      final VideoControlLayout migrated = VideoControlLayout.decode(
        legacyV1(<VideoControlButton, VideoControlPlacement>{
          VideoControlButton.subtitleList: VideoControlPlacement.rightRail,
        }),
      );
      expect(migrated.slotOf(VideoControlItem.subtitleList),
          VideoControlSlot.screenRight);
    });

    test('legacy settingsOnly maps to hidden', () {
      final VideoControlLayout migrated = VideoControlLayout.decode(
        legacyV1(<VideoControlButton, VideoControlPlacement>{
          VideoControlButton.speed: VideoControlPlacement.settingsOnly,
        }),
      );
      expect(migrated.slotOf(VideoControlItem.speed), VideoControlSlot.hidden);
      expect(migrated.isOnPlayer(VideoControlItem.speed), isFalse);
    });

    test('full legacy default config migrates every learning key correctly',
        () {
      final VideoControlLayout migrated = VideoControlLayout.decode(
          VideoControlCustomization.defaults.encode());
      expect(migrated.slotOf(VideoControlItem.speed),
          VideoControlSlot.bottomRight);
      for (final VideoControlItem item in <VideoControlItem>[
        VideoControlItem.subtitleList,
        VideoControlItem.favoriteSentence,
        VideoControlItem.favoriteSentences,
        VideoControlItem.settings,
      ]) {
        expect(migrated.slotOf(item), VideoControlSlot.screenRight,
            reason:
                'legacy rightRail must map to screenRight for ${item.name}');
      }
    });

    test('a customized legacy config upgrades losslessly (mixed placements)',
        () {
      final String v1 = legacyV1(<VideoControlButton, VideoControlPlacement>{
        VideoControlButton.speed: VideoControlPlacement.rightRail,
        VideoControlButton.subtitleList: VideoControlPlacement.settingsOnly,
        VideoControlButton.favoriteSentence: VideoControlPlacement.bottom,
        VideoControlButton.settings: VideoControlPlacement.bottom,
      });
      final VideoControlLayout migrated = VideoControlLayout.decode(v1);
      expect(migrated.slotOf(VideoControlItem.speed),
          VideoControlSlot.screenRight);
      expect(migrated.slotOf(VideoControlItem.subtitleList),
          VideoControlSlot.hidden);
      expect(migrated.slotOf(VideoControlItem.favoriteSentence),
          VideoControlSlot.bottomRight);
      expect(migrated.slotOf(VideoControlItem.settings),
          VideoControlSlot.bottomRight);
      expect(migrated.slotOf(VideoControlItem.playPause),
          VideoControlSlot.bottomCenter);
      expect(
          migrated.slotOf(VideoControlItem.title), VideoControlSlot.topCenter);
    });

    test('migration leaves every button placed (no orphan)', () {
      final VideoControlLayout migrated = VideoControlLayout.decode(
          VideoControlCustomization.defaults.encode());
      final List<VideoControlItem> seen = <VideoControlItem>[];
      for (final VideoControlSlot slot in VideoControlSlot.values) {
        seen.addAll(migrated.itemsIn(slot));
      }
      expect(seen.toSet(), VideoControlItem.values.toSet());
      expect(seen, hasLength(VideoControlItem.values.length));
    });
  });

  group('legacy model untouched (phase 0 keeps current chrome identical)', () {
    test('legacy defaults still drive the existing render contract', () {
      const VideoControlCustomization c = VideoControlCustomization.defaults;
      expect(c.placementFor(VideoControlButton.speed),
          VideoControlPlacement.bottom);
      expect(c.placementFor(VideoControlButton.subtitleList),
          VideoControlPlacement.rightRail);
      expect(c.buttonsFor(VideoControlPlacement.bottom),
          contains(VideoControlButton.speed));
      expect(c.buttonsFor(VideoControlPlacement.rightRail),
          contains(VideoControlButton.subtitleList));
    });
  });

  group('phase 2 editor catalog (slots + items the picker exposes)', () {
    test('editableSlots == the 4 rendered on-player slots + hidden', () {
      expect(VideoControlSlot.editableSlots, <VideoControlSlot>[
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomRight,
        VideoControlSlot.screenLeft,
        VideoControlSlot.screenRight,
        VideoControlSlot.hidden,
      ]);
      // bottomCenter / top* are fixed chrome and never offered to the user.
      expect(VideoControlSlot.editableSlots,
          isNot(contains(VideoControlSlot.bottomCenter)));
      expect(VideoControlSlot.editableSlots,
          isNot(contains(VideoControlSlot.topCenter)));
    });

    test(
        'customizableLearning == exactly the 5 learning keys (have a legacy peer)',
        () {
      final List<VideoControlItem> learning =
          VideoControlItem.customizableLearning;
      expect(learning, <VideoControlItem>[
        VideoControlItem.speed,
        VideoControlItem.subtitleList,
        VideoControlItem.favoriteSentence,
        VideoControlItem.favoriteSentences,
        VideoControlItem.settings,
      ]);
      for (final VideoControlItem item in learning) {
        expect(item.legacyButton, isNotNull);
      }
      // No transport key leaks into the editable set.
      expect(learning, isNot(contains(VideoControlItem.playPause)));
      expect(learning, isNot(contains(VideoControlItem.volume)));
    });

    test(
        'moving a learning key to every editable slot is honored (except '
        'hiding the required settings key)', () {
      for (final VideoControlItem item
          in VideoControlItem.customizableLearning) {
        for (final VideoControlSlot slot in VideoControlSlot.editableSlots) {
          final VideoControlLayout moved =
              VideoControlLayout.defaults.moveItem(item, slot);
          if (item.pinnedRequired && slot == VideoControlSlot.hidden) {
            // required keys bounce back — never end up hidden.
            expect(moved.isOnPlayer(item), isTrue);
          } else {
            expect(moved.slotOf(item), slot,
                reason: '${item.name} should move into ${slot.name}');
          }
        }
      }
    });
  });
}
