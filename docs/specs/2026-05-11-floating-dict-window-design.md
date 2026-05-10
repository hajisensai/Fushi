# 悬浮查词窗设计文档

## 概述

在 app 外提供一个悬浮窗，自动监听剪贴板变化并进行词典查询，同时支持手动输入查词和 Anki 制卡。类似字幕悬浮窗的交互体验，但服务于词典查询场景。

## 架构方案：BaseFloatingService + 子类继承

### 核心思路

从现有 `FloatingLyricService`（~400行 Java）中抽取通用 overlay 能力到 `BaseFloatingService` 抽象基类，然后 `FloatingLyricService` 和新建的 `FloatingDictService` 各自继承，只实现自己的 UI 和业务逻辑。

### 架构图

```
┌─────────────────────────────────────────────┐
│              Android Native Layer            │
│                                              │
│  BaseFloatingService (abstract)              │
│  ├── overlay 创建/销毁 (WindowManager)       │
│  ├── 拖拽定位 + SharedPreferences 保存       │
│  ├── 前台通知 + 通知 channel 创建            │
│  ├── Quick Settings Tile 联动                │
│  └── Service 生命周期管理                    │
│       │                                      │
│       ├── FloatingLyricService (现有，继承)   │
│       │   └── 歌词文本 + 播放控件 UI          │
│       │                                      │
│       └── FloatingDictService (新建，继承)    │
│           ├── 剪贴板监听 (ClipboardManager)   │
│           ├── 搜索输入框 + 手动查词            │
│           ├── 词条结果渲染 (ScrollView)        │
│           └── Anki 制卡按钮                   │
│                                              │
│  FloatingDictTile (Quick Settings Tile)       │
│                                              │
├──────────── Method Channel ──────────────────┤
│              Dart / Flutter Layer             │
│                                              │
│  FloatingDictChannel                          │
│  ├── show() / hide() / updateStyle()          │
│  ├── searchTerm(String) → List<DictEntry>     │
│  ├── ankiExport(DictEntry)                    │
│  └── onClipboardLookup callback               │
│                                              │
│  设置页 UI (开关 + 样式配置)                  │
└─────────────────────────────────────────────┘
```

### 关键决策

- 词典查询走 Method Channel 调 Dart 层的现有词典引擎，**不在 Java 层重新实现查词**
- Anki 制卡走 Dart 层的 `AnkiChannelHandler`
- 悬浮窗 UI 是纯 Android View（不是 Flutter 渲染），和 FloatingLyricService 一致

## BaseFloatingService 抽取

### 基类职责

| 基类负责 | 子类实现 |
|----------|----------|
| `WindowManager` overlay 创建/销毁 | `createContentView()` 返回具体 UI 布局 |
| 拖拽手势 + 位置保存/恢复 (SharedPreferences) | `getPreferencePrefix()` 返回存储 key 前缀 |
| 前台 Service + 通知 channel 创建 | `buildNotification()` 构建各自的通知内容 |
| `startForeground()` / `stopSelf()` 生命周期 | `onServiceCommand(intent)` 处理各自的 intent action |
| overlay 权限检查 (`SYSTEM_ALERT_WINDOW`) | — |

### 抽取原则

只抽通用机制，不抽 UI。歌词是单行 TextView + 播放按钮，查词是输入框 + 滚动列表，两者没有可共享的 View 层。

## FloatingDictService 详细设计

### UI 布局

```
┌──────────────────────────────┐
│ ☰ (拖拽)    查词悬浮窗    ✕  │  ← 标题栏，可拖拽
├──────────────────────────────┤
│ [  输入框/当前词汇  ] [🔍]  │  ← 手动输入 或 显示剪贴板词汇
├──────────────────────────────┤
│                              │
│  词条释义内容 (ScrollView)   │
│  - 词头                      │
│  - 读音                      │
│  - 释义列表                  │
│                              │
├──────────────────────────────┤
│  [📋 Anki]                   │  ← 底部操作栏
└──────────────────────────────┘
```

