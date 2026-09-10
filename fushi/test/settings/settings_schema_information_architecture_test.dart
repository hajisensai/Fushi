import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_schema_listening.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart';
import 'package:fushi/src/settings/settings_schema_manga.dart';
import 'package:fushi/src/settings/settings_schema_profiles.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart';
import 'package:fushi/src/settings/settings_schema_storage.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';

List<SettingsDestination> _destinations() => <SettingsDestination>[
  buildAppearanceDestination(),
  buildReadingDestination(),
  buildListeningDestination(),
  buildMangaDestination(),
  buildVideoDestination(),
  buildLookupDestination(),
  buildProfilesDestination(),
  buildStorageDestination(),
  buildSystemDestination(),
];

SettingsSection _section(SettingsDestination destination, String id) =>
    destination.sections.singleWhere((SettingsSection s) => s.id == id);

SettingsItem _item(SettingsDestination destination, String id) => destination
    .sections
    .expand((SettingsSection s) => s.items)
    .singleWhere((SettingsItem i) => i.id == id);

void main() {
  test('ordinary sections have unique persistent identities', () {
    final List<String?> ids = _destinations()
        .expand((SettingsDestination d) => d.sections)
        .map((SettingsSection s) => s.id)
        .toList();
    expect(ids, everyElement(isNotNull));
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('video exposes subtitles before library and advanced processing', () {
    expect(
      buildVideoDestination().sections.map((SettingsSection s) => s.id),
      <String>[
        'video.section.playback',
        'video.section.subtitles',
        'video.section.library',
        'video.section.danmaku',
        'video.section.hdr',
        'video.section.quality',
        'video.section.geometry',
        'video.section.color',
        'video.section.audio',
        'video.section.session',
      ],
    );
    for (final SettingsSection section in buildVideoDestination().sections) {
      final bool advanced = <String>{
        'video.section.hdr',
        'video.section.quality',
        'video.section.geometry',
        'video.section.color',
        'video.section.audio',
      }.contains(section.id);
      expect(
        section.presentation,
        advanced
            ? SettingsSectionPresentation.collapsed
            : SettingsSectionPresentation.alwaysExpanded,
      );
    }
  });

  test(
    'reading groups gestures together and places advanced typography last',
    () {
      expect(
        buildReadingDestination().sections.map((SettingsSection s) => s.id),
        <String>[
          'reading.section.mode',
          // #1351 的 VN 设置组（本轮重构的基底还没有它），位置紧跟阅读模式：
          // 它整组只在 VN 模式下可见，排在模式选择之后最自然。
          'reading.section.visual_novel',
          'reading.section.typography',
          'reading.section.page_turn_input',
          'reading.section.page_turn_direction',
          'reading.section.chrome',
          'reading.section.statistics',
          'reading.section.advanced_typography',
        ],
      );
    },
  );

  test('optional feature switches remain outside collapsed groups', () {
    for (final (SettingsDestination destination, String sectionId)
        in <(SettingsDestination, String)>[
          (buildListeningDestination(), 'listening.section.floating_lyric'),
          (buildVideoDestination(), 'video.section.danmaku'),
          (buildMangaDestination(), 'manga.section.ocr'),
          (buildLookupDestination(), 'lookup.section.integrations'),
        ]) {
      expect(
        _section(destination, sectionId).presentation,
        SettingsSectionPresentation.alwaysExpanded,
      );
    }
  });

  test(
    'ASR and OCR managers are reachable subpages using existing body widgets',
    () {
      for (final (SettingsDestination destination, String itemId)
          in <(SettingsDestination, String)>[
            (buildStorageDestination(), 'listening.asr_models'),
            (buildMangaDestination(), 'manga.ocr'),
          ]) {
        final SettingsNavigationItem navigation =
            _item(destination, itemId) as SettingsNavigationItem;
        final SettingsDestination child = navigation.child!();
        expect(child.id, destination.id);
        expect(child.body, isNotNull);
        expect(
          child.sections,
          isEmpty,
          reason:
              'The model manager already owns its cards; avoid a nested card.',
        );
      }
    },
  );

  test(
    'ASR models have one global storage owner independent of module settings',
    () {
      final List<SettingsDestination> owners = _destinations()
          .where(
            (SettingsDestination d) => d.sections.any(
              (SettingsSection s) => s.items.any(
                (SettingsItem i) => i.id == 'listening.asr_models',
              ),
            ),
          )
          .toList();
      expect(
        owners.map((SettingsDestination d) => d.id),
        <SettingsDestinationId>[SettingsDestinationId.storage],
      );
      final SettingsDestination storage = owners.single;
      expect(
        storage.visible,
        isNull,
        reason: 'Global models must not be gated by the listening module',
      );
      final List<SettingsSearchEntry> results =
          flattenVisibleSettings(<SettingsDestination>[
                storage,
              ], _GlobalModelContext())
              .where(
                (SettingsSearchEntry e) => e.item.id == 'listening.asr_models',
              )
              .toList();
      expect(results, hasLength(isAsrSupported ? 1 : 0));
      if (isAsrSupported) {
        expect(results.single.destination.id, SettingsDestinationId.storage);
        expect(results.single.hasRevealTarget, isTrue);
        expect(
          results.single.sectionTitle,
          _section(storage, 'storage.section.models_components').title,
        );
      }
    },
  );

  test(
    'lookup audio and external application entries belong to their own groups',
    () {
      final SettingsDestination lookup = buildLookupDestination();
      expect(
        _section(lookup, 'lookup.section.dictionaries').items
            .whereType<SettingsNavigationItem>()
            .map((SettingsNavigationItem i) => i.id),
        isNot(contains('lookup.browser_extension')),
      );
      expect(
        _section(
          lookup,
          'lookup.section.integrations',
        ).items.map((SettingsItem i) => i.id),
        contains('lookup.browser_extension'),
      );
      expect(
        _section(lookup, 'lookup.section.audio').items.first.id,
        buildManageAudioSourcesItem().id,
      );
    },
  );

  test(
    'catalog endpoint is separate from OCR and data root belongs to storage',
    () {
      final SettingsDestination manga = buildMangaDestination();
      expect(
        _section(
          manga,
          'manga.section.catalog',
        ).items.map((SettingsItem i) => i.id),
        contains('manga.online_catalog_base_url'),
      );
      expect(
        _section(
          manga,
          'manga.section.ocr',
        ).items.map((SettingsItem i) => i.id),
        isNot(contains('manga.online_catalog_base_url')),
      );
      expect(
        _item(buildStorageDestination(), 'sync.data_storage_location'),
        isA<SettingsCustomItem>(),
      );
      expect(
        buildSystemDestination().sections
            .expand((SettingsSection s) => s.items)
            .map((SettingsItem i) => i.id),
        isNot(contains('sync.data_storage_location')),
      );
    },
  );
}

/// Global resources must not require a listening configuration or a live host.
class _GlobalModelContext implements SettingsContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected context dependency: ${invocation.memberName}',
  );
}
