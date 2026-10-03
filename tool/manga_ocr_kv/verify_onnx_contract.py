#!/usr/bin/env python3
"""Validate the manga-ocr KV-cache release assets before (and after) upload.

Checks, in order:
1. sha256 and byte length of both graphs match model_manifest.json;
2. the ONNX graphs pass onnx.checker and expose exactly the input / output
   names, dtypes and ranks the app feeds (`manga_ocr_kv_recognizer.dart`);
3. optional end-to-end parity against the classic decoder the app already
   ships (mayocream/manga-ocr-onnx `encoder_model.onnx` + `decoder_model.onnx`):
   for a fixed token sequence, the KV graphs stepped one token at a time must
   reproduce the classic decoder's logits at every position, including the
   first step with the [4, 1, 12, 1, 64] zero placeholder past and a beam
   reorder through `beam_idx`.

Usage:
  python verify_onnx_contract.py --dir out/ --manifest model_manifest.json
  python verify_onnx_contract.py --dir out/ --manifest model_manifest.json \\
      --classic-encoder encoder_model.onnx --classic-decoder decoder_model.onnx
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

EXPECTED = {
    'cross_kv.onnx': {
        'inputs': [('encoder_hidden_states', 'float32', 3)],
        'outputs': [('cross_key_values', 'float32', 5)],
    },
    'decoder_kv.onnx': {
        'inputs': [('input_ids', 'int64', 2), ('beam_idx', 'int64', 1),
                   ('past_key_values', 'float32', 5), ('cross_key_values', 'float32', 5)],
        'outputs': [('logits', 'float32', 2), ('present_key_values', 'float32', 5)],
    },
}
TOLERANCE = 1e-3


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def check_assets(directory: Path, manifest: dict) -> None:
    import onnx

    type_names = {1: 'float32', 7: 'int64'}
    for asset in manifest['assets']:
        path = directory / asset['file']
        digest = sha256_of(path)
        if digest != asset['sha256']:
            raise SystemExit(f"{asset['file']}: sha256 {digest} != {asset['sha256']}")
        if path.stat().st_size != asset['bytes']:
            raise SystemExit(f"{asset['file']}: {path.stat().st_size} bytes != {asset['bytes']}")
        graph = onnx.load(str(path))
        onnx.checker.check_model(graph)
        for side in ('inputs', 'outputs'):
            values = graph.graph.input if side == 'inputs' else graph.graph.output
            actual = [(v.name, type_names.get(v.type.tensor_type.elem_type),
                       len(v.type.tensor_type.shape.dim)) for v in values]
            if actual != EXPECTED[asset['file']][side]:
                raise SystemExit(f"{asset['file']} {side}: {actual}")


def check_parity(directory: Path, encoder_path: Path, decoder_path: Path) -> dict:
    import onnxruntime as ort

    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    providers = ['CPUExecutionProvider']
    encoder = ort.InferenceSession(str(encoder_path), options, providers=providers)
    classic = ort.InferenceSession(str(decoder_path), options, providers=providers)
    cross = ort.InferenceSession(str(directory / 'cross_kv.onnx'), options, providers=providers)
    step = ort.InferenceSession(str(directory / 'decoder_kv.onnx'), options, providers=providers)

    y, x = np.mgrid[0:224, 0:224].astype(np.float32)
    plane = np.sin(x / 7.0) * np.cos(y / 11.0)
    pixels = np.stack([plane, plane, plane])[None].astype(np.float32)
    hidden = encoder.run(None, {'pixel_values': pixels})[0]
    cross_kv = cross.run(None, {'encoder_hidden_states': hidden})[0]

    # (source beams, new tokens) per step, the way the app drives beam search:
    # the first step runs one beam on the zero placeholder past, then both
    # beams fork from it, diverge, swap places, and finally both continue the
    # same beam. Each beam's KV logits must equal the classic decoder run on
    # that beam's whole history.
    schedule = [
        ([0], [2]),
        ([0, 0], [1500, 1500]),
        ([0, 1], [77, 13]),
        ([1, 0], [256, 902]),
        ([0, 0], [88, 4410]),
    ]
    worst = 0.0
    past = np.zeros((4, 1, 12, 1, 64), dtype=np.float32)
    histories: list[list[int]] = [[]]
    for sources, tokens in schedule:
        histories = [histories[s] + [t] for s, t in zip(sources, tokens)]
        logits, past = step.run(None, {
            'input_ids': np.array([[t] for t in tokens], dtype=np.int64),
            'beam_idx': np.array(sources, dtype=np.int64),
            'past_key_values': past,
            'cross_key_values': cross_kv,
        })
        for beam, history in enumerate(histories):
            reference = classic.run(None, {
                'input_ids': np.array([history], dtype=np.int64),
                'encoder_hidden_states': hidden,
            })[0][0, -1]
            worst = max(worst, float(np.abs(logits[beam] - reference).max()))
    if worst > TOLERANCE:
        raise SystemExit(f'KV logits differ from the classic decoder by {worst}')
    return {'maxAbsLogitDiff': worst, 'steps': len(schedule)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--dir', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--classic-encoder', type=Path)
    parser.add_argument('--classic-decoder', type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding='utf-8'))
    check_assets(args.dir, manifest)
    result: dict = {'assets': [a['file'] for a in manifest['assets']], 'contract': 'ok'}
    if args.classic_encoder and args.classic_decoder:
        result['parity'] = check_parity(args.dir, args.classic_encoder, args.classic_decoder)
    print(json.dumps(result, indent=1))


if __name__ == '__main__':
    main()
