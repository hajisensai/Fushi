# Apple 签名与 TestFlight

Hibiki 的 iOS / macOS 发布签名怎么配、怎么轮换、坏了怎么查。
构建通道与版本号规则见 [build.md](build.md)；这里只讲 Apple 那一侧。

## 两条互不相干的链路

| | iOS | macOS |
|---|---|---|
| 分发方式 | TestFlight / App Store | Developer ID（商店之外直接下载） |
| 证书 | `Apple Distribution` | `Developer ID Application` |
| 描述文件 | `IOS_APP_STORE` 类型，绑 `app.fushi.reader` | 不需要 |
| 后处理 | 上传 App Store Connect 审核处理 | `notarytool` 公证 + `stapler` 装订 |
| 沙盒 | 不涉及 | **刻意不进 Mac App Store** |

macOS 不上架的原因不是懒：`macos/Runner/Release.entitlements` 已经刻意移除
`com.apple.security.app-sandbox`，因为应用内自动更新要替换 `/Applications/fushi.app`，
沙盒容器写不了那里（决策见 `docs/specs/2026-06-04-all-platform-auto-update-design.md` §5）。
Mac App Store 强制沙盒，两者不能兼得。Developer ID + 公证是「不上架但不被
Gatekeeper 拦」的正解。

**不要**为了「统一」把 macOS 也塞进 TestFlight —— 那等于把自动更新废掉。

## Bundle ID 现状（2026-08-06 改名 Fushi）

| 平台 | bundle ID / application ID | 备注 |
|---|---|---|
| iOS | `app.fushi.reader` | App Store / TestFlight 用；旧 `app.hibiki.reader` 已废弃 |
| macOS | `app.fushi.reader` | 原 `com.example.hibiki` |
| Android | `app.fushi.reader` | 新包身份（`android/app/build.gradle` 的 `namespace`/`applicationId` 是唯一真相源）；老包 `app.hibiki.reader` 只作为过渡桥包与迁移探测目标存活 |
| Linux | `app.fushi.reader` | `linux/CMakeLists.txt` 的 `APPLICATION_ID`（原 `com.example.hibiki`） |

**macOS 换包名是有代价且已被明确接受的决定。** Flutter 的
`getApplicationSupportDirectory()` 在 macOS 上返回
`~/Library/Application Support/<bundleId>`，Hibiki 的整个 Drift 数据库（书库、阅读
进度、统计）就落在那里，偏好落 `~/Library/Preferences/<bundleId>.plist`。换包名之后
旧目录**还在磁盘上但 app 不再读它**，现有 mac 用户升级即等同全新安装。用户已在知情
下选择「不做迁移」。将来若要补迁移，落点是 `lib/src/storage/data_root_migrator.dart`
旁边新加一条「平台 support 根变更」的一次性搬迁，而不是改 `AppPaths` 的解析逻辑。

**Android 换包名同样是有代价且已被明确接受的决定。** 改 `applicationId` 在 Android 上
等于全新应用：老包 `app.hibiki.reader` 的私有数据目录不共享，Play/侧载更新链路也断。
方案是**桥包迁移**而不是「不改」——老包出一版带导出器的过渡版，新包 `app.fushi.reader`
带导入器（`lib/src/migration/`，旧包身份收口在常量 `kHibikiPackageName`），完整决策与
阶段见 [docs/plans/2026-08-06-rename-fushi-migration.md](../plans/2026-08-06-rename-fushi-migration.md)。
MethodChannel 前缀已同批切到 `app.fushi.reader/*`（Dart 真相源
`fushi/lib/src/utils/misc/channel_constants.dart` 的 `FushiChannels._prefix`，Java 侧
`app.fushi.reader.constants.ChannelNames` 必须同步）。

## 仓库 Secrets 清单

`.github/workflows/release-desktop.yml` 的 `macos` / `ios` job 读这些。
**每一项都是可选的**：缺任何一项，对应链路整段跳过，未签名 IPA / ad-hoc zip 照常
发布。fork 和无开发者账号的状态下发布链路完全不受影响。

