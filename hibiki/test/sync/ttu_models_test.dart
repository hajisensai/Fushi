import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/ttu_models.dart';

void main() {
  group('TtuProgress', () {
    const json = {
      'dataId': 0,
      'exploredCharCount': 1500,
      'progress': 0.35,
      'lastBookmarkModified': 1705944232500,
    };

    test('fromJson parses correctly', () {
      final progress = TtuProgress.fromJson(json);
      expect(progress.dataId, 0);
      expect(progress.exploredCharCount, 1500);
      expect(progress.progress, 0.35);
      expect(progress.lastBookmarkModified, 1705944232500);
    });

    test('toJson produces compatible output', () {
      final progress = TtuProgress.fromJson(json);
      final output = progress.toJson();
      expect(output['dataId'], 0);
      expect(output['exploredCharCount'], 1500);
      expect(output['progress'], 0.35);
      expect(output['lastBookmarkModified'], 1705944232500);
    });

    test('round-trip via encode/decode', () {
      final original = TtuProgress.fromJson(json);
      final decoded = TtuProgress.decode(original.encode());
      expect(decoded.exploredCharCount, original.exploredCharCount);
      expect(decoded.progress, original.progress);
      expect(decoded.lastBookmarkModified, original.lastBookmarkModified);
    });
  });

  group('TtuStatistics', () {
    const json = {
      'title': 'かがみの孤城',
      'dateKey': '2026-01-15',
      'charactersRead': 2500,
      'readingTime': 3600.5,
      'minReadingSpeed': 300,
      'altMinReadingSpeed': 280,
      'lastReadingSpeed': 450,
      'maxReadingSpeed': 500,
      'lastStatisticModified': 1705944232500,
    };

    test('fromJson parses correctly', () {
      final stat = TtuStatistics.fromJson(json);
      expect(stat.title, 'かがみの孤城');
      expect(stat.dateKey, '2026-01-15');
      expect(stat.charactersRead, 2500);
      expect(stat.readingTimeSec, 3600.5);
      expect(stat.minReadingSpeed, 300);
      expect(stat.lastStatisticModified, 1705944232500);
    });

    test('toJson uses readingTime key (not readingTimeMs)', () {
      final stat = TtuStatistics.fromJson(json);
      final output = stat.toJson();
      expect(output.containsKey('readingTime'), true);
      expect(output.containsKey('readingTimeMs'), false);
      expect(output['readingTime'], 3600.5);
    });

    test('decodeList/encodeList round-trip', () {
      final list = [TtuStatistics.fromJson(json)];
      final encoded = TtuStatistics.encodeList(list);
      final decoded = TtuStatistics.decodeList(encoded);
      expect(decoded.length, 1);
      expect(decoded.first.title, 'かがみの孤城');
      expect(decoded.first.readingTimeSec, 3600.5);
    });
  });

  group('TtuAudioBook', () {
    const json = {
      'title': 'かがみの孤城',
      'playbackPosition': 123.45,
      'lastAudioBookModified': 1705944232500,
    };

    test('fromJson parses correctly', () {
      final audio = TtuAudioBook.fromJson(json);
      expect(audio.title, 'かがみの孤城');
      expect(audio.playbackPositionSec, 123.45);
      expect(audio.lastAudioBookModified, 1705944232500);
    });

    test('toJson uses playbackPosition key (seconds)', () {
      final audio = TtuAudioBook.fromJson(json);
      final output = audio.toJson();
      expect(output['playbackPosition'], 123.45);
    });

    test('round-trip via encode/decode', () {
      final original = TtuAudioBook.fromJson(json);
      final decoded = TtuAudioBook.decode(original.encode());
      expect(decoded.playbackPositionSec, 123.45);
      expect(decoded.lastAudioBookModified, 1705944232500);
    });
  });

  group('JSON encoding safety', () {
    test('Japanese text survives jsonEncode round-trip', () {
      final stat = TtuStatistics(
        title: 'かがみの孤城',
        dateKey: '2026-01-15',
        charactersRead: 2500,
        readingTimeSec: 3600.5,
        minReadingSpeed: 300,
        altMinReadingSpeed: 280,
        lastReadingSpeed: 450,
        maxReadingSpeed: 500,
        lastStatisticModified: 1705944232500,
      );
      final encoded = jsonEncode(stat.toJson());
      final decoded =
          TtuStatistics.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded.title, 'かがみの孤城');
    });

    test('special chars in title do not break JSON', () {
      final stat = TtuStatistics(
        title: 'Book "with" \\slashes/ and\nnewlines',
        dateKey: '2026-01-15',
        charactersRead: 100,
        readingTimeSec: 60,
        minReadingSpeed: 100,
        altMinReadingSpeed: 100,
        lastReadingSpeed: 100,
        maxReadingSpeed: 100,
        lastStatisticModified: 1000,
      );
      final encoded = jsonEncode(stat.toJson());
      final decoded =
          TtuStatistics.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded.title, 'Book "with" \\slashes/ and\nnewlines');
    });
  });
}
