# OCR DirectML 能力探针（BUG-2050）

回答一个问题：**某个 ONNX 模型在本机 ORT 的 DirectML EP 上到底能不能建出会话，
建得起来的话比 CPU 快多少。**

存在的理由：`fushi/lib/src/ocr/ocr_inference.dart` 的 Windows EP 偏好表写着
「不要 DirectML」，依据是 2026-09-02 的实测。那条注释同时写了「要改回来先重新
拿数」——这个目录就是拿数的量具。没有它，那句话是空的。

不参与任何构建，不被 app 引用；手动编译、手动跑。

## 它分三段，互不推断

| 段 | 问题 | 为什么必须分开 |
|---|---|---|
| ① `GetAvailableProviders()` | DML **编译**进当前运行时了吗 | 编译进来 ≠ 能建出会话。这是必要不充分条件 |
| ② `D3D12CreateDevice` | 这台机器**此刻**建得出 D3D12 设备吗 | 本机 GPU 客户端饱和时任何新进程都建不出（`E_OUTOFMEMORY 0x8007000E`），会伪装成模型问题，且会自行波动 |
| ③ `Ort::Session(DML)` / `(CPU)` | 这个**模型**在 DML 上成立吗，快多少 | 只有 ①② 都过了，③ 的失败才能归因到模型 |

DML 会话选项严格复刻
`third_party/flutter_onnxruntime/windows/src/dml_provider.cc`：
`ORT_SEQUENTIAL` + `DisableMemPattern` +
`OrtDmlApi::SessionOptionsAppendExecutionProvider_DML(0)`。改了那边，这边要跟着改。

## 跑法

运行时用与 `third_party/flutter_onnxruntime/windows/CMakeLists.txt` **同一组
SHA-256 钉死的 nupkg**，所以探针里的字节和 app 构建产出的完全一致。版本号和
哈希以那个 CMakeLists 为准，下面的值是 2026-09-02 的快照。

```bash
# 1) 取运行时（本机需要代理见 CLAUDE.local.md）
curl -L --proxy http://127.0.0.1:34151 --ssl-no-revoke -o ort-dml.nupkg \
  https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/1.22.0/microsoft.ml.onnxruntime.directml.1.22.0.nupkg
curl -L --proxy http://127.0.0.1:34151 --ssl-no-revoke -o directml.nupkg \
  https://api.nuget.org/v3-flatcontainer/microsoft.ai.directml/1.15.4/microsoft.ai.directml.1.15.4.nupkg

# 必须核对，否则测的不是 app 会用的那份字节
sha256sum ort-dml.nupkg directml.nupkg
# 29F9872D786236B79AA83F94482F3A17C14297E4833768D6D0ED4883EE732E60  ort-dml
# 4E7CB7DDCE8CF837A7A75DC029209B520CA0101470FCDF275C1F49736A3615B9  directml

unzip -q ort-dml.nupkg -d ort && unzip -q directml.nupkg -d dml

# 2) 取模型（清单见 fushi/lib/src/ocr/manga_ocr_model_manifest.dart）
curl -L --proxy http://127.0.0.1:34151 --ssl-no-revoke -o detector-v4-s_int8.onnx \
  https://huggingface.co/ogkalu/comic-text-and-bubble-detector/resolve/main/detector-v4-s_int8.onnx
```

编译（MSVC；`/utf-8` 不能省，否则本文件的中文注释会被按 GBK 解释、编译报一串
莫名其妙的语法错误）：

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cl /nologo /EHsc /std:c++17 /O2 /utf-8 /I ort\build\native\include probe.cpp ^
   /link /OUT:run\probe.exe ort\runtimes\win-x64\native\onnxruntime.lib d3d12.lib dxgi.lib
```

跑（三个 DLL 必须和 exe 同目录）：

```bash
cp ort/runtimes/win-x64/native/onnxruntime.dll run/
cp ort/runtimes/win-x64/native/onnxruntime_providers_shared.dll run/
cp dml/bin/x64-win/DirectML.dll run/
run/probe.exe detector-v4-s_int8.onnx
```

## 怎么读结果

**一个模型的一次观测不足以下结论**，必须有同架构对照组把变量隔离出来。
2026-09-02 那次就是靠 fp32 对照才把「是这台机器坏了」排除掉的：

```
                     DML 建会话        DML 稳态   CPU 建会话   CPU 稳态
int8（出包用）       ❌ 1547ms 后失败   —          734ms        81.5ms
fp32（对照组）       ✅ 2957ms          21.6ms     1461ms       419.4ms
```

fp32 在同一台机器、同一个运行时上建得起来且比 CPU 快 19.4 倍 ⇒ 不是显卡、
不是打包、不是 D3D12 ⇒ **变量精确就是 int8 量化**。

失败长这样，`80070057` 是 `E_INVALIDARG`：

```
ortErrorCode = ORT_RUNTIME_EXCEPTION
message      = Exception during initialization: ...\DmlExecutionProvider\src\
               MLOperatorAuthorImpl.cpp(2851)\onnxruntime.dll!...: 80070057
```

顺带记一笔：int8 在 **CPU** 上反而比 fp32 快 5 倍（81.5ms vs 419.4ms），
这就是当初选 int8 小档（11MB vs 168MB）的原因。fp32+DML 稳态虽然更快
（21.6ms），但建会话 2957ms + 首次推理 8817ms 的暖机代价，对「重新识别框选
区域」这种单图交互是净亏。要换档得连这笔一起算。