| Secret | 内容 | 用在哪 |
|---|---|---|
| `APPLE_TEAM_ID` | 10 位 Team ID | iOS + macOS |
| `APPSTORE_API_KEY_ID` | App Store Connect API Key ID | 上传 TestFlight、公证 |
| `APPSTORE_API_ISSUER_ID` | Issuer ID（UUID，整个团队一个） | 同上 |
| `APPSTORE_API_PRIVATE_KEY` | `.p8` 私钥全文（PEM 文本，含 BEGIN/END 行） | 同上 |
| `IOS_DIST_CERT_P12_BASE64` | Apple Distribution 证书 + 私钥的 p12，base64 单行 | iOS |
| `IOS_DIST_CERT_P12_PASSWORD` | 上面 p12 的导出口令 | iOS |
| `IOS_PROVISIONING_PROFILE_BASE64` | App Store 描述文件，base64 单行 | iOS |
| `MACOS_DEVELOPER_ID_P12_BASE64` | Developer ID Application 证书 + 私钥的 p12 | macOS |
| `MACOS_DEVELOPER_ID_P12_PASSWORD` | 上面 p12 的导出口令 | macOS |

写入/ 轮换统一走 `tool/apple_signing_secrets.sh`，它会先把材料自洽性验一遍再写：

```bash
tool/apple_signing_secrets.sh \
  --team-id 8N35BLYGL5 \
  --asc-key-id <KEYID> --asc-issuer-id <UUID> \
  --asc-key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
  --ios-cert ~/.hibiki-apple-signing/ios_distribution.p12 \
  --ios-cert-password-file ~/.hibiki-apple-signing/ios_distribution.p12.password \
  --ios-profile ~/.hibiki-apple-signing/hibiki_appstore.mobileprovision
```

加 `--verify-only` 只验不写。它挡掉的正是那些「CI 跑到 codesign 才炸、报错还毫无
指向性」的错误：p12 里装的是 Development 证书、描述文件绑的是另一张证书、描述文件
是 ad-hoc 类型、bundle id 对不上、证书 30 天内到期。

## 首次配置

### 1. App Store Connect API Key

appstoreconnect.apple.com → 用户和访问 → 集成 → App Store Connect API → 团队密钥 →
新建，角色 **App Manager**。下载的 `.p8` **只能下一次**，丢了只能作废重建。
页面顶部的 Issuer ID 一并记下。

### 2. 证书、Bundle ID、描述文件

除 Developer ID 外全部可以用 API 建（不用碰 Keychain Access 的 CSR 流程）：

```bash
# 私钥留在本地，只把 CSR 发给 Apple
openssl req -new -newkey rsa:2048 -nodes \
  -keyout ios_distribution.key -out ios_distribution.csr \
  -subj "/CN=Hibiki iOS Distribution/O=Hibiki/C=US"
```

然后 `POST /v1/certificates`（`certificateType: DISTRIBUTION`）→
`POST /v1/bundleIds`（`app.fushi.reader`，platform `IOS`）→
`POST /v1/profiles`（`profileType: IOS_APP_STORE`，关联上面两者）。
返回的证书 subject 里的 `OU=` 就是 Team ID。

把证书和私钥打成 p12 时**要把 WWDR 中间证书一起打进去**，证书链自足，不依赖
runner 钥匙串里预装了什么：

```bash
curl -fsSL -o AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
openssl x509 -inform DER -in AppleWWDRCAG3.cer -out AppleWWDRCAG3.pem
openssl pkcs12 -export -inkey ios_distribution.key -in ios_distribution.pem \
  -certfile AppleWWDRCAG3.pem -passout "pass:$P12_PASS" -out ios_distribution.p12
```

**Developer ID 证书是例外**：Apple 限定只有「账号持有人」能创建，API key 一律
403 `This operation can only be performed by the Account Holder.`。必须去
developer.apple.com/account/resources/certificates → **+** → **Developer ID
Application** → 上传本地生成的 CSR → 下载 `.cer`，再和本地私钥合成 p12。

