<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo de Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | **Español** | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Descargar la última versión](https://img.shields.io/badge/%E2%AC%87%20Descargar%20la%20%C3%BAltima%20versi%C3%B3n-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Únete a Discord](https://img.shields.io/badge/%C3%9Anete%20a%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Compatibilidad de plataformas

| Plataforma | Estado | Notas |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) o posterior |
| Windows | ✅ | El hooking de texto y voz de galgames solo está disponible en Windows |
| macOS | ✅ | Solo Apple Silicon; los Mac con Intel no son compatibles |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Sin descubrimiento, fuentes en línea ni centro de descargas (directrices de la App Store) |
| Linux | 🔧 Compilar desde el código fuente | Aún no hay versión precompilada; el lector EPUB necesita WPE WebKit |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Host sin interfaz para Linux / Windows / macOS con interfaz web — consulta [packages/fushi_server](../../packages/fushi_server/README.md) |

**Sistema de diseño** — todas las plataformas usan por defecto **Material 3 Expressive**; se puede elegir un sistema de diseño **Cupertino** (estilo Apple) en *Configuración › Apariencia › Sistema de diseño*; con Cupertino, el fondo de la ventana usa Mica en Windows 11 y vibrancy en macOS (salvo que esté activado el ajuste del sistema de reducir la transparencia o de alto contraste).

> Los idiomas disponibles para la búsqueda en diccionarios los determinan los diccionarios importados y las tablas de transformación de Yomitan, con independencia del idioma de la interfaz. Las actualizaciones de iOS llegan por TestFlight unos días más tarde que en las demás plataformas.

### Idiomas de interfaz (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Instalación

Descarga la última versión desde el [sitio web de Fushi](https://fushi.moe/): hay disponibles el APK de Android, el instalador de Windows y las compilaciones de macOS (solo Apple Silicon; los Mac con Intel no son compatibles); iOS se instala mediante [TestFlight](https://testflight.apple.com/join/j88d69jx). Linux aún no tiene una versión precompilada de la aplicación; compílala desde el código fuente. Fushi Server, el servidor sin interfaz, se publica por separado en [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> Requiere Android 7.0 (API 24) o superior.

## Compilación

Preparación con un solo comando (`flutter pub get` + aplicar parches), luego compila:

```bash
# Desde la raíz del repositorio
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Escritorio
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Servidor sin interfaz (desde packages/fushi_server; usa `dart build cli`, no `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` agrupan `flutter pub get` y `ci/apply-patches.sh` en un único comando. Este proyecto está fijado a Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`); las versiones anteriores de Flutter no pueden compilarlo porque Material y Cupertino se consumen como los paquetes `material_ui` / `cupertino_ui`. Algunas dependencias upstream están incluidas en `third_party/` o parcheadas por `ci/apply-patches.sh`; consulta [docs/agent/build.md](../agent/build.md) para más detalles, incluidas las dependencias de compilación del escritorio Linux.

<details>
<summary><b>Pila tecnológica</b></summary>

| Capa | Tecnología |
|---|---|
| Framework | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Plataformas | Android / Windows / macOS / iOS / Linux, más un servidor sin interfaz |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Lector | Motor de paginación WebView (derivado de la familia Hoshi Reader) |
| Vídeo | media_kit (libmpv core) + libplacebo |
| Almacenamiento | Drift (SQLite, WAL) + fushidicts (motor de diccionarios FFI en C++) |
| PLN | Tablas de transformación de Yomitan (lematización multilingüe) + kana_kit (conversión de kana); tokenización mediante fushidicts FFI |
| IA en el dispositivo | ONNX Runtime para reconocimiento de voz (generación de subtítulos) y OCR de manga; los algoritmos residen en [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Descargas | libtorrent 2.x mediante un puente FFI con C-ABI (qBittorrent externo como alternativa) |
| Sincronización | Backends en la nube + Fushi Interconnect (LAN, direcciones remotas y un túnel P2P iroh) |
| Motor compartido | `fushi_engine`: núcleo en Dart puro compartido por la aplicación y Fushi Server |
| Creación de tarjetas | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 idiomas) |

</details>

<details>
<summary><b>Estructura del proyecto</b></summary>

