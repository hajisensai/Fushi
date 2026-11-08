// 视频库「整理文件名」预览框（反馈 ZDYNkAP3Ln）：逐条「旧名 → 新名」、做种标记、
// 跳过数；做种联动查不清时必须把原因摆出来，并把确认按钮换成「仍然改名」——用户
// 是在知情的前提下选择可能中断做种。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/video_filename_organize_dialog.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

VideoFilenameOrganizePlan _plan(VideoFilenameTorrentCheck check) {
  final String dir = p.join('D:', 'dl', 'Bocchi');
  return VideoFilenameOrganizePlan(
    torrentCheck: check,
    torrentCheckError: check == VideoFilenameTorrentCheck.unverified
        ? 'backend offline'
        : null,
    items: <VideoFilenameItemPlan>[
      VideoFilenameItemPlan(
        bookUid: 'video/re',
        title: 'Bocchi Re:',
        status: VideoFilenamePlanStatus.ready,
        moves: <VideoFilenamePlannedMove>[
          VideoFilenamePlannedMove(
            move: VideoFileMove(
              from: p.join(dir, 'Bocchi Re_Re_ (2024).mkv'),
              to: p.join(dir, 'Bocchi Re： (2024).mkv'),
              isVideo: true,
            ),
            torrent: const VideoFilenameTorrentLink(
              infoHash: 'abc',
              fileIndex: 0,
              currentRelativePath: 'Bocchi Re_Re_ (2024).mkv',
              newRelativePath: 'Bocchi Re： (2024).mkv',
            ),
          ),
          VideoFilenamePlannedMove(
            move: VideoFileMove(
              from: p.join(dir, 'Bocchi Re_Re_ (2024).ja.ass'),
              to: p.join(dir, 'Bocchi Re： (2024).ja.ass'),
              isVideo: false,
            ),
          ),
        ],
      ),
      const VideoFilenameItemPlan(
        bookUid: 'video/raw',
        title: 'raw',
        status: VideoFilenamePlanStatus.noIdentity,
      ),
    ],
  );
}

Future<void> _open(WidgetTester tester, VideoFilenameOrganizePlan plan) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => Center(
          child: TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (BuildContext context) =>
                  VideoFilenameOrganizeDialog(plan: plan),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocale(AppLocale.en);

  testWidgets('核对过做种：列出旧名 → 新名、做种标记、跳过数，确认按钮是「改名」', (
    WidgetTester tester,
  ) async {
    await _open(tester, _plan(VideoFilenameTorrentCheck.verified));
    expect(find.text('Bocchi Re_Re_ (2024).mkv'), findsOneWidget);
    expect(find.text('Bocchi Re： (2024).mkv'), findsOneWidget);
    expect(
      find.text(t.video_filename_organize_sidecars(count: '1')),
      findsOneWidget,
    );
    expect(find.byTooltip(t.video_filename_organize_seeding), findsOneWidget);
    expect(
      find.text(t.video_filename_organize_skipped(count: '1')),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        t.video_filename_organize_unverified(reason: 'backend offline'),
      ),
      findsNothing,
    );
    expect(find.text(t.video_filename_organize_confirm), findsOneWidget);
    expect(find.text(t.video_filename_organize_confirm_anyway), findsNothing);
  });

  testWidgets('做种联动查不清：摆出原因，确认按钮换成「仍然改名」，点了返回 true', (
    WidgetTester tester,
  ) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () async {
                confirmed = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext context) =>
                      VideoFilenameOrganizeDialog(
                        plan: _plan(VideoFilenameTorrentCheck.unverified),
                      ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        t.video_filename_organize_unverified(reason: 'backend offline'),
      ),
      findsOneWidget,
    );
    expect(find.text(t.video_filename_organize_confirm), findsNothing);
    await tester.tap(find.text(t.video_filename_organize_confirm_anyway));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });
}
