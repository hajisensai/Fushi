<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="Fushi 로고" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | **한국어** | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![최신 버전 다운로드](https://img.shields.io/badge/%E2%AC%87%20%EC%B5%9C%EC%8B%A0%20%EB%B2%84%EC%A0%84%20%EB%8B%A4%EC%9A%B4%EB%A1%9C%EB%93%9C-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Discord 참여](https://img.shields.io/badge/Discord%20%EC%B0%B8%EC%97%AC-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## 플랫폼 지원

| 플랫폼 | 상태 | 렌더링／UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Material Design 3 |

> 최소 요구 사항은 Android 7.0(API 24)입니다. 사전 검색에서 사용할 수 있는 언어는 가져온 사전과 Yomitan 변환 테이블에 의해 결정되며, 인터페이스 언어와는 독립적입니다. iOS 버전은 TestFlight로 배포됩니다. App Store 심사 지침이 허용하지 않는 발견·다운로드 기능이 빠져 있으며, 업데이트도 다른 플랫폼보다 며칠 늦습니다.

### 인터페이스 언어(17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## 설치 및 빌드

원커맨드로 준비(`flutter pub get` ＋ 패치 적용)한 후 빌드합니다.

```bash
# 저장소 루트에서
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows 데스크톱
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1`은 `flutter pub get`과 `ci/apply-patches.sh`를 하나의 명령으로 통합합니다. 이 프로젝트는 Flutter 3.44.0(Dart SDK `>=3.5.0 <4.0.0`)에 고정되어 있습니다. 일부 상위 의존성은 `third_party/`에 vendored되어 있거나 `ci/apply-patches.sh`로 패치가 적용됩니다. 자세한 내용은 [docs/agent/build.md](../agent/build.md)를 참조하세요.

<details>
<summary><b>기술 스택</b></summary>

| 레이어 | 기술 |
|---|---|
| 프레임워크 | Flutter 3.44.0(Dart SDK `>=3.5.0 <4.0.0`) |
| 플랫폼 | Android / Windows / macOS / iOS(Material Design 3) |
| 리더 | WebView 페이징 엔진(Hoshi Reader 계열에서 파생) |
| 동영상 | media_kit(libmpv 코어) |
| 스토리지 | Drift(SQLite, WAL) ＋ fushidicts(C++ FFI 사전 엔진) |
| NLP | Yomitan 변환 테이블(다국어 표제어화) ＋ kana_kit(가나 변환); 토큰화는 fushidicts FFI 경유 |
| 카드 생성 | AnkiDroid API ＋ AnkiConnect |
| i18n | Slang(17개 언어) |

</details>

<details>
<summary><b>프로젝트 구조</b></summary>

```
Fushi/                      # Repository root (Melos workspace: fushi_workspace)
├── fushi/                  # Flutter 앱 메인 디렉터리
│   ├── lib/
│   │   ├── i18n/            # 국제화(17개 언어, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # 페이지(책장, 리더, 사전, 설정 등)
│   │   │   ├── reader/      # 리더 WebView JS/CSS 스크립트
│   │   │   ├── media/       # 오디오북, 자막 파싱, 리더 소스
│   │   │   └── models/      # 데이터 모델과 상태 관리(AppModel)
│   │   └── main.dart
│   └── android/             # Android 프로젝트(manifest, 네이티브 fushidicts)
├── packages/                # 내부 패키지 ＋ flutter_inappwebview_windows (fork) ＋ gamepads_android_stub
├── native/                  # fushidicts C++ 사전 엔진(FFI)
├── third_party/             # vendored된 패치 적용 패키지(dependency_overrides)
├── ci/                      # 빌드 패치와 통합 테스트 스크립트
├── tool/                    # bootstrap / i18n_sync 등의 스크립트
└── docs/                    # 개발 문서(docs/agent/ 운영 매뉴얼 포함)
```

</details>

## 개인정보 및 데이터

Fushi는 가져온 책, 사전, 글꼴, 오디오북 데이터, 동영상, 독서 진행 상황, 하이라이트, 통계, 설정을 앱의 로컬 저장소에 저장합니다.

클라우드 동기화(Google Drive / OneDrive / Dropbox)는 사용자가 설정한 OAuth 자격 증명을 사용합니다. WebDAV / FTP / SFTP는 사용자가 제공한 서버 주소와 자격 증명을 사용합니다. Fushi Interconnect는 사용자가 설정한 주소로 직접 연결합니다. Anki 카드 생성은 AnkiDroid 또는 설정된 AnkiConnect 주소와 통신합니다.

## 감사의 말

Fushi는 다음 프로젝트와 생태계를 기반으로 합니다.

### 학습 도구 및 선행 프로젝트

| 프로젝트 | 설명 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 일본어 몰입형 학습 도구 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 일본어 리더; 리더 페이징 엔진 참고 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 네이티브 일본어 리더 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 사전 엔진 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 오디오북 동기화 솔루션 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 사전 포맷, 변환 테이블, 검색 경험 참고 |
| [Lapis](https://github.com/donkuri/lapis) | Anki 노트 유형 |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android 카드 생성 통합 |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | 로컬 음성과 AnkiDroid 연동 참고 |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | 리더, 통계, 동기화 호환성 참고 |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter 동영상 재생 프레임워크(libmpv 코어) |
| [Niratan](https://github.com/W1ght/Niratan) | macOS용 몰입형 언어 학습 도구 모음 |

### 엔진 및 네이티브 구성 요소

| 프로젝트 | 설명 |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | 갈게임 텍스트 후킹 엔진(인젝터가 로드하는 벤더링된 DLL) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | 갈게임 인젝터가 사용하는 인라인 후킹 라이브러리 |
| [libtorrent](https://github.com/arvidn/libtorrent) | 내장 토렌트 다운로드 엔진 |
| [mpv](https://github.com/mpv-player/mpv) | media_kit 기반의 libmpv 재생 코어 |
| [FFmpeg](https://ffmpeg.org) | 미디어 분석, 구간 추출, 오디오 추출 |
| [libplacebo](https://github.com/haasn/libplacebo) | GPU 비디오 셰이더 및 HDR 톤 매핑 |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | EPUB 리더를 렌더링하는 WebView 엔진 |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | 음성 인식과 OCR의 온디바이스 추론 |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | 사전 엔진 의존 라이브러리 |

### 온디바이스 모델

| 프로젝트 | 설명 |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer 음성 인식 모델 패키지 및 VAD 빌드 |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | 일본어 음성 인식 모델 |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | 다국어 CTC 음성 인식 모델 |
| [Silero VAD](https://github.com/snakers4/silero-vad) | 음성 구간 검출 모델 |
| [manga-ocr](https://github.com/kha-white/manga-ocr) / [manga-ocr-onnx](https://huggingface.co/mayocream/manga-ocr-onnx) | 만화 OCR 모델 |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | 만화 텍스트 및 말풍선 검출 모델 |

### 콘텐츠 소스 및 연동

| 프로젝트 | 설명 |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | 만화 소스 확장 생태계 |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | 데스크톱용 만화 확장 런타임 |
| [aidoku-rs](https://github.com/Aidoku/aidoku-rs) | 만화 소스 런타임 ABI |
| [asbplayer](https://github.com/asbplayer/asbplayer) | 브라우저 확장의 스트리밍 자막 브리지 참고 |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | 애니메이션 식별 및 스크래핑 아키텍처 참고 |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | 갈게임 라이브러리 정보 구조 참고 |
| [AniDB](https://anidb.net) | 애니메이션, 에피소드, 파일 식별 |
| [TMDB](https://www.themoviedb.org) | 보조 메타데이터 및 이미지 |
| [Jimaku](https://jimaku.cc) | 일본어 자막 소스 |
| [OpenSubtitles](https://www.opensubtitles.com) | 자막 소스 |

> 이 애플리케이션은 TMDB 및 TMDB API를 사용하지만, TMDB가 보증, 인증 또는 승인하지 않습니다.

## 라이선스

GNU General Public License v3.0에 따라 배포됩니다. 자세한 내용은 [LICENSE](../../LICENSE)를 참조하세요.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | **한국어** | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
