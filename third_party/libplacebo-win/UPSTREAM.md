# libplacebo（Windows x64，仅 D3D11 后端）

内置网页播放器的超分通道（计划 P2）：fork `packages/flutter_inappwebview_windows` 在 WGC 抓到的页面帧
上用 libplacebo 跑 mpv 用户着色器（Anime4K 各档 `.glsl`，与 mpv 视频页同一套文件），输出再交给 Flutter 纹理。
fork **运行期 `LoadLibrary` 动态加载**（`custom_platform_view/placebo_pass.cc`），不链接导入库：DLL 缺失 /
加载失败一律 fail-open 回到原样拷贝。

| 项 | 值 |
|---|---|
| 上游 | https://github.com/haasn/libplacebo |
| 版本 | v7.360.1（commit `cee9b076f2c63104ccfd497fa79c39a867293ec4`），API 版本 360 → `libplacebo-360.dll` |
| 许可 | LGPL-2.1（见 `LICENSE.libplacebo`；动态加载、未修改源码） |
| 工具链 | MSYS2 MINGW64：gcc 16.1.0、meson 1.12.0、ninja 1.13.2、shaderc 2026.3、spirv-cross 1.4.357 |
| 构建 | `.github/workflows/libplacebo-win.yml`（workflow_dispatch）复刻同一配方；本地 `tool/libplacebo-win/build.sh` |

## 配置

```
meson setup build --buildtype=release -Ddefault_library=shared \
  -Dvulkan=disabled -Dopengl=disabled -Dd3d11=enabled -Dshaderc=enabled -Dglslang=disabled \
  -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled -Dxxhash=disabled -Dunwind=disabled \
  -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
```

## 产物（`bin/`，哈希见 `bin/SHA256SUMS`）

- `libplacebo-360.dll` — 本体
- `libshaderc_shared.dll`、`libspirv-cross-c-shared.dll` — GLSL → SPIR-V → HLSL 编译链（D3D11 后端必需）
- `libgcc_s_seh-1.dll`、`libstdc++-6.dll`、`libwinpthread-1.dll` — MinGW 运行时（shaderc / spirv-cross 依赖）

fork 的 CMake 把 `bin/*.dll` 整批列进 `flutter_inappwebview_windows_bundled_libraries` → 落在 `fushi.exe` 同级。
与 media_kit 随包的 `libmpv-2.dll`（内含静态 libplacebo，不导出）无符号冲突；本包 DLL 名均不与现有随包重名。

## 头文件（`include/libplacebo/`）

上游 `src/include/libplacebo/` 原样 + 构建生成的 `config.h`（`PL_API_VER 360`）。fork 只用来取结构体布局与函数
签名（`decltype`），**必须与 DLL 同版本**——升级时两者一起换。

## 待办

- 体积：`libshaderc_shared.dll` 10.6 MB。CI 可改为把 shaderc / spirv-cross 静态链进 libplacebo（`--prefer-static`
  + 静态 MinGW 运行时）收成单 DLL；本地首版先求可用。
