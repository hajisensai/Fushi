<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Leitor imersivo de japonês para Android</p>
<p align="center">EPUB · Dicionário · Anki · Sincronização de audiolivros</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <b>Português</b> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introdução

**hibiki** é um aplicativo de leitura Android para estudantes de japonês.

## Recursos

### Leitura EPUB
- Renderização EPUB em WebView (motor de paginação derivado do [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- Toque para consultar, selecione para analisar
- Fontes e temas personalizáveis (claro/escuro)
- Estatísticas de leitura e marcadores
- Dois modos: rolagem contínua / paginação

### Dicionário
- Importação de dicionários no formato [Yomitan](https://github.com/yomidevs/yomitan) (antigo Yomichan)
- Suporte a acento tonal e dados de frequência
- Consulta paralela em múltiplos dicionários, histórico de buscas
- Desconjugação Ve

### Cartões Anki
- Exportação com um toque para o [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Preenchimento automático de frases de contexto
- Gravação de áudio e recorte de capturas de tela
- Múltiplos perfis de exportação, mapeamento de campos personalizado
- Ações rápidas (Quick Actions) para criar cartões em um passo

### Sincronização de audiolivros (Sasayaki)
- Formatos de legenda: SRT / LRC / VTT / ASS
- Alinhamento automático das legendas com o texto EPUB
- Destaque acompanhando a leitura, mudança de página sincronizada com o áudio
- Barra de controle de reprodução (progresso, navegação, velocidade)

### Outros
- 17 idiomas de interface
- Múltiplos perfis de usuário
- Modo anônimo
- Consulta direta compartilhando texto de outros aplicativos

## Idiomas suportados

A interface suporta os seguintes idiomas:

| Idioma | Código |
|---|---|
| English | `en` |
| 简体中文 | `zh-CN` |
| 繁體中文 | `zh-HK` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español | `es` |
| Français | `fr` |
| Deutsch | `de` |
| Português (Brasil) | `pt-BR` |
| Русский | `ru` |
| Tiếng Việt | `vi` |
| ภาษาไทย | `th` |
| Bahasa Indonesia | `id` |
| Italiano | `it` |
| Nederlands | `nl` |
| Türkçe | `tr` |
| العربية | `ar` |

## Stack tecnológico

| Camada | Tecnologia |
|---|---|
| Framework | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plataforma | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptativo) |
| Leitor | Motor de paginação em WebView (derivado do [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Armazenamento | Drift (SQLite, WAL) + hoshidicts (engine de dicionários C++ FFI) |
| NLP | Ve (desconjugação) |
| Criação de cartões | AnkiDroid API |
| Internacionalização | Slang (17 idiomas) |
| Versão mínima | Android 7.0 (API 24) |

## Compilação

Preparação com um único comando (`flutter pub get` + aplicação de patches), depois compile:

```bash
# na raiz do repositório
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # ou (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` reúne duas etapas em um único comando: ① `flutter pub get`; ② execução do `ci/apply-patches.sh`. O `melos bootstrap`, via post hook, faz o mesmo (no Windows o melos tem um bug de codificação CJK, então use `tool/bootstrap.ps1`).

> **Sobre os patches:** `ci/apply-patches.sh` sobrepõe as alterações de `ci/patches/` ao pub cache real. Após cada limpeza do pub cache ou novo `flutter pub get`, ele precisa ser executado novamente (o bootstrap já inclui esta etapa). Se o script não encontrar nenhum alvo de patch, ele pula com um aviso em vez de fingir sucesso.

## Dependências e patches

Este projeto está fixado no Flutter 3.41.6 e algumas dependências upstream ainda não foram adaptadas. As correções seguem dois caminhos: ① pacotes que precisam ser entrada de build e reproduzir-se de forma idêntica entre máquinas são vendored em `third_party/` e apontados via `dependency_overrides` (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **sem** patch no pub cache); ② os demais pacotes são corrigidos por `ci/apply-patches.sh` no código-fonte do pub cache. Detalhes do mecanismo em [docs/agent/build.md](../agent/build.md). As tabelas recolhíveis abaixo são uma lista histórica organizada por alteração; para pacotes que se sobrepõem ao mecanismo ①, prevalece a versão vendored.

<details>
<summary><b>Patches de alterações de API do Flutter</b></summary>

| Pacote | Alterações |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; substituição do `imageCache.putIfAbsent` removido |
| `flutter_blurhash` 0.7.0 | Idem `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Adição de `hide CarouselController` nos imports internos para evitar conflitos de nomes |
| `fading_edge_scrollview` 3.0.0 | Correção nullable do `PageView.controller` |

</details>

<details>
<summary><b>Patches de remoção do embedding v1</b></summary>

O Flutter 3.41.6 removeu completamente a API de embedding v1 (`PluginRegistry.Registrar`). Os seguintes plugins requerem a remoção das referências correspondentes:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Patches Gradle / Kotlin</b></summary>

| Alvo | Alterações |
|---|---|
| `android/build.gradle` afterEvaluate | Forçar `compileSdk` para subprojetos (padrão 36, alguns 34); remoção de `-Werror` |
| `audio_session` 0.1.14 | Remoção de `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Correção de segurança null do Kotlin |
| `receive_intent` (git) | Correção de segurança null do Kotlin |

</details>

<details>
<summary><b>Dependências Git</b></summary>

| Pacote | Fonte |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

</details>

## Estrutura do projeto

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
├── third_party/             # Pacotes de patch vendored (apontados via dependency_overrides)
├── ci/                      # Scripts de patches de build e testes de integração
├── tool/                    # Scripts bootstrap / i18n_sync, etc.
└── docs/                    # Documentação de desenvolvimento (inclui manual do agent em docs/agent/)
```

## Agradecimentos

| Projeto | Descrição |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Ferramenta de aprendizado imersivo de japonês |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Leitor de japonês para Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Engine de dicionários C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Leitor de japonês para iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solução de sincronização de audiolivros |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Engine de renderização EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Versão comunitária do ttu (SvelteKit v2), base upstream do fork hibiki |
| [Yomitan](https://github.com/yomidevs/yomitan) | Fonte do formato de dicionário |

## Licença

[GNU General Public License v3.0](../../LICENSE)
