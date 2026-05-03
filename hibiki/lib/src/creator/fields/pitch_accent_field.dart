import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/dictionary.dart';
import 'package:hibiki/language.dart';
import 'package:hibiki/models.dart';

/// Returns the formatted pitch accent diagram HTML of a [DictionaryEntry].
class PitchAccentField extends Field {
  /// Initialise this field with the predetermined and hardset values.
  PitchAccentField._privateConstructor()
      : super(
          uniqueKey: key,
          label: 'Pitch Accent',
          description: 'Pre-fills text to export for pitch accent diagrams.',
          icon: Icons.swap_vert,
        );

  /// Get the singleton instance of this field.
  static PitchAccentField get instance => _instance;

  static final PitchAccentField _instance =
      PitchAccentField._privateConstructor();

  /// The unique key for this field.
  static const String key = 'pitch_accent';

  /// Extra value key for pitch-position HTML.
  static const String pitchPositionsExtraKey = 'pitchPositions';

  /// Extra value key for pitch-category HTML.
  static const String pitchCategoriesExtraKey = 'pitchCategories';

  /// Extracts pitch values returned by the popup mining JavaScript.
  static Map<String, String> extraValuesFromMineFields(
    Map<String, String> fields,
  ) {
    return {
      pitchPositionsExtraKey: fields[pitchPositionsExtraKey] ?? '',
      pitchCategoriesExtraKey: fields[pitchCategoriesExtraKey] ?? '',
    };
  }

  /// Builds pitch extra values from a dictionary entry.
  static Map<String, String> extraValuesFromEntry({
    required AppModel appModel,
    required DictionaryEntry entry,
  }) {
    final reading = entry.reading.isNotEmpty ? entry.reading : entry.word;
    final positions = _readPitchPositions(entry);
    return {
      pitchPositionsExtraKey: getAllHtmlPitch(
        reading: reading,
        positions: positions,
      ),
      pitchCategoriesExtraKey: _getAllCategories(reading, positions),
    };
  }

  /// Returns pitch-position SVG HTML from positions and reading.
  static String getAllHtmlPitch({
    required String reading,
    required List<int> positions,
  }) {
    if (positions.isEmpty || reading.isEmpty) return '';
    final buffer = StringBuffer();
    final seen = <int>{};
    for (final position in positions) {
      if (!seen.add(position)) continue;
      final patt = PitchSvg.pitchValueToPatt(reading, position);
      if (patt.isEmpty) continue;
      buffer.write(PitchSvg.pitchSvg(reading, patt));
    }
    return buffer.toString();
  }

  static String _getAllCategories(String reading, List<int> positions) {
    if (positions.isEmpty) return '';
    final moraCount = PitchSvg.hiraToMora(reading).length;
    final categories = <String>[];
    final seen = <int>{};
    for (final pos in positions) {
      if (!seen.add(pos)) continue;
      final cat = _pitchCategory(pos, moraCount);
      if (cat.isNotEmpty && !categories.contains(cat)) {
        categories.add(cat);
      }
    }
    return categories.join(',');
  }

  static String _pitchCategory(int pitchValue, int moraCount) {
    if (pitchValue == 0) return 'heiban';
    if (pitchValue == 1) return 'atamadaka';
    if (pitchValue >= moraCount) return 'odaka';
    if (pitchValue >= 2) return 'nakadaka';
    return '';
  }

  static List<int> _readPitchPositions(DictionaryEntry entry) {
    if (entry.extra.isEmpty) {
      return [];
    }

    Object? decoded;
    try {
      decoded = jsonDecode(entry.extra);
    } catch (_) {
      return [];
    }

    if (decoded is! Map) {
      return [];
    }
    final rawGroups = decoded['pitches'];
    if (rawGroups is! List) {
      return [];
    }

    final positions = <int>[];
    for (final rawGroup in rawGroups) {
      if (rawGroup is! Map) {
        continue;
      }
      final rawPositions = rawGroup['positions'];
      if (rawPositions is! List) {
        continue;
      }
      for (final rawPosition in rawPositions) {
        final position = (rawPosition as num?)?.toInt();
        if (position != null) {
          positions.add(position);
        }
      }
    }
    return positions;
  }

  @override
  String? onCreatorOpenAction({
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required DictionaryEntry entry,
    required bool creatorJustLaunched,
    required String? dictionaryName,
  }) {
    if (appModel.targetLanguage is! JapaneseLanguage) {
      return null;
    }

    final reading = entry.reading.isNotEmpty ? entry.reading : entry.word;
    final positions = _readPitchPositions(entry);
    return getAllHtmlPitch(reading: reading, positions: positions);
  }
}

