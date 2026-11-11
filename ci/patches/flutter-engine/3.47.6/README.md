# Flutter 3.47.6 Windows 引擎补丁：合成器内 HDR 输出、无障碍树加固

让 HDR 视频画在 Flutter **自己的**交换链里（R16G16B16A16_FLOAT + scRGB），
不再需要把 libmpv 的 gpu-next 画进主窗后面的独立宿主窗（该宿主窗已于 2026-10-18 删除）。只改 Windows 嵌入层
（`flutter_windows.dll`），Dart 侧与其它平台不受影响。

## 基线

| 仓库 | 提交 |
|---|---|
| flutter/flutter（tag 3.47.6） | `5fc346839b5d0eef006ed8404392afb4dfae428d` |
| 引擎版本（`bin/internal/engine.version`） | `692136cb6582dbfc5af3fb33c2515a069f2f66d0` |
| ANGLE（`engine/src/flutter/third_party/angle`，DEPS 拉取） | `84027aca9b71c9ba335bd000dad1107b8810a511` |

升级 Flutter 时全部补丁都要重新对齐基线（3.44.0 → 3.47.6 的移植记录见文末）；`tool/engine_overlay.ps1` 会拒绝把
引擎版本不符的产物装进 SDK。

## 补丁（按顺序 `git apply`）

渲染后端：Fushi 五端全线 Impeller、不保留 Skia 回退（所有者 2026-10-24 拍板，
`docs/specs/2026-10-23-music-module-design.md` D13）。runner（`fushi/windows/runner/main.cpp`）显式
`set_impeller_switch(Enabled)`；HDR 输出在 Impeller 下由第 3 份补丁接上。

### `engine-hdr-output.patch`（flutter 仓库根目录 `git apply`）

- 新导出 `FlutterDesktopViewSetHdrOutput(view, enabled, sdr_white_nits)`：按 view 开关。
- `egl::Manager`：可选的 RGBA16F 配置（`EGL_EXT_pixel_format_float`）+ 不绑配置的
  上下文（`EGL_KHR_no_config_context`），同一上下文能挂 8-bit 与半浮点 surface；
  HDR 窗口 surface 带 `EGL_GL_COLORSPACE = EGL_GL_COLORSPACE_SCRGB_LINEAR_EXT`。
  任一扩展缺失 → HDR 不可用，原版路径不受影响。
- 合成器：HDR 开启时 backing store 是 RGBA16F，存「扩展范围 sRGB」（1.0 = 界面白，
  视频高光 >1、广色域为负分量）；Present 用一个 shader pass 解码成 scRGB
  （去预乘 → 保号 sRGB EOTF → × SDR 白/80 → 预乘）写进交换链。该 pass 保存并恢复
  它碰过的全部 GL 状态（与 Skia 共用上下文，泄漏 `GL_ARRAY_BUFFER` 会让 Skia
  下一帧把 VBO 偏移当指针读，ANGLE 内访问违例）。
- 外部纹理：`kFlutterDesktopPixelFormatRGBA16F`（=3）的 GPU surface 描述符按半浮点
  导入，Skia 侧按 `kRGBA_F16` 采样，不钳位。
- 渲染目标缓存按尺寸命中，补了「格式代」计数：开关 HDR 时作废旧 backing store。
- 诊断：`FUSHI_HDR_PROBE=1` 时在切到 RGBA16F 后第 120 帧回读 backing store 三个点；
  状态切换以 `FML_LOG(IMPORTANT)` 记一行（只在变化时）。
- 这份补丁本身只接了 Skia 路径（Impeller 下 `SetHdrOutput` 返回 false）；Impeller 由
  `engine-impeller-hdr.patch` 接上。

### `engine-underlay-composition.patch`（flutter 仓库根目录，叠在上一份之上）

`FlutterDesktopViewSetUnderlayComposition`：按 view 改用 DirectComposition 顶层 visual 呈现
（8-bit，开着时 HDR 暂停），让网页视频的窗口化 WebView2 子窗透过 Flutter 透明像素显示。
与渲染后端无关（只换窗口 surface）。

