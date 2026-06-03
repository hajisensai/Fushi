import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/creator.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import '../helpers/test_platform_services.dart';

/// Test seam: subclasses [AppModel] and overrides exactly the four members
/// [TagsField.onCreatorOpenAction] reads — [savedTags], [autoAddBookNameToTags],
/// [isMediaOpen] and [getCurrentMediaItem]. Nothing else is touched, so the
/// uninitialised [prefsRepo] / database late fields are never dereferenced.
class _FakeTagsAppModel extends AppModel {
  _FakeTagsAppModel({
    required this.fakeSavedTags,
    required this.fakeAutoAdd,
    required this.fakeMediaOpen,
    required this.fakeMediaItem,
  }) : super(testPlatformServices());

  final String fakeSavedTags;
  final bool fakeAutoAdd;
  final bool fakeMediaOpen;
  final MediaItem? fakeMediaItem;

  @override
  String get savedTags => fakeSavedTags;

  @override
  bool get autoAddBookNameToTags => fakeAutoAdd;

  @override
  bool get isMediaOpen => fakeMediaOpen;

  @override
  MediaItem? getCurrentMediaItem() => fakeMediaItem;
}

MediaItem _bookItem(String title) => MediaItem(
      mediaIdentifier: 'book/1',
      title: title,
      mediaTypeIdentifier: 'reader_hibiki',
      mediaSourceIdentifier: 'reader_hibiki',
      position: 0,
      duration: 0,
      canDelete: false,
      canEdit: false,
    );

void main() {
  final DictionaryEntry entry = DictionaryEntry(word: '本', reading: 'ほん');
  final CreatorModel creatorModel = CreatorModel();

  Future<String?> runAction(
    WidgetTester tester,
    AppModel appModel,
  ) async {
    String? result;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? _) {
            result = TagsField.instance.onCreatorOpenAction(
              ref: ref,
              appModel: appModel,
              creatorModel: creatorModel,
              entry: entry,
              creatorJustLaunched: true,
              dictionaryName: null,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return result;
  }

  group('TagsField.onCreatorOpenAction — auto-add book title to tags', () {
    testWidgets('auto-add ON + media open: book title joins saved tags',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: 'jp',
        fakeAutoAdd: true,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('My Book'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'jp My_Book');
    });

    testWidgets('auto-add OFF: book title is NOT added even when media open',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: 'jp',
        fakeAutoAdd: false,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('My Book'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'jp');
      expect(out, isNot(contains('My_Book')));
    });

    testWidgets('no media open: only saved tags returned',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: 'jp',
        fakeAutoAdd: true,
        fakeMediaOpen: false,
        fakeMediaItem: null,
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'jp');
    });

    testWidgets('empty saved tags + auto-add: title becomes the only tag',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: '',
        fakeAutoAdd: true,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('Solo Title'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'Solo_Title');
    });

    testWidgets('title with tabs is sanitised to underscores',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: '',
        fakeAutoAdd: true,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('A\tB C'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'A_B_C');
    });

    testWidgets('duplicate book tag is not appended twice',
        (WidgetTester tester) async {
      final AppModel appModel = _FakeTagsAppModel(
        fakeSavedTags: 'jp My_Book',
        fakeAutoAdd: true,
        fakeMediaOpen: true,
        fakeMediaItem: _bookItem('My Book'),
      );

      final String? out = await runAction(tester, appModel);
      expect(out, 'jp My_Book');
    });
  });
}