```
Fushi/                      # Raíz del repositorio (espacio de trabajo Melos: fushi_workspace)
├── fushi/                  # Directorio principal de la aplicación Flutter
│   ├── lib/
│   │   ├── i18n/            # Internacionalización (17 idiomas, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Páginas (páginas de biblioteca, lector, reproductor de vídeo, ajustes, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS del WebView del lector
│   │   │   ├── media/       # Libros, manga, vídeo, audiolibros, fuentes en línea
│   │   │   ├── lookup/      # Ventanas emergentes y superposiciones de búsqueda en diccionarios
│   │   │   ├── mining/      # Creación de tarjetas (incl. minería de galgames)
│   │   │   ├── sync/        # Sincronización en la nube, Interconnect, servidores multimedia
│   │   │   └── models/      # Modelos de datos y gestión de estado (AppModel)
│   │   └── main.dart
│   └── android/             # Proyecto Android
├── packages/                # Paquetes Dart
│   ├── fushi_core/          #   Esquema de la base de datos, preferencias
│   ├── fushi_engine/        #   Motor en Dart puro compartido con el servidor
│   ├── fushi_server/        #   CLI del servidor sin interfaz + interfaz web
│   ├── fushi_cli/           #   Cliente de línea de comandos para escritorio
│   ├── fushi_dictionary/    #   Bindings del motor de diccionarios e importadores
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # Bindings FFI de libtorrent / iroh
│   └── …                    #   Forks incluidos (inappwebview Windows/Linux, gamepads)
├── native/                  # Fuentes nativas: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Recolector de registros y backends del ranking (se despliegan por separado)
├── tools/browser-extension/ # Extensión de navegador para búsquedas en diccionarios
├── third_party/             # Paquetes parcheados incluidos (dependency_overrides)
├── ci/                      # Parches de compilación y scripts de CI
├── tool/                    # Scripts bootstrap / setup_worktree / seguimiento de errores
└── docs/                    # Documentación de desarrollo (incl. manual de operaciones docs/agent/)
```

</details>

La importación de vídeo permite agrupar por obra o por carpeta. Consulta el [flujo de trabajo de vídeo](../specs/2026-09-07-video-library-workflow.md) y los [metadatos de MAL/TMDB con hash de archivos de AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md) para la coincidencia y las tareas en segundo plano.

La [configuración opcional de servicios en línea](../specs/2026-09-07-online-services-setup.md) explica las identidades de aplicación incluidas, las credenciales personales y el recordatorio descartable de configuración de vídeo.

## Privacidad y datos

Fushi almacena los libros importados, diccionarios, fuentes, datos de audiolibros, vídeos, progreso de lectura, resaltados, estadísticas y ajustes en el almacenamiento local de la aplicación.

