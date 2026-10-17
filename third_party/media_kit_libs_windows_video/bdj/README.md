# Windows BD-J optional component

The two libbluray JARs are built from the included, unmodified VideoLAN 1.5.0
source archive. `manifest.json` pins both their hashes and the private x64 Eclipse
Temurin 8u504-b01 JRE ZIP. The JRE is downloaded only when the user installs the
component; it is not a machine Java installation and writes no registry settings,
user environment variables, or system environment variables.

## Installed application contract

The Windows package copies this self-contained directory, including the canonical
`bdj_runtime.ps1`, to `bluray/bdj/` beside the application. The developer command
`tool/bluray/bdj_runtime.ps1` only forwards to this installer. The package additionally
copies `libbluray-j2se-1.5.0.jar` and `libbluray-awt-j2se-1.5.0.jar` beside
`fbdbluray-4.dll`, the privately named native dependency, which discovers its
classpath using its own module address and directory rather than its DLL name.

Invoke the installed script using argument arrays (paths may contain spaces):

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass
  -File <app>/bluray/bdj/bdj_runtime.ps1
  -Bundle <app>/bluray/bdj -Action Install
```

`Probe` never downloads. `Install` downloads about 40 MB, verifies the pinned
SHA-256 before extraction, validates all bundled artifacts and actually starts
the private JVM, then publishes the component using an atomic directory rename.
Existing installations are validated without replacement. `-Archive <zip>`
supports offline installation of exactly the pinned ZIP with the same hash check.
The application downloads and verifies this ZIP through its own proxy-aware
download pipeline and supplies `-Archive`; the installer independently checks
the hash again before extracting. This avoids bypassing the application's proxy.

The application should supply `-StagingDirectory <root-parent>/.bdj-install-<id>`,
where `<id>` is a fresh UUID formatted as 32 lowercase hex digits. The script
requires this directory to be empty or absent, directly beside the final root,
and not a reparse point. On ordinary failure it removes only its own stage and
retains at most 8 KB in `<stage>.error.log`. On cancellation the caller terminates
the installer, awaits process exit, then removes only the explicitly supplied
stage. It must not delete the installed component or another session's stage.
For application launches, also pass `-StartSignal <unique temporary file>`.
The installer waits for that file before probing or starting any Java child.
The application assigns the new PowerShell process to its Windows job first,
then creates the signal; on cancellation it terminates and awaits the whole job
before cleaning its stage and signal. The signal contents are ignored. Missing
signals fail after 60 seconds. Omitting the option preserves direct CLI behavior.
Atomic directory rename rejects an already-existing destination, including
concurrent installations, rather than nesting stages inside an existing root.

The default root is `%LOCALAPPDATA%` joined to
`manifest.runtime.componentRootSuffix` (`Fushi/components/bdj/1.5.0-temurin8u504b01`).
This is also the application's source for its session staging parent.
Success returns exit code 0 and one UTF-8, no-BOM JSON object on stdout:

```json
{
  "ready": true,
  "componentRoot": "<root>",
  "libbluray": "1.5.0",
  "javaHome": "<root>/jdk8u504-b01-jre",
  "classPath": "<root>/libbluray-j2se-1.5.0.jar",
  "jvm": "<root>/jdk8u504-b01-jre/bin/server/jvm.dll",
  "probe": "BDJ_RUNTIME_OK 1.8.0_504-b01"
}
```

Failure returns exit code 1 and an error on stderr. Before opening a BD-J disc,
pass `javaHome` through mpv's `bluray-java-home` option to libbluray's
`BLURAY_PLAYER_JAVA_HOME`. Do not change the host application's `JAVA_HOME` or
`PATH`. The optional script `Run` action is for command-line diagnostics only:
it sets `JAVA_HOME` and `LIBBLURAY_CP` in its own child process environment and
restores them on exit. `LIBBLURAY_CP` must name the full primary JAR, or a directory
ending in a path separator; an ordinary directory without a separator is invalid.

## Build provenance

- VideoLAN source URL and SHA-256: `manifest.json`; exact archive in `source/`.
- JAR license: LGPL 2.1 or later, including `COPYING.libbluray`; the corresponding
  source archive includes notices for the bundled ASM code.
- JRE: Eclipse Temurin portable release, GPLv2 with Classpath Exception. The
  entire distribution including its `LICENSE`, `ASSEMBLY_EXCEPTION` and
  `THIRD_PARTY_README` is preserved at installation.
- Compiler used: Microsoft OpenJDK 21.0.10.7, source/target 8.
- Apache Ant 1.10.15 from Maven Central: `ant-1.10.15.jar` SHA-256
  `763acda4a69588c9ea8817a952851ff0c2fc4bffa1d081c2565dc407f29d5794`;
  `ant-launcher-1.10.15.jar` SHA-256
  `5c8551990307a032336d98ddaed549a39a689f07d4d4c6b950601bf22b3d6a1b`.

Run Ant against the extracted `src/libbluray/bdj/build.xml` with these properties:

```text
-Dsrc_awt=:java-j2se:java-build-support
-Djavac_path=<JDK>/bin/javac.exe
-Djavac_arg=-Xlint:-removal
-Dversion=j2se-1.5.0
-Djava_version_asm=1.8
-Djava_version_bdj=1.8
```

The resulting JARs are in `src/.libs/`. Compile `BdjRuntimeProbe.java` with
`javac -source 8 -target 8`, then package its class into `bdj-runtime-probe.jar`.
After intentional rebuilds, refresh artifact hashes in the manifest. ZIP/JAR
timestamps may differ even when class contents match.

## Verification and limits

```powershell
$env:FUSHI_BDJ_RUNTIME = '<installed component root>'
$env:FUSHI_BDJ_DLL = '<native bundle>/fbdbluray-4.dll'
$env:FUSHI_BDJ_ARCHIVE = '<downloaded pinned ZIP>'
python -m unittest tool.bluray.test_bdj_runtime -v
```

The optional native test creates its own unencrypted BD-J first-play title and
BDJO with no applications. It starts libbluray through ctypes, selects the private
JVM through the native per-player setting, initializes JNI and the libbluray AWT
window, and checks the asynchronous initialization-complete log before shutdown.
It does not prove commercial-disc Xlet behavior, graphics rendering through mpv,
video navigation, or AACS/BD+ decryption. Those require separate player fixtures.
Java is shared within a process; this component does not make simultaneous BD-J
virtual machines possible.
