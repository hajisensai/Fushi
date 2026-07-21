# LunaHook vendored 二进制（GPLv3）

`galgame_voice_hook` 的 injector 在 **host 侧** 用 LunaHook 抓全引擎精确台词，写进共享内存文本环
（补 GDI hook 抓不到的 KiriKiriZ/RenPy/Unity 等引擎）。这里 vendor 其现成二进制（动态加载，不链
`.lib`、不编进任何目标）。

## 文件

| 文件 | 作用 | 加载方 |
|---|---|---|
| `LunaHost64.dll` / `LunaHost32.dll` | 宿主 API（`Luna_Start` 等 C 导出） | `LoadLibrary` 进 **injector 进程** |
| `LunaHook64.dll` / `LunaHook32.dll` | 引擎级文本 hook | 注入进 **游戏进程**（injector 用 `CreateRemoteThread(LoadLibraryW)`） |
| `LICENSE` | GNU GPLv3 | — |

DLL 位数必须匹配目标进程：32 位游戏用 `*32.dll`，64 位用 `*64.dll`。构建后 CMake 把与编译位数
匹配的两个 DLL 拷到 injector 输出目录。

## 来源与 ABI 版本（**换 DLL 前必读**）

- 来源：LunaTranslator [`v10.16.1.2`](https://github.com/HIllya51/LunaTranslator/releases/tag/v10.16.1.2)
  官方发布包。64 位 DLL 来自 `LunaTranslator_x64.zip`，32 位 DLL 来自
  `LunaTranslator_x86_win7.zip`，避免把不同 Windows 目标的 Host/Hook 混用。
- **ABI 定死**：以该 tag 发布包内 `LunaTranslator/textio/textsource/texthook.py` 和同 tag
  `src/NativeImpl/LunaHook/LunaHost/LunaHostDll.cpp` 为准。injector 的 `Luna_Start`（10 个
  `__cdecl` 回调槽）、`Luna_ConnectProcess` / `Luna_CheckIfNeedInject` / `Luna_DetachProcess`、
  `Luna_Settings`（6 参）和 `LunaThreadParam`（32B）均逐一与其对齐。
- **升级纪律**：先核发布包 DLL 的版本/哈希与导出，再读配套 `texthook.py` 和上游导出实现，同步改
  `injector_main.cpp` 与 `luna_symcheck.cpp`；禁止只覆盖 DLL。
- 校验：`hibiki_luna_symcheck.exe`（`tools/luna_symcheck.cpp`）纯 `LoadLibrary`+`GetProcAddress`，
  离线确认 4 个必需导出齐全。

## 发布文件校验

| 文件 | SHA-256 |
|---|---|
| `LunaHook32.dll` | `78580D5108A7E47B955508F1181DEB0EA76FF80C240F693FEEAA06711E41406C` |
| `LunaHost32.dll` | `532EAF37D20A0DB0B96DA9FE97314F6A0BBFB9F3F4EDE69AD8F6BE5115E2BFE3` |
| `LunaHook64.dll` | `5415A8DA6AB7F0B0A17310B1B46B9601BBECA8100161D516CBDE64452BCAF10B` |
| `LunaHost64.dll` | `A159B93D15DD91A756B9A48324AE0F68A9B1A010673E9A48D2CED8723C02C7A6` |

## 许可

LunaHook / LunaTranslator 为 GPLv3。本组件（`galgame_voice_hook`）亦按 GPLv3 分发；vendored 二进制
以未修改原样入库，见 `LICENSE`。