### `engine-impeller-hdr.patch`（flutter 仓库根目录，叠在前两份之上）

把合成器内 HDR 接到 Impeller（GLES / ANGLE）路径上，行为与 Skia 路径一致：

- 合成器：Impeller 的三条 backing store 分支都能分配 RGBA16F（隐式 MSAA = 半浮点纹理 +
  `EXT_multisampled_render_to_texture`；只有离屏 MSAA 时半浮点改走单采样纹理，因为 Present
  的 scRGB pass 要把 backing store 当纹理采样）；`SetHdrOutput` 不再因 Impeller 拒绝。
- embedder：`GL_RGBA16F` 的 backing store 包成 `kR16G16B16A16Float` 渲染目标；RGBA16F 外部
  纹理（HDR 视频）按 `kR16G16B16A16Float` 包装，不再被「只支持 GL_RGBA8」拒掉。
- Impeller 离屏格式：Impeller GLES 的离屏层（saveLayer、背景滤镜触发的整帧 readback、模糊等
  滤镜子 pass）一律按上下文默认的 8-bit 分配——不改的话画面里一出现 `BackdropFilter`，整帧
  就被钳回 ≤1.0（实测：backing store 中线三点全部 1.000）。`RenderTargetAllocator` 加了「默认
  颜色格式覆盖」，`Canvas` 在根目标是 RGBA16F 的帧里把它设成 RGBA16F、帧尾还原；渲染目标缓存
  命中时额外比对颜色格式。Impeller GLES 的着色器程序按 shader 缓存、与目标格式无关，半浮点
  变体不触发重新编译。
- 诊断：`FUSHI_HDR_PROBE=repeat` 每 30 帧回读一次（8-bit 帧也读，便于两种渲染器对照），
  `FUSHI_HDR_PROBE_LOG=<文件>` 同时追加到文件（`flutter test -d windows` 不收引擎日志）。
  取证脚本：`fushi/integration_test/video_compositor_hdr_probe_itest.dart`。

### `engine-d3d-keyed-mutex.patch`（flutter 仓库根目录，叠在前三份之上；BUG-3888）

外部视频纹理改成 keyed mutex 同步。原版 `ExternalTextureD3d` 对 share handle 只做一次
`eglCreatePbufferFromClientBuffer` + `eglBindTexImage`，之后一直直接采样那块跨设备共享纹理；
legacy `D3D11_RESOURCE_MISC_SHARED` 资源只靠 OS 隐式串行化，生产端（media_kit 的设备）随时可能
覆写正在被采样的纹理，ANGLE 自己也从不 `AcquireSync`。补丁：

- `ExternalTextureD3d`：share handle 先在 ANGLE 设备上 `OpenSharedResource` 看 `MiscFlags`。带
  `D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX` 时**不绑共享纹理**，另建一块引擎自有的同尺寸同格式纹理，
  GL 只绑它（`EGL_D3D_TEXTURE_ANGLE`）。每次 resolve（即生产端每 mark 一帧）在 raster 线程上
  `AcquireSync(0, 0)` → `CopyResource(引擎副本, 共享纹理)` → 立刻 `ReleaseSync(0)`；取不到（生产端正在写，
  `WAIT_TIMEOUT`）就沿用上一份副本，生产端放锁后再 mark 会重新 resolve。锁从不跨 ANGLE 的 draw 持有
  （ANGLE 注释：keyed mutex 释放会把资源从管线上解绑，打乱它的状态缓存），raster 线程从不等锁。
  不带 keyed mutex 的纹理走原版路径不变。
- `egl::Manager`：构造时解析 ANGLE 的 D3D11 设备并 `ID3D10Multithread::SetMultithreadProtected(TRUE)`——
  上面的 D3D11 调用发生在 ANGLE 的共享上下文锁之外，而 IO 线程的 resource context 可能同时在 ANGLE
  里用同一个 immediate context；必须在任何别的线程用设备之前打开（中途切换会和在途调用竞争）。
  设备没被保护时，带 keyed mutex 的纹理不显示（报错日志），绝不无锁采样。
