import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi/utils.dart'
    show FushiListItem, FushiListItemSelectedShape;

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 松约束宿主：固定宽度、**无界高度**（与真实宿主 ListView 一致）。
///
/// 直接塞进 `Scaffold.body` 会被拉成紧约束，任何两态高度比较都恒真（BUG：选中
/// 态才画的 1px 边框把行撑高 2px，原来的等高测试就是这样漏掉的）。仅用 `Align`
/// 放松也不够：高度仍是有界的 600，行内 `Column` 默认 `mainAxisSize.max` 会把
/// 两态都撑到 600，照样恒真——变异实测抓出来的。
Widget _loose(Widget child, {double width = 420}) => _host(
  SingleChildScrollView(
    child: SizedBox(width: width, child: child),
  ),
);

OnboardingAction _action(
  String label,
  OnboardingActionNecessity necessity, {
  VoidCallback? onPressed,
}) => OnboardingAction(
  icon: Icons.settings_outlined,
  label: label,
  description: '$label 的说明',
  necessity: necessity,
  onPressed: onPressed ?? () {},
);

void main() {
  testWidgets('OnboardingFeatureTile toggles via onToggle and shows check', (
    WidgetTester tester,
  ) async {
    bool toggled = false;
    await tester.pumpWidget(
      _host(
        OnboardingFeatureTile(
          icon: Icons.auto_stories_outlined,
          title: '词典查词',
          subtitle: '导入词典',
          selected: true,
          onToggle: () => toggled = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('词典查词'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    await tester.tap(find.text('词典查词'));
    expect(toggled, isTrue);
  });

  testWidgets('OnboardingFeatureTile unselected shows hollow marker', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        OnboardingFeatureTile(
          icon: Icons.style_outlined,
          title: 'Anki',
          subtitle: 'hint',
          selected: false,
          onToggle: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
  });

  testWidgets('OnboardingFeatureTile keeps equal height under loose bounds', (
    WidgetTester tester,
  ) async {
    Widget tile(bool selected) => _loose(
      OnboardingFeatureTile(
        icon: Icons.cloud_sync_outlined,
        title: '备份与同步',
        subtitle: 'Google Drive、WebDAV 或本地文件',
        selected: selected,
        onToggle: () {},
      ),
    );

    await tester.pumpWidget(tile(false));
    await tester.pumpAndSettle();
    final Size unselected = tester.getSize(find.byType(OnboardingFeatureTile));
    final FontWeight? unselectedTitleWeight = tester
        .widget<Text>(find.text('备份与同步'))
        .style
        ?.fontWeight;

    await tester.pumpWidget(tile(true));
    await tester.pumpAndSettle();
    final Size selected = tester.getSize(find.byType(OnboardingFeatureTile));
    final FontWeight? selectedTitleWeight = tester
        .widget<Text>(find.text('备份与同步'))
        .style
        ?.fontWeight;

    // 高度必须是真量出来的（非零），且两态相等——含边框在内的整块几何不随选中变。
    expect(unselected.height, greaterThan(0));
    expect(selected.height, unselected.height);
    expect(selected.width, unselected.width);
    expect(selectedTitleWeight, unselectedTitleWeight);
  });

  testWidgets(
    'FushiListItem pill shape keeps equal height whether selected or not',
    (WidgetTester tester) async {
      // 根因守卫：pill 形态曾只在选中时给 Border.all（1px），未选中为 null，
      // BoxDecoration 的边框把子节点向内挤，导致选中行比未选中行高 2px。
      Widget item(bool selected) => _loose(
        FushiListItem(
          leading: const Icon(Icons.style_outlined),
          title: const Text('Anki 制卡'),
          subtitle: const Text('查词后一键做成卡片'),
          selected: selected,
          selectedShape: FushiListItemSelectedShape.pill,
          trailing: const Icon(Icons.check_circle),
          onTap: () {},
        ),
      );

      await tester.pumpWidget(item(false));
      await tester.pumpAndSettle();
      final double unselected = tester
          .getSize(find.byType(FushiListItem))
          .height;

      await tester.pumpWidget(item(true));
      await tester.pumpAndSettle();
      final double selected = tester.getSize(find.byType(FushiListItem)).height;

      expect(unselected, greaterThan(0));
      expect(selected, unselected);
    },
  );

  testWidgets('OnboardingFeatureGrid lays out two equal-height columns wide', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        OnboardingFeatureGrid(
          tiles: <OnboardingFeatureTile>[
            OnboardingFeatureTile(
              icon: Icons.menu_book_outlined,
              title: '小说',
              subtitle: '一行',
              selected: true,
              onToggle: () {},
            ),
            OnboardingFeatureTile(
              icon: Icons.photo_library_outlined,
              title: '漫画',
              subtitle:
                  '这一条副标题写得特别长，长到在半宽的卡片里一定会折成两行甚至三行，'
                  '用来验证同一行的两张卡片会被拉齐。',
              selected: false,
              onToggle: () {},
            ),
            OnboardingFeatureTile(
              icon: Icons.smart_display_outlined,
              title: '视频',
              subtitle: '第二行',
              selected: false,
              onToggle: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect novels = tester.getRect(
      find.byType(OnboardingFeatureTile).at(0),
    );
    final Rect manga = tester.getRect(find.byType(OnboardingFeatureTile).at(1));
    final Rect video = tester.getRect(find.byType(OnboardingFeatureTile).at(2));
    // 前两张同一行：顶边相同、高度相同（短的那张被拉到长的那张的高度）。
    expect(novels.top, manga.top);
    expect(novels.height, manga.height);
    expect(manga.left, greaterThan(novels.right));
    // 第三张换行，落在第一列下方。
    expect(video.top, greaterThan(novels.bottom));
    expect(video.left, novels.left);
  });

  testWidgets('OnboardingFeatureGrid falls back to one column when narrow', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        OnboardingFeatureGrid(
          tiles: <OnboardingFeatureTile>[
            OnboardingFeatureTile(
              icon: Icons.menu_book_outlined,
              title: '小说',
              subtitle: 'a',
              selected: true,
              onToggle: () {},
            ),
            OnboardingFeatureTile(
              icon: Icons.photo_library_outlined,
              title: '漫画',
              subtitle: 'b',
              selected: false,
              onToggle: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect first = tester.getRect(find.byType(OnboardingFeatureTile).at(0));
    final Rect second = tester.getRect(
      find.byType(OnboardingFeatureTile).at(1),
    );
    expect(second.top, greaterThan(first.bottom));
    expect(second.left, first.left);
  });

  testWidgets('OnboardingProgressBar renders one segment per step', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(const OnboardingProgressBar(current: 2, total: 7)),
    );
    await tester.pumpAndSettle();

    final Finder segments = find.descendant(
      of: find.byType(OnboardingProgressBar),
      matching: find.byType(AnimatedContainer),
    );
    expect(segments, findsNWidgets(7));
    final ColorScheme colors = Theme.of(
      tester.element(find.byType(OnboardingProgressBar)),
    ).colorScheme;
    Color segmentColor(int index) =>
        (tester.widget<AnimatedContainer>(segments.at(index)).decoration!
                as BoxDecoration)
            .color!;
    // 0..current 用主色，之后用轮廓色。
    expect(segmentColor(0), colors.primary);
    expect(segmentColor(2), colors.primary);
    expect(segmentColor(3), colors.outlineVariant);
    expect(segmentColor(6), colors.outlineVariant);
  });

  testWidgets('OnboardingStepView renders title, body and actions', (
    WidgetTester tester,
  ) async {
    bool pressed = false;
    await tester.pumpWidget(
      _host(
        OnboardingStepView(
          icon: Icons.cloud_sync_outlined,
          title: '配置备份',
          body: '选择备份后端并登录。',
          actions: <OnboardingAction>[
            OnboardingAction(
              icon: Icons.settings_backup_restore_outlined,
              label: '打开备份设置',
              description: '选备份后端并登录，换机器时库还在。',
              necessity: OnboardingActionNecessity.optional,
              onPressed: () => pressed = true,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('配置备份'), findsOneWidget);
    expect(find.text('选择备份后端并登录。'), findsOneWidget);
    // 说明必须和标题一起渲染出来：动作只有标签就是「不知道点了干什么」。
    expect(find.text('选备份后端并登录，换机器时库还在。'), findsOneWidget);
    await tester.tap(find.text('打开备份设置'));
    expect(pressed, isTrue);
  });

  testWidgets(
    'OnboardingActionList folds optional actions behind primary ones',
    (WidgetTester tester) async {
      bool optionalPressed = false;
      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            child: OnboardingActionList(
              actions: <OnboardingAction>[
                _action('下载并导入', OnboardingActionNecessity.recommended),
                _action(
                  '选择本地包文件',
                  OnboardingActionNecessity.optional,
                  onPressed: () => optionalPressed = true,
                ),
                _action('打开词典管理', OnboardingActionNecessity.optional),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 主线摊开，可选项收起在「其他方式」后面。
      expect(find.text('下载并导入'), findsOneWidget);
      expect(find.text('选择本地包文件'), findsNothing);
      expect(find.text('打开词典管理'), findsNothing);
      expect(find.byType(OnboardingDisclosureRow), findsOneWidget);

      await tester.tap(find.byType(OnboardingDisclosureRow));
      await tester.pumpAndSettle();
      expect(find.text('选择本地包文件'), findsOneWidget);
      expect(find.text('打开词典管理'), findsOneWidget);
      await tester.tap(find.text('选择本地包文件'));
      expect(optionalPressed, isTrue);

      await tester.tap(find.byType(OnboardingDisclosureRow));
      await tester.pumpAndSettle();
      expect(find.text('选择本地包文件'), findsNothing);
    },
  );

  testWidgets('OnboardingActionList shows everything when nothing is primary', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        OnboardingActionList(
          actions: <OnboardingAction>[
            _action('打开备份设置', OnboardingActionNecessity.optional),
            _action('打开互联设置', OnboardingActionNecessity.optional),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 全是可选项时折叠等于把整页藏起来——必须全部摊开、没有折叠行。
    expect(find.text('打开备份设置'), findsOneWidget);
    expect(find.text('打开互联设置'), findsOneWidget);
    expect(find.byType(OnboardingDisclosureRow), findsNothing);
  });

  testWidgets(
    'OnboardingActionTile shows the description and a necessity badge',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _host(
          const Column(
            children: <Widget>[
              OnboardingActionTile(
                action: OnboardingAction(
                  icon: Icons.download_outlined,
                  label: '下载并导入',
                  description: '在后台下载整个推荐包，下完自动进入导入。',
                  necessity: OnboardingActionNecessity.recommended,
                  onPressed: null,
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('下载并导入'), findsOneWidget);
      expect(find.text('在后台下载整个推荐包，下完自动进入导入。'), findsOneWidget);
      // 徽标是「要不要点」的唯一载体，不能被 OnboardingActionTile 悄悄漏掉。
      expect(
        find.descendant(
          of: find.byType(OnboardingActionTile),
          matching: find.byType(OnboardingNecessityBadge),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('OnboardingActionTile survives a long label on a narrow screen', (
    WidgetTester tester,
  ) async {
    // 标题行是「标签 + 必要性徽标」两件东西挤一行。窄机 + 长标签（下载按钮的标签
    // 还要拼上体积，是全场最长的一个）曾是这类 Row 溢出的经典形状——溢出会让
    // widget 测试直接抛异常，所以这条用例本身就是断言。
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        const Column(
          children: <Widget>[
            OnboardingActionTile(
              action: OnboardingAction(
                icon: Icons.download_outlined,
                label: '下载并导入推荐包（词典 + 日英发音音频库，9.5 GB）',
                description:
                    '在后台下载整个推荐包，下完自动进入导入。'
                    '随时可以取消，下次从断点续传。',
                necessity: OnboardingActionNecessity.recommended,
                onPressed: null,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(OnboardingNecessityBadge), findsOneWidget);
  });

  testWidgets('OnboardingNecessityBadge label differs per necessity', (
    WidgetTester tester,
  ) async {
    final Set<String> labels = <String>{};
    for (final OnboardingActionNecessity necessity
        in OnboardingActionNecessity.values) {
      await tester.pumpWidget(
        _host(OnboardingNecessityBadge(necessity: necessity)),
      );
      await tester.pumpAndSettle();
      labels.add((tester.widget(find.byType(Text).last) as Text).data!);
    }
    // 三档必须是三个不同的词——否则徽标存在但什么都没说。
    expect(labels.length, OnboardingActionNecessity.values.length);
  });

  testWidgets('operation tutorial renders ordered instructions and action', (
    WidgetTester tester,
  ) async {
    bool opened = false;
    await tester.pumpWidget(
      _host(
        OnboardingOperationTutorialView(
          icon: Icons.touch_app_outlined,
          title: '点击查词',
          body: '点文字即可查词。',
          items: const <OnboardingTutorialItem>[
            OnboardingTutorialItem(
              icon: Icons.ads_click_outlined,
              title: '点一个字',
              description: '从点中的位置匹配完整单词。',
            ),
            OnboardingTutorialItem(
              icon: Icons.account_tree_outlined,
              title: '继续点词条',
              description: '打开下一层释义。',
              extra: Text('附加内容'),
            ),
          ],
          actions: <OnboardingAction>[
            OnboardingAction(
              icon: Icons.settings_outlined,
              label: '打开设置',
              description: '调整操作方式。',
              necessity: OnboardingActionNecessity.optional,
              onPressed: () => opened = true,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('点击查词'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('点一个字'), findsOneWidget);
    expect(find.text('继续点词条'), findsOneWidget);
    expect(find.text('附加内容'), findsOneWidget);
    // 编号按阅读顺序从上往下。
    expect(
      tester.getTopLeft(find.text('1')).dy,
      lessThan(tester.getTopLeft(find.text('2')).dy),
    );
    await tester.tap(find.text('打开设置'));
    expect(opened, isTrue);
  });

  testWidgets('OnboardingSummaryRow lists chips or a "none" placeholder', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            OnboardingSummaryRow(label: '显示的库页', items: <String>['小说', '视频']),
            OnboardingSummaryRow(label: '本次配置', items: <String>[]),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('小说'), findsOneWidget);
    expect(find.text('视频'), findsOneWidget);
    // 空集合要有占位词，不能只剩一个孤零零的标签。
    expect(find.text('本次配置'), findsOneWidget);
    expect(find.byType(Text), findsNWidgets(5));
  });

  testWidgets('sample sentence card shows the sentence and is tappable', (
    WidgetTester tester,
  ) async {
    bool opened = false;
    await tester.pumpWidget(
      _host(
        OnboardingSampleSentenceCard(
          sentence: '今日はいい天気ですね。',
          onTap: () => opened = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今日はいい天気ですね。'), findsOneWidget);
    await tester.tap(find.text('今日はいい天気ですね。'));
    expect(opened, isTrue);
  });

  testWidgets('operation tutorial renders the preface between hero and steps', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _host(
        OnboardingOperationTutorialView(
          icon: Icons.touch_app_outlined,
          title: '点击查词',
          body: '先用下面这句话练手。',
          preface: OnboardingSampleSentenceCard(
            sentence: '练习句子在这里',
            onTap: () {},
          ),
          items: const <OnboardingTutorialItem>[
            OnboardingTutorialItem(
              icon: Icons.ads_click_outlined,
              title: '点一下文字',
              description: '说明',
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final double hero = tester.getTopLeft(find.text('点击查词')).dy;
    final double preface = tester.getTopLeft(find.text('练习句子在这里')).dy;
    final double step = tester.getTopLeft(find.text('点一下文字')).dy;
    // 引子在 hero 之下、步骤之上：用户先看到句子，再看怎么点。
    expect(preface, greaterThan(hero));
    expect(step, greaterThan(preface));
  });
}
