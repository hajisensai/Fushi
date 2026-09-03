/// 守卫：字体库的「作用域用途」必须真的被消费。
///
/// ## 为什么需要这条守卫
///
/// `CustomFontsPage.target` 曾经是**死参数**：字段声明了，调用方
/// （`settings_schema_game.dart` 的「设置·游戏·Hook 文本字体」）也认真传了
/// `FontTarget.gameLookup`，但 `_CustomFontsPageState` 裸继承 `BasePageState`，
/// 泛型实参缺省 → `T` 退化成 `BasePage` → `widget` 的静态类型跟着退化 →
/// `widget.target` 在 State 里**根本访问不到**。四个新增字体的入口于是全部硬编码
/// `FontTarget.body: true`。
///
/// 实际后果：用户从游戏设置进字体库、导入一个字体，该字体被挂到 EPUB 正文，游戏
/// hook 台词浮窗一直不变。用户报的「字体库里缺游戏 / 设了不生效」就是这个。
///
/// 已有的 `game_overlay_appearance_settings_guard_test.dart:30` 只断言源码里出现
/// `'CustomFontsPage(target: FontTarget.gameLookup)'` 这串字面量——**传参被断言了，
/// 消费没有**，所以整个缺陷从它眼皮底下走了过去。本守卫补的正是缺的那一半。
///
/// ## 守什么
///
/// 1. State 必须带泛型实参 `BasePageState<CustomFontsPage>`。这是 `widget.target`
///    可达的唯一前提。
/// 2. 新增字体的挂载点不得再出现硬编码 `FontTarget.body: true`；四个入口（文件
///    导入 / 压缩包解包 / 推荐字体下载 / 系统字体）必须走同一个 `_newFontTargets()`。
/// 3. `_newFontTargets()` 必须由 `widget.target` 派生，不得退回常量。
/// 4. 用途开关按平台过滤走 `isFontTargetAvailableOnPlatform`，且**只影响显示**：
///    回写仍按 `FontTarget.values` 全量，否则跨平台同步会把别的平台的勾选抹掉。
///
/// 所有结构断言都在**剥掉注释**的代码上做（`maskComments`）：本守卫的文档注释里
/// 就写满了 `FontTarget.body: true` 这类字面量，拿原文扫会自指假红；反过来，把真
/// 声明改写进注释也能骗绿。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

const String kPageFile = 'lib/src/pages/implementations/custom_fonts_page.dart';
const String kSettingsFile = 'lib/src/reader/reader_settings.dart';

/// 读取 [path] 并把注释换成**等长空白**后的代码文本。
String _codeOf(String path) => maskComments(File(path).readAsStringSync());

void main() {
  final String page = _codeOf(kPageFile);
  final String settings = _codeOf(kSettingsFile);

  test('State 带泛型实参，widget.target 才可达', () {
    expect(
      page.contains('class _CustomFontsPageState '
          'extends BasePageState<CustomFontsPage>'),
      isTrue,
      reason: '裸 BasePageState 会让 T 退化成 BasePage，widget.target 不可达——'
          '这正是 target 当初沦为死参数的机制',
    );
  });

  test('新增字体不再硬编码挂到 body', () {
    expect(
      page.contains('FontTarget.body: true'),
      isFalse,
      reason: '新增字体必须走 _newFontTargets()（跟随进入页面的作用域），'
          '硬编码 body 会让「从游戏入口导入的字体」挂到小说正文',
    );
  });

  test('_newFontTargets 由 widget.target 派生', () {
    final int at = page.indexOf('Map<FontTarget, bool> _newFontTargets()');
    expect(at, greaterThan(-1), reason: '四个新增入口共用的挂载点消失了');
    // 取声明起后一小段，确认返回值里出现 widget.target 而不是某个写死的枚举值。
    final String body = page.substring(at, at + 120);
    expect(
      body.contains('widget.target'),
      isTrue,
      reason: '_newFontTargets 退回常量的话，作用域参数就又白传了',
    );
  });

  test('四个新增入口都走 _newFontTargets()', () {
    final int uses = 'targetEnabled: _newFontTargets()'.allMatches(page).length;
    expect(
      uses,
      4,
      reason: '文件导入 / 压缩包解包(含 override 与批量两支) / 系统字体，共 4 处；'
          '数目变了说明有新入口没接作用域，或旧入口被删',
    );
  });

  test('用途开关按平台过滤，但回写不受影响', () {
    expect(
      page.contains('isFontTargetAvailableOnPlatform(target)'),
      isTrue,
      reason: 'gameLookup 只有 Windows 有 native 消费端，其余平台勾了等于写一个'
          '永远没人读的键',
    );
    expect(
      settings.contains('bool isFontTargetAvailableOnPlatform(FontTarget'),
      isTrue,
      reason: '平台判据必须与 FontTarget 同处，跟着枚举一起穷尽',
    );
    // 回写侧必须仍是全量遍历：平台过滤只能影响显示。
    expect(
      page.contains('for (final FontTarget target in FontTarget.values)'),
      isTrue,
      reason: '若回写也按平台过滤，Windows 上勾的 gameLookup 会在手机端被抹掉',
    );
  });

  test('native 分层窗的格式判据由 loader 与 UI 共用', () {
    expect(
      page.contains('AppFontLoader.nativeOverlayCanUse('),
      isTrue,
      reason: 'WOFF/WOFF2 在 DirectWrite 用不了。UI 若不复用同一判据就会让用户勾一个'
          '下游静默忽略的组合，表现为「设了不生效且没有任何反馈」',
    );
  });
}
