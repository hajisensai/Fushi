import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/fushi_audio_handler.dart';

void main() {
  group('FushiAudioHandler notification subtitles', () {
    FushiAudioHandler buildHandler() {
      return FushiAudioHandler(
        onPlayIntent: (_) {},
        onSeek: (_) {},
        onRewind: () {},
        onFastForward: () {},
      );
    }

    test('uses current cue text in every media subtitle field', () {
      final FushiAudioHandler handler = buildHandler();

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

    test(
      'restores fallback artist and clears display subtitle when disabled',
      () {
        final FushiAudioHandler handler = buildHandler();

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
      },
    );
  });

  // BUG-4507：会话在控制器每次 notify 时都重推副标题；audio_service 的 Android 端
  // 每收到一次 setMediaItem 就新开一条线程抢 setMetadata 的锁，几千次重复推送让
  // 主线程 buildNotification 拿不到锁而 ANR。内容没变就不能再推给平台。
  group('FushiAudioHandler media item dedupe (BUG-4507)', () {
    FushiAudioHandler buildHandler() => FushiAudioHandler(
      onPlayIntent: (_) {},
      onSeek: (_) {},
      onRewind: () {},
      onFastForward: () {},
    );

    test('identical subtitle pushes reach the platform stream once', () async {
      final FushiAudioHandler handler = buildHandler();
      handler.setMediaItemInfo(title: 'Book', artist: 'Author');
      final List<Object?> pushed = <Object?>[];
      final sub = handler.mediaItem.skip(1).listen(pushed.add);

      for (int i = 0; i < 500; i++) {
        handler.updateNotificationSubtitle(title: 'Book', subtitle: '一行目');
      }
      await Future<void>.delayed(Duration.zero);
      expect(pushed, hasLength(1));

      handler.updateNotificationSubtitle(title: 'Book', subtitle: '二行目');
      handler.updateNotificationSubtitle(title: 'Book', subtitle: ' 二行目 ');
      await Future<void>.delayed(Duration.zero);
      expect(pushed, hasLength(2));
      await sub.cancel();
    });

    test('repeated identical media info is pushed once', () async {
      final FushiAudioHandler handler = buildHandler();
      final List<Object?> pushed = <Object?>[];
      final sub = handler.mediaItem.skip(1).listen(pushed.add);

      handler.setMediaItemInfo(
        title: 'Book',
        artist: 'Author',
        duration: const Duration(minutes: 3),
      );
      handler.setMediaItemInfo(
        title: 'Book',
        artist: 'Author',
        duration: const Duration(minutes: 3),
      );
      handler.setMinimalMediaItem(title: 'Book');
      handler.setMinimalMediaItem(title: 'Book');
      await Future<void>.delayed(Duration.zero);
      expect(pushed, hasLength(2));
      await sub.cancel();
    });

    test('after clearing the notification the same item is pushed again', () {
      final FushiAudioHandler handler = buildHandler();
      handler.setMinimalMediaItem(title: 'Book');
      handler.clearNotification();
      expect(handler.mediaItem.value, isNull);
      handler.setMinimalMediaItem(title: 'Book');
      expect(handler.mediaItem.value?.title, 'Book');
    });
  });
}