- 新导出 `FlutterDesktopGpuSurfaceSupportsKeyedMutex()`：插件用 `GetProcAddress` 查到它才给纹理加 keyed
  mutex；原版引擎没有这个导出，插件留在 legacy 共享纹理，「补丁引擎与原版引擎都能跑同一份 app」不变。
- 代价：每个新视频帧在 Flutter 设备上多一次整帧 GPU 拷贝。

### `engine-a11y-tree-hardening.patch`（flutter 仓库根目录，与前四份互不重叠，按序叠在其后；BUG-4380）

Windows 无障碍树加固（Windows 嵌入层与 `shell/platform/common` 的无障碍桥，Dart 侧不变）。原版
`AccessibilityBridge::CommitUpdates` 把框架的增量语义更新原样交给 `ui::AXTree::Unserialize`；
AXTree 拒收时**已经改完一部分树**，bridge 只打日志就 return，节点委托映射与树从此脱节，外部 UIA
客户端（输入法、划词、讲述人）一查询就在 `flutter_windows.dll` 里解引用空委托 / 已释放节点，或在
下一次重挂时 `CreateRemoveReparentedNodesUpdate` 的 `child_ids.erase(end())` 越界写坏堆（BUG-2337 /
BUG-2345 / BUG-3796 / BUG-4073 / BUG-4333 都是这一个失步模型）。补丁：

- bridge 保留框架下发过的每个节点的最新数据（`semantics_nodes_`，flags 按值存，不再指向已释放的
  embedder 缓冲区）和自定义动作（`custom_actions_`）。每次提交先合并 pending，再从根推出目标树
  （`PlanTree`：子节点必须有数据、每个节点只挂一个父节点且本帧重发的父节点优先、先父后子），与当前
  AXTree 比对生成两步更新（`ApplyTreePlan`）。框架违约的帧（列出没下发的子节点、孤儿节点、换父节点
  不重发、同一子节点两个父节点）不再交给 AXTree 拒收；缺的部分在数据到达后自动挂上。保留数据的上限是
  框架 id 空间（id 在 2^16-1 回绕）。
- AXTree 仍拒收时整树重建（`RebuildTree`）：先清事件、销毁全部委托（平台节点 `Destroy`，客户端拿到
  「元素不可用」），再用同一 tree id 新建 AXTree 从目标树重建；重建也失败就留空树。树与委托映射
  始终一致，绝不半应用。
- `OnNodeReparented` 重建委托（AXTree 在同一份更新里销毁并重建同 id 节点时只发这个回调）；
  删掉 release 下无效的 `assert` 与 `CreateRemoveReparentedNodesUpdate`。
- 委托：`ChildAtIndex` 越界返回 `nullptr`，`HitTestSync` 跳过拿不到委托的子节点。
- 引擎单测加在 `accessibility_bridge_unittests.cc`（未纳入本仓 CI，编引擎时跑
  `ninja -C out\host_debug flutter/shell/platform/common:common_cpp_unittests` 一类目标）。

上游没有对应修复（截至 2026-11-10，`main` 上 `accessibility_bridge.cc` 仍是拒收即 return）。
**删除条件**：上游 bridge 改成拒收后能自愈、且不再依赖 release 下无效的 `assert` 时删掉，或回移上游实现。

### `engine-program-binary-cache.patch`（flutter 仓库根目录，叠在前五份之上）

着色器程序磁盘缓存。冷启动时 `FlutterWindowsEngine::Run → … → PlatformView::NotifyCreated` 在主线程上
干等 raster 线程建 `impeller::ContentContext`，后者逐条 `PipelineLibraryGLES::CreatePipeline →
glLinkProgram`，ANGLE 在后台线程 `ProgramD3D::GetPixelExecutableTask → d3dcompiler_47` 把每条管线编成
DXBC——每次启动全量重编，Release 实测主线程阻塞约 1 秒（580→1587 ms）。ANGLE 自带的程序缓存只在内存里，
应用不给 `EGL_ANDROID_blob_cache` 回调就不落盘。补丁：

