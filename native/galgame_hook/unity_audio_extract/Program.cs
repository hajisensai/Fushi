using System.Diagnostics;
using AssetsTools.NET;
using AssetsTools.NET.Extra;

namespace Fushi.UnityAudioExtract;

internal static class Program
{
    private sealed record Options(
        string? Bundle,
        string? DataDirectory,
        string Clip,
        string Output,
        string ClassData,
        string Decoder);

    public static int Main(string[] args)
    {
        try
        {
            Options options = Parse(args);
            string rawPath = Path.Combine(
                Path.GetTempPath(),
                $"hibiki_unity_{Environment.ProcessId}_{Guid.NewGuid():N}.fsb");
            try
            {
                ExtractRawClip(options, rawPath);
                Decode(options.Decoder, rawPath, options.Output);
            }
            finally
            {
                try
                {
                    File.Delete(rawPath);
                }
                catch
                {
                    // Temporary cleanup is best-effort; extraction result is already durable.
                }
            }
            Console.WriteLine($"OK clip={options.Clip} output={options.Output}");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"unity_audio_extract: {ex.Message}");
            return 2;
        }
    }

    private static Options Parse(string[] args)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < args.Length; i++)
        {
            if (!args[i].StartsWith("--", StringComparison.Ordinal) || i + 1 >= args.Length)
            {
                throw new ArgumentException(
                    "usage: (--bundle <path> | --data-dir <path>) " +
                    "--clip <name> --output <wav> " +
                    "--classdata <classdata.tpk> --decoder <vgmstream-cli.exe>");
            }
            values[args[i][2..]] = args[++i];
        }

        string Required(string name)
        {
            if (!values.TryGetValue(name, out string? value) || string.IsNullOrWhiteSpace(value))
            {
                throw new ArgumentException($"missing --{name}");
            }
            return Path.GetFullPath(value);
        }

        string clip = values.TryGetValue("clip", out string? clipName) ? clipName : string.Empty;
        if (string.IsNullOrWhiteSpace(clip))
        {
            throw new ArgumentException("missing --clip");
        }
        string? bundle = values.TryGetValue("bundle", out string? bundlePath) &&
                         !string.IsNullOrWhiteSpace(bundlePath)
            ? Path.GetFullPath(bundlePath)
            : null;
        string? dataDirectory =
            values.TryGetValue("data-dir", out string? dataPath) &&
            !string.IsNullOrWhiteSpace(dataPath)
                ? Path.GetFullPath(dataPath)
                : null;
        if ((bundle is null) == (dataDirectory is null))
        {
            throw new ArgumentException(
                "exactly one of --bundle or --data-dir is required");
        }
        return new Options(
            bundle, dataDirectory, clip, Required("output"),
            Required("classdata"), Required("decoder"));
    }

    private static void ExtractRawClip(Options options, string rawPath)
    {
        if (!File.Exists(options.ClassData)) throw new FileNotFoundException("classdata.tpk not found", options.ClassData);

        var manager = new AssetsManager();
        manager.LoadClassPackage(options.ClassData);
        if (options.Bundle is not null)
        {
            ExtractFromBundle(manager, options.Bundle, options.Clip, rawPath);
        }
        else
        {
            ExtractFromLooseAssets(
                manager, options.DataDirectory!, options.Clip, rawPath);
        }
    }

    private static void ExtractFromBundle(
        AssetsManager manager, string bundlePath, string clip, string rawPath)
    {
        if (!File.Exists(bundlePath))
        {
            throw new FileNotFoundException("bundle not found", bundlePath);
        }
        BundleFileInstance bundle =
            manager.LoadBundleFile(bundlePath, unpackIfPacked: true);
        try
        {
            int directoryCount = bundle.file.BlockAndDirInfo.DirectoryInfos.Count;
            for (int i = 0; i < directoryCount; i++)
            {
                AssetsFileInstance? assets = manager.LoadAssetsFileFromBundle(bundle, i);
                if (assets is null) continue;
                manager.LoadClassDatabaseFromPackage(assets.file.Metadata.UnityVersion);

                foreach (AssetFileInfo info in assets.file.GetAssetsOfType(AssetClassID.AudioClip))
                {
                    AssetTypeValueField field = manager.GetBaseField(assets, info);
                    if (!string.Equals(field["m_Name"].AsString, clip,
                                       StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    AssetTypeValueField resource = field["m_Resource"];
                    string source = resource["m_Source"].AsString;
                    long offset = resource["m_Offset"].AsLong;
                    long size = resource["m_Size"].AsLong;
                    if (size <= 0 || size > int.MaxValue)
                    {
                        throw new InvalidDataException($"invalid AudioClip resource size {size}");
                    }

                    string resourceName = Path.GetFileName(source.Replace('\\', '/'));
                    AssetBundleDirectoryInfo? resourceInfo =
                        BundleHelper.GetDirInfo(bundle.file, resourceName);
                    if (resourceInfo is null)
                    {
                        throw new InvalidDataException(
                            $"resource node '{resourceName}' not found in bundle");
                    }
                    if (offset < 0 || offset + size > resourceInfo.DecompressedSize)
                    {
                        throw new InvalidDataException(
                            $"AudioClip range {offset}+{size} exceeds resource node");
                    }

                    lock (bundle.file.DataReader)
                    {
                        bundle.file.DataReader.Position = resourceInfo.Offset + offset;
                        File.WriteAllBytes(rawPath, bundle.file.DataReader.ReadBytes((int)size));
                    }
                    return;
                }
            }
        }
        finally
        {
            manager.UnloadAll();
        }
        throw new KeyNotFoundException(
            $"AudioClip '{clip}' was not found in '{bundlePath}'");
    }

    private static void ExtractFromLooseAssets(
        AssetsManager manager, string dataDirectory, string clip,
        string rawPath)
    {
        if (!Directory.Exists(dataDirectory))
        {
            throw new DirectoryNotFoundException(
                $"Unity data directory not found: {dataDirectory}");
        }
        var candidates = new List<string>
        {
            Path.Combine(dataDirectory, "resources.assets"),
            Path.Combine(dataDirectory, "globalgamemanagers"),
            Path.Combine(dataDirectory, "globalgamemanagers.assets"),
        };
        candidates.AddRange(
            Directory.EnumerateFiles(
                dataDirectory, "sharedassets*.assets",
                SearchOption.TopDirectoryOnly));

        try
        {
            foreach (string assetsPath in candidates.Distinct(
                         StringComparer.OrdinalIgnoreCase))
            {
                if (!File.Exists(assetsPath)) continue;
                AssetsFileInstance assets;
                try
                {
                    assets = manager.LoadAssetsFile(
                        assetsPath, loadDeps: false);
                    manager.LoadClassDatabaseFromPackage(
                        assets.file.Metadata.UnityVersion);
                }
                catch
                {
                    continue;
                }

                foreach (AssetFileInfo info in
                         assets.file.GetAssetsOfType(AssetClassID.AudioClip))
                {
                    AssetTypeValueField field =
                        manager.GetBaseField(assets, info);
                    if (!string.Equals(
                            field["m_Name"].AsString, clip,
                            StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }
                    AssetTypeValueField resource = field["m_Resource"];
                    string source = resource["m_Source"].AsString;
                    long offset = resource["m_Offset"].AsLong;
                    long size = resource["m_Size"].AsLong;
                    if (size <= 0 || size > int.MaxValue)
                    {
                        throw new InvalidDataException(
                            $"invalid AudioClip resource size {size}");
                    }
                    string resourceName =
                        Path.GetFileName(source.Replace('\\', '/'));
                    string resourcePath =
                        Path.Combine(dataDirectory, resourceName);
                    if (!File.Exists(resourcePath))
                    {
                        throw new FileNotFoundException(
                            $"AudioClip resource '{resourceName}' not found",
                            resourcePath);
                    }
                    using var stream = File.Open(
                        resourcePath, FileMode.Open, FileAccess.Read,
                        FileShare.ReadWrite);
                    if (offset < 0 || offset + size > stream.Length)
                    {
                        throw new InvalidDataException(
                            $"AudioClip range {offset}+{size} exceeds " +
                            $"'{resourceName}'");
                    }
                    stream.Position = offset;
                    byte[] bytes = new byte[(int)size];
                    stream.ReadExactly(bytes);
                    File.WriteAllBytes(rawPath, bytes);
                    return;
                }
            }
        }
        finally
        {
            manager.UnloadAll();
        }
        throw new KeyNotFoundException(
            $"AudioClip '{clip}' was not found in loose assets under " +
            $"'{dataDirectory}'");
    }

    private static void Decode(string decoder, string rawPath, string outputPath)
    {
        if (!File.Exists(decoder)) throw new FileNotFoundException("vgmstream decoder not found", decoder);
        Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
        var startInfo = new ProcessStartInfo(decoder)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.ArgumentList.Add("-o");
        startInfo.ArgumentList.Add(outputPath);
        startInfo.ArgumentList.Add(rawPath);
        using Process process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("failed to launch vgmstream decoder");
        string stdout = process.StandardOutput.ReadToEnd();
        string stderr = process.StandardError.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0 || !File.Exists(outputPath) || new FileInfo(outputPath).Length <= 44)
        {
            throw new InvalidOperationException(
                $"vgmstream failed ({process.ExitCode}): {stderr}{stdout}");
        }
    }
}
