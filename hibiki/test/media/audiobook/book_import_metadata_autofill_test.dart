// TODO-1045: importing an M4B autofills the title/author fields from the
// container's tags (©nam/©ART -> title/artist via ffprobe) BUT only when the
// corresponding field is still empty -- a user who typed a title first must not
// have it clobbered when they then pick the audio. Cover already works; this
// closes the title/author gap.
//
// Behavioral tests model the exact "fill-only-if-empty" gate. Source guards pin
// that the production dialog (1) exposes `_tryExtractAudioMetadata`, (2) gates
// each field on `.isEmpty`, and (3) fires the metadata probe from every audio
// trigger point (pick / drop / sidecar / initState prefill) alongside the cover.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';

/// Mirror of the production fill-only-if-empty gate: applies tag title/author to
/// the current field values, returning the new (title, author). A non-empty
/// field is never overwritten; a null tag never blanks an existing value.
({String title, String author}) applyMetadataFillOnly({
  required String currentTitle,
  required String currentAuthor,
  required AudioMetadata? meta,
}) {
  if (meta == null) return (title: currentTitle, author: currentAuthor);
  final String title =
      currentTitle.isEmpty && meta.title != null ? meta.title! : currentTitle;
  final String author = currentAuthor.isEmpty && meta.author != null
      ? meta.author!
      : currentAuthor;
  return (title: title, author: author);
}

void main() {
  group('fill-only-if-empty gate (TODO-1045)', () {
    test('empty title/author get filled from tags', () {
      final r = applyMetadataFillOnly(
        currentTitle: '',
        currentAuthor: '',
        meta: const AudioMetadata(title: 'Kokoro', author: 'Soseki'),
      );
      expect(r.title, 'Kokoro');
      expect(r.author, 'Soseki');
    });

    test('user-typed title is NOT overwritten by tag title', () {
      final r = applyMetadataFillOnly(
        currentTitle: 'My Title',
        currentAuthor: '',
        meta: const AudioMetadata(title: 'Tag Title', author: 'Tag Author'),
      );
      expect(r.title, 'My Title', reason: 'must not clobber user input');
      expect(r.author, 'Tag Author', reason: 'empty author still filled');
    });

    test('null meta (no ffprobe / no tag) keeps filename fallback intact', () {
      final r = applyMetadataFillOnly(
        currentTitle: 'book_from_filename',
        currentAuthor: '',
        meta: null,
      );
      expect(r.title, 'book_from_filename');
      expect(r.author, '');
    });

    test('tag with null title but real author fills only author', () {
      final r = applyMetadataFillOnly(
        currentTitle: 'filename_title',
        currentAuthor: '',
        meta: const AudioMetadata(author: 'Narrator'),
      );
      expect(r.title, 'filename_title');
      expect(r.author, 'Narrator');
    });
  });

  group('book_import_dialog source guards (TODO-1045)', () {
    late String source;

    setUpAll(() {
      source = File('lib/src/media/audiobook/book_import_dialog.dart')
          .readAsStringSync();
    });

    test('exposes _tryExtractAudioMetadata', () {
      expect(source, contains('Future<void> _tryExtractAudioMetadata()'),
          reason: 'the metadata autofill helper must exist.');
    });

    test('title/author fills are gated on .isEmpty (fill-only)', () {
      final int start = source.indexOf('_tryExtractAudioMetadata() async');
      expect(start, isNonNegative);
      final int end = source.indexOf('\n  }', start);
      final String body = source.substring(start, end);
      expect(body, contains('_titleCtrl.text.isEmpty'),
          reason: 'title must only be filled when empty (never clobber user).');
      expect(body, contains('_authorCtrl.text.isEmpty'),
          reason: 'author must only be filled when empty.');
      expect(body, contains('_titleCtrl.text = meta.title!'));
      expect(body, contains('_authorCtrl.text = meta.author!'));
    });

    test('metadata probe fires from every audio trigger point', () {
      // Count invocations: initState prefill, drop, sidecar, pickAudio = 4
      // call sites plus the method definition = at least 5 occurrences.
      final int calls =
          RegExp(r'_tryExtractAudioMetadata\(\)').allMatches(source).length;
      expect(calls, greaterThanOrEqualTo(5),
          reason: 'metadata autofill must be wired at pick/drop/sidecar/'
              'initState triggers (mirroring the cover extraction).');
    });

    test('uses TtsChannel.extractAudioMetadata bridge (all-platform ffprobe)',
        () {
      expect(source, contains('TtsChannel.instance.extractAudioMetadata('),
          reason: 'must go through the platform bridge so mobile ffmpeg-kit '
              'ffprobe path is used too, not a desktop-only call.');
    });
  });
}
