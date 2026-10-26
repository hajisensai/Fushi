import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/reader/image_actions_sheet.dart';
import 'package:fushi/src/utils/misc/image_file_saver.dart';

/// 长按图片的全局动作面板（保存 / 分享 / 复制）与唯一的保存实现。
class _FakeSaver implements ImageFileSaver {
  _FakeSaver(this.result);

  final ImageSaveResult result;
  final List<String> saved = <String>[];

  @override
  Future<ImageSaveResult> save(File file) async {
    saved.add(file.path);
    return result;
  }
}

class _ThrowingSaver implements ImageFileSaver {
  @override
  Future<ImageSaveResult> save(File file) async =>
      throw const FileSystemException('disk full');
}

Widget _host(void Function(BuildContext context) onPressed) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (BuildContext context) => Center(
        child: TextButton(
          key: const ValueKey<String>('open'),
          onPressed: () => onPressed(context),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

void main() {
  tearDown(() => debugImageFileSaverOverride = null);

  group('imageActionsFor', () {
    test('手机与 macOS：保存在前，再是系统分享', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        expect(imageActionsFor(platform), <ImageAction>[
          ImageAction.save,
          ImageAction.share,
        ], reason: '$platform');
      }
    });

    test('Windows：保存 + 复制（剪贴板 channel 只在 Windows 注册）', () {
      expect(imageActionsFor(TargetPlatform.windows), <ImageAction>[
        ImageAction.save,
        ImageAction.copy,
      ]);
    });

    test('Linux：只有保存（share_plus 无 Linux 注册）', () {
      expect(imageActionsFor(TargetPlatform.linux), <ImageAction>[
        ImageAction.save,
      ]);
    });
  });

  group('保存目的地与默认文件名', () {
    test('手机写相册，桌面另存为文件', () {
      expect(
        imageSaveDestinationFor(TargetPlatform.android),
        ImageSaveDestination.gallery,
      );
      expect(
        imageSaveDestinationFor(TargetPlatform.iOS),
        ImageSaveDestination.gallery,
      );
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        expect(
          imageSaveDestinationFor(platform),
          ImageSaveDestination.file,
          reason: '$platform',
        );
      }
    });

    test('保留原文件名，缺扩展名补 .png', () {
      expect(suggestedImageFileName('/books/x/OEBPS/i-012.jpg'), 'i-012.jpg');
      // 入参是本机 File.path（分隔符随平台）：用本机绝对路径造「无扩展名」样例，
      // 而不是写死 Windows 反斜杠路径——POSIX 上反斜杠是合法文件名字符，那条样例
      // 在 Linux CI 上测的根本不是「取 basename」。
      final String bare = p.join(p.rootPrefix(p.current), 'b', 'cover');
      expect(suggestedImageFileName(bare), 'cover.png');
      expect(suggestedImageFileName(''), 'image.png');
    });
  });

  group('saveImageFileWithFeedback', () {
    test('把文件交给保存后端并返回结局', () async {
      final _FakeSaver saver = _FakeSaver(
        const ImageSaveResult(ImageSaveStatus.saved),
      );
      debugImageFileSaverOverride = saver;
      final ImageSaveResult result = await saveImageFileWithFeedback(
        File('a.png'),
      );
      expect(result.status, ImageSaveStatus.saved);
      expect(saver.saved, <String>['a.png']);
    });

    test('后端抛异常时收成 failed、不向上抛', () async {
      debugImageFileSaverOverride = _ThrowingSaver();
      final ImageSaveResult result = await saveImageFileWithFeedback(
        File('a.png'),
      );
      expect(result.status, ImageSaveStatus.failed);
      expect(result.error, isA<FileSystemException>());
    });

    test('文件不存在：平台后端直接报 unavailable，不弹权限也不开对话框', () async {
      const PlatformImageFileSaver saver = PlatformImageFileSaver(
        destination: ImageSaveDestination.gallery,
      );
      final ImageSaveResult result = await saver.save(
        File('${Directory.systemTemp.path}/fushi_no_such_image_4f1.png'),
      );
      expect(result.status, ImageSaveStatus.unavailable);
    });
  });

  group('showImageActionsSheet', () {
    testWidgets('列出平台动作，点「保存图片」走唯一的保存实现', (WidgetTester tester) async {
      final _FakeSaver saver = _FakeSaver(
        const ImageSaveResult(ImageSaveStatus.saved),
      );
      debugImageFileSaverOverride = saver;
      ImageAction? picked;
      await tester.pumpWidget(
        _host((BuildContext context) async {
          picked = await showImageActionsSheet(
            context,
            file: File('/books/OEBPS/i-001.jpg'),
            platform: TargetPlatform.android,
          );
        }),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();

      expect(find.byType(ImageActionsSheet), findsOneWidget);
      expect(find.text('i-001.jpg'), findsOneWidget);
      final Finder save = find.byKey(
        const ValueKey<String>('image_action_save'),
      );
      final Finder share = find.byKey(
        const ValueKey<String>('image_action_share'),
      );
      expect(save, findsOneWidget);
      expect(share, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('image_action_copy')),
        findsNothing,
      );
      expect(
        tester.getTopLeft(save).dy,
        lessThan(tester.getTopLeft(share).dy),
        reason: '保存是首项',
      );

      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.byType(ImageActionsSheet), findsNothing);
      expect(picked, ImageAction.save);
      expect(saver.saved, <String>['/books/OEBPS/i-001.jpg']);
    });

    testWidgets('关掉面板什么也不做', (WidgetTester tester) async {
      final _FakeSaver saver = _FakeSaver(
        const ImageSaveResult(ImageSaveStatus.saved),
      );
      debugImageFileSaverOverride = saver;
      ImageAction? picked = ImageAction.share;
      await tester.pumpWidget(
        _host((BuildContext context) async {
          picked = await showImageActionsSheet(
            context,
            file: File('x.png'),
            platform: TargetPlatform.windows,
          );
        }),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('image_action_copy')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ImageActionsSheet), findsNothing);
      expect(picked, isNull);
      expect(saver.saved, isEmpty);
    });
  });
}
