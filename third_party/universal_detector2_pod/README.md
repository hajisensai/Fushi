# UniversalDetector2 pod 本地化（iOS）

`flutter_charset_detector_ios`（文本编码探测）依赖 CocoaPods trunk 上的
`UniversalDetector2` 2.0.1。trunk 的 podspec 用 `git` + `submodules: true` 取源码：
`pod install` 会去 `github.com/amake/UniversalDetector2` clone，再去
`gitlab.freedesktop.org/uchardet/uchardet` 拉子模块。2026-11-27 的发版构建里后者返回 503，
iOS job 在 `pod install` 直接失败。发版构建不应依赖第三方主机当场在线，所以把 pod 用到的源码
原样收进本目录，`fushi/ios/Podfile` 用 `:path =>` 指过来，构建时不再联网取这个 pod。

## 内容

- `UniversalDetector2.podspec.json`：trunk 原文（`Specs/f/e/1/UniversalDetector2/2.0.1/`），一字未改。
  `:path` pod 不读 `source`，其中的 git 地址只作出处记录。
- `UniversalDetector/*.{h,m}`、`LICENSE`：`amake/UniversalDetector2` tag `2.0.1`
  （commit `d3217b732a0c56af689ea38cb52c8e20e2399dd8`）。
- `external/uchardet/src/**/*.{h,cpp}`、`external/uchardet/src/*.tab`、`COPYING`、`AUTHORS`：
  该 tag 钉住的子模块 `uchardet` commit `ae6302a016088ad07177f86d417b20010053632b`。

只收 podspec 的 `source_files` / `preserve_paths` / 许可文件，测试、Xcode 工程、CMake 脚本不收。
两者都是 MPL-1.1/GPL/LGPL 三许可（uchardet）与 MPL（UniversalDetector2），按原样分发源码满足许可。

## 升级

改版本时整体替换：clone 新 tag（`--recurse-submodules`），按 podspec 的 `source_files` /
`preserve_paths` 重新拷文件，换 `UniversalDetector2.podspec.json` 为 trunk 新原文，更新上面的
两个 commit。守卫 `fushi/test/build/apple_pods_offline_guard_test.dart` 钉住 Podfile 指向本目录、
podspec 版本与 `flutter_charset_detector_ios` 要求的版本一致。
