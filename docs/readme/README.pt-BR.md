<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logotipo do Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português** | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Baixar a versão mais recente](https://img.shields.io/badge/%E2%AC%87%20Baixar%20a%20vers%C3%A3o%20mais%20recente-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Entrar no Discord](https://img.shields.io/badge/Entrar%20no%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Suporte a plataformas

| Plataforma | Status | Observações |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) ou posterior |
| Windows | ✅ | O hooking de texto e voz de galgames só está disponível no Windows |
| macOS | ✅ | Somente Apple Silicon; Macs com Intel não são compatíveis |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Sem descoberta, fontes online nem central de downloads (diretrizes da App Store) |
| Linux | 🔧 Compilar a partir do código-fonte | Ainda não há versão pré-compilada; o leitor de EPUB precisa do WPE WebKit |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Host sem interface para Linux / Windows / macOS com interface web — veja [packages/fushi_server](../../packages/fushi_server/README.md) |

**Sistema de design** — todas as plataformas usam **Material 3 Expressive** por padrão; um sistema de design **Cupertino** (estilo Apple) pode ser selecionado em *Configurações › Aparência › Sistema de design*; com o Cupertino, o fundo da janela usa Mica no Windows 11 e vibrancy no macOS (a menos que a configuração do sistema de reduzir a transparência ou de alto contraste esteja ativada).

> Os idiomas disponíveis para busca em dicionários são determinados pelos dicionários importados e pelas tabelas de transformação do Yomitan, independentemente do idioma da interface. As atualizações do iOS chegam pelo TestFlight alguns dias depois das demais plataformas.

### Idiomas de interface (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Instalação

Baixe a versão mais recente no [site do Fushi](https://fushi.moe/) — estão disponíveis o APK do Android, o instalador do Windows e as compilações do macOS (somente Apple Silicon; Macs com Intel não são compatíveis); o iOS é instalado pelo [TestFlight](https://testflight.apple.com/join/j88d69jx). O Linux ainda não tem uma versão pré-compilada do aplicativo; compile a partir do código-fonte. O Fushi Server, o servidor sem interface, é lançado separadamente em [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> Requer Android 7.0 (API 24) ou superior.

## Compilação

Preparação com um único comando (`flutter pub get` + aplicar patches) e, em seguida, compile:

```bash
# A partir da raiz do repositório
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Servidor sem interface (a partir de packages/fushi_server; use `dart build cli`, não `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` reúnem `flutter pub get` e `ci/apply-patches.sh` em um único comando. Este projeto está fixado no Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`); versões anteriores do Flutter não conseguem compilá-lo porque o Material e o Cupertino são consumidos como os pacotes `material_ui` / `cupertino_ui`. Algumas dependências upstream estão incluídas em `third_party/` ou recebem patch de `ci/apply-patches.sh`; consulte [docs/agent/build.md](../agent/build.md) para mais detalhes, incluindo as dependências de compilação do desktop Linux.

<details>
<summary><b>Pilha de tecnologias</b></summary>

