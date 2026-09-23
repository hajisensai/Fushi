import 'package:fushi/src/media/manga/manga_reading_mode.dart';

/// Mihon-compatible page scaling choices.
enum MangaScaleType { fitScreen, stretch, fitWidth, fitHeight, original, smart }

extension MangaScaleTypeKey on MangaScaleType {
  String get key => switch (this) {
    MangaScaleType.fitScreen => 'fit_screen',
    MangaScaleType.stretch => 'stretch',
    MangaScaleType.fitWidth => 'fit_width',
    MangaScaleType.fitHeight => 'fit_height',
    MangaScaleType.original => 'original',
    MangaScaleType.smart => 'smart',
  };

  static MangaScaleType fromKey(String value) => switch (value) {
    'stretch' => MangaScaleType.stretch,
    'fit_width' => MangaScaleType.fitWidth,
    'fit_height' => MangaScaleType.fitHeight,
    'original' => MangaScaleType.original,
    'smart' => MangaScaleType.smart,
    _ => MangaScaleType.fitScreen,
  };
}

/// Tap-zone layouts exposed by Mihon.  The existing [MangaTapZoneLayout]
/// remains the rendering type; this enum is the persisted reader contract.
enum MangaTapZonePreset {
  defaultZones,
  lShaped,
  kindle,
  edge,
  rightAndLeft,
  disabled,
  topBottom,
}

extension MangaTapZonePresetKey on MangaTapZonePreset {
  String get key => switch (this) {
    MangaTapZonePreset.defaultZones => 'default',
    MangaTapZonePreset.lShaped => 'l_shaped',
    MangaTapZonePreset.kindle => 'kindle',
    MangaTapZonePreset.edge => 'edge',
    MangaTapZonePreset.rightAndLeft => 'right_left',
    MangaTapZonePreset.disabled => 'disabled',
    MangaTapZonePreset.topBottom => 'top_bottom',
  };

  static MangaTapZonePreset fromKey(String value) => switch (value) {
    'l_shaped' => MangaTapZonePreset.lShaped,
    'kindle' => MangaTapZonePreset.kindle,
    'edge' => MangaTapZonePreset.edge,
    'right_left' => MangaTapZonePreset.rightAndLeft,
    'disabled' => MangaTapZonePreset.disabled,
    'top_bottom' => MangaTapZonePreset.topBottom,
    _ => MangaTapZonePreset.defaultZones,
  };
}

/// Immutable, validated reader defaults. Per-book overrides are sparse JSON:
/// absent/null fields inherit the current global value, including future changes.
class MangaReaderPreferences {
  const MangaReaderPreferences({
    this.mode = MangaReadingMode.spread,
    this.scaleType = MangaScaleType.fitScreen,
    this.direction = 'rtl',
    this.background = 'black',
    this.zoomStartPosition = 'automatic',
    this.rotation = 'free',
    this.saveDirectory = 'chapter',
    this.zoomStart = 100,
    this.longStripSidePadding = 0,
    this.tapZones = MangaTapZonePreset.defaultZones,
    this.autoMode = false,
    this.autoZoomWide = false,
    this.panWide = true,
    this.animateDoubleTap = true,
    this.disableZoomOut = false,
    this.cropBorders = false,
    this.splitWidePages = false,
    this.rotateWidePages = false,
    this.showPageNumber = true,
    this.invertHorizontal = false,
    this.invertVertical = false,
    this.invertBoth = false,
    this.showReadingMode = true,
    this.showTapZonesOverlay = false,
    this.animateTransitions = true,
    this.fullscreen = true,
    this.keepScreenOn = true,
    this.showCutout = true,
    this.flashOnPageChange = false,
    this.skipRead = false,
    this.skipFiltered = true,
    this.skipDuplicate = false,
    this.alwaysShowChapterTransition = true,
    this.volumeKeys = true,
    this.invertVolumeKeys = false,
    this.automaticBackground = false,
    this.webtoonDoubleTapZoom = true,
    this.showPageGaps = true,
    this.autoScroll = false,
    this.autoScrollSpeed = 40,
    this.readerHideThreshold = 13,
    this.einkMode = false,
    this.lookupOnHover = false,
    this.showOcrBoxes = false,
    this.invertColors = false,
    this.grayscale = false,
    this.brightness = 0,
    this.contrast = 100,
    this.saturation = 100,
    this.customColorFilter = false,
    this.colorFilterColor = '#F4ECD8',
    this.colorFilterOpacity = 20,
    this.ocrTrigger = 'automatic',
  });

