import 'dart:io' show Directory, File, Platform;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/updates/local_update_notifier.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:path/path.dart' as p;

/// 系统通知后端的两条纯函数契约：
/// ① Windows 按钮把「按钮 id + 本体载荷」编进 arguments 再拆回来（插件在 Windows
///   上把 payload 与 actionId 都填成被点元素的 arguments，本体载荷会丢）；
/// ② 本地化文案：单条带发布时刻与两个按钮，多条汇总不带时刻；
/// ③ Windows 头部图标：随包资产路径全是本机分隔符，且每条 toast 自带
///   `appLogoOverride`（注册表 `IconUri` 那条路在实机上头部可以是空的）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('decodeNotificationResponse', () {
    const String payload =
        '{"kind":"video_episode","entryId":"video_episode:1"}';

    test('Windows 按钮：arguments 自带载荷，拆成 (payload, actionId)', () {
      final String arguments = encodeWindowsActionArguments('open', payload);
      final UpdateNotificationResponse response = decodeNotificationResponse(
        NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: arguments,
          actionId: arguments,
        ),
      );
      expect(response.actionId, 'open');
      expect(response.payload, payload);
    });

    test('点本体：payload 原样、actionId 为 null（哪怕插件填了东西）', () {
      final UpdateNotificationResponse response = decodeNotificationResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: payload,
          actionId: payload,
        ),
      );
      expect(response.actionId, isNull);
      expect(response.payload, payload);
    });

    test('Android/Linux 按钮：payload 与 actionId 本来分开，直接透传', () {
      final UpdateNotificationResponse response = decodeNotificationResponse(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
          payload: payload,
          actionId: 'view_all',
        ),
      );
      expect(response.actionId, 'view_all');
      expect(response.payload, payload);
    });
  });

  group('Windows 头部图标', () {
    test('bundledAssetPath 不把 asset 名里的 / 混进本机路径', () {
      final String path = LocalUpdateNotifier.bundledAssetPath(
        kWindowsNotificationIconAsset,
      );
      expect(path, endsWith(p.join('assets', 'meta', 'icon.png')));
      if (Platform.isWindows) {
        expect(
          path,
          isNot(contains('/')),
          reason: '混合斜杠写进注册表 IconUri 后 toast 头部是空的',
        );
      }
    });

    test('每条 toast 自带 appLogoOverride 指向随包图标', () {
      if (!Platform.isWindows) return;
      final Directory dir = Directory.systemTemp.createTempSync('fushi_toast');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File icon = File(p.join(dir.path, 'icon.png'))
        ..writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47]);
      final LocalUpdateNotifier notifier = LocalUpdateNotifier(
        appName: 'Fushi',
        windowsIconPath: icon.path,
      );
      final WindowsNotificationDetails details =
          notifier.windowsDetailsForTesting(
        const UpdateNotification(id: 1, title: '2.6.0', body: ''),
      );
      final List<WindowsImage> logos = details.images
          .where(
            (WindowsImage image) =>
                image.placement == WindowsImagePlacement.appLogoOverride,
          )
          .toList();
      expect(logos, hasLength(1));
      expect(logos.single.uri, Uri.file(icon.path, windows: true));
    });

    test('图标文件不在就不挂：挂个不存在的路径是坏图，不是没图', () {
      if (!Platform.isWindows) return;
      final LocalUpdateNotifier notifier = LocalUpdateNotifier(
        appName: 'Fushi',
        windowsIconPath: p.join(Directory.systemTemp.path, 'nope', 'x.png'),
      );
      final WindowsNotificationDetails details =
          notifier.windowsDetailsForTesting(
        const UpdateNotification(id: 1, title: '2.6.0', body: ''),
      );
      expect(details.images, isEmpty);
    });
  });

  group('localizedUpdateNotificationText', () {
    test('单条：副标题 · MM-dd HH:mm，两个按钮', () {
      final DateTime published = DateTime(2026, 9, 10, 18, 30);
      final UpdateNotificationText text =
          AppModel.localizedUpdateNotificationText(
        UpdateFeedKind.videoEpisode,
        <UpdateFeedDraft>[
          UpdateFeedDraft(
            kind: UpdateFeedKind.videoEpisode,
            targetKey: '1',
            title: 'グロウアップショウ',
            subtitle: 'S01E02 · 1080p',
            publishedAt: published.millisecondsSinceEpoch,
          ),
        ],
      );
      expect(text.title, 'グロウアップショウ');
      expect(text.body, 'S01E02 · 1080p · 09-10 18:30');
      expect(text.openLabel, isNotEmpty);
      expect(text.viewAllLabel, isNotEmpty);
    });

    test('单条无副标题无时刻：正文只剩空串，不留孤零零的分隔符', () {
      final UpdateNotificationText text =
          AppModel.localizedUpdateNotificationText(
        UpdateFeedKind.appRelease,
        const <UpdateFeedDraft>[
          UpdateFeedDraft(
            kind: UpdateFeedKind.appRelease,
            targetKey: '2.4.0',
            title: '2.4.0',
          ),
        ],
      );
      expect(text.body, '');
    });

    test('多条：汇总句不带时刻（时刻属于谁说不清）', () {
      final UpdateNotificationText text =
          AppModel.localizedUpdateNotificationText(
        UpdateFeedKind.videoEpisode,
        <UpdateFeedDraft>[
          for (int i = 1; i <= 3; i++)
            UpdateFeedDraft(
              kind: UpdateFeedKind.videoEpisode,
              targetKey: '$i',
              title: 'Show',
              subtitle: 'S01E0$i',
              publishedAt: 1700000000000,
            ),
        ],
      );
      expect(text.body, contains('S01E01'));
      expect(text.body, isNot(contains(':')));
      expect(text.body, contains('2'));
    });
  });
}
