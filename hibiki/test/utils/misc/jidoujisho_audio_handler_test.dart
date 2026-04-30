import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/jidoujisho_audio_handler.dart';

void main() {
  group('JidoujishoAudioHandler notification subtitles', () {
    JidoujishoAudioHandler buildHandler() {
      return JidoujishoAudioHandler(
        onPlayPause: () {},
        onSeek: (_) {},
        onRewind: () {},
        onFastForward: () {},
      );
    }

    test('uses current cue text in every media subtitle field', () {
      final JidoujishoAudioHandler handler = buildHandler();

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
      final JidoujishoAudioHandler handler = buildHandler();

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
