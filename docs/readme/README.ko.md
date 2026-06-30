<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="hibiki 로고" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | **한국어** | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[사용 설명서](../user-guide.ko.md) | [최신 버전 다운로드](https://github.com/hajisensai/hibiki/releases)

hibiki는 Android와 Windows를 위한 몰입형 어학 학습 도구입니다. EPUB 독서, 오디오북 동기화, 동영상 자막 단어 검색, 원탭 Anki 카드 생성을 하나로 통합하여, 모든 입력이 자연스럽게 복습 가능한 어휘가 되도록 합니다.

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="책장" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="동영상 라이브러리" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="데스크톱에서의 세로쓰기 독서와 검색 팝업" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="동영상 단어 검색(중첩 팝업)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="동영상 단어 검색(자막 목록)" width="100%"></td>
  </tr>
</table>

</div>

## 기능

### 책장

- EPUB을 개별, 일괄, 또는 폴더 단위로 재귀적으로 가져오고, 책장에서 독서 진행 상황을 확인할 수 있습니다.
- 사용자 지정 책장, 태그 필터, 드래그로 순서 변경을 통해 책을 정리할 수 있습니다.
- 파일을 드래그 앤 드롭하여 책, 자막, 동영상을 가져올 수 있습니다(데스크톱).
- 가져오기 시 같은 이름의 자막／음성 파일을 자동으로 연결합니다.

### 독서

- 세로쓰기 또는 가로쓰기 레이아웃으로 읽을 수 있으며, 페이지 넘김 모드와 연속 스크롤 모드를 전환할 수 있습니다.
- 테마(라이트／다크／순흑／사용자 지정), 글꼴, 단락 간격, 리더 컨트롤을 사용자 지정할 수 있습니다.
- 후리가나(ふりがな) 주석을 표시합니다.
- UI 배율을 조정할 수 있으며, 하단 바 컨트롤도 배율에 따라 함께 조정됩니다.
- 다중 사용자 프로필(Profile)을 지원하며, 책별로 자동 전환됩니다.

### 단어 검색

- [Yomitan](https://github.com/yomidevs/yomitan)(이전 Yomichan), ABBYY Lingvo(DSL), MDict(MDX), Migaku 사전을 가져올 수 있습니다.
- 리더에서 텍스트를 탭하여 단어를 검색하거나, 사전 페이지에서 검색하거나, 다른 앱에서 텍스트를 공유하여 검색할 수 있습니다.
- **Yomitan의 모든 변환 언어**를 포괄하는 활용 복원과, 검색 전 텍스트 정규화(대소문자／발음 구별 기호／아랍어 하라카트)를 지원하며, 코드 포인트 기반으로 동작하여 언어 전환이 필요 없습니다.
- 뜻풀이 안의 단어를 탭하여 재귀적으로 검색할 수 있습니다(중첩 팝업).
- 다중 사전 병렬 쿼리, 하위 소스 우선순위 지정 및 전환, 피치 악센트와 빈도 주석을 지원합니다.
- 온라인 및 로컬 단어 음성을 재생할 수 있습니다.
- 사용자 지정 CSS를 주입할 수 있습니다.

### 하이라이트와 통계

- 독서 중 5색 하이라이트를 추가할 수 있으며, 언제든지 원하는 하이라이트로 이동할 수 있습니다.
- 독서 통계: 읽은 글자 수, 소요 시간, 독서 속도를 독서 중에 실시간으로 표시합니다.
- 동영상 통계: 시청 시간, 생성한 카드 수, 즐겨찾기 수를 표시합니다.

### Anki 카드 생성

- [AnkiDroid](https://github.com/ankidroid/Anki-Android) 또는 AnkiConnect로 카드를 생성할 수 있습니다.
- [Lapis](https://github.com/donkuri/lapis) 노트 유형을 내장(vendored 1.7.0)하여, 앱 내에서 원탭으로 카드 템플릿과 덱을 생성할 수 있습니다.
- 문맥 예문을 자동으로 채우고, 음성 녹음과 스크린샷 자르기를 지원합니다.
- 여러 내보내기 프로필(Profile)과 사용자 지정 필드 매핑을 지원합니다.
- 단어를 즐겨찾기에 추가할 수 있으며, 생성한 카드와 즐겨찾기는 통계에 집계됩니다.

### 오디오북 동기화(Sasayaki)

- SRT / LRC / VTT / ASS 자막을 지원하며, 자막 텍스트를 EPUB 본문에 자동으로 정렬합니다.
- 재생 중 문장 따라가기 하이라이트와 자동 페이지 넘김을 지원합니다.
- 재생 속도, 탐색 동작, 시스템 미디어 컨트롤을 지원합니다.
- "이 문장부터 재생"으로 챕터를 넘나들며 끊김 없이 이어서 재생할 수 있습니다.

### 동영상 자막 단어 검색

- [media_kit](https://github.com/media-kit/media-kit)(libmpv 코어) 기반의 동영상 플레이어를 내장하고 있습니다.
- 내장 자막(텍스트＋그래픽 트랙)과 외부 자막, .m3u8 재생목록 가져오기를 지원합니다.
- 재생 중 자막에서 직접 단어를 검색하고 카드를 생성할 수 있습니다.
- 동영상 라이브러리 관리, 태그 필터, 시리즈 그룹화, 일괄 작업을 지원합니다.

### 데이터 동기화

- 7가지 동기화 백엔드: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP, Hibiki P2P.
- 독서 진행 상황, 통계, 책을 동기화합니다.

### 더보기

- **17개 인터페이스 언어**를 지원하며, 모든 플랫폼에서 완전히 현지화되어 있습니다.
- 다른 앱에서 텍스트를 공유하여 바로 단어를 검색할 수 있습니다.

## 플랫폼 지원

| 플랫폼 | 상태 | 렌더링／UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> 최소 요구 사항은 Android 7.0(API 24)입니다. 사전 검색에서 사용할 수 있는 언어는 가져온 사전과 Yomitan 변환 테이블에 의해 결정되며, 인터페이스 언어와는 독립적입니다.

### 인터페이스 언어(17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## 설치 및 빌드

원커맨드로 준비(`flutter pub get` ＋ 패치 적용)한 후 빌드합니다.

```bash
# 저장소 루트에서
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
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
| 플랫폼 | Android / Windows(Material Design 3) |
| 리더 | WebView 페이징 엔진(Hoshi Reader 계열에서 파생) |
| 동영상 | media_kit(libmpv 코어) |
| 스토리지 | Drift(SQLite, WAL) ＋ hoshidicts(C++ FFI 사전 엔진) |
| NLP | Yomitan 변환 테이블(다국어 표제어화) ＋ kana_kit(가나 변환); 토큰화는 hoshidicts FFI 경유 |
| 카드 생성 | AnkiDroid API ＋ AnkiConnect |
| i18n | Slang(17개 언어) |

</details>

<details>
<summary><b>프로젝트 구조</b></summary>

```
hibiki/                      # Repository root (Melos workspace: hibiki_workspace)
├── hibiki/                  # Flutter 앱 메인 디렉터리
│   ├── lib/
│   │   ├── i18n/            # 국제화(17개 언어, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # 페이지(책장, 리더, 사전, 설정 등)
│   │   │   ├── reader/      # 리더 WebView JS/CSS 스크립트
│   │   │   ├── media/       # 오디오북, 자막 파싱, 리더 소스
│   │   │   └── models/      # 데이터 모델과 상태 관리(AppModel)
│   │   └── main.dart
│   └── android/             # Android 프로젝트(manifest, 네이티브 hoshidicts)
├── packages/                # 내부 패키지 ＋ flutter_inappwebview_windows (fork) ＋ gamepads_android_stub
├── native/                  # hoshidicts C++ 사전 엔진(FFI)
├── third_party/             # vendored된 패치 적용 패키지(dependency_overrides)
├── ci/                      # 빌드 패치와 통합 테스트 스크립트
├── tool/                    # bootstrap / i18n_sync 등의 스크립트
└── docs/                    # 개발 문서(docs/agent/ 운영 매뉴얼 포함)
```

</details>

## 개인정보 및 데이터

hibiki는 가져온 책, 사전, 글꼴, 오디오북 데이터, 동영상, 독서 진행 상황, 하이라이트, 통계, 설정을 앱의 로컬 저장소에 저장합니다.

클라우드 동기화(Google Drive / OneDrive / Dropbox)는 사용자가 설정한 OAuth 자격 증명을 사용합니다. WebDAV / FTP / SFTP는 사용자가 제공한 서버 주소와 자격 증명을 사용합니다. Hibiki P2P는 사용자가 설정한 주소로 직접 연결합니다. Anki 카드 생성은 AnkiDroid 또는 설정된 AnkiConnect 주소와 통신합니다.

## 감사의 말

hibiki는 다음 프로젝트와 생태계를 기반으로 합니다.

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

## 라이선스

GNU General Public License v3.0에 따라 배포됩니다. 자세한 내용은 [LICENSE](../../LICENSE)를 참조하세요.

<div align="center">

<br>

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | **한국어** | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
