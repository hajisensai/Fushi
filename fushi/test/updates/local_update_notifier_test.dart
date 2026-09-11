import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/updates/local_update_notifier.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';

/// 系统通知后端的两条纯函数契约：
/// ① Windows 按钮把「按钮 id + 本体载荷」编进 arguments 再拆回来（插件在 Windows
///   上把 payload 与 actionId 都填成被点元素的 arguments，本体载荷会丢）；
/// ② 本地化文案：单条带发布时刻与两个按钮，多条汇总不带时刻。
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
