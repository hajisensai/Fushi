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

    test('decode drops invalid volume slots and restores one bottom fallback',
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
    });

    test('decode preserves volume on both bottom slots but dedupes one slot',
        () {
      final String duplicated = jsonEncode(<String, Object>{
        'version': 2,
        'slots': <String, List<String>>{
          'bottomLeft': <String>['volume', 'volume'],
          'bottomRight': <String>['volume'],
          'topLeft': <String>['volume'],
        },
      });
      final VideoControlLayout decoded = VideoControlLayout.decode(duplicated);
      expect(decoded.slotsOf(VideoControlItem.volume), <VideoControlSlot>[
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomRight,
      ]);
      expect(
        decoded
            .itemsIn(VideoControlSlot.bottomLeft)
            .where((VideoControlItem i) => i == VideoControlItem.volume),
        hasLength(1),
      );
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

    test('moveItem to hidden removes a non-required button from the player',
        () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .moveItem(VideoControlItem.speed, VideoControlSlot.hidden);
      expect(layout.isOnPlayer(VideoControlItem.speed), isFalse);
      expect(layout.removedItems, contains(VideoControlItem.speed));
      expect(layout.itemsIn(VideoControlSlot.hidden),
          isNot(contains(VideoControlItem.speed)));
    });
  });

  group('required-button guard (playPause cannot be removed)', () {
    test('moveItem refuses to hide playPause but allows settings removal', () {
      final VideoControlLayout base = VideoControlLayout.defaults;
      final VideoControlLayout afterSettings =
          base.moveItem(VideoControlItem.settings, VideoControlSlot.hidden);
      expect(afterSettings.isOnPlayer(VideoControlItem.settings), isFalse);
      expect(afterSettings.removedItems, contains(VideoControlItem.settings));

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
      expect(layout.isOnPlayer(VideoControlItem.settings), isFalse);
      expect(layout.removedItems, contains(VideoControlItem.settings));
      expect(layout.isOnPlayer(VideoControlItem.playPause), isTrue);
    });
  });

  group('encode/decode round-trip (v3)', () {
    test('preserves per-slot order through a round trip', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .moveItem(VideoControlItem.speed, VideoControlSlot.topLeft, index: 0)
          .moveItem(VideoControlItem.fullscreen, VideoControlSlot.topLeft,
              index: 0);
      final String encoded = layout.encode();
      expect(jsonDecode(encoded), containsPair('version', 3));
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

    test('removed buttons encode outside slots and decode without hidden items',
        () {
      final VideoControlLayout layout = VideoControlLayout.currentChrome
          .moveItem(VideoControlItem.speed, VideoControlSlot.hidden);
      final Map<String, dynamic> encoded =
          jsonDecode(layout.encode()) as Map<String, dynamic>;
      expect(encoded['version'], 3);
      expect(encoded['removed'], contains('speed'));
      final Map<String, dynamic> slots =
          encoded['slots'] as Map<String, dynamic>;
      expect(slots.containsKey('hidden'), isFalse);
      expect(
        slots.values.expand((Object? raw) => raw as List<dynamic>),
        isNot(contains('speed')),
      );

      final VideoControlLayout decoded =
          VideoControlLayout.decode(jsonEncode(encoded));
      expect(decoded.isOnPlayer(VideoControlItem.speed), isFalse);
      expect(decoded.removedItems, contains(VideoControlItem.speed));
      expect(decoded.itemsIn(VideoControlSlot.hidden), isEmpty);
    });

    test('palette restore removes the item from removed set', () {
      final VideoControlLayout removed = VideoControlLayout.currentChrome
          .moveItem(VideoControlItem.speed, VideoControlSlot.hidden);
      final VideoControlLayout restored = removed.addItemToSlot(
        VideoControlItem.speed,
        VideoControlSlot.bottomRight,
      );
      expect(restored.isOnPlayer(VideoControlItem.speed), isTrue);
      expect(restored.removedItems, isNot(contains(VideoControlItem.speed)));
      expect(restored.itemsIn(VideoControlSlot.bottomRight),
          contains(VideoControlItem.speed));
    });

    test('old v2 hidden entries migrate to removed items', () {
      final String blob = jsonEncode(<String, Object>{
        'version': 2,
        'slots': <String, List<String>>{
          'hidden': <String>['speed'],
        },
      });
      final VideoControlLayout layout = VideoControlLayout.decode(blob);
      expect(layout.isOnPlayer(VideoControlItem.speed), isFalse);
      expect(layout.removedItems, contains(VideoControlItem.speed));
      expect(layout.itemsIn(VideoControlSlot.hidden), isEmpty);
      expect(layout.isOnPlayer(VideoControlItem.playPause), isTrue);
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

    test('legacy settingsOnly maps to removed', () {
      final VideoControlLayout migrated = VideoControlLayout.decode(
        legacyV1(<VideoControlButton, VideoControlPlacement>{
          VideoControlButton.speed: VideoControlPlacement.settingsOnly,
        }),
      );
      expect(migrated.slotOf(VideoControlItem.speed), VideoControlSlot.hidden);
      expect(migrated.isOnPlayer(VideoControlItem.speed), isFalse);
      expect(migrated.removedItems, contains(VideoControlItem.speed));
      expect(migrated.itemsIn(VideoControlSlot.hidden), isEmpty);
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
      expect(migrated.removedItems, contains(VideoControlItem.subtitleList));
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

    test('removing the last visible copy marks the button removed', () {
      // speed only sits in bottomRight by default; remove it -> removed set.
      final VideoControlLayout layout = VideoControlLayout.defaults
          .removeItemFromSlot(
              VideoControlItem.speed, VideoControlSlot.bottomRight);
      expect(layout.isOnPlayer(VideoControlItem.speed), isFalse);
      expect(layout.removedItems, contains(VideoControlItem.speed));
      expect(layout.itemsIn(VideoControlSlot.hidden), isEmpty);
    });

    test('removeItemFromSlot refuses to remove the last copy of a required key',
        () {
      // playPause is pinnedRequired: removing its only copy must be rejected.
      final VideoControlSlot home =
          VideoControlLayout.defaults.slotOf(VideoControlItem.playPause);
      final VideoControlLayout layout = VideoControlLayout.defaults
          .removeItemFromSlot(VideoControlItem.playPause, home);
      expect(layout.isOnPlayer(VideoControlItem.playPause), isTrue);
      expect(layout.slotOf(VideoControlItem.playPause), home);
    });

    test('a required key with two copies can still drop one copy', () {
      final VideoControlSlot home =
          VideoControlLayout.defaults.slotOf(VideoControlItem.playPause);
      final VideoControlLayout layout = VideoControlLayout.defaults
          .addItemToSlot(VideoControlItem.playPause, VideoControlSlot.topLeft)
          .removeItemFromSlot(
              VideoControlItem.playPause, VideoControlSlot.topLeft);
      expect(
          layout.slotsOf(VideoControlItem.playPause), <VideoControlSlot>[home]);
      expect(layout.isOnPlayer(VideoControlItem.playPause), isTrue);
    });

    test('settings can be removed and restored through the palette', () {
      final VideoControlLayout removed = VideoControlLayout.defaults
          .moveItem(VideoControlItem.settings, VideoControlSlot.hidden);
      expect(removed.isOnPlayer(VideoControlItem.settings), isFalse);
      expect(removed.removedItems, contains(VideoControlItem.settings));

      final VideoControlLayout restored = removed.addItemToSlot(
        VideoControlItem.settings,
        VideoControlSlot.screenRight,
      );
      expect(restored.isOnPlayer(VideoControlItem.settings), isTrue);
      expect(restored.removedItems, isNot(contains(VideoControlItem.settings)));
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

    test('slotsOf returns hidden-only for a removed button', () {
      final VideoControlLayout layout = VideoControlLayout.defaults
          .moveItem(VideoControlItem.speed, VideoControlSlot.hidden);
      expect(layout.slotsOf(VideoControlItem.speed),
          <VideoControlSlot>[VideoControlSlot.hidden]);
      expect(layout.itemsIn(VideoControlSlot.hidden), isEmpty);
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

    test('title is editable as a text chip while position stays out', () {
      // Volume has a bespoke player widget, but the editor can represent its
      // bottom-left/right placement with an icon chip. Title is a single
      // movable/removable text control, but position stays a dedicated readout.
      final List<VideoControlItem> items = VideoControlItem.customizableItems;
      expect(items, contains(VideoControlItem.volume));
      expect(items, contains(VideoControlItem.title));
      expect(items, isNot(contains(VideoControlItem.positionIndicator)));
    });
  });

  group('TODO-504/505 title placement and deletion semantics', () {
    test('title only moves among top title slots or hidden', () {
      expect(VideoControlItem.title.isChipRenderable, isTrue);
      expect(
          VideoControlItem.customizableItems, contains(VideoControlItem.title));

      for (final VideoControlSlot allowed in <VideoControlSlot>[
        VideoControlSlot.topLeft,
        VideoControlSlot.topCenter,
        VideoControlSlot.topRight,
        VideoControlSlot.hidden,
      ]) {
        expect(VideoControlItem.title.canMoveToSlot(allowed), isTrue,
            reason: 'title should accept ${allowed.name}');
      }

      for (final VideoControlSlot forbidden in <VideoControlSlot>[
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomCenter,
        VideoControlSlot.bottomRight,
        VideoControlSlot.screenLeft,
        VideoControlSlot.screenRight,
      ]) {
        expect(VideoControlItem.title.canMoveToSlot(forbidden), isFalse,
            reason: 'title should reject ${forbidden.name}');
      }

      expect(VideoControlItem.speed.canMoveToSlot(VideoControlSlot.topCenter),
          isFalse,
          reason: 'topCenter is title-only, not a generic button slot');
    });

    test('title moves as one instance, can hide, and can be restored', () {
      final VideoControlLayout left = VideoControlLayout.currentChrome.moveItem(
        VideoControlItem.title,
        VideoControlSlot.topLeft,
      );
      expect(left.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.topLeft]);
      expect(left.itemsIn(VideoControlSlot.topCenter),
          isNot(contains(VideoControlItem.title)));

      final VideoControlLayout hidden =
          left.moveItem(VideoControlItem.title, VideoControlSlot.hidden);
      expect(hidden.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.hidden]);
      expect(hidden.isOnPlayer(VideoControlItem.title), isFalse);
      expect(hidden.itemsIn(VideoControlSlot.hidden), isEmpty);

      final VideoControlLayout restored = hidden.addItemToSlot(
          VideoControlItem.title, VideoControlSlot.topRight);
      expect(restored.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.topRight]);
      expect(restored.itemsIn(VideoControlSlot.hidden),
          isNot(contains(VideoControlItem.title)));
    });

    test('decode keeps explicit hidden title but restores missing title', () {
      final VideoControlLayout hidden = VideoControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 2,
          'slots': <String, List<String>>{
            'hidden': <String>['title'],
          },
        }),
      );
      expect(hidden.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.hidden]);
      expect(hidden.itemsIn(VideoControlSlot.hidden), isEmpty);

      final VideoControlLayout missing = VideoControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 2,
          'slots': <String, List<String>>{
            'topLeft': <String>['speed'],
          },
        }),
      );
      expect(missing.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.topCenter]);
    });

    test('decode normalizes invalid or duplicated title to one valid slot', () {
      final VideoControlLayout invalid = VideoControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 2,
          'slots': <String, List<String>>{
            'bottomLeft': <String>['title'],
          },
        }),
      );
      expect(invalid.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.topCenter]);

      final VideoControlLayout duplicated = VideoControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 2,
          'slots': <String, List<String>>{
            'topLeft': <String>['title'],
            'topRight': <String>['title'],
          },
        }),
      );
      expect(duplicated.slotsOf(VideoControlItem.title),
          <VideoControlSlot>[VideoControlSlot.topLeft]);
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

    test('moving a learning key to every editable slot is honored', () {
      for (final VideoControlItem item
          in VideoControlItem.customizableLearning) {
        for (final VideoControlSlot slot in VideoControlSlot.editableSlots) {
          final VideoControlLayout moved =
              VideoControlLayout.defaults.moveItem(item, slot);
          expect(moved.slotOf(item), slot,
              reason: '${item.name} should move into ${slot.name}');
        }
      }
    });
  });

  group('TODO-554 settings stays reachable on touch controls', () {
    test(
        'settings is pinnedOnTouch but not pinnedRequired (desktop can remove)',
        () {
      // pinnedRequired = removable on no platform (playPause).
      // pinnedOnTouch  = removable on desktop only (settings).
      expect(VideoControlItem.settings.pinnedRequired, isFalse);
      expect(VideoControlItem.settings.pinnedOnTouch, isTrue);
      expect(VideoControlItem.playPause.pinnedRequired, isTrue);
      expect(VideoControlItem.playPause.pinnedOnTouch, isFalse);
    });

    test('canMoveToSlot forbids hiding settings only on touch controls', () {
      // Desktop default (isTouchControls: false) keeps settings removable so the
      // right-click `Icons.tune` menu can restore it.
      expect(
        VideoControlItem.settings.canMoveToSlot(VideoControlSlot.hidden),
        isTrue,
      );
      // Touch controls forbid it: settings is the sole in-player settings entry,
      // and there is no right-click fallback, so hiding it would soft-lock the
      // user out of the panel / on-screen editor (the regression dd988f477 let
      // this through after dropping settings' pinnedRequired flag).
      expect(
        VideoControlItem.settings.canMoveToSlot(
          VideoControlSlot.hidden,
          isTouchControls: true,
        ),
        isFalse,
      );
    });

    test('canRemoveFromPlayer mirrors the touch gate for settings', () {
      expect(VideoControlItem.settings.canRemoveFromPlayer(), isTrue);
      expect(
        VideoControlItem.settings.canRemoveFromPlayer(isTouchControls: true),
        isFalse,
      );
    });

    test('touch gate only affects the hidden target, not visible slots', () {
      // settings can still be dragged to any visible slot on touch controls.
      for (final VideoControlSlot slot in <VideoControlSlot>[
        VideoControlSlot.topLeft,
        VideoControlSlot.topRight,
        VideoControlSlot.bottomLeft,
        VideoControlSlot.bottomCenter,
        VideoControlSlot.bottomRight,
        VideoControlSlot.screenLeft,
        VideoControlSlot.screenRight,
      ]) {
        expect(
          VideoControlItem.settings.canMoveToSlot(slot, isTouchControls: true),
          isTrue,
          reason: 'settings should still reach ${slot.name} on touch',
        );
      }
    });

    test('touch gate does not loosen other items (non-pinnedOnTouch removable)',
        () {
      // A plain learning key stays removable on both surfaces.
      expect(VideoControlItem.speed.canMoveToSlot(VideoControlSlot.hidden),
          isTrue);
      expect(
        VideoControlItem.speed.canMoveToSlot(
          VideoControlSlot.hidden,
          isTouchControls: true,
        ),
        isTrue,
      );
      // playPause stays non-removable on both surfaces (model-layer pin).
      expect(VideoControlItem.playPause.canMoveToSlot(VideoControlSlot.hidden),
          isFalse);
      expect(
        VideoControlItem.playPause.canMoveToSlot(
          VideoControlSlot.hidden,
          isTouchControls: true,
        ),
        isFalse,
      );
    });

    test('persisted model stays cross-platform identical (decode unaffected)',
        () {
      // Decoding a saved layout that removed settings must NOT depend on the
      // current platform: the pure model still removes it (the UI gate, not the
      // model, keeps it on the player for touch users).
      final VideoControlLayout decoded = VideoControlLayout.decode(
        jsonEncode(<String, Object>{
          'version': 3,
          'slots': <String, List<String>>{
            'bottomRight': <String>['speed'],
          },
          'removed': <String>['settings'],
        }),
      );
      expect(decoded.isOnPlayer(VideoControlItem.settings), isFalse);
      expect(decoded.removedItems, contains(VideoControlItem.settings));
    });
  });
}