- `egl::ProgramBinaryCache`（新文件 `egl/program_binary_cache.{h,cc}` + 单测）：blob cache 的磁盘后端。
  一键一文件（`<目录>\<命名空间>\<SHA-1 十六进制>.bin`），文件头带 magic / 格式号 / 键长 / 值长 /
  FNV-1a 校验和、正文带完整键；读出时逐项核对，短文件、校验不符、键不符一律当未命中并入队删除。
  `Get` 同步读（它替代的就是同线程上的一次编译），ANGLE 先问大小再要字节，第一次读出的值暂存一次，
  不读两遍。`Put` 只把值拷进队列；后台线程（`THREAD_MODE_BACKGROUND_BEGIN`，CPU 与 I/O 都降优先级）
  负责写（临时文件 + `MoveFileExW` 原子替换，不 `FlushFileBuffers`——断电撕裂的文件过不了校验和）、
  命中后刷新 mtime、删坏文件、总量封顶（32 MB，按 mtime 淘汰最久未用；单条 >4 MB 不存；排队未写
  >16 MB 丢弃）。建不出目录、`ERROR_DISK_FULL` / `ERROR_ACCESS_DENIED` 等就整场停写，只退回照常编译。
- 命名空间（子目录名）= FNV-1a(格式号 + `GetFlutterEngineVersion()` + 本 `flutter_windows.dll` 文件的
  大小与修改时间)：换引擎版本、换补丁、重编 DLL 都换新目录，旧目录在后台删掉（只删 16 位小写十六进制
  名的目录，不碰别的东西）。
- `egl::Manager`：`eglInitialize` 之后、建上下文之前，若 runner 配了目录且 display 声明
  `EGL_ANDROID_blob_cache`，调 `eglSetBlobCacheFuncsANDROID`。display 被所有 manager 共用、最后一个才
  `eglTerminate`（ANGLE terminate 时清掉回调），所以装没装按 display 生命周期记。
- 新导出 `FlutterDesktopSetProgramBinaryCacheDirectory(const wchar_t*)`：进程级，必须在建第一个引擎
  之前调。runner 用 `GetProcAddress` 解析，原版引擎没有它就照常每次编译。

缓存 key 与失效（ANGLE `84027ac` 源码）：

- key 是 `MemoryProgramCache::ComputeHash`（`src/libANGLE/MemoryProgramCache.cpp:69-113`）：各 shader 的
  `writeShaderKey`（源码 + 编译选项）、`ANGLE_PROGRAM_VERSION`、`GetANGLESHVersion()`、上下文 ES 版本、
  **`GL_RENDERER` 字符串**、attrib / uniform / 输出位置绑定、TF varyings。D3D11 下 `GL_RENDERER` =
  `ANGLE (<厂商>, <适配器描述> (<DeviceId>) Direct3D11 vs_5_0 ps_5_0, D3D11-<驱动版本>)`
  （`src/libANGLE/Context.cpp:3490-3520`、`renderer/d3d/d3d11/Renderer11.cpp:2340-2356`、`:4533-4540`，
  非 WebGL 上下文带完整驱动版本），所以**换显卡、换驱动都换 key**。
- 载入时再查一遍：`Program::deserialize`（`src/libANGLE/Program.cpp:2260-2300`）核对程序版本、
  64 位、SH 版本、renderer 字符串、ES 版本；`ProgramExecutableD3D::load`
  （`renderer/d3d/ProgramExecutableD3D.cpp:491-520`）核对 `DeviceIdentifier`（VendorId / DeviceId /
  SubSysId / Revision / FeatureLevel，`Renderer11.cpp:2358-2370`）与编译优化级别。任一不符 →
  `CacheGetResult::Rejected` → 重新从源码链接（`Program.cpp:996-1001`），并经 `Put` 覆盖旧文件。
- 值是 gzip（`angletypes.cpp:1063-1125` 的 `CompressBlob` / `DecompressBlob`），解压失败同样当未命中
  （`MemoryProgramCache.cpp:137-143`）。
- ANGLE 自己的 key **不**覆盖：ANGLE 翻译器 / D3D 后端改了 HLSL 生成但没动 `ANGLE_PROGRAM_VERSION`
  （那个哈希只跟序列化相关文件走）。这一块由上面的命名空间兜住：换任何一份 DLL 都换目录。
