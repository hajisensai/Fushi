import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/listening_reminder.dart';
import 'package:fushi/src/media/listening_reminder_app.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_general.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:material_ui/material_ui.dart';

/// 可控的播放器桩。
class _Player {
  _Player({required this.playing});

  bool playing;
  int pauses = 0;

  ListeningReminderPlayer get handle => ListeningReminderPlayer(
    isPlaying: () => playing,
    pause: () async {
      pauses++;
      playing = false;
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  FushiDialogAction actionLabelled(WidgetTester tester, String label) =>
      tester.widget<FushiDialogAction>(
        find.byWidgetPredicate(
          (Widget w) => w is FushiDialogAction && w.label == label,
        ),
      );

  testWidgets('dialog shows the minutes; Enter = keep listening', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    final Future<ListeningReminderChoice?> result = showListeningReminderDialog(
      context,
      minutes: 45,
    );
    await tester.pumpAndSettle();
    expect(find.text(t.listening_reminder_notice_title), findsOneWidget);
    expect(
      find.text(t.listening_reminder_notice_body(minutes: 45)),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await result, ListeningReminderChoice.keepListening);
  });

  testWidgets('dialog offers pause and turn off', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    Future<ListeningReminderChoice?> result = showListeningReminderDialog(
      context,
      minutes: 60,
    );
    await tester.pumpAndSettle();
    actionLabelled(tester, t.listening_reminder_action_pause).onPressed!();
    await tester.pumpAndSettle();
    expect(await result, ListeningReminderChoice.pause);

    result = showListeningReminderDialog(context, minutes: 60);
    await tester.pumpAndSettle();
    actionLabelled(tester, t.listening_reminder_action_turn_off).onPressed!();
    await tester.pumpAndSettle();
    expect(await result, ListeningReminderChoice.turnOff);
  });

  group('applyListeningReminderChoice', () {
    test('pause pauses only the players that are playing', () async {
      final _Player music = _Player(playing: true);
      final _Player book = _Player(playing: false);
      final _Player video = _Player(playing: true);
      final ListeningReminderPlayers players = ListeningReminderPlayers(
        <ListeningReminderPlayer>[music.handle, book.handle, video.handle],
      );
      expect(players.anyPlaying, isTrue);
      int turnOffs = 0;
      await applyListeningReminderChoice(
        ListeningReminderChoice.pause,
        players: players,
        turnOff: () async => turnOffs++,
      );
      expect(music.pauses, 1);
      expect(book.pauses, 0);
      expect(video.pauses, 1);
      expect(players.anyPlaying, isFalse);
      expect(turnOffs, 0);
    });

    test('turn off disables the reminder and leaves playback alone', () async {
      final _Player music = _Player(playing: true);
      int turnOffs = 0;
      await applyListeningReminderChoice(
        ListeningReminderChoice.turnOff,
        players: ListeningReminderPlayers(<ListeningReminderPlayer>[
          music.handle,
        ]),
        turnOff: () async => turnOffs++,
      );
      expect(turnOffs, 1);
      expect(music.pauses, 0);
    });

    test('keep listening / dismissed changes nothing', () async {
      final _Player music = _Player(playing: true);
      int turnOffs = 0;
      for (final ListeningReminderChoice? choice in <ListeningReminderChoice?>[
        ListeningReminderChoice.keepListening,
        null,
      ]) {
        await applyListeningReminderChoice(
          choice,
          players: ListeningReminderPlayers(<ListeningReminderPlayer>[
            music.handle,
          ]),
          turnOff: () async => turnOffs++,
        );
      }
      expect(turnOffs, 0);
      expect(music.pauses, 0);
    });
  });

  group('postListeningReminderNotification', () {
    test('posts one replaceable, ungrouped notification', () async {
      final RecordingUpdateNotifier notifier = RecordingUpdateNotifier();
      await postListeningReminderNotification(notifier, minutes: 30);
      await postListeningReminderNotification(notifier, minutes: 30);
      expect(notifier.sent, hasLength(2));
      final UpdateNotification n = notifier.sent.first;
      expect(n.id, kListeningReminderNotificationId);
      expect(notifier.sent.last.id, n.id);
      expect(n.payload, kListeningReminderNotificationPayload);
      expect(n.grouped, isFalse);
      expect(n.title, t.listening_reminder_notice_title);
      expect(n.body, t.listening_reminder_notice_body(minutes: 30));
    });

    test('never asks for permission on its own', () async {
      final RecordingUpdateNotifier notifier = RecordingUpdateNotifier(
        permission: false,
      );
      await postListeningReminderNotification(notifier, minutes: 30);
      expect(notifier.sent, isEmpty);
      expect(notifier.requestPermissionCalls, 0);
    });
  });

  test('settings: general › hearing care holds the switch and interval', () {
    final SettingsSection section = buildGeneralDestination().sections
        .singleWhere((SettingsSection s) => s.id == 'general.section.hearing');
    expect(section.items.map((SettingsItem i) => i.id), <String>[
      'general.listening_reminder',
      'general.listening_reminder_minutes',
    ]);
    final SettingsSwitchItem toggle = section.items.first as SettingsSwitchItem;
    // 默认关闭（拍板：提醒是可选的）。
    expect(toggle.defaultValue, isFalse);
    final SettingsSegmentedItem<int> interval =
        section.items.last as SettingsSegmentedItem<int>;
    expect(interval.defaultValue, kListeningReminderMinutesDefault);
    expect(
      interval.options.map((SettingsSegmentOption<int> o) => o.value),
      kListeningReminderMinutesChoices,
    );
  });
}