- **Sincronización** — Google Drive / OneDrive / Dropbox usan inicio de sesión OAuth; WebDAV / FTP / SFTP / Fushi Server usan la dirección del servidor y las credenciales que proporcionas. Fushi Interconnect conecta directamente los dispositivos emparejados (LAN, IPv6, redes superpuestas o direcciones públicas) y, cuando no hay ninguna ruta directa, recurre a un túnel P2P iroh de extremo a extremo; los enlaces de emparejamiento siempre piden confirmación.
- **Anki** — la creación de tarjetas se comunica con AnkiDroid o con la dirección de AnkiConnect que configures.
- **Estadísticas de uso** — una vez al día, las compilaciones de escritorio y Android envían a fushi.moe un ID de instalación aleatorio, la versión de la aplicación, la plataforma y el canal de actualización para contar los usuarios activos; no se incluye ninguna cuenta, biblioteca ni dato de lectura, y no se almacenan direcciones IP. Desactívalo con *Compartir estadísticas de uso* en los ajustes de actualización. Las compilaciones de iOS no las envían.
- **Solo cuando lo pides** — la subida de registros (tras un aviso de consentimiento único), los comentarios dentro de la aplicación y el ranking (desactivado por defecto; sube los títulos de tu biblioteca y tu progreso solo después de que lo actives).
- **OCR de manga** — el motor por defecto es Google Lens, que envía la imagen de la página a Google; cambia al modelo en el dispositivo o al OCR del sistema en los ajustes para mantener las imágenes en local.
- **Funciones de IA** — las solicitudes van únicamente al proveedor de LLM que configures y asignes a una función; si no hay ningún proveedor asignado, no se envía nada.
- **Servicios de terceros** — las funciones de metadatos, subtítulos y fuentes en línea contactan con los servicios enumerados en [Fuentes de contenido e integraciones](#fuentes-de-contenido-e-integraciones) solo cuando las usas.

## Actividad de desarrollo

[![Actividad de desarrollo](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

El trabajo diario se integra en `develop`; `main` solo recibe las fusiones de lanzamiento. El gráfico se muestra aquí en `main`, pero se genera a partir de `develop`, por lo que refleja el desarrollo real y no el tráfico de fusiones.

Los tres carriles son los canales de actualización que ofrece la propia aplicación, y cada uno está escalado a su propio máximo: las compilaciones debug superan a las versiones estables en dos órdenes de magnitud, así que una escala común dejaría los otros dos carriles reducidos a nada.

| Carril | Qué cuenta | Cómo obtenerlo |
|---|---|---|
| **Debug (continuo)** | Compilaciones correctas por push de [release.yml](../../.github/workflows/release.yml) | Prelanzamiento continuo, republicado en cada push |
| **Beta** | Prelanzamientos `v<version>-beta.<seq>` | Compilación de prueba lanzada manualmente |
| **Estable** | Versiones `v<version>` | Última versión |

> El gráfico anterior se genera dentro de este repositorio (sin servicios de terceros) y lo actualiza a diario el workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml).

## Historial de estrellas

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star History](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> El gráfico anterior se genera dentro de este repositorio (sin servicios de terceros) y lo actualiza a diario el workflow [Update Star History](../../.github/workflows/star-history.yml).

## Agradecimientos

Fushi se apoya en los siguientes proyectos y ecosistema:

### Herramientas de aprendizaje y referencias previas

| Proyecto | Descripción |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Herramienta de aprendizaje inmersivo de japonés |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lector de japonés para iOS; referencia del motor de paginación del lector |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lector de japonés nativo para Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motor de diccionarios en C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solución de sincronización de audiolibros |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Algoritmo de alineación temporal de subtítulos respecto a una referencia (GPL-3.0); base para alinear automáticamente los subtítulos descargados con las pistas incrustadas |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referencia de formato de diccionario, tablas de transformación y experiencia de búsqueda |
| [Lapis](https://github.com/donkuri/lapis) | Tipo de nota de Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Integración de creación de tarjetas en Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referencia de audio local e interacción con AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referencia de compatibilidad de lector, estadísticas y sincronización |
| [media_kit](https://github.com/media-kit/media-kit) | Framework de reproducción de vídeo de Flutter (núcleo libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Suite de aprendizaje inmersivo de idiomas para macOS |

### Motores y componentes nativos

| Proyecto | Descripción |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Motor de hooking de texto para galgames (DLL incluidas, cargadas por el inyector) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Biblioteca de inline hooking usada por el inyector de galgames |
| [libtorrent](https://github.com/arvidn/libtorrent) | Motor de descargas torrent integrado |
| [mpv](https://github.com/mpv-player/mpv) | Núcleo de reproducción libmpv detrás de media_kit |
| [FFmpeg](https://ffmpeg.org) | Análisis de medios, recortes y extracción de audio |
| [libplacebo](https://github.com/haasn/libplacebo) | Shaders de vídeo por GPU y mapeo de tonos HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Motor WebView que renderiza el lector EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Inferencia en el dispositivo para reconocimiento de voz y OCR |
| [iroh](https://github.com/n0-computer/iroh) | Túnel P2P para las conexiones remotas de Fushi Interconnect |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Dependencias del motor de diccionarios |

### Modelos en el dispositivo

| Proyecto | Descripción |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Paquetes de modelos Zipformer de reconocimiento de voz y compilaciones de VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Modelo de reconocimiento de voz en japonés |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Modelo de reconocimiento de voz en japonés |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Modelo de reconocimiento de voz en japonés (CC BY-NC 4.0, se descarga desde su repositorio de Hugging Face) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Modelo multilingüe de reconocimiento de voz CTC |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Modelo de detección de actividad de voz |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Modelo de detección de texto y bocadillos en manga |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Modelo de detección de viñetas de manga, entrenado con [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Detección y reconocimiento de líneas de texto; el rec ajustado a manga (entrenado con [Manga109-s](http://www.manga109.org/en/download_s.html) y [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) impulsa el modelo de OCR local CTC por columna |

> El modelo de detección de viñetas de manga y PP-OCRv6_manga se entrenan con el conjunto de datos Manga109-s (Matsui et al. 2017; Aizawa et al. 2020), cuyos términos exigen indicar claramente este uso del conjunto de datos. PP-OCRv6_manga (Apache-2.0) se entrena además con el conjunto de datos AnimeText, que tiene licencia CC BY-NC-SA 4.0; la aplicación descarga ese modelo desde su repositorio de Hugging Face y no lo redistribuye.

### Fuentes de contenido e integraciones

| Proyecto | Descripción |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Ecosistema de extensiones de fuentes de manga |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Ecosistema de extensiones de fuentes de anime (extensions-lib 14–16, alojadas por el mismo runtime) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Runtime de extensiones de manga para escritorio (incluido, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Referencia de adaptación de extensiones de Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Ecosistema de plugins de fuentes de novelas ligeras |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Servidores multimedia que se pueden explorar desde la biblioteca de vídeo |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Referencia del puente de subtítulos en streaming para la extensión de navegador |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Referencia de arquitectura para identificación y scraping de anime |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Referencia de arquitectura de información de la biblioteca de galgames |
| [AniDB](https://anidb.net) | Identidad de anime, episodios y archivos |
| [MyAnimeList](https://myanimelist.net) (mediante [Jikan](https://jikan.moe)) | Metadatos de anime |
| [TMDB](https://www.themoviedb.org) | Metadatos e imágenes complementarios |
| [VNDB](https://vndb.org) | Metadatos de novelas visuales |
| [Jimaku](https://jimaku.cc) | Fuente de subtítulos en japonés |
| [OpenSubtitles](https://www.opensubtitles.com) | Fuente de subtítulos |

> Esta aplicación utiliza TMDB y las APIs de TMDB pero no está respaldada, certificada ni aprobada por TMDB.

## Licencia

Distribuido bajo la Licencia Pública General de GNU v3.0. Consulta [LICENSE](../../LICENSE) para más detalles.

## Mantenedor

Fushi está mantenido por [hajisensai](https://github.com/hajisensai). Sitio web: [fushi.moe](https://fushi.moe). Contacto: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | **Español** | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