### 3. App Store Connect 的 App 记录

**API 建不了**（`The resource 'apps' does not allow 'CREATE'`）。必须在
appstoreconnect.apple.com →「我的 App」→ **+** 手动建，Bundle ID 选
`app.fushi.reader`。没有这条记录，`altool --upload-app` 会以
"No suitable application records were found" 失败。

## 发一版 TestFlight

Actions → **Build Desktop and Apple Release Artifacts** → Run workflow：

- `channel` = `beta`（或 `formal`）
- `upload_testflight` = true（默认）

**TestFlight 只在手动 `workflow_dispatch` 的 beta / formal 通道上传**。push 触发的
debug 通道每次提交都会跑，传上去只会白烧 App Store Connect 的处理配额，并且把构建号
推高 —— 构建号在同一个 `CFBundleShortVersionString` 下必须单调递增，浪费掉不可回收。

上传后 App Store Connect 处理通常 5–30 分钟，之后才出现在测试员列表里。

### GitHub Release 资产不受影响

Release 里挂的 `fushi-<版本>-ios.ipa` **仍然是未签名包**，走的还是原来的
`flutter build ios --release --no-codesign` + 手工打 Payload。老用户用 AltStore /
Sideloadly 自签侧载的就是它，换成 App Store 签名包会直接打断他们。TestFlight 用的是
另外一次、只在手动 beta/formal 时才发生的签名构建，产物不进 Release 资产。

代价是这种发布下 iOS 会构建两次。可以接受：手动 beta/formal 本来就不频繁。

## 实现要点（改之前先读）

### iOS 签名设置为什么写进 `ios/Flutter/Release.xcconfig`

`Runner.xcodeproj` 在 **project 级**钉了
`CODE_SIGN_IDENTITY[sdk=iphoneos*] = "iPhone Developer"`，CI 钥匙串里没有这张证书。
Xcode 的优先级是「命令行 > target 设置 > **target 的 xcconfig** > project 设置」，
而 `Flutter/Release.xcconfig` 正是 Runner **target** 的 base configuration，
所以往它追加就能压过 project 级的钉死值。

两个坑：

1. **带条件的赋值只能被同样带条件的赋值压过**。只写 `CODE_SIGN_IDENTITY = ...`
   压不住 `CODE_SIGN_IDENTITY[sdk=iphoneos*]`，两种写法都要写。
2. **不要用 `xcodebuild` 命令行传签名设置**。命令行优先级最高，但会同时作用到
   CocoaPods 的 pod target 上；Hibiki 的 Podfile 用了 `use_frameworks!`，pod
   target 也要签名，会撞出 "Provisioning profile doesn't match target"。
   xcconfig 只作用于 Runner 工程，Pods 工程有自己的 xcconfig。

验证方式（不需要完整构建）：

```bash
cd fushi/ios
xcodebuild -project Runner.xcodeproj -target Runner -configuration Release \
  -sdk iphoneos -showBuildSettings \
  | grep -E "CODE_SIGN_IDENTITY|CODE_SIGN_STYLE|DEVELOPMENT_TEAM|PROVISIONING_PROFILE_SPECIFIER"
```

追加 xcconfig 后这里必须显示 `Apple Distribution` / `Manual` / 你的 Team ID /
描述文件名，显示 `iPhone Developer` 就说明覆盖没生效。

### macOS 是构建后重签，不是构建时签

`flutter build macos` 出的是 ad-hoc 签名的 app，workflow 之后做一遍完整重签。
三条硬性约束：

**1. 必须排在 Mihon / ffmpeg 打包步骤之后。** 那两步往 bundle 里塞可执行文件并用
`codesign --force --deep --sign -` 重签整个 app —— 签在它们前面的 Developer ID
签名会被那个 ad-hoc 签名整个盖掉，而且盖得静悄悄，直到公证被拒才发现。

