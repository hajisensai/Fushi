import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr_host/asr_host.dart' show isAsrSupported;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/settings/settings_schema_general.dart';
import 'package:fushi/src/settings/settings_schema_listening.dart';
import 'package:fushi/src/settings/settings_schema_local_services.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart';
import 'package:fushi/src/settings/settings_schema_manga.dart';
import 'package:fushi/src/settings/settings_schema_models.dart';
import 'package:fushi/src/settings/settings_schema_navigation.dart';
import 'package:fushi/src/settings/settings_schema_profiles.dart';
import 'package:fushi/src/settings/settings_schema_reading.dart';
import 'package:fushi/src/settings/settings_schema_storage.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';

List<SettingsDestination> _destinations() => <SettingsDestination>[
  buildGeneralDestination(),
  buildAppearanceDestination(),
  buildNavigationDestination(),
  buildReadingDestination(),
  // 听书是独立分类，分区不再挂在阅读下面。
  buildListeningDestination(),
  buildMangaDestination(),
  buildVideoDestination(),
  // 视频画面 / 字幕两组分区住在子页里，唯一性同样要覆盖它们。
  buildVideoPictureDestination(),
  buildVideoSubtitleDestination(),
  buildLookupDestination(),
  _lookupPopupDestination(),
  buildModelsDestination(),
  buildProfilesDestination(),
  buildStorageDestination(),
  buildSystemDestination(),
];

