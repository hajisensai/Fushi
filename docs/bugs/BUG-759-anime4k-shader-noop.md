## BUG-759 · Anime4K 着色器开了跟没开一样（glsl-shaders-append 非法 property 空下发）
- **报告**：2026-07-12（用户：hibiki 的 anime4k 跟没开一样，mpv 的正常）
- **真实性**：✅ 真 bug，根因 `hibiki/lib/src/media/video/video_shader_manager.dart:282-285`（修复前）
- **[x] ① 已修复** — 提交 `8d69c7b55`
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_shader_manager_test.dart`（纯函数 + 源码守卫）；`hibiki/integration_test/video_shader_apply_readback_itest.dart`（Windows 实机回读）
- **备注**：

### 现象
用户在着色器对话框勾选/下载了 Anime4K，视频画面「开了跟没开一样」；同一台 Windows 上用**独立 mpv** 加载同一套着色器则正常。

### 根因（数据流 + 平台边界）
着色器应用路径 `applyShadersToPlayer`（修复前）：
```dart
await native.setProperty('glsl-shaders', '');          // 清空成功
for (path in absolutePaths) {
  await native.setProperty('glsl-shaders-append', path); // ← 静默失败
}
```
`native` 是 media_kit `NativePlayer`，`setProperty` 底层是 `mpv_set_property_string`
（`media_kit-1.2.6/.../native/player/real.dart:1239`）。

- mpv 的 `-append` / `-clr` 等**后缀 action 只在命令行 / 配置文件**解析路径
  （`options/m_config_frontend.c` 的 `m_config_mogrify_cli_opt`，仅被 `m_config_set_option_cli` 调用）被识别。
- 作为 **property** 名经 `mpv_set_property_string` → `player/command.c` 的
  `mp_property_generic_option` → `m_config_get_co` **精确名查找（不剥后缀）** → 找不到
  `glsl-shaders-append` → 返回 `MPV_ERROR_PROPERTY_NOT_FOUND`。
- 而 media_kit 的 `setProperty` **丢弃 `mpv_set_property_string` 的返回码、不抛异常**
  （real.dart:1239-1246 调用后直接 free 返回），于是 `applyShadersToPlayer` 里的 `catch`
  **永不触发**，append 静默失败。

净效果：`glsl-shaders` 被清空后一个都没挂回去 → 恒为空 → 着色器从未进 libmpv 渲染管线
→「开了跟没开一样」。独立 mpv 正常，是因为它经 input.conf / 命令行路径下发（`-append` 在
那条路径合法）。

> 与 Windows ANGLE(OpenGL ES) 渲染后端无关：若真是 GLES 编译失败，`glsl-shaders` 会非空
> 且日志有 shader compile error；这里列表始终为空，mpv 根本没走到编译着色器那一步。

### 修复
改用 mpv 官方运行时改列表机制 `change-list` 命令，经 `NativePlayer.command(List<String>)`
（`mpv_command` 数组形式）下发——把每个路径作为**独立命令参数**传入，天然规避平台路径分隔符
（Unix `:` / Windows `;`）与 Windows 盘符 `:` 的转义问题：
```dart
for (cmd in buildShaderChangeListCommands(paths)) await native.command(cmd);
// buildShaderChangeListCommands: [ [change-list,glsl-shaders,clr,''],
//   [change-list,glsl-shaders,append,<path1>], ... ]
```
新增纯函数 `buildShaderChangeListCommands`（`video_shader_manager.dart`）便于单测；
`applyShadersToPlayer` 只把命令逐条 `command` 下发，best-effort 静默降级不变。五平台
libmpv 一致（移动端 `command` 同样写穿，不是移动端 no-op）。

### 测试
- 单测（CI 可跑）：`test/media/video/video_shader_manager_test.dart`
  - `buildShaderChangeListCommands`：空集→仅 clr；多路径→clr+逐个 append 保序；
    Windows 盘符路径（含 `:`/反斜杠）作为独立参数原样传入；**绝不出现 `glsl-shaders-append`**。
  - 源码守卫：apply 路径用 `native.command(`、不再有 `setProperty('glsl-shaders-append'`。
- 实机（Windows + libmpv）：`integration_test/video_shader_apply_readback_itest.dart`
  建 media_kit `Player`，`applyShadersToPlayer` 下发两个真实 `.glsl` 后
  `getProperty('glsl-shaders')` 回读 → 断言含两个路径（修复生效）；对照旧
  `glsl-shaders-append` property 写法回读为空（复现空下发根因）。
</content>
