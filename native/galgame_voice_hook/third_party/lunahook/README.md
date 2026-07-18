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

- 来源：LunaTranslator（<https://github.com/HIllya51/LunaTranslator>）随附的 LunaHook 引擎。
  取自本机安装 `D:\LunaTranslator\files\plugins\LunaHook\`。
- **ABI 定死**：本批 DLL 是一个**回调式**过渡版本，其确切 C 导出契约由同版本安装自带的
  `LunaTranslator/textsource/texthook.py`（那份 `ctypes` 声明）给出。injector 里
  `injector_main.cpp` 的 `Luna_Start`（8 个 __cdecl 回调）/`Luna_CreatePipeAndCheck`/`Luna_Detach`
  /`LunaThreadParam`(32B) 签名逐一按它对齐。
- ⚠️ 与当前 GitHub HEAD 的 LunaHost API **不同**（HEAD 已改名 `Luna_ConnectProcess`/
  `Luna_DetachProcess` + 10 回调）。**升级 DLL 时**：先 `dumpbin /exports LunaHost64.dll` 核导出集，
  再找配套 `texthook.py` 重新定签名，同步改 `injector_main.cpp`——别直接照 HEAD 源接线。
- 校验：`hibiki_luna_symcheck.exe`（`tools/luna_symcheck.cpp`）纯 `LoadLibrary`+`GetProcAddress`，
  离线确认 3 个必需导出（`Luna_Start`/`Luna_CreatePipeAndCheck`/`Luna_Detach`）齐全。

## 许可

LunaHook / LunaTranslator 为 GPLv3。本组件（`galgame_voice_hook`）亦按 GPLv3 分发；vendored 二进制
以未修改原样入库，见 `LICENSE`。
