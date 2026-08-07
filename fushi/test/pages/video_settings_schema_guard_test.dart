import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';

/// 阶段 B 守卫：视频设置的唯一真相源是 settings_schema_video.dart——全局设置页直接
/// 渲染其 sections，播放页快捷面板按 [VideoPlacement] 投影消费同一份声明。本文件
/// 用数据模型断言（仿 reader_settings_reorg_guard_test）锁住：
/// 1) 首页 pref-only 集合仍可达（TODO-286 never-break-userspace）；
/// 2) 面板七个分组的投影非空、组内 order 严格单调无撞号；
/// 3) 控制器绑定行全部 host 门控（全局设置页恒隐藏）；
/// 4) 面板文件真的在消费投影，而不是又长出第二套手写行。
void main() {
  /// 展平 schema 里的所有 item（含 host 门控的「播放中专属」section）。
  List<SettingsItem> allItems() {
    final SettingsDestination destination = buildVideoDestination();
    return <SettingsItem>[
      for (final SettingsSection section in destination.sections)
        ...section.items,
    ];
  }

  test('TODO-186: global settings has a dedicated video destination', () {
    final String destinationSrc =
        File('lib/src/settings/settings_destination.dart').readAsStringSync();
    final String schemaSrc =
        File('lib/src/settings/settings_schema.dart').readAsStringSync();
    expect(destinationSrc.contains('video,'), isTrue,
        reason: 'SettingsDestinationId must include a dedicated video tab');
    expect(schemaSrc.contains('buildVideoDestination(),'), isTrue,
        reason:
            'buildSettingsSchema must expose video settings as a top-level destination');
    final SettingsDestination destination = buildVideoDestination();
    expect(destination.id, SettingsDestinationId.video);
  });

  test('TODO-286: video destination owns the pref-only in-player parity set',
      () {
    final Set<String> ids =
        allItems().map((SettingsItem item) => item.id).toSet();

    // TODO-286 parity list: every pref-only video setting that also lives in the
    // in-player sheet must be reachable from home settings.
    for (final String id in <String>[
      // Playback
      'video.playback.auto_play_next',
      'video.playback.immersive_mode',
      'video.playback.picture_fit',
      'video.playback.double_tap',
      'video.playback.lock_window_aspect',
      'video.playback.long_press_speed',
      'video.playback.seek_seconds',
      'video.playback.pause_at_subtitle_end',
      // Image quality (mpv pure-pref subset)
      'video.quality.enhancement',
      'video.quality.sigmoid',
      'video.quality.hwdec',
      'video.quality.deband',
      'video.quality.loop',
      'video.quality.dither',
      'video.quality.interpolation',
      'video.quality.deinterlace',
      'video.quality.correct_downscale',
      // TODO-1247 geometry parity (mpv videoMpvConfig, applies on next open).
      'video.geometry.rotate',
      'video.geometry.aspect',
      'video.geometry.zoom',
      'video.geometry.panscan',
      // TODO-1247 color-balance parity.
      'video.color.brightness',
      'video.color.contrast',
      'video.color.saturation',
      'video.color.gamma',
      'video.color.hue',
      // TODO-1247 audio parity.
      'video.audio.pitch',
      'video.audio.channels',
      'video.audio.normalize_downmix',
      // Subtitle appearance
      'video.subtitle.obscure',
      'video.subtitle.respect_ass_style',
      'video.subtitle.font_size',
      'video.subtitle.font_weight',
      'video.subtitle.shadow',
      'video.subtitle.bg_opacity',
      'video.subtitle.position',
      // Danmaku
      'video.danmaku.enabled',
      'video.danmaku.online',
      'video.danmaku.max_active',
      // Controls
      'video.controls.reset_layout',
    ]) {
      expect(ids, contains(id), reason: 'video destination should own $id');
    }
  });

  test('阶段B: every VideoGroup projects a non-empty ordered set', () {
    final Map<VideoGroup, List<SettingsItem>> grouped =
        <VideoGroup, List<SettingsItem>>{};
    for (final SettingsItem item in allItems()) {
      final VideoPlacement? placement = item.video;
      if (placement == null) continue;
      grouped.putIfAbsent(placement.group, () => <SettingsItem>[]).add(item);
    }

    for (final VideoGroup group in VideoGroup.values) {
      final List<SettingsItem> items = grouped[group] ?? <SettingsItem>[];
      expect(items, isNotEmpty,
          reason: '面板分类 ${group.name} 不能投影为空——旧手写面板每个分类都有内容');
      // 组内 order 严格单调无撞号（撞号会让投影顺序取决于声明顺序，脆弱）。
      final List<int> orders =
          items.map((SettingsItem i) => i.video!.order).toList();
      final Set<int> unique = orders.toSet();
      expect(unique.length, orders.length,
          reason: '${group.name} 组内 order 撞号: $orders');
    }
  });

  test('阶段B: controller-bound rows are host-gated (hidden on the home page)',
      () {
    // 播放中专属行：全局设置页 SettingsContext.video == null，必须声明 visible
    // 谓词门控（否则会在首页出现一个没有播放器就没意义/会崩的行）。
    const Set<String> hostOnlyIds = <String>{
      'video.player.quality_entry',
      'video.player.skia_fallback',
      'video.player.speed',
      'video.playback.speed_step',
      'video.player.audio_track',
      'video.player.subtitle_track',
      'video.player.subtitle_sync',
      'video.player.subtitle_text_color',
      'video.subtitle.no_background',
      'video.player.subtitle_bg_color',
      'video.player.subtitle_style_reset',
      'video.player.shaders',
      'video.player.mpv_raw',
      'video.player.mpv_reset',
      'video.player.danmaku_manual_match',
      'video.danmaku.font_scale',
      'video.danmaku.opacity',
      'video.danmaku.speed',
      'video.danmaku.area',
      'video.player.danmaku_block_rules',
      'video.player.controls_editor',
    };
    final Map<String, SettingsItem> byId = <String, SettingsItem>{
      for (final SettingsItem item in allItems()) item.id: item,
    };
    for (final String id in hostOnlyIds) {
      final SettingsItem? item = byId[id];
      expect(item, isNotNull, reason: 'missing in-player item $id');
      expect(item!.visible, isNotNull,
          reason: '$id 必须 host 门控（visible 谓词），否则会泄漏进全局设置页');
      expect(item.video, isNotNull,
          reason: '$id 必须带 VideoPlacement 才能出现在播放页面板');
      // 播放中专属行不得进全局搜索（无播放器时是死胡同）。
      if (item is SettingsCustomItem) {
        expect(item.searchTitle, isNull,
            reason: '$id 是播放中专属行，不应声明 searchTitle 进入全局搜索');
      }
    }
  });

  test(
      '阶段B: the sheet consumes the schema projection (no second hand-built copy)',
      () {
    final String sheetSrc =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();
    // 面板必须经共享投影 + 渲染器消费 schema（与阅读器面板同款）。
    expect(sheetSrc.contains('buildVideoGroupDestination('), isTrue,
        reason: 'sheet must project groups via buildVideoGroupDestination');
    expect(sheetSrc.contains('buildDetailContent('), isTrue,
        reason: 'sheet must render through the shared renderer path');
    // 不允许再长出第二套手写配置行（阶段 B 消灭的镜像重复）。分类导航行
    // （AdaptiveSettingsNavigationRow）是外壳导航，不算配置行。
    for (final String forbidden in <String>[
      'AdaptiveSettingsSwitchRow(',
      'AdaptiveSettingsSliderRow(',
      'AdaptiveSettingsStepperRow(',
      'AdaptiveSettingsSegmentedRow<',
      'AdaptiveSettingsPickerRow<',
      'VideoMpvConfig.decode',
      'VideoAsbplayerConfig.decode',
      'VideoSubtitleStyle.decode',
    ]) {
      expect(sheetSrc.contains(forbidden), isFalse,
          reason:
              'sheet must not hand-build settings rows ($forbidden found) — '
              'declare the row once in settings_schema_video.dart instead');
    }
  });

  test(
      '审查 Finding 9: sheet categories are driven by VideoGroup.values '
      '(no parallel hand-written list)', () {
    // _categories() 必须由 VideoGroup 枚举驱动：新增第 8 个分组时 _groupIcon /
    // _groupTitle 的 exhaustive switch 编译期报错，面板不可能静默漏掉分组。
    // 本守卫防止回退成与枚举平行的手写分类列表（那会让新分组悄悄不出现在面板）。
    final String sheetSrc =
        File('lib/src/media/video/video_quick_settings_sheet.dart')
            .readAsStringSync();
    expect(
        sheetSrc.contains('for (final VideoGroup group in VideoGroup.values)'),
        isTrue,
        reason: '_categories() 必须遍历 VideoGroup.values 生成，禁止手写平行列表');
    // 每个分组在 icon/label 映射里都被显式处理（exhaustive switch 的源码影子）。
    for (final VideoGroup group in VideoGroup.values) {
      expect(sheetSrc.contains('case VideoGroup.${group.name}:'), isTrue,
          reason: '分组 ${group.name} 必须有 icon/label 映射分支');
    }
  });

  test('TODO-286: home video settings stay pref-only (no live controller)', () {
    // schema 文件本身不得依赖活播放器类型；控制器交互只能经
    // video_settings_actions.dart 的 host 回调间接发生。
    final String videoSrc =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    for (final String forbidden in <String>[
      'VideoPlayerController',
      'media_kit',
      'Player(',
    ]) {
      expect(videoSrc.contains(forbidden), isFalse,
          reason: 'settings_schema_video.dart must not depend on a live player '
              '($forbidden found)');
    }
    // 双路写穿层同样不得直接引播放器类型（回调闭包由视频页在构造 host 时捕获）。
    final String actionsSrc =
        File('lib/src/media/video/video_settings_actions.dart')
            .readAsStringSync();
    expect(actionsSrc.contains('VideoPlayerController'), isFalse);
    expect(actionsSrc.contains('media_kit'), isFalse);
  });

  test('TODO-522: global video settings can reset player button layout', () {
    final String videoSrc =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    expect(videoSrc.contains("id: 'video.controls.reset_layout'"), isTrue);
    expect(videoSrc.contains('t.video_control_reset_layout'), isTrue);
    // 双路写穿：无 host 落 pref（setVideoControlLayout），host 在场经页面回调实时生效。
    expect(videoSrc.contains('resetVideoControlLayoutDual('), isTrue);
    final String actionsSrc =
        File('lib/src/media/video/video_settings_actions.dart')
            .readAsStringSync();
    expect(actionsSrc.contains('setVideoControlLayout('), isTrue);
    expect(actionsSrc.contains('VideoControlLayout.currentChrome'), isTrue);
  });

  test(
      'TODO-1116/1119: Windows video quality group carries a black-flicker known-issue notice',
      () {
    final String videoSrc =
        File('lib/src/settings/settings_schema_video.dart').readAsStringSync();
    final String stringsSrc =
        File('lib/i18n/strings.i18n.json').readAsStringSync();

    // The notice must live inside the schema (Image quality group) as a
    // dedicated custom item, gated Windows-only via the isWindowsPlatform
    // helper. Never-break-userspace: it is a pure explanation row — it must not
    // wire a switch/default that would degrade non-Windows or Windows users.
    expect(videoSrc.contains("id: 'video.quality.windows_black_flash_notice'"),
        isTrue,
        reason: 'video quality group must own the black-flicker notice item');
    expect(videoSrc.contains('isWindowsPlatform'), isTrue,
        reason: 'black-flicker notice must be gated to Windows only');
    expect(videoSrc.contains('_buildWindowsBlackFlashNotice'), isTrue,
        reason: 'notice item must delegate to its info-row builder');

    // i18n-backed, and it must be a plain info row (no new pref write / default).
    expect(
        videoSrc.contains('t.video_windows_black_flash_notice_title'), isTrue);
    expect(
        videoSrc.contains('t.video_windows_black_flash_notice_body'), isTrue);
    expect(videoSrc.contains('Icons.info_outline'), isTrue,
        reason: 'notice should render as an informational row');
    expect(stringsSrc.contains('"video_windows_black_flash_notice_title"'),
        isTrue);
    expect(
        stringsSrc.contains('"video_windows_black_flash_notice_body"'), isTrue);
  });
}
