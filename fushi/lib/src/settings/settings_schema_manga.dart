import 'dart:io';

import 'package:flutter/material.dart';

import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_manga_ocr.dart';
import 'package:fushi/utils.dart';

/// 「漫画」一级设置分类。
///
/// 此前漫画在设置页只有一个折叠的「漫画 OCR」组，寄生在**阅读**分类末尾
/// （`settings_schema_reading.dart` 内联 [buildMangaOcrSection]），而真正影响日常
/// 观看的三项（阅读方向 / 缩放 / 翻页）根本不在设置里，只能在漫画阅读器的右键菜单
/// 里改，重装或换设备后无从预设。漫画与 EPUB 阅读共用「阅读」分类本身就是错的：
/// 两者没有一个设置项是共享的（漫画没有字体/行距/排版方向，EPUB 没有跨页/缩放）。
///
/// 故拆成独立一级分类，并把漫画阅读器的观看偏好一并抬进来。OCR 组原样复用
/// （[buildMangaOcrSection]），只是换了归属。
SettingsDestination buildMangaDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.manga,
    title: t.manga_library,
    summary: t.settings_destination_manga_summary,
    icon: Icons.auto_stories_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.manga_section_viewing,
        items: <SettingsItem>[
          // 阅读方向：偏好是新书的默认值，已打开的书仍按自身状态走。
          SettingsSegmentedItem<String>(
            id: 'manga.reading_direction',
            title: t.manga_reading_direction,
            icon: Icons.swap_horiz_outlined,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'rtl',
                label: t.manga_direction_rtl,
              ),
              SettingsSegmentOption<String>(
                value: 'ltr',
                label: t.manga_direction_ltr,
              ),
            ],
            selected: (SettingsContext c) => c.appModel.mangaReadingDirection,
            onChanged: (SettingsContext c, String value) =>
                c.appModel.setMangaReadingDirection(value),
          ),
          SettingsSliderItem(
            id: 'manga.default_zoom',
            title: t.manga_default_zoom,
            icon: Icons.zoom_in_outlined,
            min: kMangaZoomMinPercent.toDouble(),
            max: kMangaZoomMaxPercent.toDouble(),
            divisions: (kMangaZoomMaxPercent - kMangaZoomMinPercent) ~/ 10,
            step: 10,
            titleReadout: true,
            commitOnRelease: true,
            label: (double v) => '${v.round()}%',
            value: (SettingsContext c) => c.appModel.mangaZoomPercent
                .clamp(kMangaZoomMinPercent, kMangaZoomMaxPercent)
                .toDouble(),
            onChanged: (SettingsContext c, double value) =>
                c.appModel.setMangaZoomPercent(value.round()),
          ),
          // 灵敏度：滚轮/捏合每一步缩放多少的倍率。旧实现丢弃滚轮 delta 幅值、
          // 恒定 ±10 个百分点，触控板与鼠标同等对待，是「缩放极其不灵敏」的主因；
          // 算法已改成按 delta 比例的乘法缩放，这里让用户再微调总倍率。
          SettingsSliderItem(
            id: 'manga.zoom_sensitivity',
            title: t.manga_zoom_sensitivity,
            icon: Icons.tune_outlined,
            min: kMangaZoomSensitivityMin.toDouble(),
            max: kMangaZoomSensitivityMax.toDouble(),
            divisions:
                (kMangaZoomSensitivityMax - kMangaZoomSensitivityMin) ~/ 25,
            step: 25,
            titleReadout: true,
            commitOnRelease: true,
            label: (double v) => '${v.round()}%',
            value: (SettingsContext c) => c.appModel.mangaZoomSensitivity
                .clamp(kMangaZoomSensitivityMin, kMangaZoomSensitivityMax)
                .toDouble(),
            onChanged: (SettingsContext c, double value) =>
                c.appModel.setMangaZoomSensitivity(value.round()),
          ),
          SettingsSegmentedItem<String>(
            id: 'manga.page_animation',
            title: t.manga_page_animation,
            icon: Icons.animation_outlined,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: MangaPageAnimation.none.key,
                label: t.manga_page_animation_none,
              ),
              SettingsSegmentOption<String>(
                value: MangaPageAnimation.slide.key,
                label: t.manga_page_animation_slide,
              ),
              SettingsSegmentOption<String>(
                value: MangaPageAnimation.fade.key,
                label: t.manga_page_animation_fade,
              ),
            ],
            selected: (SettingsContext c) =>
                MangaPageAnimationKey.fromKey(c.appModel.mangaPageAnimation)
                    .key,
            onChanged: (SettingsContext c, String value) =>
                c.appModel.setMangaPageAnimation(value),
          ),
          SettingsSwitchItem(
            id: 'manga.tap_zone_paging',
            title: t.manga_tap_zone_paging,
            subtitle: t.manga_tap_zone_paging_subtitle,
            icon: Icons.touch_app_outlined,
            value: (SettingsContext c) => c.appModel.mangaTapZonePaging,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.setMangaTapZonePaging(value),
          ),
          // 音量键只有 Android 侧 `MainActivity.dispatchKeyEvent` 会拦截并转发
          // （见 VolumeKeyChannel），iOS 与桌面端均没有实现，故只在 Android 显示。
          SettingsSwitchItem(
            id: 'manga.volume_key_paging',
            title: t.manga_volume_key_paging,
            subtitle: t.manga_volume_key_paging_subtitle,
            icon: Icons.volume_up_outlined,
            visible: (_) => Platform.isAndroid,
            value: (SettingsContext c) => c.appModel.mangaVolumeKeyPaging,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.setMangaVolumeKeyPaging(value),
          ),
        ],
      ),
      buildMangaOcrSection(),
    ],
  );
}
