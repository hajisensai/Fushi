# fushi_shell_thumbs

Windows 资源管理器里的书 / 漫画文件显示**封面**，而不是 `Fushi.Book` 的 exe 图标（拍板台
WoAtPpuvwm）。只随 Windows 安装包走，不是 app 进程的依赖。

## 支持的格式

容器按**文件内容**识别（不看扩展名，后缀写错的 cbr 也照样出封面）：

| 内容 | 封面怎么取 | 解析器 |
|---|---|---|
| epub | OPF `properties="cover-image"` → `<meta name="cover">` → `<guide>` 封面页里的第一张图 → spine 第一页里的第一张图 → 名字带 cover 的图 → 第一张图 | 纯 Rust（zip + quick-xml） |
| cbz / zip | 文件名以 `cover` 开头（或 `front` / `folder`）的图优先，否则自然排序（`2.jpg` < `10.jpg`）后的第一张；跳过 `__MACOSX/`、点文件 | 纯 Rust（zip） |
| cbr（RAR 4 / 5）、cb7 | 同 cbz | 安装目录里随包的 `7za\7z.dll` |
| pdf | 渲第一页（白底） | 安装目录里随包的 `pdfium.dll`（与 app 的 pdfrx 同一份） |

图片解码：jpeg / png / webp / gif / bmp / tiff（`image` crate，纯 Rust）。单张封面 ≤ 128 MiB、
像素边长 ≤ 32768、解码分配 ≤ 512 MiB，超了按坏文件处理。

不做：`.txt`（没有封面）、`.mokuro`（JSON，页图在旁边的目录里，资源管理器只给单个文件）；视频
不需要——Windows 自带的视频缩略图处理器注册在扩展名键上，`Fushi.Video` 不会盖掉它。

## 结构

```
explorer.exe
 └─ fushi_shell_thumbs.dll          COM 进程内服务器（IInitializeWithFile + IThumbnailProvider）
      │  只拿路径，不解析任何文件
      └─ fushi_shell_thumbs_host.exe <边长> <路径>      每张缩略图一次性的子进程
           ├─ job 对象：1 GiB 内存上限、父侧关闭即杀
           ├─ 15 秒超时（WaitForSingleObject）
           └─ stdout 回一帧：b"FTHB" + u32 宽 + u32 高 + BGRA（src/wire.rs）
```

为什么不交给系统的隔离进程：安装器按用户安装（`PrivilegesRequired=lowest`，注册写 `HKCU64`），
而系统缩略图隔离进程（COM Surrogate，AppID `{AB8902B4-…}`）激活不到 HKCU 注册的 CLSID——
2026-11-16 在 Windows 11 上实测 `IShellItemImageFactory::GetImage` 回 `REGDB_E_CLASSNOTREG`，
同样的注册加 `DisableProcessIsolation=1` 后成功。所以处理器以进程内方式进 explorer，隔离由我们
自己的宿主进程做：坏文件让宿主崩溃、卡死、吃内存，都只丢这一张缩略图，explorer 拿到 `E_FAIL`
退回图标。

宿主用普通优先级：实测（2026-11-16）机器满载时 `BELOW_NORMAL_PRIORITY_CLASS` 的宿主约 1/12 被饿到
超时，普通优先级下 84/84 成功。

## 注册（`fushi/windows/installer/fushi.iss`，`bookassoc` 任务）

- `HKCU64\Software\Classes\CLSID\{7CEC7E60-07B9-4389-BFC1-7B83D334456E}`：`InprocServer32` =
  `{app}\fushi_shell_thumbs.dll`、`ThreadingModel=Apartment`、`DisableProcessIsolation=1`。
  CLSID 与 `src/lib.rs` 的 `THUMBNAIL_PROVIDER_CLSID` 一致（守卫 `tests/registration_contract.rs`）。
- `Fushi.Book\ShellEx\{e357fccd-…}`：用户把书设成用 Fushi 打开时生效（就是「显示 Fushi 图标」的场景）。
- `SystemFileAssociations\.<epub|cbz|cbr|cb7|pdf>\ShellEx\{e357fccd-…}`：兜底，**只在该扩展名还没有
  别的缩略图处理器时**才写（`FushiThumbnailSlotFree`），不抢 CBXShell / SumatraPDF / Acrobat 等。
- 升级：被 explorer 占着的旧 DLL 在复制前改名成 `*.old`（加载中的 DLL 能改名不能删），下次安装 /
  卸载清掉。`ChangesAssociations=yes` 让资源管理器装完就重读关联。

## 构建与测试

```powershell
powershell -ExecutionPolicy Bypass -File native/fushi_shell_thumbs/build_windows_dll.ps1 [-InstallDirectory <dir>]
```

```bash
cd native/fushi_shell_thumbs
cargo test --profile quick                       # 单测 + 端到端（缺 7z / pdfium 时那几条 SKIP）
FUSHI_TEST_7Z_DIR=<含 7z.dll 的目录> FUSHI_TEST_PDFIUM_DLL=<pdfium.dll> FUSHI_THUMBS_REQUIRE_DEPS=1 \
  cargo test --profile quick                     # 与 PR 门 native-shell-thumbs-gate.yml 同口径
cargo run --profile quick --example probe -- <依赖目录> <输出目录> <文件...>   # 真实文件出 PNG
```

端到端测试照资源管理器的顺序走 COM，处理器真的拉起 cargo 编出的宿主 exe；RAR5 夹具按格式规范
手搓（store），7z 夹具用 7z.exe 现做，pdf 夹具现算 xref。
