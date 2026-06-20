import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

void main() {
  group('AnkiDeck', () {
    test('fromJson and toJson round-trip', () {
      final deck = AnkiDeck(id: 1, name: 'Japanese');

      final json = deck.toJson();
      final restored = AnkiDeck.fromJson(json);

      expect(restored.id, 1);
      expect(restored.name, 'Japanese');
    });
  });

  group('AnkiNoteType', () {
    test('fromJson and toJson round-trip', () {
      final noteType = AnkiNoteType(
        id: 2,
        name: 'Basic',
        fields: ['Front', 'Back'],
      );

      final json = noteType.toJson();
      final restored = AnkiNoteType.fromJson(json);

      expect(restored.id, 2);
      expect(restored.name, 'Basic');
      expect(restored.fields, ['Front', 'Back']);
    });
  });

  group('AnkiSettings', () {
    test('default values', () {
      const settings = AnkiSettings();

      expect(settings.selectedDeckId, isNull);
      expect(settings.selectedDeckName, isNull);
      expect(settings.selectedNoteTypeId, isNull);
      expect(settings.selectedNoteTypeName, isNull);
      expect(settings.availableDecks, isEmpty);
      expect(settings.availableNoteTypes, isEmpty);
      expect(settings.fieldMappings, isEmpty);
      expect(settings.tags, '');
      expect(settings.allowDupes, isFalse);
      expect(settings.compactGlossaries, isFalse);
      expect(settings.embedMedia, isTrue);
      // TODO-614: 覆写范围默认 latest（仅覆写本会话最近一张，等价旧行为）。
      expect(settings.overwriteScope, AnkiOverwriteScope.latest);
    });

    test('fromJson handles complete payload', () {
      final json = {
        'selectedDeckId': 42,
        'selectedDeckName': 'Mining',
        'selectedNoteTypeId': 7,
        'selectedNoteTypeName': 'Vocab',
        'availableDecks': [
          {'id': 1, 'name': 'D1'},
        ],
        'availableNoteTypes': [
          {
            'id': 2,
            'name': 'N1',
            'fields': ['F1'],
          },
        ],
        'fieldMappings': {'Front': 'term', 'Back': 'meaning'},
        'tags': 'japanese n5',
        'allowDupes': true,
        'compactGlossaries': true,
        'embedMedia': false,
        'overwriteScope': 'all',
      };

      final settings = AnkiSettings.fromJson(json);

      expect(settings.selectedDeckId, 42);
      expect(settings.selectedDeckName, 'Mining');
      expect(settings.selectedNoteTypeId, 7);
      expect(settings.availableDecks, hasLength(1));
      expect(settings.availableNoteTypes, hasLength(1));
      expect(settings.fieldMappings['Front'], 'term');
      expect(settings.tags, 'japanese n5');
      expect(settings.allowDupes, isTrue);
      expect(settings.compactGlossaries, isTrue);
      expect(settings.embedMedia, isFalse);
      expect(settings.overwriteScope, AnkiOverwriteScope.all);
    });

    test('fromJson handles missing fields gracefully', () {
      final json = <String, dynamic>{};

      final settings = AnkiSettings.fromJson(json);

      expect(settings.selectedDeckId, isNull);
      expect(settings.tags, '');
      expect(settings.embedMedia, isTrue);
      expect(settings.availableDecks, isEmpty);
      // TODO-614: 缺字段（旧用户存档）容错回 latest = 现状不破。
      expect(settings.overwriteScope, AnkiOverwriteScope.latest);
    });

    test('fromJson to toJson round-trip via jsonEncode/Decode', () {
      final original = AnkiSettings(
        selectedDeckId: 5,
        selectedDeckName: 'Test',
        fieldMappings: {'A': 'B'},
        tags: 'test',
      );

      final encoded = jsonEncode({
        'selectedDeckId': original.selectedDeckId,
        'selectedDeckName': original.selectedDeckName,
        'fieldMappings': original.fieldMappings,
        'tags': original.tags,
        'allowDupes': original.allowDupes,
        'compactGlossaries': original.compactGlossaries,
        'embedMedia': original.embedMedia,
      });
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final restored = AnkiSettings.fromJson(decoded);

      expect(restored.selectedDeckId, 5);
      expect(restored.selectedDeckName, 'Test');
      expect(restored.fieldMappings, {'A': 'B'});
    });
  });
}