  final MangaReadingMode mode;
  final MangaScaleType scaleType;
  final String direction;
  final String background;
  final String zoomStartPosition;
  final String rotation;
  final String saveDirectory;
  final int zoomStart;
  final int longStripSidePadding;
  final MangaTapZonePreset tapZones;
  final bool autoMode;
  final bool autoZoomWide;
  final bool panWide;
  final bool animateDoubleTap;
  final bool disableZoomOut;
  final bool cropBorders;
  final bool splitWidePages;
  final bool rotateWidePages;
  final bool showPageNumber;
  final bool invertHorizontal;
  final bool invertVertical;
  final bool invertBoth;
  final bool showReadingMode;
  final bool showTapZonesOverlay;
  final bool animateTransitions;
  final bool fullscreen;
  final bool keepScreenOn;
  final bool showCutout;
  final bool flashOnPageChange;
  final bool skipRead;
  final bool skipFiltered;
  final bool skipDuplicate;
  final bool alwaysShowChapterTransition;
  final bool volumeKeys;
  final bool invertVolumeKeys;
  final bool automaticBackground;
  final bool webtoonDoubleTapZoom;
  final bool showPageGaps;
  final bool autoScroll;

  /// Continuous scrolling speed in CSS pixels per second.
  final int autoScrollSpeed;
  final int readerHideThreshold;
  final bool einkMode;
  final bool lookupOnHover;
  final bool showOcrBoxes;
  final bool invertColors;
  final bool grayscale;

  /// Percentage adjustment, with zero preserving the source brightness.
  final int brightness;
  final int contrast;
  final int saturation;
  final bool customColorFilter;
  final String colorFilterColor;
  final int colorFilterOpacity;
  final String ocrTrigger;

  Map<String, Object> toJson() => <String, Object>{
    'mode': mode.storageKey,
    'scaleType': scaleType.key,
    'direction': direction,
    'background': background,
    'zoomStartPosition': zoomStartPosition,
    'rotation': rotation,
    'saveDirectory': saveDirectory,
    'zoomStart': zoomStart,
    'longStripSidePadding': longStripSidePadding,
    'tapZones': tapZones.key,
    'autoMode': autoMode,
    'autoZoomWide': autoZoomWide,
    'panWide': panWide,
    'animateDoubleTap': animateDoubleTap,
    'disableZoomOut': disableZoomOut,
    'cropBorders': cropBorders,
    'splitWidePages': splitWidePages,
    'rotateWidePages': rotateWidePages,
    'showPageNumber': showPageNumber,
    'invertHorizontal': invertHorizontal,
    'invertVertical': invertVertical,
    'invertBoth': invertBoth,
    'showReadingMode': showReadingMode,
    'showTapZonesOverlay': showTapZonesOverlay,
    'animateTransitions': animateTransitions,
    'fullscreen': fullscreen,
    'keepScreenOn': keepScreenOn,
    'showCutout': showCutout,
    'flashOnPageChange': flashOnPageChange,
    'skipRead': skipRead,
    'skipFiltered': skipFiltered,
    'skipDuplicate': skipDuplicate,
    'alwaysShowChapterTransition': alwaysShowChapterTransition,
    'volumeKeys': volumeKeys,
    'invertVolumeKeys': invertVolumeKeys,
    'automaticBackground': automaticBackground,
    'webtoonDoubleTapZoom': webtoonDoubleTapZoom,
    'showPageGaps': showPageGaps,
    'autoScroll': autoScroll,
    'autoScrollSpeed': autoScrollSpeed,
    'readerHideThreshold': readerHideThreshold,
    'einkMode': einkMode,
    'lookupOnHover': lookupOnHover,
    'showOcrBoxes': showOcrBoxes,
    'invertColors': invertColors,
    'grayscale': grayscale,
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
    'customColorFilter': customColorFilter,
    'colorFilterColor': colorFilterColor,
    'colorFilterOpacity': colorFilterOpacity,
    'ocrTrigger': ocrTrigger,
  };