/// 查词弹窗子页（构造函数私有，只能经入口行 `lookup.popup.open` 打开）。
SettingsDestination _lookupPopupDestination() =>
    (_item(buildLookupDestination(), 'lookup.popup.open')
            as SettingsNavigationItem)
        .child!();

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

  test('video groups follow playback, picture, subtitles, audio, controls', () {
    // 视频首页：播放 → 沉浸 → 原盘 → 画面与字幕（两个子页入口）→ 音频 →
    // 操控与手势 → 弹幕 → 截图与片段 → 媒体库 → 高级（Lua）→ 播放中专属。
    expect(
      buildVideoDestination().sections.map((SettingsSection s) => s.id),
      <String>[
        'video.section.playback',
        'video.section.immersive',
        'video.section.disc',
        'video.section.picture_subtitle',
        'video.section.audio',
        'video.section.controls',
        'video.section.danmaku',
        'video.section.capture',
        'video.section.library',
        'video.section.advanced',
        'video.section.session',
      ],
    );
    expect(
      _section(
        buildVideoDestination(),
        'video.section.picture_subtitle',
      ).items.map((SettingsItem i) => i.id),
      containsAll(<String>['video.picture.open', 'video.subtitle.open']),
    );
    // 画面子页：缩放与比例（含画面几何项）→ 画质 → HDR → 色彩。
    expect(
      buildVideoPictureDestination().sections.map((SettingsSection s) => s.id),
      <String>[
        'video.section.display',
        'video.section.quality',
        'video.section.hdr',
        'video.section.color',
      ],
    );
    // 字幕子页：外观 → 位置 → 轨道选择 → 听力练习 → 硬字幕 → 获取与对齐。
    expect(
      buildVideoSubtitleDestination().sections.map((SettingsSection s) => s.id),
      <String>[
        'video.section.subtitles',
        'video.section.subtitle_position',
        'video.section.subtitle_tracks',
        'video.section.subtitle_listening',
        'video.section.subtitle_hardsub',
        'video.section.subtitle_behavior',
      ],
    );
    expect(
      _section(
        buildVideoSubtitleDestination(),
        'video.section.subtitles',
      ).items.first.id,
      'video.subtitle.preview',
      reason: 'The subtitle style preview leads the subtitle group.',
    );
    // 进阶组折叠：首页的音频与高级；子页本身已是二级入口，里面只有色彩折叠。
    for (final SettingsSection section in <SettingsSection>[
      ...buildVideoDestination().sections,
      ...buildVideoPictureDestination().sections,
      ...buildVideoSubtitleDestination().sections,
    ]) {
      final bool advanced = <String>{
        'video.section.color',
        'video.section.audio',
        'video.section.advanced',
      }.contains(section.id);
      expect(
        section.presentation,
        advanced
            ? SettingsSectionPresentation.collapsed
            : SettingsSectionPresentation.alwaysExpanded,
        reason: section.id,
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
          'reading.section.pages',
          // #1351 的 VN 设置组：整组只在 VN 模式下可见，紧跟模式与分页选择。
          'reading.section.visual_novel',
          'reading.section.typography',
          'reading.section.margins',
          // 翻页方向并进「翻页与手势」，手势类设置只有这一组。
          'reading.section.page_turn_input',
          'reading.section.toolbar',
          'reading.section.chrome',
          'reading.section.advanced_typography',
        ],
      );
      // 听书是独立分类：阅读页不再混入 listening.section.*；学习计时归「通用」。
      expect(
        buildListeningDestination().sections.map((SettingsSection s) => s.id),
        <String>[
          'listening.section.playback',
          'listening.section.tts',
          'listening.section.materials',
          'listening.section.floating_lyric',
          // 悬浮字幕外观与排版（默认折叠，与 galgame 浮窗「窗口与可读性」同构）。
          'listening.section.floating_lyric_appearance',
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
          (buildLocalServicesDestination(), 'local_services.section.fushi_api'),
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
            (buildModelsDestination(), 'listening.asr_models'),
            (buildModelsDestination(), 'models.ocr'),
            (buildModelsDestination(), 'storage.ocr_models'),
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
    'ASR models have one global Models owner independent of module settings',
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
        <SettingsDestinationId>[SettingsDestinationId.models],
      );
      final SettingsDestination models = owners.single;
      expect(
        models.visible,
        isNull,
        reason: 'Global models must not be gated by the listening module',
      );
      final List<SettingsSearchEntry> results =
          flattenVisibleSettings(<SettingsDestination>[
                models,
              ], _GlobalModelContext())
              .where(
                (SettingsSearchEntry e) => e.item.id == 'listening.asr_models',
              )
              .toList();
      expect(results, hasLength(isAsrSupported ? 1 : 0));
      if (isAsrSupported) {
        expect(results.single.destination.id, SettingsDestinationId.models);
        expect(results.single.hasRevealTarget, isTrue);
        expect(
          results.single.sectionTitle,
          _section(models, 'models.section.kinds').title,
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
      // 浏览器扩展入口跟着 Fushi API 服务器搬进「本机服务」（导航里的独立
      // 分类）；查词页连指路行 lookup.local_services 也已删除。
      expect(
        _section(
          lookup,
          'lookup.section.integrations',
        ).items.map((SettingsItem i) => i.id),
        allOf(
          isNot(contains('lookup.local_services')),
          isNot(contains('lookup.fushi_api_server')),
          isNot(contains('lookup.fushi_api_key')),
        ),
      );
      // 本机服务页：服务器本身的开关 / 访问范围 / 端口 / 密钥一组，接入它的工具
      // （浏览器扩展、AnkiConnect 端点）另起「接入的工具」一组。
      expect(
        _section(
          buildLocalServicesDestination(),
          'local_services.section.tools',
        ).items.map((SettingsItem i) => i.id),
        contains('local_services.browser_extension'),
      );
      expect(
        _section(
          buildLocalServicesDestination(),
          'local_services.section.fushi_api',
        ).items.map((SettingsItem i) => i.id),
        containsAll(<String>[
          'local_services.fushi_api_server',
          'local_services.fushi_api_access',
          'local_services.fushi_api_port',
          'local_services.fushi_api_key',
        ]),
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
///
/// The only state exposed is module visibility with **every module off**: the
/// Models page's LLM row is gated by the services module, while ASR models must
/// stay reachable regardless.
class _GlobalModelContext implements SettingsContext {
  @override
  AppModel get appModel => _NoModulesAppModel();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected context dependency: ${invocation.memberName}',
  );
}

class _NoModulesAppModel implements AppModel {
  @override
  ModuleVisibility get moduleVisibility => const ModuleVisibility(<ModuleId>{});

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected AppModel dependency: ${invocation.memberName}',
  );
}