- 命中路径对 Impeller 成立：`PipelineLibraryGLES` 的 `LinkProgram`（`impeller/renderer/backend/gles/
  pipeline_library_gles.cc:77-175`）是普通的 `glCompileShader` ×2 + `glBindAttribLocation` +
  `glLinkProgram`，不设 `GL_PROGRAM_BINARY_RETRIEVABLE_HINT`、不是 separable，正好走
  `Program::link` 里的缓存查找（`Program.cpp:961-1001`）与 `cacheProgramBinaryIfNotAlready`
  （`:2380-2410`）。ANGLE 调回调时持着自己的 blob cache 锁（`BlobCache.cpp:55-72`、`:85-126`）。
- 只缓存链好的程序，不改任何着色器、管线状态或渲染目标格式：渲染结果与不缓存完全一样；HDR
  （`engine-impeller-hdr.patch`）的半浮点目标不进 key、也不触发重新编译（见上文该节）。

目录由 runner 决定（`fushi/windows/runner/main.cpp` `ResolveProgramBinaryCacheDirectory`）：
`FUSHI_TEST_ROOT` → `<测试根>\cache\shader-programs`；否则 exe 旁可写 → `<exe>.ShaderCache`；
否则 `%LOCALAPPDATA%\Fushi\ShaderCache\<exe 路径哈希>`。永远不在生产数据根 `%APPDATA%\Fushi\Fushi` 下。
诊断：`FUSHI_PROGRAM_CACHE_LOG=<文件>` 时后台线程每次排空队列追加一行命中 / 未命中 / 坏文件 / 写入 /
丢弃 / 淘汰计数。引擎单测 `egl/program_binary_cache_unittests.cc`（目标
`flutter/shell/platform/windows:flutter_windows_unittests`，未纳入本仓 CI）。

**删除条件**：上游 Windows 嵌入层自己接上 `EGL_ANDROID_blob_cache`（或 Impeller GLES 自带程序二进制
缓存）时删掉。

### `angle-scrgb-swapchain.patch`（ANGLE 仓库根目录 `git apply`）

ANGLE 的 D3D11 后端原本**从不设置交换链色彩空间**，也不声明
`EGL_EXT_gl_colorspace_scrgb_linear`。没有色彩空间标记的 FP16 交换链被 DWM 当
sRGB 合成，>1.0 全被钳掉（实测：backing store 里 2.57，桌面上 1.000）。补丁：

- Win32 构建声明 `EGL_EXT_gl_colorspace_scrgb_linear`；
- 窗口 surface 请求 scRGB-linear 时改建 **flip 模型**交换链（DWM 只在 flip 模型上
  认色彩空间），`CheckColorSpaceSupport` 确认可呈现后 `SetColorSpace1(G10_P709)`；
  任何一步不行就让 surface 创建失败（引擎随之回退 8-bit），不做静默降级。

## 构建与产物

一条脚本（Windows，VS 2022 C++ 工作负载 + ATL、任一 Windows 10/11 SDK、Python 3、
`<工作目录>\depot_tools`）：

```powershell
tool/flutter_engine/build_patched_engine.ps1 -Root D:\fe -PatchVersion hdr-output-3   # 自动取 fushi/.fvmrc 的 Flutter 版本
# 只重编 / 只打包：-Steps build,stage,pack -Modes release
# 本机 VS 缺 ATL 时：-AtlDir '<另一套 VS>\VC\Tools\MSVC\<ver>\atlmfc'
# 机器忙时限并发：-Jobs 8（每个 clang-cl 最多吃约 1 GB）
# SDK 没装「Debugging Tools for Windows」（gn 报 dbghelp.dll not found）：-WindowsSdkDir <镜像目录>，
#   目录里用 junction 指回真 SDK 的各子目录，再放一份 Debuggers\x64\dbghelp.dll（只被拷进 out 目录，不进产物）
```

