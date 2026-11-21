# onnxruntime pod 覆盖（Apple）

`flutter_onnxruntime`（本地漫画 OCR 等）在 iOS / macOS 依赖 CocoaPods trunk 上的
`onnxruntime-objc` / `onnxruntime-c` 1.23.0。两者 podspec 的唯一源
`https://download.onnxruntime.ai/pod-archive-onnxruntime-{c,objc}-1.23.0.zip`
自 2026-11-21 起不可用（该域名改发 `*.azureedge.net` 证书，curl 60；关掉校验也是 404），
`github.com/microsoft/onnxruntime` 与 `microsoft/onnxruntime-swift-package-manager`
自 2026-11-17 起 404。NuGet `Microsoft.ML.OnnxRuntime` 1.23.0 只有 iOS xcframework
（无 macOS 切片、且是另一份构建）、也没有 ObjC 源码，替代不了这两个 pod。

这里的两份 `*.podspec.json` 与 trunk 原文逐字一致，只把 `source` 换成本仓 release
[`onnxruntime-pods-1.23.0`](https://github.com/hajisensai/Fushi/releases/tag/onnxruntime-pods-1.23.0)
并钉 sha256；`fushi/ios/Podfile` 与 `fushi/macos/Podfile` 用 `:podspec =>` 指过来。

release 里的 zip 是 Mac 构建机 2026-11-20 从官方源拉下的 CocoaPods 缓存
（`~/Library/Caches/CocoaPods/Pods/Release/onnxruntime-{c,objc}/1.23.0-*`）原样 `zip -ry`
重打的包——即截至 11-20 所有 Apple 构建里打进去的同一份二进制；归档哈希与微软原 zip 不同。

清理条件：微软恢复任一官方 Apple 分发渠道（pod 源、SPM 包）后删掉本目录与两个 Podfile 里的
`pod ... :podspec` 两行；升级 onnxruntime 版本时必须同时重新确定来源，不能只改版本号。