### 剪贴板监听

- 注册 `ClipboardManager.OnPrimaryClipChangedListener`
- 在 `onPrimaryClipChanged()` 中读取文本，和上一次相同则跳过
- 将新词填入输入框并触发查词

### 查词流程

1. 新文本进入（剪贴板变化或手动输入）
2. 通过 Method Channel 调 Dart 层 `searchTerm(text)`
3. Dart 层用现有词典引擎查询，返回结果（JSON 序列化）
4. Java 层解析 JSON，渲染到 ScrollView。只渲染简化格式（词头、读音、释义纯文本），不支持完整 structured content（复杂 HTML 表格/图片等留给 app 内查看）

### Anki 制卡

- 点击底部 Anki 按钮
- 通过 Method Channel 调 Dart 层，带上 `word` + `reading` + `meaning`
- 复用现有 `AnkiChannelHandler` 的 `addNote` 逻辑

### 窗口尺寸

- 默认宽 300dp，高 400dp
- 位置和尺寸持久化到 SharedPreferences
- 可在设置中配置

## 启动入口

### 1. App 内开关

- 设置页新增"悬浮查词窗"开关
- 开启时检查 `SYSTEM_ALERT_WINDOW` 权限，没有则引导授权
- 可配置项：字体大小、背景透明度、自动剪贴板监听开/关

### 2. 通知栏

- FloatingDictService 启动后显示常驻通知
- 通知 action 按钮：「暂停监听」/「恢复监听」、「关闭」

### 3. Quick Settings Tile

- 新增 `FloatingDictTile extends TileService`
- 点击切换 Service 开/关
- Tile 状态和 Service 状态双向同步（通过 `requestListeningState()`）
- 用户需手动将磁贴添加到快捷面板（Android 标准行为）

## 权限

| 权限 | 用途 | 已有 |
|------|------|------|
| `SYSTEM_ALERT_WINDOW` | overlay 悬浮窗 | ✅ 歌词悬浮窗已申请 |
| `FOREGROUND_SERVICE` | 前台 Service | ✅ 已有 |
| `FOREGROUND_SERVICE_SPECIAL_USE` | 查词 Service 类型 | ❌ 新增，Play Console 需解释用途 |

## 数据流

```
用户在其他 app 复制文本
       │
       ▼
ClipboardManager.OnPrimaryClipChangedListener
       │
       ▼
FloatingDictService.onPrimaryClipChanged()
  - 读取文本，过滤重复
  - 更新输入框显示
       │
       ▼
Method Channel → Dart: searchTerm(text)
       │
       ▼
Dart 词典引擎查询 (Yomitan/MDict/etc.)
       │
       ▼
Method Channel → Java: 返回 JSON 结果
       │
       ▼
FloatingDictService 渲染结果到 ScrollView
       │
       ▼ (用户点击 Anki 按钮)
Method Channel → Dart: ankiExport(word, reading, meaning)
       │
       ▼
AnkiChannelHandler.addNote() → AnkiDroid
```

## 新增文件清单

### Android (Java)

| 文件 | 说明 |
|------|------|
| `BaseFloatingService.java` | 抽象基类，从 FloatingLyricService 抽取 |
| `FloatingDictService.java` | 悬浮查词窗 Service |
| `FloatingDictTile.java` | Quick Settings 磁贴 |

### Dart

| 文件 | 说明 |
|------|------|
| `floating_dict_channel.dart` | Method Channel 封装 |
| 设置页修改 | 新增悬浮查词开关和配置项 |

### 现有文件修改

| 文件 | 修改 |
|------|------|
| `FloatingLyricService.java` | 重构为继承 BaseFloatingService |
| `MainActivity.java` | 注册 floating_dict Method Channel |
| `AndroidManifest.xml` | 声明 FloatingDictService + FloatingDictTile |
| `HibikiChannels` / channel constants | 新增 channel 名 |
