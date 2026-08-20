import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/drop_decision.dart';
import 'package:fushi/src/media/drag_drop/drop_surface_scope.dart';

/// 拖放「落到哪个页面」与「文件夹算什么」的守卫。
///
/// 背景（用户实测）：停在**视频页**把一个视频文件夹拖进窗口，结果隐藏的书架页弹出
/// 「导入漫画」对话框、隐藏的游戏页同时弹「拖入的文件里没有新的游戏 .exe」，而真正
/// 可见的视频页一动不动。根因是 desktop_drop 全局广播 + home-shell 用 Offstage 保活
/// （RenderOffstage 在隐藏时仍以完整约束布局，只关 Flutter 自己的 hitTest），四个 tab
/// 的 drop target 同时命中；唯一的门 `ModalRoute.isCurrent` 对同级 tab 恒为 true。
void main() {
  group('DropSurfaceScope 决定谁接这次拖放', () {
    testWidgets('没有作用域时放行（对话框 / 播放页各自独占路由，行为不变）', (WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (BuildContext context) {
          captured = context;
          return const SizedBox();
        }),
      ));
      expect(DropSurfaceScope.activeFor(captured), isTrue);
    });

    testWidgets('隐藏 tab 的子树被判为不活跃，可见 tab 放行', (WidgetTester tester) async {
      late BuildContext hidden;
      late BuildContext visible;
      await tester.pumpWidget(MaterialApp(
        home: Stack(children: <Widget>[
          // 隐藏的保活 tab：Offstage 不阻止 desktop_drop，只有作用域能挡。
          Offstage(
            offstage: true,
            child: DropSurfaceScope(
              isActive: () => false,
              child: Builder(builder: (BuildContext context) {
                hidden = context;
                return const SizedBox();
              }),
            ),
          ),
          DropSurfaceScope(
            isActive: () => true,
            child: Builder(builder: (BuildContext context) {
              visible = context;
              return const SizedBox();
            }),
          ),
        ]),
      ));
      expect(DropSurfaceScope.activeFor(hidden), isFalse,
          reason: '隐藏 tab 绝不能接拖放——这正是「视频页拖文件夹却弹出导入漫画」的根因');
      expect(DropSurfaceScope.activeFor(visible), isTrue);
    });

    testWidgets('嵌套作用域逐层 AND：外层不活跃则内层一律不活跃', (WidgetTester tester) async {
      late BuildContext inner;
      await tester.pumpWidget(MaterialApp(
        home: DropSurfaceScope(
          isActive: () => false,
          child: DropSurfaceScope(
            isActive: () => true,
            child: Builder(builder: (BuildContext context) {
              inner = context;
              return const SizedBox();
            }),
          ),
        ),
      ));
      expect(DropSurfaceScope.activeFor(inner), isFalse,
          reason: '内层「我这一屏是当前子页」不能凌驾于外层「我这个 tab 根本没显示」');
    });
  });

  group('目录是事实，不是判断', () {
    test('classifyDroppedFiles 把目录同时记进 directories 与 mangas', () {
      final DroppedFiles files = classifyDroppedFiles(
        <String>[r'C:\anime\[VCB-Studio] Yuru Yuri'],
        isDirectory: (String path) => true,
      );
      // directories = 事实（谁都能读）；mangas = 书架/漫画库的既有解释，保留不动。
      expect(files.directories, <String>[r'C:\anime\[VCB-Studio] Yuru Yuri']);
      expect(files.mangas, <String>[r'C:\anime\[VCB-Studio] Yuru Yuri']);
    });

    test('不传 isDirectory 时不产生 directories（历史行为逐字节不变）', () {
      final DroppedFiles files =
          classifyDroppedFiles(<String>[r'C:\anime\Yuru Yuri']);
      expect(files.directories, isEmpty);
      expect(files.mangas, isEmpty);
    });
  });

  group('decideDropIntent：文件夹按落点表面解释', () {
    DroppedFiles folderDrop() => classifyDroppedFiles(
          <String>[r'C:\anime\S01'],
          isDirectory: (String path) => true,
        );

    test('视频页：文件夹 → 登记成扫描根（此前是完全静默）', () {
      expect(
        decideDropIntent(
          surface: DropSurface.video,
          files: folderDrop(),
          cardHit: false,
        ),
        DropIntent.addFolderAsSource,
      );
    });

    test('视频页：文件夹优先于同批拖入的单个视频文件', () {
      final DroppedFiles mixed = classifyDroppedFiles(
        <String>[r'C:\anime\S01', r'C:\anime\ep1.mkv'],
        isDirectory: (String path) => !path.endsWith('.mkv'),
      );
      expect(
        decideDropIntent(
          surface: DropSurface.video,
          files: mixed,
          cardHit: false,
        ),
        DropIntent.addFolderAsSource,
        reason: '拖一整个剧集目录进来要的是加来源，不是导入恰好也选中的那一个 mp4',
      );
    });

    test('书架 / 漫画库：文件夹仍是「一本漫画的页图文件夹」，既有能力不许被拿掉', () {
      for (final DropSurface surface in <DropSurface>[
        DropSurface.books,
        DropSurface.manga
      ]) {
        expect(
          decideDropIntent(
            surface: surface,
            files: folderDrop(),
            cardHit: false,
          ),
          DropIntent.importNewManga,
          reason: '$surface 的整目录页图导入是既有功能',
        );
      }
    });
  });

  group('多文件拖入：字幕按文件名主干配对', () {
    test('主干相同即配对，大小写不敏感', () {
      expect(
        subtitleForVideoByStem(r'C:\a\EP01.mkv', <String>[
          r'C:\a\EP02.srt',
          r'C:\a\ep01.srt',
        ]),
        r'C:\a\ep01.srt',
      );
    });

    test('配不上就返回 null——宁可不挂，也不要把同一条字幕挂到每一集', () {
      expect(
        subtitleForVideoByStem(
            r'C:\a\EP01.mkv', <String>[r'C:\a\something else.srt']),
        isNull,
      );
    });
  });
}
