<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="Fushi ロゴ" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | **日本語** | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![最新版をダウンロード](https://img.shields.io/badge/%E2%AC%87%20%E6%9C%80%E6%96%B0%E7%89%88%E3%82%92%E3%83%80%E3%82%A6%E3%83%B3%E3%83%AD%E3%83%BC%E3%83%89-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Discord に参加](https://img.shields.io/badge/Discord%20%E3%81%AB%E5%8F%82%E5%8A%A0-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## プラットフォーム対応

| プラットフォーム | 状態 | 備考 |
|---|---|---|
| Android | ✅ | Android 7.0（API 24）以降 |
| Windows | ✅ | ギャルゲーのテキスト／音声フックは Windows 限定 |
| macOS | ✅ | Apple Silicon のみ。Intel Mac は非対応 |
| iOS | ✅（[TestFlight](https://testflight.apple.com/join/j88d69jx)） | App Store の審査ガイドラインにより、発見・オンラインソース・ダウンロードセンターは含まれません |
| Linux | 🔧 ソースからビルド | ビルド済みリリースはまだありません。EPUB リーダーには WPE WebKit が必要です |
| Fushi Server | 🧪 Beta（[fushi-server](https://github.com/hajisensai/fushi-server/releases)） | Linux / Windows / macOS 向けの Web UI 付きヘッドレスホスト。[packages/fushi_server](../../packages/fushi_server/README.md) を参照 |

**デザインシステム**：すべてのプラットフォームで既定は **Material 3 Expressive** です。「設定 › 外観 › デザインシステム」で **Cupertino**（Apple スタイル）に切り替えられます。Cupertino 使用時、ウィンドウ背景は Windows 11 では Mica、macOS では vibrancy になります（システムの「透明度を下げる」または高コントラスト設定がオンの場合を除く）。

> 辞書検索で利用できる言語は、インポートした辞書と Yomitan の変換テーブルによって決まり、インターフェース言語とは独立しています。iOS 版は TestFlight 経由で更新されるため、他のプラットフォームより数日遅れます。

### インターフェース言語（17）

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## インストール

[Fushi 公式サイト](https://fushi.moe/)から最新版をダウンロードしてください。Android APK、Windows インストーラー、macOS ビルド（Apple Silicon のみ。Intel Mac は非対応）を提供しています。iOS は [TestFlight](https://testflight.apple.com/join/j88d69jx) からインストールします。Linux 向けのビルド済みアプリはまだないため、ソースからビルドしてください。ヘッドレスの Fushi Server は [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases) で別途リリースされます。

> Android 7.0（API 24）以降が必要です。

## ビルド

ワンコマンドで準備（`flutter pub get` ＋ パッチ適用）し、ビルドします。

```bash
# リポジトリのルートから
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# デスクトップ
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# ヘッドレスサーバー（packages/fushi_server で。`dart compile exe` ではなく `dart build cli` を使う）
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` は `flutter pub get` と `ci/apply-patches.sh` を一つのコマンドにまとめます。本プロジェクトは Flutter 3.47.6（Dart SDK `>=3.8.0 <4.0.0`）に固定されています。Material と Cupertino は `material_ui` / `cupertino_ui` パッケージ経由で利用するため、それより古い Flutter ではビルドできません。一部の上流依存は `third_party/` に vendored されているか、`ci/apply-patches.sh` によってパッチが当てられます。Linux デスクトップのビルド依存を含む詳細は [docs/agent/build.md](../agent/build.md) を参照してください。

<details>
<summary><b>技術スタック</b></summary>

| レイヤー | 技術 |
|---|---|
| フレームワーク | Flutter 3.47.6（Dart SDK `>=3.8.0 <4.0.0`）、Riverpod |
| プラットフォーム | Android / Windows / macOS / iOS / Linux、およびヘッドレスサーバー |
| UI | `material_ui`（Material 3 Expressive）/ `cupertino_ui`（Cupertino） |
| リーダー | WebView ページングエンジン（Hoshi Reader 系統から派生） |
| 動画 | media_kit（libmpv コア）＋ libplacebo |
| ストレージ | Drift（SQLite, WAL）＋ fushidicts（C++ FFI 辞書エンジン） |
| NLP | Yomitan 変換テーブル（多言語の見出し語化）＋ kana_kit（かな変換）；トークン化は fushidicts FFI 経由 |
| 端末内 AI | 音声認識（字幕生成）とマンガ OCR に ONNX Runtime を使用；アルゴリズムは [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) にあります |
| ダウンロード | libtorrent 2.x（C ABI FFI ブリッジ）、外部 qBittorrent はフォールバック |
| 同期 | クラウドバックエンド ＋ Fushi Interconnect（LAN、リモートアドレス、iroh P2P トンネル） |
| 共有エンジン | `fushi_engine`：アプリと Fushi Server が共用する純 Dart コア |
| カード作成 | AnkiDroid API ＋ AnkiConnect |
| i18n | Slang（17 言語） |

</details>

<details>
<summary><b>プロジェクト構成</b></summary>

```
Fushi/                      # リポジトリルート（Melos workspace: fushi_workspace）
├── fushi/                  # Flutter アプリのメインディレクトリ
│   ├── lib/
│   │   ├── i18n/            # 国際化（17 言語、Slang）
│   │   ├── src/
│   │   │   ├── pages/       # ページ（ライブラリ、リーダー、動画プレーヤー、設定など）
│   │   │   ├── reader/      # リーダー WebView の JS/CSS スクリプト
│   │   │   ├── media/       # 書籍、マンガ、動画、オーディオブック、オンラインソース
│   │   │   ├── lookup/      # 辞書検索ポップアップとオーバーレイ
│   │   │   ├── mining/      # カード作成（ギャルゲーのカード作成を含む）
│   │   │   ├── sync/        # クラウド同期、Interconnect、メディアサーバー
│   │   │   └── models/      # データモデルと状態管理（AppModel）
│   │   └── main.dart
│   └── android/             # Android プロジェクト
├── packages/                # Dart パッケージ
│   ├── fushi_core/          #   データベーススキーマ、設定
│   ├── fushi_engine/        #   サーバーと共用する純 Dart エンジン
│   ├── fushi_server/        #   ヘッドレスサーバー CLI ＋ Web UI
│   ├── fushi_cli/           #   デスクトップ向けコマンドラインクライアント
│   ├── fushi_dictionary/    #   辞書エンジンのバインディングとインポーター
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # libtorrent / iroh の FFI バインディング
│   └── …                    #   vendored フォーク（inappwebview Windows/Linux、gamepads）
├── native/                  # ネイティブソース：fushidicts、fushi_torrent、fushi_p2p（Rust）、galgame_hook など
├── services/                # ログ受信とリーダーボードのバックエンド（個別にデプロイ）
├── tools/browser-extension/ # ブラウザ辞書検索拡張
├── third_party/             # vendored されたパッチ済みパッケージ（dependency_overrides）
├── ci/                      # ビルドパッチと CI スクリプト
├── tool/                    # bootstrap / setup_worktree / バグ記録などのスクリプト
└── docs/                    # 開発ドキュメント（docs/agent/ 運用マニュアルを含む）
```

</details>

動画のインポートは作品またはフォルダー単位のグルーピングに対応しています。マッチングとバックグラウンドタスクについては、[動画ワークフロー](../specs/2026-09-07-video-library-workflow.md)と [MAL/TMDB メタデータと AniDB ファイルハッシュ](../specs/2026-09-07-mal-tmdb-anidb-hash.md)を参照してください。

[オプションのオンラインサービス設定](../specs/2026-09-07-online-services-setup.md)では、同梱のアプリケーション ID、個人用認証情報、閉じられる動画セットアップのリマインダーについて説明しています。

## プライバシーとデータ

Fushi は、インポートした書籍、辞書、フォント、オーディオブックのデータ、動画、読書進捗、ハイライト、統計、設定をアプリのローカルストレージに保存します。

- **同期**：Google Drive / OneDrive / Dropbox は OAuth サインインを使用します。WebDAV / FTP / SFTP / Fushi Server は、ユーザーが指定したサーバーアドレスと認証情報を使用します。Fushi Interconnect はペアリング済みのデバイス同士を直接接続し（LAN、IPv6、オーバーレイネットワーク、公開アドレス）、直接経路がない場合はエンドツーエンドの iroh P2P トンネルにフォールバックします。ペアリングリンクは常に確認を求めます。
- **Anki**：カード作成は AnkiDroid、または設定した AnkiConnect アドレスとのみ通信します。
- **利用統計**：デスクトップ版と Android 版は 1 日 1 回、ランダムなインストール ID、アプリのバージョン、プラットフォーム、更新チャンネルを fushi.moe に送信し、アクティブユーザー数を集計します。アカウント、ライブラリ、読書データは含まれず、IP アドレスも保存されません。更新設定の「利用統計を送信」でオフにできます。iOS 版は送信しません。
- **ユーザーが操作したときのみ**：ログのアップロード（初回の同意確認あり）、アプリ内フィードバック、リーダーボード（既定はオフ。オプトイン後にのみライブラリのタイトルと進捗をアップロード）。
- **マンガ OCR**：既定のエンジンは Google Lens で、ページ画像を Google に送信します。画像を端末内に留めたい場合は、設定で端末内モデルまたはシステム OCR に切り替えてください。
- **AI 機能**：設定して機能に割り当てた LLM プロバイダーにのみリクエストを送ります。プロバイダーが割り当てられていなければ何も送信しません。
- **サードパーティサービス**：メタデータ、字幕、オンラインソースの機能は、使用したときにのみ、[コンテンツソースと連携](#コンテンツソースと連携)に挙げたサービスへ接続します。

## 開発アクティビティ

[![開発アクティビティ](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

日々の作業は `develop` に入り、`main` にはリリースのマージのみが入ります。このグラフは `main` 上に表示されていますが `develop` から生成されるため、マージの流量ではなく実際の開発量を反映します。

3 本のレーンはアプリ自体が提供する更新チャンネルで、それぞれ独自のピークでスケールされています。debug ビルドは安定版より 2 桁多いため、共通のスケールだと他の 2 本が見えなくなってしまいます。

| レーン | 集計対象 | 入手方法 |
|---|---|---|
| **Debug（ローリング）** | [release.yml](../../.github/workflows/release.yml) の成功した push ビルド | ローリングのプレリリース。push のたびに再公開 |
| **Beta** | `v<version>-beta.<seq>` プレリリース | 手動でディスパッチするテストビルド |
| **Stable** | `v<version>` リリース | 最新リリース |

> 上のグラフはこのリポジトリ内で生成され（サードパーティサービスは不使用）、[Update Dev Activity Chart](../../.github/workflows/dev-activity.yml) ワークフローが毎日更新します。

## Star 履歴

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star 履歴](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> 上のグラフはこのリポジトリ内で生成され（サードパーティサービスは不使用）、[Update Star History](../../.github/workflows/star-history.yml) ワークフローが毎日更新します。

## 謝辞

Fushi は以下のプロジェクトとエコシステムを基盤としています。

### 学習ツールと先行事例

| プロジェクト | 説明 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 日本語没入型学習ツール |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 向け日本語リーダー；リーダーページングエンジンの参考 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android ネイティブの日本語リーダー |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 辞書エンジン |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | オーディオブック同期ソリューション |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | 字幕を参照トラックに合わせてタイミング調整するアルゴリズム（GPL-3.0）；ダウンロードした字幕を内蔵トラックに自動で合わせる際の基礎 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 辞書フォーマット、変換テーブル、検索体験の参考 |
| [Lapis](https://github.com/donkuri/lapis) | Anki ノートタイプ |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android カード作成の統合 |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | ローカル音声と AnkiDroid 連携の参考 |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | リーダー、統計、同期の互換性の参考 |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter 動画再生フレームワーク（libmpv コア） |
| [Niratan](https://github.com/W1ght/Niratan) | macOS 向け没入型言語学習スイート |

### エンジンとネイティブコンポーネント

| プロジェクト | 説明 |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | ギャルゲーのテキストフックエンジン（vendored DLL、インジェクターが読み込み） |
| [MinHook](https://github.com/TsudaKageyu/minhook) | ギャルゲーインジェクターが使うインラインフックライブラリ |
| [libtorrent](https://github.com/arvidn/libtorrent) | 内蔵 torrent ダウンロードエンジン |
| [mpv](https://github.com/mpv-player/mpv) | media_kit の基盤となる libmpv 再生コア |
| [FFmpeg](https://ffmpeg.org) | メディア解析、切り出し、音声抽出 |
| [libplacebo](https://github.com/haasn/libplacebo) | GPU 映像シェーダーと HDR トーンマッピング |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | EPUB リーダーを描画する WebView エンジン |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | 音声認識と OCR の端末内推論 |
| [iroh](https://github.com/n0-computer/iroh) | Fushi Interconnect のリモート接続用 P2P トンネル |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | 辞書エンジンの依存ライブラリ |

### 端末内モデル

| プロジェクト | 説明 |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer 音声認識モデルパッケージと VAD ビルド |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | 日本語音声認識モデル |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | 日本語音声認識モデル |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | 日本語音声認識モデル（CC BY-NC 4.0、Hugging Face のリポジトリから直接ダウンロード） |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | 多言語 CTC 音声認識モデル |
| [Silero VAD](https://github.com/snakers4/silero-vad) | 音声区間検出モデル |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | マンガのテキストと吹き出し検出モデル |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | マンガのコマ検出モデル。[Manga109-s](http://www.manga109.org/en/download_s.html) で学習 |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | テキスト行の検出と認識；マンガ向けに調整した rec（[Manga109-s](http://www.manga109.org/en/download_s.html) と [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText) で学習）が、列ごとの CTC ローカル OCR モデルを動かします |

> マンガのコマ検出モデルと PP-OCRv6_manga は Manga109-s データセット（Matsui et al. 2017; Aizawa et al. 2020）で学習されており、その規約はデータセットの利用を明示することを求めています。PP-OCRv6_manga（Apache-2.0）はさらに AnimeText データセットでも学習されており、同データセットのライセンスは CC BY-NC-SA 4.0 です。アプリはこのモデルを Hugging Face のリポジトリからダウンロードし、再配布は行いません。

### コンテンツソースと連携

| プロジェクト | 説明 |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | マンガソース拡張のエコシステム |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | アニメソース拡張のエコシステム（extensions-lib 14–16、同一ランタイム） |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | デスクトップ向けマンガ拡張ランタイム（vendored、MPL-2.0） |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Mihon / Aniyomi 拡張の適合の参考 |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | ライトノベルソースのプラグインエコシステム |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | 動画ライブラリから閲覧できるメディアサーバー |
| [asbplayer](https://github.com/asbplayer/asbplayer) | ブラウザ拡張のストリーミング字幕ブリッジの参考 |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | アニメ識別とスクレイピング設計の参考 |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | ギャルゲーライブラリの情報設計の参考 |
| [AniDB](https://anidb.net) | アニメ・エピソード・ファイルの同定 |
| [MyAnimeList](https://myanimelist.net)（[Jikan](https://jikan.moe) 経由） | アニメのメタデータ |
| [TMDB](https://www.themoviedb.org) | 補助的なメタデータと画像 |
| [VNDB](https://vndb.org) | ビジュアルノベルのメタデータ |
| [Jimaku](https://jimaku.cc) | 日本語字幕ソース |
| [OpenSubtitles](https://www.opensubtitles.com) | 字幕ソース |

> このアプリケーションはTMDBおよびTMDB APIを使用していますが、TMDBによる推奨、認証、その他の承認を受けたものではありません。

## ライセンス

GNU General Public License v3.0 の下で配布されます。詳細は [LICENSE](../../LICENSE) を参照してください。

## メンテナー

Fushi は [hajisensai](https://github.com/hajisensai) がメンテナンスしています。ウェブサイト：[fushi.moe](https://fushi.moe)。連絡先：[contact@fushi.moe](mailto:contact@fushi.moe)。

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | **日本語** | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
