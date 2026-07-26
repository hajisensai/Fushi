## BUG-1095 · galgame 台词浮窗拖动窗口时字号跟着变，「放不下」怎么拖都放不下

- **报告**：2026-07-26（用户：）
- **真实性**：✅ 真 bug。根因 `hibiki/windows/runner/floating_lyric_window.cpp:825-831`（修复前）：
  hook 模式的字号是 `style_.font_size * clamp(strip_height_dip_ / 140dip, 0.9, 2.5)`，
  而 `strip_height_dip_` 的唯一来源就是窗口实际 rect（`SyncStripSizeFromWindow()`，
  每次 `WM_SIZE` 都重算并 `text_format_.Reset()`）。于是「把浮窗拖高」和「把台词放大」
  是同一个手势：从默认 140dip 拖到上限 480dip（3.4×）时字号同步 ×2.5，可见行数只从
  约 2.3 行涨到约 4.3 行——用户「放不下想拖高」永远拖不出想要的效果。
  另一半是文本区没有滚动：段落垂直居中 + `PushAxisAlignedClip` 硬裁，溢出直接被切掉。
  字号当时**没有任何独立真值**（`kGalHookTextFontSize = 30.0` 是硬常量、无 pref），
  整个 galgame 浮窗在设置页也一条条目都没有。
- **[x] ① 已修复** — 字号与窗高彻底解耦：
  - native `hibiki/windows/runner/floating_lyric_window.cpp:45-62`（常量注释）、`:828-841`
    hook 模式的 `height_scale` 恒为 `1.0f`，直接用 `style_.font_size`；有声书歌词条保持
    原有随高缩放行为不变。删除 `kHookTextBaseHeightForFontDip` / `kHookTextFontScaleMin`
    / `kHookTextFontScaleMax` 三个常量。
  - 新增独立偏好 `gal_hook_text_font_size`（`hibiki/lib/src/models/preferences_repository.dart`
    `galHookTextFontSize`，范围 12..72，默认 30）+ `AppModel` 委托 + 设置项
    `lookup.gal_hook_text_font_size`（`hibiki/lib/src/settings/settings_schema_lookup.dart`，
    仅 Windows 可见）。
  - `GalHookTextOverlayChannel.show/updateStyle` 传真实 `fontSize`；
    `GalHookTextOverlayController.applyFontSizeFromPreferences()` 在设置页改完立刻推 native。
  - **向后兼容**：默认 30 恰好等于旧公式在默认窗高 140dip 下的实际字号（`clamp(140/140)=1.0`），
    没拖过浮窗的用户逐像素不变；拖过窗的用户字号回到 30 并从此由设置项控制——这正是本 bug
    要求的行为改变（拖高 = 多显示几行，而不是把同样两行放得更大）。老 rect pref
    `gal_hook_text_window_rect` 语义未变，不需要迁移。
  - 顺带：hook 模式下台词一旦装不下就从垂直居中改成**顶端对齐**（`floating_lyric_window.cpp:874-890`），
    保住阅读起点，只丢句尾；装得下时仍居中（像素不变）。
  - 提交：64e0e8211
- **[x] ② 已加自动化测试** —
  - 源码守卫 `hibiki/test/build/gal_overlay_font_decoupled_guard_test.dart`：断言 hook 分支不再
    出现按窗高缩放的常量/表达式、恒为 1.0f，且溢出顶端对齐存在。
  - Dart 真单测 `hibiki/test/lookup/gal_hook_text_overlay_controller_test.dart`（新增两条）：
    `show` 携带偏好里的字号；`applyFontSizeFromPreferences()` 把新字号经 `updateStyle` 推给 native。
  - 偏好边界 `hibiki/test/models/preferences_repository_gal_hook_font_test.dart`：默认值 / 上下钳位 / 脏数据收敛。
