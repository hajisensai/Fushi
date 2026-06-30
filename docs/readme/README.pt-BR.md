<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="logotipo do hibiki" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português** | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[Guia do usuário](../user-guide.pt-BR.md) | [Baixar a versão mais recente](https://github.com/hajisensai/hibiki/releases)

> **Assista ao que você quer assistir e aprenda o idioma no caminho.**

O hibiki transforma os romances que você lê, as séries que você acompanha e os audiolivros que você ouve no seu material de entrada do idioma: toque em qualquer palavra desconhecida para buscá-la e, com um toque, transforme-a em um cartão Anki com o contexto original. Ele não faz você memorizar uma lista de palavras predefinida; apenas ajuda você a captar as palavras que **realmente lê e ouve**.

A maneira mais eficaz de aprender um idioma é a exposição em grande quantidade a conteúdo real, e não memorizar palavras isoladas de um livro de vocabulário. Mas a "imersão" sempre teve dois incômodos: buscar uma palavra quebra a concentração, e você a esquece assim que desvia o olhar. O hibiki fecha esse ciclo:

📖 **Ler**: toque em uma palavra no leitor de EPUB para buscá-la, sem sair da página atual.<br>
🎧 **Ouvir**: os audiolivros destacam frase por frase e viram as páginas automaticamente.<br>
🎬 **Assistir**: busque palavras e crie cartões direto nas legendas do vídeo — acompanhar uma série *é* entrada.<br>
🃏 **Fixar**: envie ao Anki qualquer palavra que você buscar, em qualquer cenário, e revise apenas as palavras que realmente encontrou.

Todos os cenários compartilham os mesmos dicionários, estatísticas e fluxo de revisão. Serve para qualquer idioma (japonês, inglês, …) e é especialmente indicado para quem aprende por imersão e acredita em **muita entrada + apenas cartões próprios**. Disponível para Android e Windows (iOS e macOS planejados).

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="Estante" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="Biblioteca de vídeos" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="Leitura vertical no desktop com janela de busca" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="Busca em vídeo (janelas aninhadas)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="Busca em vídeo (lista de legendas)" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-mobile.png" alt="Busca por seleção de texto fora do app (celular)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-desktop.png" alt="Busca por seleção de texto fora do app (desktop)" width="100%"></td>
  </tr>
</table>

**Demonstração de criação de cartões Anki com um toque**

<video src="https://github.com/hajisensai/hibiki/raw/main/docs/static-assets/screenshots/hibiki-readme-anki-mining-demo.mp4" controls muted width="100%"></video>

</div>

## Recursos

### Estante

- Importe EPUBs individualmente, em lote ou recursivamente por pasta; veja o progresso de leitura na estante.
- Organize os livros com estantes personalizadas, filtragem por etiquetas e reordenação por arrastar.
- Arraste e solte arquivos para importar livros, legendas ou vídeos (desktop).
- Associe automaticamente arquivos de legenda / áudio com o mesmo nome ao importar.

### Leitura

- Leia em disposição vertical ou horizontal; alterne entre os modos paginado e rolagem contínua.
- Personalize temas (claro / escuro / preto puro / personalizado), fontes, espaçamento de parágrafos e controles do leitor.
- Anotações furigana (ふりがな).
- Escala de interface ajustável; os controles da barra inferior acompanham a escala.
- Perfis multiusuário (Profile), alternados automaticamente por livro.

### Busca

- Importe dicionários [Yomitan](https://github.com/yomidevs/yomitan) (antigo Yomichan), ABBYY Lingvo (DSL), MDict (MDX) e Migaku.
- Toque no texto no leitor para buscar palavras, pesquise na página de dicionário ou compartilhe texto de outros aplicativos.
- Desinflexão cobrindo **todos os idiomas de transformação do Yomitan** + normalização do texto antes da busca (maiúsculas/minúsculas / diacríticos / harakat árabe), guiada por pontos de código sem troca de idioma.
- Toque nas palavras dentro das definições para uma busca recursiva (janelas aninhadas).
- Consultas paralelas em vários dicionários, prioridade e ativação de subfontes, anotações de acento tonal e frequência.
- Áudio de palavras on-line e local.
- Injete CSS personalizado.

### Destaques e estatísticas

- Adicione destaques em cinco cores durante a leitura; salte para qualquer destaque a qualquer momento.
- Estatísticas de leitura: caracteres lidos, duração, velocidade de leitura — exibidas em tempo real durante a leitura.
- Estatísticas de vídeo: tempo de exibição, cartões criados e favoritos.

### Criação de cartões Anki

- Crie cartões via [AnkiDroid](https://github.com/ankidroid/Anki-Android) ou AnkiConnect.
- Tipo de nota [Lapis](https://github.com/donkuri/lapis) integrado (incluído 1.7.0); crie modelos de cartão e baralhos dentro do aplicativo com um toque.
- Preencha automaticamente frases de contexto; gravação de áudio e recorte de capturas de tela.
- Vários perfis de exportação (Profile) e mapeamento de campos personalizado.
- Palavras favoritas; os cartões criados e os favoritos são contabilizados nas estatísticas.

### Sincronização de audiolivros (Sasayaki)

- Suporte a legendas SRT / LRC / VTT / ASS; alinha automaticamente o texto das legendas ao corpo do EPUB.
- Destaque de frases com acompanhamento e virada de página automática durante a reprodução.
- Velocidade de reprodução, ações de busca e controles de mídia do sistema.
- "Reproduzir a partir desta frase" com continuação fluida entre capítulos.

### Busca em legendas de vídeo

- Reprodutor de vídeo integrado baseado no [media_kit](https://github.com/media-kit/media-kit) (núcleo libmpv).
- Legendas incorporadas (faixas de texto + gráficas) e externas; importação de playlists .m3u8.
- Busque palavras e crie cartões diretamente das legendas durante a reprodução.
- Gerenciamento da biblioteca de vídeos, filtragem por etiquetas, agrupamento em séries e operações em lote.

### Sincronização de dados

- Sete backends de sincronização: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP e Hibiki P2P.
- Sincronize o progresso de leitura, as estatísticas e os livros.

### Mais

- **17 idiomas de interface**, totalmente localizados em todas as plataformas.
- Compartilhe texto de outros aplicativos para buscar palavras diretamente.

## Suporte a plataformas

| Plataforma | Status | Renderização / Interface |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> Mínimo Android 7.0 (API 24). Os idiomas disponíveis para busca em dicionários são determinados pelos dicionários importados e pelas tabelas de transformação do Yomitan, independentemente do idioma da interface.

### Idiomas de interface (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Instalação e compilação

Preparação com um único comando (`flutter pub get` + aplicar patches) e, em seguida, compile:

```bash
# A partir da raiz do repositório
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
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
| Plataformas | Android / Windows (Material Design 3) |
| Leitor | Motor de paginação WebView (derivado da família Hoshi Reader) |
| Vídeo | media_kit (libmpv core) |
| Armazenamento | Drift (SQLite, WAL) + hoshidicts (motor de dicionários FFI em C++) |
| PLN | Tabelas de transformação do Yomitan (lematização multilíngue) + kana_kit (conversão de kana); tokenização via hoshidicts FFI |
| Criação de cartões | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 idiomas) |

</details>

<details>
<summary><b>Estrutura do projeto</b></summary>

```
hibiki/                      # Raiz do repositório (workspace Melos: hibiki_workspace)
├── hibiki/                  # Diretório principal do aplicativo Flutter
│   ├── lib/
│   │   ├── i18n/            # Internacionalização (17 idiomas, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Páginas (estante, leitor, dicionário, configurações, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS do WebView do leitor
│   │   │   ├── media/       # Audiolivros, análise de legendas, fonte do leitor
│   │   │   └── models/      # Modelos de dados e gerenciamento de estado (AppModel)
│   │   └── main.dart
│   └── android/             # Projeto Android (manifest, hoshidicts nativo)
├── packages/                # Pacotes internos + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Motor de dicionários em C++ hoshidicts (FFI)
├── third_party/             # Pacotes com patch incluídos (dependency_overrides)
├── ci/                      # Patches de compilação e scripts de testes de integração
├── tool/                    # Scripts bootstrap / i18n_sync e outros
└── docs/                    # Documentação de desenvolvimento (incl. manual de operações docs/agent/)
```

</details>

## Privacidade e dados

O hibiki armazena os livros importados, dicionários, fontes, dados de audiolivros, vídeos, progresso de leitura, destaques, estatísticas e configurações no armazenamento local do aplicativo.

A sincronização na nuvem (Google Drive / OneDrive / Dropbox) usa credenciais OAuth configuradas pelo usuário; WebDAV / FTP / SFTP usa endereços de servidor e credenciais fornecidos pelo usuário; o Hibiki P2P conecta-se diretamente por meio de um endereço configurado pelo usuário. A criação de cartões Anki comunica-se com o AnkiDroid ou com um endereço AnkiConnect configurado.

## Agradecimentos

O hibiki baseia-se nos seguintes projetos e ecossistema:

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

## Licença

Distribuído sob a Licença Pública Geral GNU v3.0. Consulte [LICENSE](../../LICENSE) para mais detalhes.

<div align="center">

<br>

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português** | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