**2. 签名面是「每一个 Mach-O」，不是「每一个 dylib」。** `Contents/MacOS/` 下的
`ffmpeg` / `ffprobe`、`Contents/Resources/mihon_bridge/` 里的 JVM 可执行体都算，
而它们**都没有扩展名** —— 所以按 `file | grep Mach-O` 判定，不能按后缀。按路径深度
倒序签，内层先签（codesign 会把内层签名封进外层，顺序反了外层立刻失效）；
`find -type f` 同时排除符号链接，jlink 镜像和 framework 里的符号链接不能签。

**3. `--options runtime` + `--timestamp` 一个都不能少**，这是公证的前提。特别注意
`macos/Runner.xcodeproj` 里 hoshidicts 的构建脚本用的是 `codesign --timestamp=none`
的 ad-hoc 签名 —— 重签这一步正是用来覆盖它的。

### 捆绑 JVM 的额外 entitlement

`Contents/Resources/mihon_bridge` 是一个 Temurin JDK 21 的 jlink 镜像
（`tool/mihon/build_desktop_runtime.sh`）。HotSpot 在强化运行时下需要 JIT、
可写可执行内存，还要能加载镜像里那堆库，所以这些可执行体单独用一份 entitlements 签：

```
com.apple.security.cs.allow-jit
com.apple.security.cs.allow-unsigned-executable-memory
com.apple.security.cs.disable-library-validation
```

**只给 JVM，不给主 app**。主 app 是 AOT 编译的 Flutter，不需要其中任何一项，
给了纯属白白扩大攻击面。JVM 是独立进程、有自己的签名和 entitlements，
这样切分不会削弱主 app 的强化运行时。

### `ITSAppUsesNonExemptEncryption`

`ios/Runner/Info.plist` 里写了 `false`。不写的话每个 TestFlight 构建都会卡在
「缺少出口合规信息」，要去网页上手动答问卷才能分发，CI 自动发布就没意义了。
`false` 的依据是 Hibiki 只用系统 HTTPS/TLS，没有自研或专有加密算法。
**将来如果引入自研加密（比如端到端加密的互联同步），必须回头改这个值并补交年度
自分类报告。**

## 排障

| 症状 | 原因 |
|---|---|
| `No suitable application records were found` | App Store Connect 里没建 App 记录，或 bundle id 对不上 |
| `The bundle version must be higher than the previously uploaded version` | 构建号回退了。构建号 = `git rev-list --count HEAD`，检查是不是在旧提交上发布 |
| `Missing export compliance` 卡住构建 | `ITSAppUsesNonExemptEncryption` 没生效，确认它在 `Info.plist` 顶层 dict 里 |
| `codesign` 卡住不返回 | 忘了 `security set-key-partition-list`，无人值守 runner 上会等一个永远不来的 UI 授权 |
| 签名过了但 App Store 校验拒收 | p12 的证书不在描述文件的 `DeveloperCertificates` 里。跑 `tool/apple_signing_secrets.sh --verify-only` 会直接报出来 |
| 公证失败但看不出原因 | `xcrun notarytool log <submission-id> --key ... --key-id ... --issuer ...` 会逐个列出被拒的二进制 |
| 公证后 app 启动即崩 | 强化运行时的库校验。先确认 `Contents/Frameworks` 下每个 dylib 都被同一 Team ID 签过；确实需要加载外部未签名库时才考虑 `com.apple.security.cs.disable-library-validation` |
| `Developer ID` 证书创建 403 | 只有账号持有人能建，API key 不行。走网页端 |

## 轮换

- **分发证书 / Developer ID 证书**：一年到期。到期前重新走「首次配置」第 2 步，
  再跑一遍 `tool/apple_signing_secrets.sh`。**旧证书不要急着撤销** —— 撤销
  Developer ID 会让已经发出去的 macOS 包失效。
- **描述文件**：跟着证书一起换（描述文件绑定证书）。
- **API Key**：泄露或人员变动时在 App Store Connect 作废重建，然后重写
  `APPSTORE_API_*` 三个 secret。
