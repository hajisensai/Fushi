<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="Fushi 로고" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | **한국어** | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![최신 버전 다운로드](https://img.shields.io/badge/%E2%AC%87%20%EC%B5%9C%EC%8B%A0%20%EB%B2%84%EC%A0%84%20%EB%8B%A4%EC%9A%B4%EB%A1%9C%EB%93%9C-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Discord 참여](https://img.shields.io/badge/Discord%20%EC%B0%B8%EC%97%AC-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## 플랫폼 지원

| 플랫폼 | 상태 | 비고 |
|---|---|---|
| Android | ✅ | Android 7.0(API 24) 이상 |
| Windows | ✅ | 갈게임 텍스트/음성 후킹은 Windows 전용 |
| macOS | ✅ | Apple Silicon 전용, Intel Mac은 지원하지 않음 |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | App Store 심사 지침에 따라 발견, 온라인 소스, 다운로드 센터는 제외 |
| Linux | 🔧 소스에서 빌드 | 아직 빌드된 릴리스 없음; EPUB 리더에 WPE WebKit 필요 |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Linux / Windows / macOS용 헤드리스 호스트(웹 UI 포함), [packages/fushi_server](../../packages/fushi_server/README.md) 참조 |

**디자인 시스템**: 모든 플랫폼의 기본값은 **Material 3 Expressive**이며, 「설정 › 외관 › 디자인 시스템」에서 **Cupertino**(Apple 스타일)로 전환할 수 있습니다. Cupertino 사용 시 창 배경은 Windows 11에서는 Mica, macOS에서는 vibrancy를 사용합니다(시스템의 투명도 줄이기 또는 고대비 설정이 켜져 있으면 제외).

> 사전 검색에서 사용할 수 있는 언어는 가져온 사전과 Yomitan 변환 테이블에 의해 결정되며, 인터페이스 언어와는 독립적입니다. iOS 버전은 TestFlight로 업데이트되므로 다른 플랫폼보다 며칠 늦습니다.

### 인터페이스 언어(17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## 설치

[Fushi 웹사이트](https://fushi.moe/)에서 최신 버전을 다운로드하세요. Android APK, Windows 설치 프로그램, macOS 빌드(Apple Silicon 전용, Intel Mac은 지원하지 않음)를 제공합니다. iOS는 [TestFlight](https://testflight.apple.com/join/j88d69jx)로 설치합니다. Linux용 앱은 아직 빌드된 릴리스가 없으므로 소스에서 직접 빌드해야 합니다. 헤드리스 Fushi Server는 [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases)에서 별도로 릴리스됩니다.

> Android 7.0(API 24) 이상이 필요합니다.

## 빌드

원커맨드로 준비(`flutter pub get` ＋ 패치 적용)한 후 빌드합니다.

```bash
# 저장소 루트에서
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# 데스크톱
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# 헤드리스 서버 (packages/fushi_server에서; `dart compile exe`가 아니라 `dart build cli` 사용)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1`은 `flutter pub get`과 `ci/apply-patches.sh`를 하나의 명령으로 합칩니다. 이 프로젝트는 Flutter 3.47.6(Dart SDK `>=3.8.0 <4.0.0`)에 고정되어 있으며, Material과 Cupertino를 `material_ui` / `cupertino_ui` 패키지로 사용하므로 더 이전 버전의 Flutter로는 빌드할 수 없습니다. 일부 업스트림 의존성은 `third_party/`에 vendored되어 있거나 `ci/apply-patches.sh`로 패치됩니다. Linux 데스크톱 빌드 의존성을 포함한 자세한 내용은 [docs/agent/build.md](../agent/build.md)를 참조하세요.

<details>
<summary><b>기술 스택</b></summary>

| 계층 | 기술 |
|---|---|
| 프레임워크 | Flutter 3.47.6(Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| 플랫폼 | Android / Windows / macOS / iOS / Linux, 그리고 헤드리스 서버 |
| UI | `material_ui`(Material 3 Expressive) / `cupertino_ui`(Cupertino) |
| 리더 | WebView 페이징 엔진(Hoshi Reader 계열에서 파생) |
| 동영상 | media_kit(libmpv 코어) ＋ libplacebo |
| 스토리지 | Drift(SQLite, WAL) ＋ fushidicts(C++ FFI 사전 엔진) |
| NLP | Yomitan 변환 테이블(다국어 표제어 추출) ＋ kana_kit(가나 변환); 토큰화는 fushidicts FFI 경유 |
| 온디바이스 AI | 음성 인식(자막 생성)과 만화 OCR에 ONNX Runtime 사용; 알고리즘은 [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles)에 있음 |
| 다운로드 | libtorrent 2.x(C ABI FFI 브리지), 외부 qBittorrent는 대체 수단 |
| 동기화 | 클라우드 백엔드 ＋ Fushi Interconnect(LAN, 원격 주소, iroh P2P 터널) |
| 공유 엔진 | `fushi_engine`: 앱과 Fushi Server가 공유하는 순수 Dart 코어 |
| 카드 생성 | AnkiDroid API ＋ AnkiConnect |
| i18n | Slang(17개 언어) |

</details>

<details>
<summary><b>프로젝트 구조</b></summary>

```
Fushi/                      # 저장소 루트 (Melos workspace: fushi_workspace)
├── fushi/                  # Flutter 앱 메인 디렉터리
│   ├── lib/
│   │   ├── i18n/            # 국제화(17개 언어, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # 페이지(라이브러리, 리더, 동영상 플레이어, 설정 등)
│   │   │   ├── reader/      # 리더 WebView JS/CSS 스크립트
│   │   │   ├── media/       # 도서, 만화, 동영상, 오디오북, 온라인 소스
│   │   │   ├── lookup/      # 사전 검색 팝업과 오버레이
│   │   │   ├── mining/      # 카드 생성(갈게임 카드 생성 포함)
│   │   │   ├── sync/        # 클라우드 동기화, Interconnect, 미디어 서버
│   │   │   └── models/      # 데이터 모델과 상태 관리(AppModel)
│   │   └── main.dart
│   └── android/             # Android 프로젝트
├── packages/                # Dart 패키지
│   ├── fushi_core/          #   데이터베이스 스키마, 설정
│   ├── fushi_engine/        #   서버와 공유하는 순수 Dart 엔진
│   ├── fushi_server/        #   헤드리스 서버 CLI ＋ 웹 UI
│   ├── fushi_cli/           #   데스크톱 커맨드라인 클라이언트
│   ├── fushi_dictionary/    #   사전 엔진 바인딩과 임포터
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # libtorrent / iroh FFI 바인딩
│   └── …                    #   vendored 포크(inappwebview Windows/Linux, gamepads)
├── native/                  # 네이티브 소스: fushidicts, fushi_torrent, fushi_p2p(Rust), galgame_hook 등
├── services/                # 로그 수집기와 리더보드 백엔드(별도 배포)
├── tools/browser-extension/ # 브라우저 사전 검색 확장
├── third_party/             # vendored된 패치 패키지(dependency_overrides)
├── ci/                      # 빌드 패치와 CI 스크립트
├── tool/                    # bootstrap / setup_worktree / 버그 기록 등의 스크립트
└── docs/                    # 개발 문서(docs/agent/ 운영 매뉴얼 포함)
```

</details>

동영상 가져오기는 작품 또는 폴더 단위 그룹화를 지원합니다. 매칭과 백그라운드 작업은 [동영상 워크플로](../specs/2026-09-07-video-library-workflow.md)와 [MAL/TMDB 메타데이터 및 AniDB 파일 해시](../specs/2026-09-07-mal-tmdb-anidb-hash.md)를 참조하세요.

[선택적 온라인 서비스 설정](../specs/2026-09-07-online-services-setup.md)에서는 번들된 애플리케이션 ID, 개인 자격 증명, 닫을 수 있는 동영상 설정 알림을 설명합니다.

## 개인정보 및 데이터

Fushi는 가져온 책, 사전, 글꼴, 오디오북 데이터, 동영상, 독서 진행 상황, 하이라이트, 통계, 설정을 앱의 로컬 저장소에 저장합니다.

- **동기화**: Google Drive / OneDrive / Dropbox는 OAuth 로그인을 사용합니다. WebDAV / FTP / SFTP / Fushi Server는 사용자가 제공한 서버 주소와 자격 증명을 사용합니다. Fushi Interconnect는 페어링된 기기끼리 직접 연결하며(LAN, IPv6, 오버레이 네트워크, 공용 주소), 직접 경로가 없으면 종단 간 iroh P2P 터널로 전환합니다. 페어링 링크는 항상 확인을 요청합니다.
- **Anki**: 카드 생성은 AnkiDroid 또는 사용자가 설정한 AnkiConnect 주소와만 통신합니다.
- **사용 통계**: 데스크톱과 Android 빌드는 하루에 한 번 무작위 설치 ID, 앱 버전, 플랫폼, 업데이트 채널을 fushi.moe로 보내 활성 사용자 수를 집계합니다. 계정, 라이브러리, 독서 데이터는 포함되지 않으며 IP 주소도 저장하지 않습니다. 업데이트 설정의 「사용 통계 보내기」로 끌 수 있습니다. iOS 빌드는 보내지 않습니다.
- **사용자가 요청할 때만**: 로그 업로드(최초 1회 동의 확인 후), 앱 내 피드백, 리더보드(기본값 꺼짐; 옵트인한 뒤에만 라이브러리 제목과 진행 상황을 업로드).
- **만화 OCR**: 기본 엔진은 Google Lens이며 페이지 이미지를 Google로 보냅니다. 이미지를 기기 안에 두려면 설정에서 온디바이스 모델이나 시스템 OCR로 바꾸세요.
- **AI 기능**: 사용자가 설정하고 기능에 할당한 LLM 제공자에게만 요청을 보냅니다. 할당된 제공자가 없으면 아무것도 전송하지 않습니다.
- **서드파티 서비스**: 메타데이터, 자막, 온라인 소스 기능은 사용할 때에만 [콘텐츠 소스 및 연동](#콘텐츠-소스-및-연동)에 나열된 서비스에 접속합니다.

## 개발 활동

[![개발 활동](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

일상적인 작업은 `develop`에 반영되고, `main`에는 릴리스 병합만 들어옵니다. 이 차트는 `main`에 표시되지만 `develop`에서 생성되므로 병합 트래픽이 아니라 실제 개발량을 반영합니다.

세 개의 레인은 앱이 직접 제공하는 업데이트 채널이며, 각각 자체 최댓값에 맞춰 스케일됩니다. debug 빌드는 안정 릴리스보다 두 자릿수 많아서, 공통 스케일을 쓰면 나머지 두 레인이 보이지 않게 됩니다.

| 레인 | 집계 대상 | 받는 방법 |
|---|---|---|
| **Debug(롤링)** | [release.yml](../../.github/workflows/release.yml)의 성공한 push 빌드 | 롤링 프리릴리스, push마다 다시 게시 |
| **Beta** | `v<version>-beta.<seq>` 프리릴리스 | 수동으로 디스패치하는 테스트 빌드 |
| **Stable** | `v<version>` 릴리스 | 최신 릴리스 |

> 위 차트는 이 저장소 안에서 생성되며(서드파티 서비스 없음), [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml) 워크플로가 매일 갱신합니다.

## Star 기록

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star 기록](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> 위 차트는 이 저장소 안에서 생성되며(서드파티 서비스 없음), [Update Star History](../../.github/workflows/star-history.yml) 워크플로가 매일 갱신합니다.

## 감사의 말

Fushi는 다음 프로젝트와 생태계를 기반으로 합니다.

### 학습 도구와 선행 사례

| 프로젝트 | 설명 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 일본어 몰입형 학습 도구 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS용 일본어 리더; 리더 페이징 엔진 참고 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 네이티브 일본어 리더 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 사전 엔진 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 오디오북 동기화 솔루션 |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | 자막을 참조 트랙에 맞춰 타이밍을 정렬하는 알고리즘(GPL-3.0); 다운로드한 자막을 내장 트랙에 자동으로 맞추는 기반 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 사전 형식, 변환 테이블, 검색 경험 참고 |
| [Lapis](https://github.com/donkuri/lapis) | Anki 노트 유형 |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android 카드 생성 통합 |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | 로컬 오디오와 AnkiDroid 연동 참고 |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | 리더, 통계, 동기화 호환성 참고 |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter 동영상 재생 프레임워크(libmpv 코어) |
| [Niratan](https://github.com/W1ght/Niratan) | macOS용 몰입형 언어 학습 스위트 |

### 엔진과 네이티브 구성 요소

| 프로젝트 | 설명 |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | 갈게임 텍스트 후킹 엔진(vendored DLL, 인젝터가 로드) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | 갈게임 인젝터가 사용하는 인라인 후킹 라이브러리 |
| [libtorrent](https://github.com/arvidn/libtorrent) | 내장 torrent 다운로드 엔진 |
| [mpv](https://github.com/mpv-player/mpv) | media_kit의 기반이 되는 libmpv 재생 코어 |
| [FFmpeg](https://ffmpeg.org) | 미디어 분석, 클리핑, 오디오 추출 |
| [libplacebo](https://github.com/haasn/libplacebo) | GPU 영상 셰이더와 HDR 톤 매핑 |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | EPUB 리더를 렌더링하는 WebView 엔진 |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | 음성 인식과 OCR의 온디바이스 추론 |
| [iroh](https://github.com/n0-computer/iroh) | Fushi Interconnect 원격 연결용 P2P 터널 |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | 사전 엔진 의존 라이브러리 |

### 온디바이스 모델

| 프로젝트 | 설명 |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer 음성 인식 모델 패키지와 VAD 빌드 |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | 일본어 음성 인식 모델 |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | 일본어 음성 인식 모델 |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | 일본어 음성 인식 모델(CC BY-NC 4.0, Hugging Face 저장소에서 직접 다운로드) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | 다국어 CTC 음성 인식 모델 |
| [Silero VAD](https://github.com/snakers4/silero-vad) | 음성 구간 감지 모델 |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | 만화 텍스트 및 말풍선 감지 모델 |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | 만화 컷 감지 모델, [Manga109-s](http://www.manga109.org/en/download_s.html)로 학습 |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | 텍스트 줄 감지 및 인식; 만화용으로 조정된 rec([Manga109-s](http://www.manga109.org/en/download_s.html)와 [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)로 학습)가 열 단위 CTC 로컬 OCR 모델을 구동합니다 |

> 만화 컷 감지 모델과 PP-OCRv6_manga는 Manga109-s 데이터셋(Matsui et al. 2017; Aizawa et al. 2020)으로 학습되었으며, 해당 약관은 데이터셋 사용을 명확히 표시할 것을 요구합니다. PP-OCRv6_manga(Apache-2.0)는 추가로 AnimeText 데이터셋으로도 학습되었으며, 이 데이터셋의 라이선스는 CC BY-NC-SA 4.0입니다. 앱은 이 모델을 Hugging Face 저장소에서 다운로드하며 재배포하지 않습니다.

### 콘텐츠 소스 및 연동

| 프로젝트 | 설명 |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | 만화 소스 확장 생태계 |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | 애니메이션 소스 확장 생태계(extensions-lib 14–16, 동일한 런타임) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | 데스크톱용 만화 확장 런타임(vendored, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Mihon / Aniyomi 확장 적응 참고 |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | 라이트 노벨 소스 플러그인 생태계 |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | 동영상 라이브러리에서 탐색할 수 있는 미디어 서버 |
| [asbplayer](https://github.com/asbplayer/asbplayer) | 브라우저 확장 스트리밍 자막 브리지 참고 |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | 애니메이션 식별 및 스크레이핑 설계 참고 |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | 갈게임 라이브러리 정보 설계 참고 |
| [AniDB](https://anidb.net) | 애니메이션, 에피소드, 파일 식별 |
| [MyAnimeList](https://myanimelist.net)([Jikan](https://jikan.moe) 경유) | 애니메이션 메타데이터 |
| [TMDB](https://www.themoviedb.org) | 보조 메타데이터와 이미지 |
| [VNDB](https://vndb.org) | 비주얼 노벨 메타데이터 |
| [Jimaku](https://jimaku.cc) | 일본어 자막 소스 |
| [OpenSubtitles](https://www.opensubtitles.com) | 자막 소스 |

> 이 애플리케이션은 TMDB 및 TMDB API를 사용하지만, TMDB가 보증, 인증 또는 승인하지 않습니다.

## 라이선스

GNU General Public License v3.0에 따라 배포됩니다. 자세한 내용은 [LICENSE](../../LICENSE)를 참조하세요.

## 메인테이너

Fushi는 [hajisensai](https://github.com/hajisensai)가 유지·관리합니다. 웹사이트: [fushi.moe](https://fushi.moe). 문의: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | **한국어** | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
