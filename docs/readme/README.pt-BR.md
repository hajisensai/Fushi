<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logotipo do Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português** | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Baixar a versão mais recente](https://img.shields.io/badge/%E2%AC%87%20Baixar%20a%20vers%C3%A3o%20mais%20recente-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Entrar no Discord](https://img.shields.io/badge/Entrar%20no%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Suporte a plataformas

| Plataforma | Status | Renderização / Interface |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Material Design 3 |

> Mínimo Android 7.0 (API 24). Os idiomas disponíveis para busca em dicionários são determinados pelos dicionários importados e pelas tabelas de transformação do Yomitan, independentemente do idioma da interface. A versão para iOS é distribuída pelo TestFlight: ela não inclui os recursos de descoberta e download que as diretrizes da App Store não permitem, e suas atualizações chegam alguns dias depois das demais plataformas.

### Idiomas de interface (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Instalação e compilação

Preparação com um único comando (`flutter pub get` + aplicar patches) e, em seguida, compile:

```bash
# A partir da raiz do repositório
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop Windows
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` reúnem `flutter pub get` e `ci/apply-patches.sh` em um único comando. Este projeto está fixado no Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); algumas dependências upstream estão incluídas em `third_party/` ou recebem patch de `ci/apply-patches.sh` — consulte [docs/agent/build.md](../agent/build.md) para mais detalhes.

<details>
<summary><b>Pilha de tecnologias</b></summary>

| Camada | Tecnologia |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plataformas | Android / Windows / macOS / iOS (Material Design 3) |
| Leitor | Motor de paginação WebView (derivado da família Hoshi Reader) |
| Vídeo | media_kit (libmpv core) |
| Armazenamento | Drift (SQLite, WAL) + fushidicts (motor de dicionários FFI em C++) |
| PLN | Tabelas de transformação do Yomitan (lematização multilíngue) + kana_kit (conversão de kana); tokenização via fushidicts FFI |
| Criação de cartões | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 idiomas) |

</details>

<details>
<summary><b>Estrutura do projeto</b></summary>

```
Fushi/                      # Raiz do repositório (workspace Melos: fushi_workspace)
├── fushi/                  # Diretório principal do aplicativo Flutter
│   ├── lib/
│   │   ├── i18n/            # Internacionalização (17 idiomas, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Páginas (estante, leitor, dicionário, configurações, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS do WebView do leitor
│   │   │   ├── media/       # Audiolivros, análise de legendas, fonte do leitor
│   │   │   └── models/      # Modelos de dados e gerenciamento de estado (AppModel)
│   │   └── main.dart
│   └── android/             # Projeto Android (manifest, fushidicts nativo)
├── packages/                # Pacotes internos + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Motor de dicionários em C++ fushidicts (FFI)
├── third_party/             # Pacotes com patch incluídos (dependency_overrides)
├── ci/                      # Patches de compilação e scripts de testes de integração
├── tool/                    # Scripts bootstrap / i18n_sync e outros
└── docs/                    # Documentação de desenvolvimento (incl. manual de operações docs/agent/)
```

</details>

## Privacidade e dados

O Fushi armazena os livros importados, dicionários, fontes, dados de audiolivros, vídeos, progresso de leitura, destaques, estatísticas e configurações no armazenamento local do aplicativo.

A sincronização na nuvem (Google Drive / OneDrive / Dropbox) usa credenciais OAuth configuradas pelo usuário; WebDAV / FTP / SFTP usa endereços de servidor e credenciais fornecidos pelo usuário; o Fushi Interconnect conecta-se diretamente por meio de um endereço configurado pelo usuário. A criação de cartões Anki comunica-se com o AnkiDroid ou com um endereço AnkiConnect configurado.

## Agradecimentos

O Fushi baseia-se nos seguintes projetos e ecossistema:

### Ferramentas de aprendizado e referências anteriores

| Projeto | Descrição |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Ferramenta de aprendizado imersivo de japonês |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Leitor de japonês para iOS; referência do motor de paginação do leitor |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Leitor de japonês nativo para Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motor de dicionários em C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solução de sincronização de audiolivros |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referência de formato de dicionário, tabelas de transformação e experiência de busca |
| [Lapis](https://github.com/donkuri/lapis) | Tipo de nota do Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Integração de criação de cartões no Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referência de áudio local e interação com o AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referência de compatibilidade de leitor, estatísticas e sincronização |
| [media_kit](https://github.com/media-kit/media-kit) | Framework de reprodução de vídeo do Flutter (núcleo libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Suíte de aprendizado imersivo de idiomas para macOS |

### Motores e componentes nativos

| Projeto | Descrição |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Motor de hooking de texto para galgames (DLLs incluídas, carregadas pelo injetor) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Biblioteca de inline hooking usada pelo injetor de galgames |
| [libtorrent](https://github.com/arvidn/libtorrent) | Motor de download torrent integrado |
| [mpv](https://github.com/mpv-player/mpv) | Núcleo de reprodução libmpv por trás do media_kit |
| [FFmpeg](https://ffmpeg.org) | Análise de mídia, recorte e extração de áudio |
| [libplacebo](https://github.com/haasn/libplacebo) | Shaders de vídeo por GPU e mapeamento de tons HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Motor WebView que renderiza o leitor EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Inferência no dispositivo para reconhecimento de fala e OCR |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Dependências do motor de dicionários |

### Modelos no dispositivo

| Projeto | Descrição |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Pacotes de modelos Zipformer de reconhecimento de fala e builds de VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Modelo de reconhecimento de fala em japonês |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Modelo multilíngue de reconhecimento de fala CTC |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Modelo de detecção de atividade de voz |
| [manga-ocr](https://github.com/kha-white/manga-ocr) / [manga-ocr-onnx](https://huggingface.co/mayocream/manga-ocr-onnx) | Modelo de OCR para mangá |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Modelo de detecção de texto e balões de fala em mangá |

### Fontes de conteúdo e integrações

| Projeto | Descrição |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Ecossistema de extensões de fontes de mangá |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Runtime de extensões de mangá para desktop |
| [aidoku-rs](https://github.com/Aidoku/aidoku-rs) | ABI do runtime de fontes de mangá |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Referência da ponte de legendas de streaming para a extensão de navegador |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Referência de arquitetura para identificação e scraping de anime |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Referência de arquitetura de informação da biblioteca de galgames |
| [AniDB](https://anidb.net) | Identidade de anime, episódios e arquivos |
| [TMDB](https://www.themoviedb.org) | Metadados e imagens complementares |
| [Jimaku](https://jimaku.cc) | Fonte de legendas em japonês |
| [OpenSubtitles](https://www.opensubtitles.com) | Fonte de legendas |

> Este aplicativo usa o TMDB e as APIs do TMDB, mas não é endossado, certificado ou aprovado pelo TMDB.

## Licença

Distribuído sob a Licença Pública Geral GNU v3.0. Consulte [LICENSE](../../LICENSE) para mais detalhes.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português** | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