| Camada | Tecnologia |
|---|---|
| Framework | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Plataformas | Android / Windows / macOS / iOS / Linux, mais um servidor sem interface |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Leitor | Motor de paginação WebView (derivado da família Hoshi Reader) |
| Vídeo | media_kit (libmpv core) + libplacebo |
| Armazenamento | Drift (SQLite, WAL) + fushidicts (motor de dicionários FFI em C++) |
| PLN | Tabelas de transformação do Yomitan (lematização multilíngue) + kana_kit (conversão de kana); tokenização via fushidicts FFI |
| IA no dispositivo | ONNX Runtime para reconhecimento de fala (geração de legendas) e OCR de mangá; os algoritmos ficam em [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Downloads | libtorrent 2.x por meio de uma ponte FFI com C-ABI (qBittorrent externo como alternativa) |
| Sincronização | Backends na nuvem + Fushi Interconnect (LAN, endereços remotos e um túnel P2P iroh) |
| Motor compartilhado | `fushi_engine` — núcleo em Dart puro compartilhado pelo aplicativo e pelo Fushi Server |
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
│   │   │   ├── pages/       # Páginas (páginas de biblioteca, leitor, player de vídeo, configurações, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS do WebView do leitor
│   │   │   ├── media/       # Livros, mangá, vídeo, audiolivros, fontes online
│   │   │   ├── lookup/      # Pop-ups e sobreposições de busca em dicionários
│   │   │   ├── mining/      # Criação de cartões (incl. mineração de galgames)
│   │   │   ├── sync/        # Sincronização na nuvem, Interconnect, servidores de mídia
│   │   │   └── models/      # Modelos de dados e gerenciamento de estado (AppModel)
│   │   └── main.dart
│   └── android/             # Projeto Android
├── packages/                # Pacotes Dart
│   ├── fushi_core/          #   Esquema do banco de dados, preferências
│   ├── fushi_engine/        #   Motor em Dart puro compartilhado com o servidor
│   ├── fushi_server/        #   CLI do servidor sem interface + interface web
│   ├── fushi_cli/           #   Cliente de linha de comando para desktop
│   ├── fushi_dictionary/    #   Bindings do motor de dicionários e importadores
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # Bindings FFI de libtorrent / iroh
│   └── …                    #   Forks incluídos (inappwebview Windows/Linux, gamepads)
├── native/                  # Fontes nativas: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Coletor de logs e backends do ranking (implantados separadamente)
├── tools/browser-extension/ # Extensão de navegador para busca em dicionários
├── third_party/             # Pacotes com patch incluídos (dependency_overrides)
├── ci/                      # Patches de compilação e scripts de CI
├── tool/                    # Scripts bootstrap / setup_worktree / rastreamento de bugs
└── docs/                    # Documentação de desenvolvimento (incl. manual de operações docs/agent/)
```

</details>

A importação de vídeo permite agrupar por obra ou por pasta. Consulte o [fluxo de trabalho de vídeo](../specs/2026-09-07-video-library-workflow.md) e os [metadados de MAL/TMDB com hash de arquivos do AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md) para a correspondência e as tarefas em segundo plano.

A [configuração opcional de serviços online](../specs/2026-09-07-online-services-setup.md) explica as identidades de aplicativo incluídas, as credenciais pessoais e o lembrete dispensável de configuração de vídeo.

## Privacidade e dados

O Fushi armazena os livros importados, dicionários, fontes, dados de audiolivros, vídeos, progresso de leitura, destaques, estatísticas e configurações no armazenamento local do aplicativo.

- **Sincronização** — Google Drive / OneDrive / Dropbox usam login OAuth; WebDAV / FTP / SFTP / Fushi Server usam o endereço do servidor e as credenciais que você fornecer. O Fushi Interconnect conecta diretamente os dispositivos pareados (LAN, IPv6, redes sobrepostas ou endereços públicos) e, quando nenhuma rota direta funciona, recorre a um túnel P2P iroh de ponta a ponta; os links de pareamento sempre pedem confirmação.
- **Anki** — a criação de cartões se comunica com o AnkiDroid ou com o endereço do AnkiConnect que você configurar.
- **Estatísticas de uso** — uma vez por dia, as compilações para desktop e Android enviam ao fushi.moe um ID de instalação aleatório, a versão do aplicativo, a plataforma e o canal de atualização para contar os usuários ativos; nenhuma conta, biblioteca ou dado de leitura é incluído e os endereços IP não são armazenados. Desative com *Compartilhar estatísticas de uso* nas configurações de atualização. As compilações para iOS não as enviam.
- **Somente quando você pede** — o envio de logs (após um aviso de consentimento único), o feedback dentro do aplicativo e o ranking (desativado por padrão; só envia os títulos da sua biblioteca e o seu progresso depois que você ativar).
- **OCR de mangá** — o mecanismo padrão é o Google Lens, que envia a imagem da página ao Google; mude para o modelo no dispositivo ou para o OCR do sistema nas configurações para manter as imagens locais.
- **Recursos de IA** — as solicitações vão apenas para o provedor de LLM que você configurar e atribuir a um recurso; sem provedor atribuído, nada é enviado.
- **Serviços de terceiros** — os recursos de metadados, legendas e fontes online só entram em contato com os serviços listados em [Fontes de conteúdo e integrações](#fontes-de-conteúdo-e-integrações) quando você os usa.

## Atividade de desenvolvimento

[![Atividade de desenvolvimento](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

O trabalho diário chega ao `develop`; o `main` só recebe as mesclagens de lançamento. O gráfico é exibido aqui no `main`, mas é gerado a partir do `develop`, portanto reflete o desenvolvimento real e não o tráfego de mesclagens.

As três faixas são os canais de atualização que o próprio aplicativo oferece, e cada uma é dimensionada pelo seu próprio pico: as compilações debug superam as versões estáveis em duas ordens de grandeza, então uma escala compartilhada reduziria as outras duas faixas a quase nada.

| Faixa | O que conta | Como obter |
|---|---|---|
| **Debug (contínuo)** | Compilações bem-sucedidas por push do [release.yml](../../.github/workflows/release.yml) | Pré-lançamento contínuo, republicado a cada push |
| **Beta** | Pré-lançamentos `v<version>-beta.<seq>` | Compilação de teste disparada manualmente |
| **Estável** | Versões `v<version>` | Última versão |

> O gráfico acima é gerado dentro deste repositório (sem serviço de terceiros) e atualizado diariamente pelo workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml).

## Histórico de estrelas

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star History](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> O gráfico acima é gerado dentro deste repositório (sem serviço de terceiros) e atualizado diariamente pelo workflow [Update Star History](../../.github/workflows/star-history.yml).

## Agradecimentos

O Fushi se apoia nos seguintes projetos e ecossistema:

### Ferramentas de aprendizado e referências anteriores

| Projeto | Descrição |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Ferramenta de aprendizado imersivo de japonês |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Leitor de japonês para iOS; referência do motor de paginação do leitor |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Leitor de japonês nativo para Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motor de dicionários em C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solução de sincronização de audiolivros |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Algoritmo de alinhamento temporal de legendas a uma referência (GPL-3.0); base para alinhar automaticamente as legendas baixadas às faixas incorporadas |
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
| [libtorrent](https://github.com/arvidn/libtorrent) | Motor de downloads torrent integrado |
| [mpv](https://github.com/mpv-player/mpv) | Núcleo de reprodução libmpv por trás do media_kit |
| [FFmpeg](https://ffmpeg.org) | Análise de mídia, recortes e extração de áudio |
| [libplacebo](https://github.com/haasn/libplacebo) | Shaders de vídeo por GPU e mapeamento de tons HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Motor WebView que renderiza o leitor de EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Inferência no dispositivo para reconhecimento de fala e OCR |
| [iroh](https://github.com/n0-computer/iroh) | Túnel P2P para as conexões remotas do Fushi Interconnect |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Dependências do motor de dicionários |

### Modelos no dispositivo

| Projeto | Descrição |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Pacotes de modelos Zipformer de reconhecimento de fala e compilações de VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Modelo de reconhecimento de fala em japonês |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Modelo de reconhecimento de fala em japonês |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Modelo de reconhecimento de fala em japonês (CC BY-NC 4.0, baixado do seu repositório no Hugging Face) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Modelo multilíngue de reconhecimento de fala CTC |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Modelo de detecção de atividade de voz |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Modelo de detecção de texto e balões de fala em mangá |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Modelo de detecção de quadros de mangá, treinado com o [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Detecção e reconhecimento de linhas de texto; o rec ajustado para mangá (treinado com o [Manga109-s](http://www.manga109.org/en/download_s.html) e o [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) alimenta o modelo de OCR local CTC por coluna |

> O modelo de detecção de quadros de mangá e o PP-OCRv6_manga são treinados com o conjunto de dados Manga109-s (Matsui et al. 2017; Aizawa et al. 2020), cujos termos exigem que esse uso do conjunto de dados seja indicado de forma clara. O PP-OCRv6_manga (Apache-2.0) é treinado adicionalmente com o conjunto de dados AnimeText, licenciado sob CC BY-NC-SA 4.0; o aplicativo baixa esse modelo do seu repositório no Hugging Face e não o redistribui.

### Fontes de conteúdo e integrações

| Projeto | Descrição |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Ecossistema de extensões de fontes de mangá |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Ecossistema de extensões de fontes de anime (extensions-lib 14–16, hospedadas pelo mesmo runtime) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Runtime de extensões de mangá para desktop (incluído, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Referência de adaptação de extensões do Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Ecossistema de plugins de fontes de light novels |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Servidores de mídia que podem ser navegados a partir da biblioteca de vídeo |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Referência da ponte de legendas de streaming para a extensão de navegador |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Referência de arquitetura para identificação e scraping de anime |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Referência de arquitetura de informação da biblioteca de galgames |
| [AniDB](https://anidb.net) | Identidade de animes, episódios e arquivos |
| [MyAnimeList](https://myanimelist.net) (via [Jikan](https://jikan.moe)) | Metadados de anime |
| [TMDB](https://www.themoviedb.org) | Metadados e imagens complementares |
| [VNDB](https://vndb.org) | Metadados de visual novels |
| [Jimaku](https://jimaku.cc) | Fonte de legendas em japonês |
| [OpenSubtitles](https://www.opensubtitles.com) | Fonte de legendas |

> Este aplicativo usa o TMDB e as APIs do TMDB, mas não é endossado, certificado ou aprovado pelo TMDB.

## Licença

Distribuído sob a Licença Pública Geral GNU v3.0. Consulte [LICENSE](../../LICENSE) para mais detalhes.

## Mantenedor

O Fushi é mantido por [hajisensai](https://github.com/hajisensai). Site: [fushi.moe](https://fushi.moe). Contato: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | **Português** | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