步骤：sync（clone `.fvmrc` 版本 + `gclient sync`；已有源码树就 fetch 新 tag 切过去再增量 sync）→ patch（六份引擎补丁 + ANGLE 一份，干净树上按序打）→
build（`gn --runtime-mode <mode>` + `ninja flutter_windows`，与官方产物同配置）→
stage（按 `windows-x64{,-profile,-release}` 布局 + `engine-overlay.json`）→
pack（连同 pdb 打 zip——`flutter build windows` 要求缓存里有 `flutter_windows.dll.pdb`，
缺了 assemble 直接失败；打印 `artifacts.json` 片段：填上发布地址后放进本目录）。

安装：`tool/engine_overlay.ps1 -ArtifactDir <stage 目录>` 或
`-Manifest ci/patches/flutter-engine/3.47.6/artifacts.json`（下载 + SHA-256 校验），
原文件备份到 `.stock-backup`，`-Restore` 还原。CI 走
`.github/actions/flutter-engine-overlay`，`artifacts.json` 不存在时用原版引擎构建（app
运行期只能 SDR 输出，并打 warning）。

## 当前产物

`artifacts.json` → release `flutter-engine-3.47.6-hdr-output-3`（prerelease、非 Latest；
2026-11-05 编，含 `engine-hdr-output` + `engine-underlay-composition` + `engine-impeller-hdr` +
`engine-d3d-keyed-mutex` 四份引擎补丁与 ANGLE 补丁；三种模式 + 匹配的 pdb——`flutter build windows`
缺 pdb 会在 assemble 失败；tag 不以数字 / `v`+数字开头，app 更新检查与发布 workflow 都不会把它当
app 版本）。**`hdr-output-3` 不含 `engine-a11y-tree-hardening.patch`**（2026-11-10 加入，尚未重编）：
下一次重编必须带上它（建议 `patchVersion` 取 `hdr-output-4`），发 release 后更新 `artifacts.json`，
在那之前出的包仍是旧引擎、无障碍树加固不生效。重编后换一个新的 `patchVersion` 发新 release，再改本目录的 `artifacts.json`，旧 release
留着给旧提交复现用（`hdr-output-2` 是前三份补丁、无 keyed mutex；`hdr-output-1` 只有 Skia 路径的
HDR、不含 underlay；3.44.0 时代的是 `flutter-engine-3.44.0-hdr-output-2`）。

注意：在**已经打过补丁**的源码树上重跑 `patch` 步骤会失败——`Invoke-Patch` 用「能否反向应用」判断
已打过，但前几份补丁的改动被后几份覆盖后不能单独反向应用。增量重编时只打新补丁
（`git -C <Root>lutter apply <新补丁>`），再跑 `-Steps build,stage,pack`。

## 3.44.0 → 3.47.6 移植记录

- ANGLE 版本没变（`84027ac`），`angle-scrgb-swapchain.patch` 原样沿用。
- `compositor_opengl.cc`：上游把 backing store 分配拆成 Impeller 的三条 MSAA 分支 + Skia
  分支，8-bit 纹理改用 `format_.sized_format`。半浮点分配挪进 Skia 分支，8-bit 沿用上游；
  `half_float` 的判定前移并直接并入 `half_float_renderable_`。
- `flutter_windows_view.h`：上游已自带 `<atomic>`，补丁不再加。
- embedder：上游把 `EmbedderExternalView::Render` 的渲染目标处理挪进
  `embedder_external_view_embedder.cc`，新增的缓存查找点用单参 `RenderTargetDescriptor`
  （取当前格式代），格式代失效语义不变。
- **Windows 默认渲染器变成 Impeller**（3.44 要显式 `--enable-impeller=true` 才开）：当时补丁只有
  Skia 路径，runner 曾显式钉 Skia；2026-10-24 起 `engine-impeller-hdr.patch` 把 HDR 接到
  Impeller，runner 改钉 Impeller（见上文「补丁」）。

## 运行时契约

- runner 用 `GetProcAddress` 解析 `FlutterDesktopViewSetHdrOutput`：原版引擎没有这个
  导出 → 报告不支持，app 留在 SDR 纹理路径。补丁引擎与原版引擎都能跑同一份 app。
- media_kit 只在引擎报告支持之后才交出 format=3 的纹理描述符。
