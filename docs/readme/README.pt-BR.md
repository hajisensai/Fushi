<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Leia um livro e torne cada palavra desconhecida sua.</b></p>
<p align="center">Leitor imersivo multiplataforma e multilíngue — leitura de EPUB · consulta de palavras por seleção · criação de cartões Anki · sincronização de audiolivros · consulta de palavras em legendas de vídeo</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  &nbsp;·&nbsp;
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Página inicial do projeto (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <b>Português</b> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introdução

**hibiki** é um leitor multiplataforma de aprendizado imersivo de idiomas. No corpo de um EPUB, **toque para consultar, selecione para analisar**, e transforme uma palavra desconhecida em um cartão Anki com um clique; sincronize o áudio de um audiolivro com o texto, destacando frase por frase; e consulte palavras e crie cartões diretamente nas legendas de vídeo. Uma única ferramenta para cobrir suas três formas de entrada imersiva: "ler · ouvir · assistir".

A consulta no dicionário cobre **todos os idiomas de transformação** do [Yomitan](https://github.com/yomidevs/yomitan) (desflexão + normalização de texto antes da consulta), a interface é localizada em **17 idiomas** e o app oferece suporte às cinco plataformas **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Estante" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Consulta" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Configurações e temas" width="300">
</p>
<p align="center"><sub>Estante · Consulta · Configurações e temas</sub></p>

---

## Destaques

### 📖 Leitura EPUB, consulta com um toque

Leitor EPUB renderizado em WebView (motor de paginação derivado do [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)): toque em qualquer palavra para consultá-la instantaneamente, selecione um trecho para análise na hora. Dois modos, rolagem contínua e paginação, fontes e temas personalizáveis (claro / escuro / preto puro / personalizado), furigana, estatísticas de leitura e marcadores, tudo incluído.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Leitura vertical · Furigana · Sincronização de audiolivro" width="300">
</p>
<p align="center"><sub>Texto vertical · Furigana · Destaque por seleção · Barra de controle de sincronização do audiolivro na parte inferior</sub></p>

### 🔍 Consulta por seleção, cobrindo todos os idiomas de transformação do Yomitan

Importe dicionários nos formatos **Yomitan** (antigo Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Lematização multilíngue (tabelas de transformação do Yomitan) + normalização de texto antes da consulta (maiúsculas/minúsculas / diacríticos / harakat árabe), orientada por ponto de código, sem precisar trocar de idioma. Consulta paralela em múltiplos dicionários, prioridade e ativação/desativação de subfontes, marcação de acento tonal e frequência de palavras, tudo em um único pop-up.

### 🎴 Criação de cartões Anki com um clique

Encontrada a palavra desconhecida, exporte-a em um passo para o [AnkiDroid](https://github.com/ankidroid/Anki-Android) e o AnkiConnect. Esquema de tipo de nota [Lapis](https://github.com/donkuri/lapis) integrado (vendored 1.7.0), que permite criar modelos de cartões e baralhos diretamente no app; preenchimento automático de frases de contexto, suporte a gravação de áudio e recorte de capturas de tela, múltiplos perfis de exportação (Profile), mapeamento de campos personalizado e ações rápidas para criar um cartão em um gesto.

### 🎧 Sincronização de audiolivros (Sasayaki)

Suporte a legendas SRT / LRC / VTT / ASS, com alinhamento automático do texto das legendas ao corpo do EPUB. Durante a reprodução, **destaque acompanhando a leitura e mudança de página sincronizada com o áudio**, junto a uma barra de controle de reprodução (progresso, navegação, velocidade): ao ouvir, o texto se ilumina frase por frase — a barra de controle na parte inferior da captura de leitura no topo desta página ilustra exatamente este recurso.

### 🎬 Consulta de palavras em legendas de vídeo

Player de vídeo integrado baseado em media_kit / libmpv, com suporte a legendas embutidas / externas. Durante a reprodução de um vídeo, **consulte palavras e crie cartões diretamente na legenda**, incorporando também material audiovisual à sua entrada imersiva; o tempo de visualização e a quantidade de cartões criados também são contabilizados.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Captura de tela do player de vídeo a ser adicionada</sub></p>

### 🔗 Mais

- **17 idiomas de interface**, localização em todas as plataformas
- **Interconexão Hibiki**: sincronização de livros / dicionários / audiolivros / progresso de leitura entre dispositivos
- **Múltiplos perfis de usuário (Profile)**, troca automática por livro
- **Modo anônimo**; **consulta direta compartilhando texto** de outros aplicativos

---

## Plataformas suportadas

| Plataforma | Status | Renderização / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (`flutter_inappwebview_windows` forkado para renderizar EPUB) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Mínimo Android 7.0 (API 24). O idioma de consulta do dicionário é determinado pelos dicionários importados e pelas tabelas de transformação do Yomitan, de forma independente do idioma da interface.

### Idiomas de interface (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Instalação e compilação

Preparação com um único comando (`flutter pub get` + aplicação de patches), depois compile:

```bash
# na raiz do repositório
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # ou (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` reúne em um único comando ① `flutter pub get` e ② `ci/apply-patches.sh`. O projeto está fixado no Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); algumas dependências upstream são vendored em `third_party/` ou corrigidas por `ci/apply-patches.sh` — detalhes do mecanismo, compilação nas cinco plataformas e lista de dependências e patches em [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Visão geral do stack tecnológico</b></summary>

| Camada | Tecnologia |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plataforma | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptativo) |
| Leitor | Motor de paginação em WebView (derivado do [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Vídeo | media_kit / libmpv |
| Armazenamento | Drift (SQLite, WAL) + hoshidicts (engine de dicionários C++ FFI) |
| NLP | Tabelas de transformação do Yomitan (lematização multilíngue) + kana_kit (conversão de kana); a segmentação passa pelo hoshidicts FFI |
| Criação de cartões | AnkiDroid API + AnkiConnect |
| Internacionalização | Slang (17 idiomas) |

</details>

<details>
<summary><b>Estrutura do projeto</b></summary>

```
hibiki/                      # Raiz do repositório (Melos workspace: hibiki_workspace)
├── hibiki/                  # Diretório principal do aplicativo Flutter
│   ├── lib/
│   │   ├── i18n/            # Internacionalização (17 idiomas, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Páginas (estante, leitor, dicionário, configurações, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS do WebView do leitor
│   │   │   ├── media/       # Audiolivros, análise de legendas, reader source
│   │   │   └── models/      # Modelos de dados e gerenciamento de estado (AppModel)
│   │   └── main.dart
│   └── android/             # Projeto Android (manifest, hoshidicts nativo)
├── packages/                # Packages internos + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # Engine de dicionários C++ hoshidicts (FFI)
├── third_party/             # Pacotes de patch vendored (apontados via dependency_overrides)
├── ci/                      # Scripts de patches de build e testes de integração
├── tool/                    # Scripts bootstrap / i18n_sync, etc.
└── docs/                    # Documentação de desenvolvimento (inclui manual do agent em docs/agent/)
```

</details>

---

## Agradecimentos

| Projeto | Descrição |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Ferramenta de aprendizado imersivo de japonês |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Leitor de japonês para Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Engine de dicionários C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Leitor de japonês para iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solução de sincronização de audiolivros |
| [Yomitan](https://github.com/yomidevs/yomitan) | Fonte dos formatos de dicionário e das tabelas de transformação |
| [Lapis](https://github.com/donkuri/lapis) | Tipo de nota Anki |

## Licença

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <b>Português</b> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
