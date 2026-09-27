import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/platform/mobile/download_keep_alive_hub.dart';

/// BUG-2714：多个下载来源共用一个 Android 保活前台服务——一个来源下完不能把
/// 别的来源的保活一起撤掉，最后一个来源结束才真正 stop。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocale(AppLocale.en);

  test('单来源：通知就是它的标题 / 进度，结束即撤', () async {
    final _Recording backend = _Recording();
    final DownloadKeepAliveHub hub = DownloadKeepAliveHub(backend);
    final DownloadKeepAlive a = hub.lease('interconnect');
    await a.update(title: 'Movie', text: 'Downloading', percent: 40);
    expect(backend.last?.title, 'Movie');
    expect(backend.last?.percent, 40);
    await a.stop();
    expect(backend.stops, 1);
  });

  test('多来源：一个结束不撤另一个的保活；最后一个结束才 stop', () async {
    final _Recording backend = _Recording();
    final DownloadKeepAliveHub hub = DownloadKeepAliveHub(backend);
    final DownloadKeepAlive video = hub.lease('interconnect');
    final DownloadKeepAlive update = hub.lease('update:x');
    await video.update(title: 'Movie', text: 'a', percent: 20);
    await update.update(title: 'Update 1.2', text: 'b', percent: 60);
    expect(backend.last?.title, t.download_keep_alive_multiple_title(count: 2));
    expect(backend.last?.percent, 40);
    expect(backend.last?.text, 'Movie · Update 1.2');

    await update.stop();
    expect(backend.stops, 0, reason: '更新下完不能把互联下载的保活撤掉');
    expect(backend.last?.title, 'Movie');
    await video.stop();
    expect(backend.stops, 1);
    // 重复 stop 不再打底层。
    await video.stop();
    expect(backend.stops, 1);
  });

  test('多来源里有一个进度未知 → 整体不确定进度', () async {
    final _Recording backend = _Recording();
    final DownloadKeepAliveHub hub = DownloadKeepAliveHub(backend);
    await hub.lease('a').update(title: 'A', text: '', percent: 50);
    await hub.lease('b').update(title: 'B', text: '');
    expect(backend.last?.percent, isNull);
  });
}

class _Recording implements DownloadKeepAlive {
  ({String title, String text, int? percent})? last;
  int stops = 0;

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {
    last = (title: title, text: text, percent: percent);
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}