/// Pitch utilities courtesy of Matthew Chan.
/// https://github.com/mathewthe2/immersion_reader/blob/main/lib/japanese/pitch.dart
class PitchSvg {
  static String pitchSvg(String word, String patt, {bool silent = false}) {
    /* Draw pitch accent patterns in SVG

    Examples:
        はし HLL (箸)
        はし LHL (橋)
        はし LHH (端)
        */
    List<String> mora = hiraToMora(word);
    if ((patt.length - mora.length != 1) && !silent) {
      debugPrint('pattern should be number of morae + 1. got $word, $patt');
    }
    int positions = max(mora.length, patt.length);
    const int stepWidth = 35;
    const int marginLr = 16;
    int svgWidth = max(0, ((positions - 1) * stepWidth) + (marginLr * 2));
    final svg = StringBuffer(
        '<svg xmlns="http://www.w3.org/2000/svg" width="${svgWidth * (3 / 5)}px" height="45px" viewBox="0 0 $svgWidth 75">');
    final chars = StringBuffer();
    for (int i = 0; i < mora.length; i++) {
      int xCenter = marginLr + (i * stepWidth);
      chars.write(_text(xCenter - 11, mora[i]));
    }
    final circles = StringBuffer();

    final paths = StringBuffer();
    String pathTyp = '';

    List<int> prevCenter = [-1, -1];
    for (int i = 0; i < patt.length; i++) {
      int xCenter = marginLr + (i * stepWidth);
      String accent = patt[i];
      int yCenter = 0;
      if (['H', 'h', '1', '2'].contains(accent)) {
        yCenter = 5;
      } else if (['L', 'l', '0'].contains(accent)) {
        yCenter = 30;
      }
      circles.write(_circle(xCenter, yCenter, o: i >= mora.length));
      if (i > 0) {
        if (prevCenter[1] == yCenter) {
          pathTyp = 's';
        } else if (prevCenter[1] < yCenter) {
          pathTyp = 'd';
        } else if (prevCenter[1] > yCenter) {
          pathTyp = 'u';
        }
        paths.write(_path(prevCenter[0], prevCenter[1], pathTyp, stepWidth));
      }
      prevCenter = [xCenter, yCenter];
    }
    svg.write(chars);
    svg.write(paths);
    svg.write(circles);
    svg.write('</svg>');

    return svg.toString();
  }

  static String _circle(int x, int y, {bool o = false}) {
    if (o) {
      return '<circle r="4" cx="${x + 4}" cy="$y" stroke="currentColor" stroke-width="2" fill="none" />';
    } else {
      return '<circle r="5" cx="$x" cy="$y" style="opacity:1;fill:currentColor;" />';
    }
  }

  static String _text(int x, String mora) {
    if (mora.length == 1) {
      return '<text x="$x" y="67.5" style="font-size:20px;font-family:sans-serif;fill:currentColor;">$mora</text>';
    } else {
      return '<text x="${x - 5}" y="67.5" style="font-size:20px;font-family:sans-serif;fill:currentColor;">${mora[0]}</text><text x="${x + 12}" y="67.5" style="font-size:14px;font-family:sans-serif;fill:currentColor;">${mora[1]}</text>';
    }
  }

  static String _path(int x, int y, String typ, int stepWidth) {
    String delta = '';
    switch (typ) {
      case 's':
        delta = '$stepWidth,0';
        break;
      case 'u':
        delta = '$stepWidth,-25';
        break;
      case 'd':
        delta = '$stepWidth,25';
        break;
    }
    return '<path d="m $x,$y $delta" style="fill:none;stroke:currentColor;stroke-width:1.5;" />';
  }

  static String pitchValueToPatt(String word, int pitchValue) {
    int numberOfMora = hiraToMora(word).length;
    if (numberOfMora >= 1) {
      if (pitchValue == 0) {
        // heiban
        return 'L${'H' * numberOfMora}';
      } else if (pitchValue == 1) {
        // atamadaka
        return 'H${'L' * numberOfMora}';
      } else if (pitchValue >= 2) {
        int stepdown = pitchValue - 2;
        return 'LH${'H' * stepdown}${'L' * (numberOfMora - pitchValue + 1)}';
      }
    }
    return '';
  }

  static List<String> hiraToMora(String hira) {
    /* Example:
          in:  'しゅんかしゅうとう'
         out: ['しゅ', 'ん', 'か', 'しゅ', 'う', 'と', 'う']
    */

    List<String> moraArr = [];
    const List<String> combiners = [
      'ゃ',
      'ゅ',
      'ょ',
      'ぁ',
      'ぃ',
      'ぅ',
      'ぇ',
      'ぉ',
      'ャ',
      'ュ',
      'ョ',
      'ァ',
      'ィ',
      'ゥ',
      'ェ',
      'ォ'
    ];

    int i = 0;
    while (i < hira.length) {
      if (i + 1 < hira.length && combiners.contains(hira[i + 1])) {
        moraArr.add('${hira[i]}${hira[i + 1]}');
        i += 2;
      } else {
        moraArr.add(hira[i]);
        i += 1;
      }
    }
    return moraArr;
  }
}
