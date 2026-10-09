# Android / Darwin 原盘菜单构建

这里复用现有的两个 media-kit 构建 fork，通过固定提交上的补丁升级视频变体。
入口只生成本地产物，不上传 release，不修改应用的默认下载版本。

| 依赖 | 固定版本 |
| --- | --- |
| Android 构建仓库 | `hajisensai/libmpv-android-video-build`，`fe04fa1102a510a4dacd66c85dbe05b774826d1b` |
| Darwin 构建仓库 | `hajisensai/libmpv-darwin-build`，`865ef1494a89007fcf51a28609847debce85fbda` |
| mpv | `36abaa32d00a7229ee206aae12dc0e97e7962dca` |
| FFmpeg | 保留既有 `6.1.6` 与 full 解码器变体 |
| libbluray | `1.5.0`，内嵌 libudfread |
| libplacebo | `7.360.1` |

`patches/mpv-gl-dovi-p5.patch` 保留纹理渲染器 `gl_video` 的 Dolby Vision
profile 5 处理。新版 mpv 的 `mpi->dovi` 类型已改变，补丁从保留的 FFmpeg
side data 读取原始元数据。它与 Windows 的 `disc-navigation-state.patch`
共同应用；只升级 mpv 而漏掉任一补丁会丢失既有画面处理或菜单时间轴契约。

## Darwin

在装有 Xcode 与 Nix 的 Mac 上运行：

```sh
TARGET=macos bash tool/bluray/platforms/build_darwin.sh
TARGET=ios bash tool/bluray/platforms/build_darwin.sh
```

`WORK` 可指定构建目录，`XCODE_PATH` 可指定 Xcode.app。
`PREPARE_ONLY=1` 只准备固定基线的独立 worktree 并检查补丁应用。
产物和 `SHA256SUMS` 放在 `$WORK/output/`。

Darwin 配方保留旧 audio 变体；video 变体新增 libbluray/libplacebo，并把其
动态库一起放入 universal xcframework。保留共享 AVAudioSession 的引用计数
和 `skip-session-management` 选项。交叉编译采用目标 SDK，不让 mpv 的宿主
macOS SDK 探测覆盖 iOS 编译参数。iOS 没有 DiskArbitration，因此按 SDK
可用性选择文件路径实现；也不编译调用桌面 `java_home` 的进程启动分支。

验证本地产物时，向 CocoaPods / Flutter 构建进程同时传入：

```sh
export FUSHI_LIBMPV_DARWIN_ARCHIVE=/absolute/path/to/frameworks.tar.gz
export FUSHI_LIBMPV_DARWIN_SHA256=<SHA256SUMS中的对应值>
```

两份 Makefile 校验散列，并按内容散列隔离缓存。取消环境变量后恢复该插件已固定的
默认依赖；缓存链接会重新选择。准备失败将中止 podspec，不继续使用旧框架。

## Android

在现有 fork 所需的 Linux 构建环境上运行：

```sh
bash tool/bluray/platforms/build_android.sh
```

详细目录参数见入口脚本。验证本地产物时，将 `FUSHI_LIBMPV_ANDROID_DIR`
指向包含四个 ABI 的 full jar 和 `sha256.json` 的输出目录；Gradle 校验散列
后使用该目录，不需要先上传到 GitHub。未指定时使用 `third_party/media_kit_libs_android_video/native/` 下的固定随包产物。

## BD-J 与验收边界

这些配方构建 HDMV 导航与原生状态 API，不捆绑 Java VM / BD-J jar。
`bdj_jar=disabled` 只关闭 Java jar 的构建；HDMV 与视频文件读取照常编入。
BD-J 是否可用必须从当前盘与原生运行时状态判断，缺少运行时时明确报告，
不能把自动播放最长标题当作菜单成功。

生产依赖的版本和散列只能在实际产物通过验证后更新：

1. 对宿主可加载的 libmpv 运行 `tool/bluray/probe_libmpv.py`，确认命令、状态
   属性、协议、TrueHD 解码器和 render API。
2. 在真实 Flutter 视频纹理中验证菜单显示、键鼠/触摸输入、进入标题、返回
   菜单、字幕/音轨切换，以及原有直接播放标题链路。
3. 用既有 Dolby Vision profile 5 样本比较升级前后画面；源文件编译通过
   不等于 shader 已在目标设备正常渲染。
4. 检查 macOS 双架构、iOS 设备与模拟器切片，Android 每个发包 ABI。

Android、macOS 和 iOS 的默认包已切换到各插件 `native/` 下经过校验的产物，
来源和验证结果见各包的 provenance。macOS arm64 另通过真实 dylib 加载/API 探针；
目标设备中的原盘菜单显示与 Dolby Vision 画面对比仍需单独验证。
Linux app 使用系统 libmpv，应用必须以运行时探测结果判断能力。
