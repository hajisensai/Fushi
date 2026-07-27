using System.Diagnostics;
using AssetsTools.NET;
using AssetsTools.NET.Extra;

namespace Hibiki.UnityAudioExtract;

internal static class Program
{
    private sealed record Options(
        string Bundle,
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
                    "usage: --bundle <path> --clip <name> --output <wav> " +
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
        return new Options(
            Required("bundle"), clip, Required("output"),
            Required("classdata"), Required("decoder"));
    }

    private static void ExtractRawClip(Options options, string rawPath)
    {
        if (!File.Exists(options.Bundle)) throw new FileNotFoundException("bundle not found", options.Bundle);
        if (!File.Exists(options.ClassData)) throw new FileNotFoundException("classdata.tpk not found", options.ClassData);

        var manager = new AssetsManager();
        manager.LoadClassPackage(options.ClassData);
        BundleFileInstance bundle = manager.LoadBundleFile(options.Bundle, unpackIfPacked: true);
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
                    if (!string.Equals(field["m_Name"].AsString, options.Clip,
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
            $"AudioClip '{options.Clip}' was not found in '{options.Bundle}'");
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