- **[x] ③ 第二阶段已补完：文本区真滚动**（本条原记为「仍未做」，现已落地）
  - **仍存在的问题**：字号解耦之后，拖高确实换来更多行，但「字号调大 + 窗口小」仍会把句尾
    硬裁掉（`PushAxisAlignedClip` / `PopAxisAlignedClip`），用户没有任何办法看到被裁的内容。
    这个窗是 runner 自有的 Win32 分层窗 + Direct2D 直绘，没有系统滚动条可用。
  - **方案**：不引入第二个渲染目标，也不做滚动容器——顶端对齐（第一阶段成果）让排版从
    `text_rect_.top` 起画，于是「滚动」就等于**把绘制原点上移 `scroll_offset_px_`，裁剪框
    `text_clip` 一动不动**，视口下移、被裁的句尾从下面走进来。
    - `hibiki/windows/runner/floating_lyric_window.h:205-213`（`ScrollBy` 声明）、`:288-293`
      （`scroll_offset_px_` / `scroll_max_px_` 状态）。
    - `hibiki/windows/runner/floating_lyric_window.cpp:97-106`（滚动条 / 滚轮步长常量）、
      `:356-364`（`UpdateText` 回顶）、`:444-462`（`ScrollBy`，三个接管前置条件集中于此）、
      `:753-775`（`WM_MOUSEWHEEL`）、`:924-928`（每帧归零行程）、`:953-966`（按实测排版高度
      算行程 + 夹紧偏移 + 算出 `text_origin_y`）、`:1051-1090`（右侧留白里的滚动指示条）、
      `:1438-1450`（`CharIndexAt` 视口判边界 / 布局取坐标）。
  - **交互语义**（三条容易打架的地方，都按「消除特殊情况」处理）：
    1. **新台词到达 → 回到顶部**（`UpdateText`）。这里换掉的是**整句**而不是往下追加，保留
       旧偏移只会把用户直接扔进一句他还没读过的话的中间，比跳回开头糟得多。所以没有
       「用户正在往下看就别动」的分支——那个分支要成立，前提是新旧文本连续，而 hook 台词
       从来不是。
    2. **穿透（pass-through）下不滚**。`WM_NCHITTEST` 早已对正文返回 `HTTRANSPARENT`，滚轮
       根本到不了本窗；顶部那条「恢复带」仍能收到消息，故 `ScrollBy` 里再挡一道
       `pass_through_`——穿透就是「鼠标整个属于游戏」，不留半个例外。
    3. **和工具条按钮不打架**：那八个按钮只吃 `WM_LBUTTONDOWN`，从不吃滚轮。所以滚轮的命中
       区可以是整个窗口，**不需要**「避开按钮」这种特例分支；鼠标停在按钮上滚也照样翻文本。
       滚动条轨道则画在 `text_rect_` **右侧的留白**（`[width - pad, width]`）里，压不到任何一个字
       ——若压字就得缩窄换行宽度，而换行宽度会反过来改变排版高度即可滚行程，形成回环；轨道
       底端另外让开右下角 resize grip，两个可拖拽的东西不叠在同一块像素上。
    4. **滚到顶 / 滚到底不吞事件**（`ScrollBy` 返回 false → 落回 `DefWindowProc`），窗口不做
       吃掉滚轮的黑洞。
  - **向后兼容**：`scroll_max_px_` 每帧先归零、只有 hook 分支会重新赋值；没有溢出时
    `scroll_offset_px_` 恒为 0，`text_origin_y == text_rect_.top`，滚动条一个像素都不画。
    有声书歌词条与剪贴板文本窗因此与引入滚动之前逐像素一致。
  - **自动化测试**：`hibiki/test/build/gal_overlay_scroll_guard_test.dart`（7 例全绿）锁死
    ①行程由实测排版高度每帧重算 ②滚动 = 移绘制原点、裁剪框不动 ③命中测试视口判边界 /
    布局取坐标 ④新台词回顶 ⑤接管条件集中在 `ScrollBy` 且滚到头不吞事件 ⑥滚动条在右侧留白
    且只在真溢出时画 ⑦第一阶段成果与歌词条行为不被连坐。第一阶段守卫
    `gal_overlay_font_decoupled_guard_test.dart` 里「溢出仍是硬裁」的说明已随之更正。
  - **顺带修掉第一阶段遗留的红测试**：`hibiki/test/tools/gal_hook_overlay_buttons_guard_test.dart`
    里那条「hook 台词字号随窗口高度缩放」（commit e8e23dd35 加的）与第一阶段的新契约**直接冲突**
    ——它断言 `kHookTextBaseHeightForFontDip` 必须存在，而第一阶段正是把这个常量删掉的。
    第一阶段（commit 64e0e8211）漏掉了它；develop 侧已在 `a44b45a91` 就地反转该断言修红，
    本阶段只是在其上**追加**一条「真滚动不得回退」的断言并收紧原有一条（原表述称
    「分支上一直是红的」不确，实为 develop 已修、本 PR 分支基线内已含该修复），
    与第二阶段改动无关）。现就地把断言**反转**成「不得回退」，并在注释里写清契约为什么翻面。
- **备注**：native C++ 改动已用 `flutter build windows --debug` 真编译验证（第一、第二阶段各一次）。
  **仍未做**：真机肉眼复测（拖高浮窗看行数是否真变多、滚轮能否翻出被裁的句尾、滚动条位置
  是否遮字）尚未进行；C++ 无法在 Dart 测试里执行，上述守卫锁的是**源码结构**而非渲染结果。
