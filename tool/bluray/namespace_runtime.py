"""Give private libmpv dependencies collision-free Windows module identities.

Same-length names preserve all PE RVAs. Normal/delay imports, export forwarders,
export module names and literal ANSI/UTF-16 LoadLibrary names are rewritten.
The public libmpv-2.dll client/render ABI remains unchanged. Requires pefile.
"""
import hashlib
import json
from pathlib import Path
import re
import pefile


PUBLIC_DLL = "libmpv-2.dll"


def private_names(names):
    names = list(names)
    original = {name.lower() for name in names}
    mapping = {name.lower(): "fbd" + name[3:] for name in names if name.lower() != PUBLIC_DLL}
    result = [name.lower() for name in mapping.values()]
    if len(set(result)) != len(result) or original.intersection(result):
        raise ValueError("Private DLL names collide")
    for old, new in mapping.items():
        if len(old) != len(new) or not new.lower().endswith(".dll"):
            raise ValueError(f"Invalid same-length namespace: {old} -> {new}")
    return mapping


def module_references(path):
    pe = pefile.PE(str(path), fast_load=True)
    try:
        pe.parse_data_directories(directories=[0, 1, 13])
        result = []
        for attr in ("DIRECTORY_ENTRY_IMPORT", "DIRECTORY_ENTRY_DELAY_IMPORT"):
            result.extend(item.dll.decode("ascii") for item in getattr(pe, attr, []))
        exports = getattr(pe, "DIRECTORY_ENTRY_EXPORT", None)
        if exports:
            for symbol in exports.symbols:
                if symbol.forwarder:
                    name = symbol.forwarder.decode("ascii").rsplit(".", 1)[0]
                    result.append(name if name.lower().endswith(".dll") else name + ".dll")
        return sorted(set(result), key=str.lower)
    finally:
        pe.close()


def rewrite_names(data, mapping):
    # Also cover GetModuleHandle/LoadLibrary and export forwarders without the
    # extension. Only complete module tokens are replaced, never function names.
    changed = 0
    def replace_ascii(match):
        nonlocal changed
        original = match.group().decode("ascii")
        replacement = mapping.get(original.lower())
        if replacement:
            changed += 1
            return replacement.encode()
        module, separator, symbol = original.rpartition(".")
        replacement = mapping.get(module.lower() + ".dll") if separator else None
        if replacement:
            changed += 1
            return (replacement[:-4] + "." + symbol).encode()
        return match.group()
    prefixes = b"|".join(re.escape(prefix.encode()) for prefix in sorted({name[:3] for name in mapping}))
    ascii_pattern = rb"(?<![A-Za-z0-9_+.-])(?:" + prefixes + rb")[A-Za-z0-9_+.-]{0,90}\.[A-Za-z0-9_+#@-]{1,120}"
    data = re.sub(ascii_pattern, replace_ascii, data, flags=re.I)
    def replace_wide(match):
        nonlocal changed
        original = match.group().decode("utf-16le")
        replacement = mapping.get(original.lower())
        if replacement:
            changed += 1
            return replacement.encode("utf-16le")
        return match.group()
    wide_pattern = b"|".join(re.escape(name.encode("utf-16le")) for name in mapping)
    data = re.sub(wide_pattern, replace_wide, data, flags=re.I)
    return data, changed


def namespace_runtime(directory):
    paths = sorted(directory.glob("*.dll"), key=lambda path: path.name.lower())
    mapping = private_names(path.name for path in paths)
    records, dynamic = [], []
    all_names = {name.lower() for name in mapping.values()} | {PUBLIC_DLL}
    for source in paths:
        original = source.read_bytes()
        rewritten, changes = rewrite_names(original, mapping)
        pe = pefile.PE(data=rewritten, fast_load=True)
        # Renamed dependencies must bind normally; never retain bound addresses.
        pe.OPTIONAL_HEADER.DATA_DIRECTORY[11].VirtualAddress = 0
        pe.OPTIONAL_HEADER.DATA_DIRECTORY[11].Size = 0
        # A rewritten binary cannot retain a valid Authenticode signature.
        pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].VirtualAddress = 0
        pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].Size = 0
        pe.OPTIONAL_HEADER.CheckSum = pe.generate_checksum()
        target = directory / mapping.get(source.name.lower(), source.name)
        pe.write(str(target))
        pe.close()
        if source != target:
            source.unlink()
        references = module_references(target)
        stale = set(name.lower() for name in references) & mapping.keys()
        if stale:
            raise RuntimeError(f"Unrewritten PE references in {target.name}: {stale}")
        payload = target.read_bytes()
        # Literal dynamic names outside the closure remain explicit in audit
        # output (e.g. system GPU drivers, optional AACS, configured jvm.dll).
        literals = set(re.findall(rb"[A-Za-z0-9_.-]{2,90}\.dll", payload, re.I))
        literals.update(match.replace(b"\0", b"") for match in re.findall(
            rb"(?:[A-Za-z0-9_.-]\x00){2,90}\.\x00d\x00l\x00l\x00", payload, re.I))
        names = sorted({name.decode("ascii").lower() for name in literals})
        if set(names) & mapping.keys():
            raise RuntimeError(f"Unrewritten dynamic references in {target.name}")
        dynamic.append({"name": target.name, "external_literals": [name for name in names if name not in all_names]})
        records.append({"name": target.name, "source_name": source.name,
                        "source_sha256": hashlib.sha256(original).hexdigest(),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                        "bytes": len(payload), "rewritten_references": changes,
                        "imports_and_forwarders": references})
    (directory / "private-dll-map.json").write_text(json.dumps(mapping, indent=2) + "\n")
    (directory / "dynamic-dll-references.json").write_text(json.dumps(dynamic, indent=2) + "\n")
    return records
