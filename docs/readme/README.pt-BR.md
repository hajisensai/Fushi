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
| iOS | ✅ | Material Design 3 |

> Mínimo Android 7.0 (API 24). Os idiomas disponíveis para busca em dicionários são determinados pelos dicionários importados e pelas tabelas de transformação do Yomitan, independentemente do idioma da interface.

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

## Licença

Distribuído sob a Licença Pública Geral GNU v3.0. Consulte [LICENSE](../../LICENSE) para mais detalhes.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português** | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
