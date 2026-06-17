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
        VideoControlItem.clipExport,
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

  group('TODO-492 volume placement constraints', () {
    test('volume is editor-visible but only allowed on bottom left or right',
        () {
      expect(VideoControlItem.volume.isChipRenderable, isTrue);
      expect(VideoControlItem.customizableItems,
          contains(VideoControlItem.volume));

      final VideoControlLayout base = VideoControlLayout.currentChrome;
      expect(
          base.slotOf(VideoControlItem.volume), VideoControlSlot.bottomRight);

      final VideoControlLayout onLeft =
          base.moveItem(VideoControlItem.volume, VideoControlSlot.bottomLeft);
      expect(
          onLeft.slotOf(VideoControlItem.volume), VideoControlSlot.bottomLeft);

      for (final VideoControlSlot forbidden in <VideoControlSlot>[
        VideoControlSlot.topLeft,
        VideoControlSlot.topRight,
        VideoControlSlot.screenLeft,
        VideoControlSlot.screenRight,
        VideoControlSlot.hidden,
      ]) {
        expect(
          onLeft.moveItem(VideoControlItem.volume, forbidden),
          onLeft,
          reason: 'volume must reject ${forbidden.name} instead of moving',
        );
      }
    });

    test(
        'decode normalizes invalid or duplicated volume back to one bottom slot',
        () {
      final String invalidOnly = jsonEncode(<String, Object>{
        'version': 2,
        'slots': <String, List<String>>{
          'topRight': <String>['volume'],
          'screenRight': <String>['volume'],
          'hidden': <String>['volume'],
        },
      });
      final VideoControlLayout recovered =
          VideoControlLayout.decode(invalidOnly);
      expect(recovered.slotsOf(VideoControlItem.volume),
          <VideoControlSlot>[VideoControlSlot.bottomRight]);

      final String duplicated = jsonEncode(<String, Object>{
        'version': 2,
        'slots': <String, List<String>>{
          'bottomLeft': <String>['volume'],
          'bottomRight': <String>['volume'],
          'topLeft': <String>['volume'],
        },
      });
      final VideoControlLayout deduped = VideoControlLayout.decode(duplicated);
      expect(deduped.slotsOf(VideoControlItem.volume),
          <VideoControlSlot>[VideoControlSlot.bottomLeft]);
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
      expect(
          d.slotOf(VideoControlItem.clipExport), VideoControlSlot.bottomRight);
      final List<VideoControlItem> bottomRight =
          d.itemsIn(VideoControlSlot.bottomRight);
      expect(
        bottomRight.indexOf(VideoControlItem.clipExport),
        bottomRight.indexOf(VideoControlItem.screenshot) + 1,
        reason: '片段导出默认应紧挨截图按钮，保持源片段导出语义',
      );
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

    test('current chrome keeps clip export next to screenshot in the top bar',
        () {
      final List<VideoControlItem> topRight =
          VideoControlLayout.currentChrome.itemsIn(VideoControlSlot.topRight);
      expect(topRight, contains(VideoControlItem.screenshot));
      expect(topRight, contains(VideoControlItem.clipExport));
      expect(
        topRight.indexOf(VideoControlItem.clipExport),
        topRight.indexOf(VideoControlItem.screenshot) + 1,
        reason: '播放器顶栏里片段导出必须贴着截图按钮',
      );
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
        VideoControlItem.speed,
        VideoControlItem.back,
      ]);
    });

    test('bad / empty storage falls back to current chrome without throwing',
        () {
      expect(VideoControlLayout.decode('{not json}'),
          VideoControlLayout.currentChrome,
          reason: 'bad data must preserve the existing player chrome');
      expect(VideoControlLayout.decode(''), VideoControlLayout.currentChrome,
          reason: 'first-run users should not see controls move');
      expect(VideoControlLayout.decode('[]'), VideoControlLayout.currentChrome);
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
      expect(
          layout.slotOf(VideoControlItem.screenshot), VideoControlSlot.topRight,
          reason: 'missing transport keys should backfill to current chrome');
      expect(layout.slotOf(VideoControlItem.settings),
          VideoControlSlot.screenRight,
          reason: 'missing legacy keys should backfill to current chrome');
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
      expect(migrated.slotOf(VideoControlItem.clipExport),
          VideoControlSlot.topRight,
          reason:
              'v1 migration should keep transport buttons in current chrome');
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

  group(
      'TODO-399: one button in multiple slots (addItemToSlot / removeItemFromSlot)',
      () {
    test('addItemToSlot copies a button into an extra slot (keeps original)',
        () {
      // speed defaults to bottomRight; add it to topLeft as well.
      final VideoControlLayout layout = VideoControlLayout.defaults
          .addItemToSlot(VideoControlItem.speed, VideoControlSlot.topLeft);
      expect(layout.itemsIn(VideoControlSlot.bottomRight),
          contains(VideoControlItem.speed),
          reason: 'original placement preserved (this is a copy, not a move)');
      expect(layout.itemsIn(VideoControlSlot.topLeft),
          contains(VideoControlItem.speed));
      expect(layout.slotsOf(VideoControlItem.speed), <VideoControlSlot>[
        VideoControlSlot.bottomRight,
        VideoControlSlot.topLeft,
      ]);
    });

    test('addItemToSlot is idempotent (no duplicate within the same slot)', () {
      final VideoControlLayout once = VideoControlLayout.defaults
          .addItemToSlot(VideoControlItem.speed, VideoControlSlot.topLeft);
      final VideoControlLayout twice =
          once.addItemToSlot(VideoControlItem.speed, VideoControlSlot.topLeft);
      expect(
          twice
              .itemsIn(VideoControlSlot.topLeft)
              .where((VideoControlItem i) => i == VideoControlItem.speed),
          hasLength(1));
    });

    test('removeItemFromSlot drops only that copy', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .addItemToSlot(VideoControlItem.speed, VideoControlSlot.topLeft)
          .removeItemFromSlot(VideoControlItem.speed, VideoControlSlot.topLeft);
      expect(layout.itemsIn(VideoControlSlot.topLeft),
          isNot(contains(VideoControlItem.speed)));
      expect(layout.itemsIn(VideoControlSlot.bottomRight),
          contains(VideoControlItem.speed),
          reason: 'the other copy survives');
    });

    test('removing the last visible copy lands the button in hidden', () {
      // speed only sits in bottomRight by default; remove it -> falls to hidden.
      final VideoControlLayout layout = VideoControlLayout.defaults
          .removeItemFromSlot(
              VideoControlItem.speed, VideoControlSlot.bottomRight);
      expect(layout.isOnPlayer(VideoControlItem.speed), isFalse);
      expect(layout.hiddenItems, contains(VideoControlItem.speed));
    });

    test('removeItemFromSlot refuses to remove the last copy of a required key',
        () {
      // settings is pinnedRequired: removing its only copy must bounce it back
      // (never leaves the player with no settings entry).
      final VideoControlSlot home =
          VideoControlLayout.defaults.slotOf(VideoControlItem.settings);
      final VideoControlLayout layout = VideoControlLayout.defaults
          .removeItemFromSlot(VideoControlItem.settings, home);
      expect(layout.isOnPlayer(VideoControlItem.settings), isTrue);
    });

    test('a required key with two copies can still drop one copy', () {
      final VideoControlSlot home =
          VideoControlLayout.defaults.slotOf(VideoControlItem.settings);
      final VideoControlLayout layout = VideoControlLayout.defaults
          .addItemToSlot(VideoControlItem.settings, VideoControlSlot.topLeft)
          .removeItemFromSlot(
              VideoControlItem.settings, VideoControlSlot.topLeft);
      expect(
          layout.slotsOf(VideoControlItem.settings), <VideoControlSlot>[home]);
      expect(layout.isOnPlayer(VideoControlItem.settings), isTrue);
    });

    test('encode/decode preserves a button placed in multiple slots', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .addItemToSlot(VideoControlItem.fullscreen, VideoControlSlot.topRight)
          .addItemToSlot(
              VideoControlItem.fullscreen, VideoControlSlot.bottomLeft);
      final VideoControlLayout decoded =
          VideoControlLayout.decode(layout.encode());
      expect(decoded, layout);
      expect(decoded.itemsIn(VideoControlSlot.topRight),
          contains(VideoControlItem.fullscreen));
      expect(decoded.itemsIn(VideoControlSlot.bottomLeft),
          contains(VideoControlItem.fullscreen));
      expect(decoded.slotsOf(VideoControlItem.fullscreen).length,
          greaterThanOrEqualTo(3));
    });

    test('decoding a v2 blob that lists a button in two slots keeps both', () {
      final String blob = jsonEncode(<String, Object>{
        'version': 2,
        'slots': <String, List<String>>{
          'topLeft': <String>['speed'],
          'bottomRight': <String>['speed'],
        },
      });
      final VideoControlLayout layout = VideoControlLayout.decode(blob);
      expect(layout.itemsIn(VideoControlSlot.topLeft),
          contains(VideoControlItem.speed));
      expect(layout.itemsIn(VideoControlSlot.bottomRight),
          contains(VideoControlItem.speed));
    });

    test('slotsOf returns hidden-only for a hidden button', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .moveItem(VideoControlItem.speed, VideoControlSlot.hidden);
      expect(layout.slotsOf(VideoControlItem.speed),
          <VideoControlSlot>[VideoControlSlot.hidden]);
    });
  });

  group('TODO-399 decision 2: the center transport block can be moved away',
      () {
    test('playPause can be moved out of bottomCenter to another slot', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .moveItem(VideoControlItem.playPause, VideoControlSlot.topLeft);
      expect(
          layout.slotOf(VideoControlItem.playPause), VideoControlSlot.topLeft);
      expect(layout.itemsIn(VideoControlSlot.bottomCenter),
          isNot(contains(VideoControlItem.playPause)));
    });

    test('playPause still cannot be fully hidden (pinned guard)', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .moveItem(VideoControlItem.playPause, VideoControlSlot.hidden);
      expect(layout.isOnPlayer(VideoControlItem.playPause), isTrue);
    });

    test('bottomCenter is an editable slot now (decision 2)', () {
      expect(VideoControlSlot.editableSlots,
          contains(VideoControlSlot.bottomCenter));
    });
  });

  group('TODO-399 decision 3b: transport / nav keys are customizable too', () {
    test('customizableItems includes transport/nav keys', () {
      final List<VideoControlItem> items = VideoControlItem.customizableItems;
      for (final VideoControlItem transport in <VideoControlItem>[
        VideoControlItem.playPause,
        VideoControlItem.seekBackward,
        VideoControlItem.seekForward,
        VideoControlItem.previousCue,
        VideoControlItem.nextCue,
        VideoControlItem.screenshot,
        VideoControlItem.clipExport,
        VideoControlItem.subtitleTrack,
        VideoControlItem.audioTrack,
        VideoControlItem.episodeList,
        VideoControlItem.fullscreen,
        VideoControlItem.speed,
        VideoControlItem.subtitleList,
        VideoControlItem.settings,
      ]) {
        expect(items, contains(transport),
            reason: '${transport.name} should be customizable');
      }
    });

    test('non-icon special renders (title/position) stay out of the chip set',
        () {
      // Volume has a bespoke player widget, but the editor can represent its
      // bottom-left/right placement with an icon chip. Title and position are
      // not single icon controls, so they stay out.
      final List<VideoControlItem> items = VideoControlItem.customizableItems;
      expect(items, contains(VideoControlItem.volume));
      expect(items, isNot(contains(VideoControlItem.title)));
      expect(items, isNot(contains(VideoControlItem.positionIndicator)));
    });
  });

  group('phase 2 editor catalog (slots + items the picker exposes)', () {
    test('editableSlots == the 6 rendered on-player slots + hidden (TODO-388)',
        () {
      // TODO-388: top-area left/right floating rails joined the editable set so
      // learning buttons can also be placed near the top (rendered via the same
      // learning-button rail path). topCenter (title chrome) + bottomCenter
      // (transport cluster) stay fixed and are never offered to the user.
      // TODO-399 decision 2: bottomCenter joined the editable set so the central
      // transport cluster can be moved. topCenter (fixed title chrome) stays out.
      expect(VideoControlSlot.editableSlots, <VideoControlSlot>[
        VideoControlSlot.topLeft,
        VideoControlSlot.topRight,
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomCenter,
        VideoControlSlot.bottomRight,
        VideoControlSlot.screenLeft,
        VideoControlSlot.screenRight,
        VideoControlSlot.hidden,
      ]);
      expect(VideoControlSlot.editableSlots,
          contains(VideoControlSlot.bottomCenter));
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
