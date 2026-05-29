import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/hibiki_audio_handler.dart';

void main() {
  group('HibikiAudioHandler notification subtitles', () {
    HibikiAudioHandler buildHandler() {
      return HibikiAudioHandler(
        onPlayPause: () {},
        onSeek: (_) {},
        onRewind: () {},
        onFastForward: () {},
      );
    }

    test('uses current cue text in every media subtitle field', () {
      final HibikiAudioHandler handler = buildHandler();

      handler.setMediaItemInfo(title: 'Book title', artist: 'Author');
      handler.updateNotificationSubtitle(
        title: 'Book title',
        subtitle: '役立たない地図の所為にして今',
        fallbackArtist: 'Author',
      );

      final item = handler.mediaItem.value;
      expect(item, isNotNull);
      expect(item!.title, 'Book title');
      expect(item.artist, '役立たない地図の所為にして今');
      expect(item.displaySubtitle, '役立たない地図の所為にして今');
      expect(item.displayDescription, '役立たない地図の所為にして今');
    });

    test('restores fallback artist and clears display subtitle when disabled',
        () {
      final HibikiAudioHandler handler = buildHandler();

      handler.setMediaItemInfo(title: 'Book title', artist: 'Author');
      handler.updateNotificationSubtitle(
        title: 'Book title',
        subtitle: '遠方に暮れています',
        fallbackArtist: 'Author',
      );
      handler.updateNotificationSubtitle(
        title: 'Book title',
        subtitle: null,
        fallbackArtist: 'Author',
      );

      final item = handler.mediaItem.value;
      expect(item, isNotNull);
      expect(item!.title, 'Book title');
      expect(item.artist, 'Author');
      expect(item.displaySubtitle, isNull);
      expect(item.displayDescription, isNull);
    });
  });
}
