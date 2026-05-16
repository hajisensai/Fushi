import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/json_alignment_parser.dart';

void main() {
  group('JsonAlignmentParser.parseString', () {
    test('parses basic alignment JSON', () {
      final json = jsonEncode({
        'bookUid': 'reader/book.epub',
        'audio': ['ch01.mp3'],
        'cues': [
          {
            'chapter': 'ch01.xhtml',
            'i': 0,
            'selector': '#p1',
            'start': 0,
            'end': 4230,
            'file': 0,
            'text': '吾輩は猫である。',
          },
          {
            'chapter': 'ch01.xhtml',
            'i': 1,
            'selector': '#p2',
            'start': 4230,
            'end': 8000,
            'file': 0,
            'text': '名前はまだ無い。',
          },
        ],
      });

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'override/uid',
      );

      expect(cues, hasLength(2));
      expect(cues[0].bookUid, 'override/uid');
      expect(cues[0].chapterHref, 'ch01.xhtml');
      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].textFragmentId, '#p1');
      expect(cues[0].startMs, 0);
      expect(cues[0].endMs, 4230);
      expect(cues[0].audioFileIndex, 0);
      expect(cues[0].text, '吾輩は猫である。');
      expect(cues[1].sentenceIndex, 1);
      expect(cues[1].startMs, 4230);
    });

    test('handles multi-file audio index', () {
      final json = jsonEncode({
        'audio': ['f0.mp3', 'f1.mp3'],
        'cues': [
          {
            'chapter': 'ch.xhtml',
            'i': 0,
            'selector': '#s1',
            'start': 100,
            'end': 200,
            'file': 1,
            'text': 'test',
          },
        ],
      });

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'b',
      );

      expect(cues.single.audioFileIndex, 1);
    });

    test('missing optional fields default to safe values', () {
      final json = jsonEncode({
        'cues': [
          <String, dynamic>{},
        ],
      });

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'b',
      );

      expect(cues, hasLength(1));
      expect(cues[0].chapterHref, '');
      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].textFragmentId, '');
      expect(cues[0].startMs, 0);
      expect(cues[0].endMs, 0);
      expect(cues[0].audioFileIndex, 0);
      expect(cues[0].text, '');
    });

    test('empty cues array returns empty list', () {
      final json = jsonEncode({'cues': <dynamic>[]});

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'b',
      );

      expect(cues, isEmpty);
    });

    test('missing cues key returns empty list', () {
      final json = jsonEncode({
        'audio': ['a.mp3']
      });

      final cues = JsonAlignmentParser.parseString(
        content: json,
        bookUid: 'b',
      );

      expect(cues, isEmpty);
    });
  });

  group('JsonAlignmentParser.cuesForChapter', () {
    late List<AudioCue> allCues;

    setUp(() {
      allCues = [
        AudioCue()
          ..bookUid = 'b'
          ..chapterHref = 'ch02.xhtml'
          ..sentenceIndex = 0
          ..textFragmentId = '#p1'
          ..text = 'c2-s0'
          ..startMs = 0
          ..endMs = 1000
          ..audioFileIndex = 0,
        AudioCue()
          ..bookUid = 'b'
          ..chapterHref = 'ch01.xhtml'
          ..sentenceIndex = 2
          ..textFragmentId = '#p3'
          ..text = 'c1-s2'
          ..startMs = 2000
          ..endMs = 3000
          ..audioFileIndex = 0,
        AudioCue()
          ..bookUid = 'b'
          ..chapterHref = 'ch01.xhtml'
          ..sentenceIndex = 0
          ..textFragmentId = '#p1'
          ..text = 'c1-s0'
          ..startMs = 0
          ..endMs = 1000
          ..audioFileIndex = 0,
      ];
    });

    test('filters by chapter and sorts by sentenceIndex', () {
      final ch1 = JsonAlignmentParser.cuesForChapter(
        allCues: allCues,
        chapterHref: 'ch01.xhtml',
      );
      expect(ch1, hasLength(2));
      expect(ch1[0].sentenceIndex, 0);
      expect(ch1[1].sentenceIndex, 2);
    });

    test('returns empty for nonexistent chapter', () {
      final ch = JsonAlignmentParser.cuesForChapter(
        allCues: allCues,
        chapterHref: 'ch99.xhtml',
      );
      expect(ch, isEmpty);
    });

    test('returns single cue for chapter with one entry', () {
      final ch2 = JsonAlignmentParser.cuesForChapter(
        allCues: allCues,
        chapterHref: 'ch02.xhtml',
      );
      expect(ch2, hasLength(1));
      expect(ch2[0].text, 'c2-s0');
    });
  });

  group('JsonAlignmentParser.findCueIndex', () {
    late List<AudioCue> cues;

    setUp(() {
      cues = [
        AudioCue()
          ..bookUid = 'b'
          ..chapterHref = 'ch'
          ..sentenceIndex = 0
          ..textFragmentId = ''
          ..text = ''
          ..startMs = 1000
          ..endMs = 2000
          ..audioFileIndex = 0,
        AudioCue()
          ..bookUid = 'b'
          ..chapterHref = 'ch'
          ..sentenceIndex = 1
          ..textFragmentId = ''
          ..text = ''
          ..startMs = 3000
          ..endMs = 4000
          ..audioFileIndex = 0,
        AudioCue()
          ..bookUid = 'b'
          ..chapterHref = 'ch'
          ..sentenceIndex = 2
          ..textFragmentId = ''
          ..text = ''
          ..startMs = 5000
          ..endMs = 6000
          ..audioFileIndex = 0,
      ];
    });

    test('empty cues returns -1', () {
      expect(
        JsonAlignmentParser.findCueIndex(cues: [], positionMs: 0),
        -1,
      );
    });

    test('position before first cue returns -1', () {
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 500),
        -1,
      );
    });

    test('position exactly at startMs returns that cue', () {
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 1000),
        0,
      );
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 3000),
        1,
      );
    });

    test('position within cue range returns that cue', () {
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 1500),
        0,
      );
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 3500),
        1,
      );
    });

    test('position at endMs returns that cue', () {
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 2000),
        0,
      );
    });

    test('position in gap between cues returns -1', () {
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 2500),
        -1,
      );
    });

    test('position after last cue returns -1', () {
      expect(
        JsonAlignmentParser.findCueIndex(cues: cues, positionMs: 7000),
        -1,
      );
    });
  });
}
