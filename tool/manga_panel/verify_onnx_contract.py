#!/usr/bin/env python3
"""Validate the immutable panel detector ONNX contract and digest."""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    import onnx
    import onnxruntime as ort
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    digest = hashlib.sha256(args.model.read_bytes()).hexdigest()
    if digest != manifest["sha256"]:
        raise SystemExit(f"sha256 mismatch: {digest} != {manifest['sha256']}")
    if args.model.stat().st_size != manifest["bytes"]:
        raise SystemExit("model byte length does not match manifest")
    graph = onnx.load(str(args.model))
    onnx.checker.check_model(graph)
    session = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    inp = session.get_inputs()
    if len(inp) != 1 or inp[0].shape != [1, 3, 640, 640]:
        raise SystemExit(f"unexpected input shape: {[x.shape for x in inp]}")
    outputs = session.get_outputs()
    if len(outputs) != 1 or outputs[0].shape != [1, 300, 6]:
        raise SystemExit(f"unexpected output shape: {[x.shape for x in outputs]}")
    print(json.dumps({"sha256": digest, "bytes": args.model.stat().st_size,
                      "input": inp[0].shape, "output": outputs[0].shape}))


if __name__ == "__main__":
    main()
