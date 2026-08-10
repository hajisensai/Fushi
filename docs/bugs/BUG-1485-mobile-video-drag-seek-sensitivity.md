## BUG-1485 · 移动端视频横滑 seek 灵敏度过高
- **报告**：2026-08-10（用户：「移动端看视频，通过滑动来调进度的时候灵敏度太高了，一拽就起飞了，可以调舒服一点」）
- **真实性**：✅ 真 bug。根因是**灵敏度与视频总时长成正比**，不是常数没调好。
  - `third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material.dart:854`（改前）
    ——fork 内建公式 `seconds = -(diff * duration / horizontalGestureSensitivity)`，分母是
    `fushi/lib/src/pages/implementations/video_fushi/controls_theme.part.dart:199`（改前）传入的
    `_videoHorizontalGestureSensitivity = 1000.0`（`fushi/lib/src/pages/implementations/video_fushi_page.dart:876`，改前）。
  - 代入实数：**每像素跨越的时间 = 总时长 / 1000**。24 分钟番剧 = 1.44 秒/px，2 小时电影 = **7.2 秒/px**；
    手机屏宽约 400dp，拖满整屏在电影上就是 **48 分钟**（总时长的 40%）——用户说的「一拽就起飞」。
    反方向同样坏：3 分钟短片每像素只有 0.18 秒，拖满整屏才 72 秒，太钝。
  - 第二层精度问题：fork 的 `swipeDuration` 是 `int` **整秒**，`duration`/`position` 也取 `inSeconds`，
    亚秒级微调被直接量化掉。
- **[x] ① 已修复** — 换掉换算模型本身，而不是改一个常数。
  - 新纯函数模型 `fushi/lib/src/media/video/video_horizontal_seek_gesture.dart`：
    `VideoHorizontalSeekGesture.resolveDelta/resolveTarget`（输入拖动像素 / 画面宽度 / 总时长 /
    当前位置 / 灵敏度档位，输出有符号增量与已 clamp 的目标位置）。三条性质：
    1. **与总时长解耦**：基准语义改成「拖过整屏宽度 = 固定一段时长」（档位给出 45 / 90 / 180 秒）。
    2. **超长 / 超短片钳制**：跨度地板 `min(max(15s, 总时长*3%), 总时长)`、天花板 `max(地板, 总时长*50%)`。
       8 小时录播仍有 14.4 分钟/屏可粗调；60 秒短片被压到 30 秒/屏，不会一屏飞完。
    3. **幂函数阻尼**（gamma = 1.5）：小位移更细（20px ≈ 1 秒，可做秒级微调）、大位移更快；
       端点不变——拖满整屏恰好等于钳制后的跨度。
  - fork 侧改成注入点而非硬编码公式（`third_party/media_kit_video/.../material.dart`）：新增
    `typedef HorizontalSeekResolver` + theme 字段 `horizontalSeekResolver`，`onHorizontalDragUpdate`
    在其非空时改调 resolver（为空时上游公式原样保留）；`swipeDuration` 由 `int` 秒**改类型为
    `Duration`**（解开亚秒量化）；`onHorizontalDragEnd` 顺带清零 `swipeDuration`，堵住「下一次退化拖动
    （只有一次 update）在松手时重放上一次增量」。补丁记入 `third_party/media_kit_video/PATCHES.md`。
  - 接线只在移动 theme：`fushi/lib/src/pages/implementations/video_fushi/controls_theme.part.dart:198`
    起。桌面 `_desktopControlsTheme` 本就没有横滑手势字段，**鼠标拖进度条 / 键盘 seek 键行为零改动**。
  - 用户可调：新增设置项「拖动调进度灵敏度」三档（低 / 中 / 高），落在既有
    `VideoAsbplayerConfig`（复用已登记的 `video_asbplayer_config` 偏好键，无新 pref key），
    schema 在 `fushi/lib/src/settings/settings_schema_video.dart`（`video.playback.drag_seek_sensitivity`，
    `visible: isMobilePlatform`——桌面无此手势不显假开关）。**默认取「中」= 拖过整屏 90 秒**，
    比旧行为在 2 小时片上钝约 32 倍、在 24 分钟片上钝约 6.4 倍。持久化存枚举 `name` 而非 index。
  - i18n（走 `tool/i18n_sync.dart --add`，17 语言）：`video_setting_drag_seek_sensitivity`、
    `_hint`、`_low`、`_medium`、`_high`。
- **[x] ② 已加自动化测试**
  - 换算模型数值单测：`fushi/test/media/video/video_horizontal_seek_gesture_test.dart`（23 条）——
    长/短片同位移对比、阻尼单调性与超线性、三档序、超长/超短钳制、片头片尾 clamp、
    时长未知 / 宽度为 0 / NaN / 无穷等退化输入、`resolveTarget == position + resolveDelta`。
  - 配置持久化：`fushi/test/media/video/video_asbplayer_config_test.dart` 新增「旧档缺键 / 脏值
    回落默认档 / 存 name 不存 index」。
  - 源码守卫：`fushi/test/pages/video_horizontal_seek_test.dart` 新增三条——旧比例制常量已删、
    移动 theme 接上 resolver + 用户档位且不再传 `horizontalGestureSensitivity`、fork 的注入点
    没被 re-vendor 抹掉。**已做变异实测**（写死档位 / 改 fork 初值 / 重新引入旧常量三次变异，
    各自确认变红后反向替换还原）。第一轮变异实测抓到守卫自身的假绿：裸 `contains` 被注释里的
    同名字面量喂绿，已全部改用 `source_guard` 的剥注释判据（`containsCodeLine` / `containsIdentifier`）。
- **备注**：未做真机验证——本轮只在 headless 层验证（`flutter analyze` 全绿 + 上述定向测试全绿）。
  手势本身（`onHorizontalDrag*` 走 media_kit 控制条）在 widget 测试里驱动不了，真机手感需下次
  Android 真机回归时确认默认档是否还需要再钝一档。