  factory MangaReaderPreferences.fromJson(Map<String, Object?> json) {
    bool flag(String key, bool fallback) =>
        json[key] is bool ? json[key]! as bool : fallback;
    int number(String key, int fallback, int min, int max) {
      final Object? value = json[key];
      return value is num && value.isFinite
          ? value.round().clamp(min, max)
          : fallback;
    }

    String text(String key, String fallback, Set<String> allowed) {
      final Object? value = json[key];
      return value is String && allowed.contains(value) ? value : fallback;
    }

    return MangaReaderPreferences(
      mode: MangaReadingModeSemantics.fromStorageKey(
        json['mode'] is String ? json['mode']! as String : 'spread',
      ),
      scaleType: MangaScaleTypeKey.fromKey(
        json['scaleType'] is String
            ? json['scaleType']! as String
            : 'fit_screen',
      ),
      direction: text('direction', 'rtl', <String>{'rtl', 'ltr'}),
      background: text('background', 'black', <String>{
        'black',
        'white',
        'gray',
        'theme',
      }),
      zoomStartPosition: text('zoomStartPosition', 'automatic', <String>{
        'automatic',
        'left',
        'center',
        'right',
      }),
      rotation: text('rotation', 'free', <String>{
        'free',
        'portrait',
        'landscape',
      }),
      saveDirectory: text('saveDirectory', 'chapter', <String>{
        'flat',
        'book',
        'chapter',
      }),
      zoomStart: number('zoomStart', 100, 50, 400),
      longStripSidePadding: number('longStripSidePadding', 0, 0, 24),
      tapZones: MangaTapZonePresetKey.fromKey(
        json['tapZones'] is String ? json['tapZones']! as String : 'default',
      ),
      autoMode: flag('autoMode', false),
      autoZoomWide: flag('autoZoomWide', false),
      panWide: flag('panWide', true),
      animateDoubleTap: flag('animateDoubleTap', true),
      disableZoomOut: flag('disableZoomOut', false),
      cropBorders: flag('cropBorders', false),
      splitWidePages: flag('splitWidePages', false),
      rotateWidePages: flag('rotateWidePages', false),
      showPageNumber: flag('showPageNumber', true),
      invertHorizontal: flag('invertHorizontal', false),
      invertVertical: flag('invertVertical', false),
      invertBoth: flag('invertBoth', false),
      showReadingMode: flag('showReadingMode', true),
      showTapZonesOverlay: flag('showTapZonesOverlay', false),
      animateTransitions: flag('animateTransitions', true),
      fullscreen: flag('fullscreen', true),
      keepScreenOn: flag('keepScreenOn', true),
      showCutout: flag('showCutout', true),
      flashOnPageChange: flag('flashOnPageChange', false),
      skipRead: flag('skipRead', false),
      skipFiltered: flag('skipFiltered', true),
      skipDuplicate: flag('skipDuplicate', false),
      alwaysShowChapterTransition: flag('alwaysShowChapterTransition', true),
      volumeKeys: flag('volumeKeys', true),
      invertVolumeKeys: flag('invertVolumeKeys', false),
      automaticBackground: flag('automaticBackground', false),
      webtoonDoubleTapZoom: flag('webtoonDoubleTapZoom', true),
      showPageGaps: flag('showPageGaps', true),
      autoScroll: flag('autoScroll', false),
      autoScrollSpeed: number('autoScrollSpeed', 40, 5, 200),
      readerHideThreshold: number('readerHideThreshold', 13, 0, 100),
      einkMode: flag('einkMode', false),
      lookupOnHover: flag('lookupOnHover', false),
      showOcrBoxes: flag('showOcrBoxes', false),
      invertColors: flag('invertColors', false),
      grayscale: flag('grayscale', false),
      brightness: number('brightness', 0, -100, 100),
      contrast: number('contrast', 100, 0, 200),
      saturation: number('saturation', 100, 0, 200),
      customColorFilter: flag('customColorFilter', false),
      colorFilterColor:
          json['colorFilterColor'] is String &&
              RegExp(
                r'^#[0-9a-fA-F]{6}$',
              ).hasMatch(json['colorFilterColor']! as String)
          ? json['colorFilterColor']! as String
          : '#F4ECD8',
      colorFilterOpacity: number('colorFilterOpacity', 20, 0, 100),
      ocrTrigger: text('ocrTrigger', 'automatic', <String>{
        'automatic',
        'manual',
      }),
    );
  }

  MangaReaderPreferences copyWithJson(Map<String, Object?> changes) =>
      resolve(this, changes);

  static MangaReaderPreferences resolve(
    MangaReaderPreferences global,
    Map<String, Object?>? override,
  ) => MangaReaderPreferences.fromJson(<String, Object?>{
    ...global.toJson(),
    ...normalizedOverride(override ?? const <String, Object?>{}),
  });

  /// Only known fields of the correct wire type can override a global value.
  /// Invalid enum values inherit rather than resetting to an unrelated default.
  static Map<String, Object?> normalizedOverride(Map<String, Object?> values) {
    final Map<String, Object> defaults = const MangaReaderPreferences()
        .toJson();
    final Map<String, Object> normalized = MangaReaderPreferences.fromJson(
      values,
    ).toJson();
    return <String, Object?>{
      for (final MapEntry<String, Object?> entry in values.entries)
        if (defaults.containsKey(entry.key) &&
            entry.value != null &&
            ((defaults[entry.key] is bool && entry.value is bool) ||
                (defaults[entry.key] is int &&
                    entry.value is num &&
                    (entry.value! as num).isFinite) ||
                (defaults[entry.key] is String &&
                    entry.value == normalized[entry.key])))
          entry.key: normalized[entry.key],
    };
  }
}
