# libplacebo（Windows x64，仅 D3D11 后端）

内置网页播放器的超分通道（计划 P2）：fork `packages/flutter_inappwebview_windows` 在 WGC 抓到的页面帧
上用 libplacebo 跑 mpv 用户着色器（Anime4K 各档 `.glsl`，与 mpv 视频页同一套文件），输出再交给 Flutter 纹理。
fork **运行期 `LoadLibrary` 动态加载**（`custom_platform_view/placebo_pass.cc`），不链接导入库：同尺寸下 DLL 缺失 /
加载失败可回到原样拷贝；异尺寸下 D3D11 `CopyResource` 不合法，因此保留上一目标帧并等待下帧重试。

| 项 | 值 |
|---|---|
| 上游 | https://github.com/haasn/libplacebo |
| 版本 | v7.360.1（commit `cee9b076f2c63104ccfd497fa79c39a867293ec4`），API 版本 360 → `libplacebo-360.dll` |
| 许可 | LGPL-2.1（见 `LICENSE.libplacebo`；动态加载、未修改源码） |
| 工具链 | MSYS2 MINGW64：gcc 16.2.0-3、binutils 2.47-3、meson 1.12.0-1、ninja 1.13.2-1、shaderc 2026.3-1、spirv-cross 1.4.357.0-1；脚本逐项守卫，漂移即失败 |
| 构建 | `.github/workflows/libplacebo-win.yml`（workflow_dispatch）调用本地同一配方 `tool/libplacebo/build_placebo.sh` |

## 配置

```
meson setup build --buildtype=release --prefer-static -Ddefault_library=shared \
  -Dc_link_args="-static-libgcc -static-libstdc++ -Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic" \
  -Dcpp_link_args="-static-libgcc -static-libstdc++ -Wl,-Bstatic -lstdc++ -lwinpthread -Wl,-Bdynamic" \
  -Dvulkan=disabled -Dopengl=disabled -Dd3d11=enabled -Dshaderc=enabled -Dglslang=disabled \
  -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled -Dxxhash=disabled -Dunwind=disabled \
  -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
```

## 产物（`bin/`，哈希见 `bin/SHA256SUMS`）

- `libplacebo-360.dll` — 唯一 DLL；shaderc、spirv-cross 及 GCC / C++ / winpthread 运行时均静态链入

MSYS2 的 `shaderc_combined.pc` 和 `spirv-cross-c-shared.pc` 不会列全静态传递依赖。构建脚本在临时
`PKG_CONFIG_PATH` 中提供同名覆盖：shaderc 补齐 glslang / SPIRV-Tools，spirv-cross 补齐各静态 backend；
不修改 libplacebo 上游源码。构建末尾以 `ldd` 拒绝任何 `/mingw64/` 依赖，并用 `objdump` 检查消费端所需导出。

fork 的 CMake 把 `bin/*.dll` 列进 `flutter_inappwebview_windows_bundled_libraries` → 单个 DLL 落在
`fushi.exe` 同级。与 media_kit 随包的 `libmpv-2.dll`（内含静态 libplacebo，不导出）无符号冲突。

## 头文件（`include/libplacebo/`）

上游 `src/include/libplacebo/` 原样 + 构建生成的 `config.h`（`PL_API_VER 360`）。fork 只用来取结构体布局与函数
签名（`decltype`），**必须与 DLL 同版本**——升级时两者一起换。
