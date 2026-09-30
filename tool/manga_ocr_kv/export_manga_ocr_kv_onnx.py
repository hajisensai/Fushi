#!/usr/bin/env python3
"""Export the manga-ocr KV-cache decoder graphs used by the OCR speed-up pack.

Produces two fp32, opset-17 graphs that only use standard ai.onnx operators:

  cross_kv.onnx
    encoder_hidden_states [Bc, S, 768] float32
      -> cross_key_values [4, Bc, 12, S, 64] float32
    The cross-attention K/V of both decoder layers (order K0, V0, K1, V1).
    Run once per text block.

  decoder_kv.onnx
    input_ids [B, 1] int64, beam_idx [B] int64,
    past_key_values [4, Bp, 12, P, 64] float32 (P >= 1, slot 0 is a placeholder),
    cross_key_values [4, Bc, 12, S, 64] float32 (Bc = 1, broadcast to B)
      -> logits [B, 6144] float32 (last position only),
         present_key_values [4, B, 12, P + 1, 64] float32

Design:
- Beam reordering happens inside the graph: past = Gather(past_key_values,
  beam_idx, axis=1), so the caller never copies the cache (HF `_reorder_cache`).
- Slot 0 of the past is a placeholder so the first step never feeds a
  zero-length tensor: attention only reads past[..., 1:, :] plus the new K/V,
  and the position index is P - 1. This is a slice, not a mask, so it is
  mathematically identical to decoding without the placeholder. present keeps
  slot 0 so it can be fed back as the next past unchanged.
- Attention follows HF BertSelfAttention (eager): softmax(q k^T / 8) v.
- The LM head runs on [B, 768] and shares the word-embedding initializer.

The encoder is not exported here: the app keeps using `encoder_model.onnx` from
mayocream/manga-ocr-onnx, whose output is the `encoder_hidden_states` input.

Usage:
  python export_manga_ocr_kv_onnx.py --out out/
  python export_manga_ocr_kv_onnx.py --out out/ --verify-only

Needs torch, transformers, onnx, onnxruntime, numpy. The exported bytes depend
on the torch / transformers versions; the release asset was produced with
torch 2.5.1+cpu and transformers 4.46.3 (recorded in export_report.json).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

import numpy as np
import torch
import torch.nn as nn

SOURCE_REPO = 'kha-white/manga-ocr-base'
SOURCE_REVISION = 'aa6573bd10b0d446cbf622e29c3e084914df9741'
OPSET = 17
HEADS = 12
HEAD_DIM = 64
HIDDEN = 768
ENCODER_TOKENS = 197


def split_heads(x: torch.Tensor) -> torch.Tensor:
    """HF transpose_for_scores: [b, t, 768] -> [b, 12, t, 64]."""
    return x.view(x.size(0), x.size(1), HEADS, HEAD_DIM).permute(0, 2, 1, 3)


def attend(q: torch.Tensor, k: torch.Tensor, v: torch.Tensor) -> torch.Tensor:
    """HF BertSelfAttention eager: softmax(q k^T / sqrt(64)) v -> [b, t, 768]."""
    scores = torch.matmul(q, k.transpose(-1, -2)) / 8.0
    probs = torch.softmax(scores, dim=-1)
    ctx = torch.matmul(probs, v).permute(0, 2, 1, 3).contiguous()
    return ctx.view(ctx.size(0), ctx.size(1), HIDDEN)


class CrossKV(nn.Module):
    def __init__(self, decoder: nn.Module) -> None:
        super().__init__()
        self.layers = decoder.bert.encoder.layer

    def forward(self, encoder_hidden_states: torch.Tensor) -> torch.Tensor:
        outs = []
        for layer in self.layers:
            attention = layer.crossattention.self
            outs.append(split_heads(attention.key(encoder_hidden_states)))
            outs.append(split_heads(attention.value(encoder_hidden_states)))
        return torch.stack(outs, dim=0)


class DecoderStep(nn.Module):
    def __init__(self, decoder: nn.Module) -> None:
        super().__init__()
        embeddings = decoder.bert.embeddings
        self.word = embeddings.word_embeddings
        self.pos_weight = embeddings.position_embeddings.weight
        # token_type_ids are all zero during decoding: only row 0 is used.
        # Attribute names become initializer names: keep them as released.
        self.type_row0 = embeddings.token_type_embeddings.weight
        self.ln = embeddings.LayerNorm
        self.layers = decoder.bert.encoder.layer
        self.cls = decoder.cls

    def forward(self, input_ids, beam_idx, past_key_values, cross_key_values):
        past = torch.index_select(past_key_values, 1, beam_idx)  # [4, B, 12, P, 64]
        past_length = torch._shape_as_tensor(past)[3]  # includes placeholder slot 0
        position = (past_length - 1).view(1)
        x = self.word(input_ids) + self.type_row0[0]
        x = x + torch.index_select(self.pos_weight, 0, position)
        h = self.ln(x)
        new_kv = []
        for index, layer in enumerate(self.layers):
            attention = layer.attention.self
            q = split_heads(attention.query(h))
            k = split_heads(attention.key(h))
            v = split_heads(attention.value(h))
            k_all = torch.cat([past[2 * index, :, :, 1:, :], k], dim=2)
            v_all = torch.cat([past[2 * index + 1, :, :, 1:, :], v], dim=2)
            h = layer.attention.output(attend(q, k_all, v_all), h)
            cross = layer.crossattention.self
            q2 = split_heads(cross.query(h))
            h = layer.crossattention.output(
                attend(q2, cross_key_values[2 * index], cross_key_values[2 * index + 1]), h)
            h = layer.output(layer.intermediate(h), h)
            new_kv += [k, v]
        logits = self.cls(h[:, 0, :])  # [B, 6144]
        present = torch.cat([past, torch.stack(new_kv, dim=0)], dim=3)
        return logits, present


def load_model(revision: str) -> nn.Module:
    from transformers import VisionEncoderDecoderModel

    model = VisionEncoderDecoderModel.from_pretrained(
        SOURCE_REPO, revision=revision, attn_implementation='eager')
    model.eval()
    return model


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b''):
            digest.update(chunk)
    return digest.hexdigest()


def export(model: nn.Module, out_dir: str) -> None:
    os.makedirs(out_dir, exist_ok=True)
    cross = CrossKV(model.decoder).eval()
    step = DecoderStep(model.decoder).eval()
    encoder_states = torch.randn(1, ENCODER_TOKENS, HIDDEN)
    with torch.no_grad():
        torch.onnx.export(
            cross, (encoder_states,), os.path.join(out_dir, 'cross_kv.onnx'),
            input_names=['encoder_hidden_states'], output_names=['cross_key_values'],
            dynamic_axes={
                'encoder_hidden_states': {0: 'cross_batch', 1: 'encoder_sequence_length'},
                'cross_key_values': {1: 'cross_batch', 3: 'encoder_sequence_length'},
            },
            opset_version=OPSET, do_constant_folding=True, dynamo=False)
        beams, past_length = 4, 3
        ids = torch.randint(5, 6000, (beams, 1), dtype=torch.long)
        beam_idx = torch.tensor([1, 0, 3, 1], dtype=torch.long)
        past = torch.randn(4, beams, HEADS, past_length, HEAD_DIM)
        cross_kv = torch.randn(4, 1, HEADS, ENCODER_TOKENS, HEAD_DIM)
        torch.onnx.export(
            step, (ids, beam_idx, past, cross_kv), os.path.join(out_dir, 'decoder_kv.onnx'),
            input_names=['input_ids', 'beam_idx', 'past_key_values', 'cross_key_values'],
            output_names=['logits', 'present_key_values'],
            dynamic_axes={
                'input_ids': {0: 'beams'},
                'beam_idx': {0: 'beams'},
                'past_key_values': {1: 'past_beams', 3: 'past_length'},
                'cross_key_values': {1: 'cross_batch', 3: 'encoder_sequence_length'},
                'logits': {0: 'beams'},
                'present_key_values': {1: 'beams', 3: 'present_length'},
            },
            opset_version=OPSET, do_constant_folding=True, dynamo=False)


def describe(path: str) -> dict:
    import onnx

    graph = onnx.load(path)
    onnx.checker.check_model(graph)
    type_names = {1: 'float32', 7: 'int64'}

    def io(value) -> dict:
        tensor = value.type.tensor_type
        return {
            'name': value.name,
            'dtype': type_names.get(tensor.elem_type, str(tensor.elem_type)),
            'shape': [d.dim_param or d.dim_value for d in tensor.shape.dim],
        }

    domains = sorted({node.domain or 'ai.onnx' for node in graph.graph.node})
    return {
        'file': os.path.basename(path),
        'bytes': os.path.getsize(path),
        'sha256': sha256_of(path),
        'opset': [(o.domain or 'ai.onnx', o.version) for o in graph.opset_import],
        'operatorDomains': domains,
        'inputs': [io(v) for v in graph.graph.input],
        'outputs': [io(v) for v in graph.graph.output],
    }


def synthetic_pixels() -> torch.Tensor:
    """A deterministic, text-free 224x224 input in the model's [-1, 1] range.

    The decoder parity checks below only need *some* realistic encoder output;
    they compare two implementations of the same decoder on it.
    """
    y, x = np.mgrid[0:224, 0:224].astype(np.float32)
    plane = np.sin(x / 7.0) * np.cos(y / 11.0)
    return torch.from_numpy(np.stack([plane, plane, plane])[None])


def verify(model: nn.Module, out_dir: str) -> dict:
    """(1) wrapper modules vs HF decoder; (2) ONNX graphs vs wrapper modules."""
    import onnxruntime as ort

    decoder = model.decoder
    step = DecoderStep(decoder).eval()
    cross = CrossKV(decoder).eval()
    report: dict = {}
    with torch.no_grad():
        encoder_states = model.encoder(pixel_values=synthetic_pixels()).last_hidden_state
        report['encoderSequenceLength'] = int(encoder_states.shape[1])
        sequence = [2, 1500, 77, 902, 4410, 13, 256]
        full = decoder(input_ids=torch.tensor([sequence]), encoder_hidden_states=encoder_states,
                       use_cache=False).logits[0]
        cross_kv = cross(encoder_states)
        past = torch.zeros(4, 1, HEADS, 1, HEAD_DIM)
        diffs = []
        for position, token in enumerate(sequence):
            logits, past = step(torch.tensor([[token]]), torch.tensor([0]), past, cross_kv)
            diffs.append(float((logits[0] - full[position]).abs().max()))
        report['torchStepVsHfFullMaxAbs'] = max(diffs)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    cross_session = ort.InferenceSession(
        os.path.join(out_dir, 'cross_kv.onnx'), options, providers=['CPUExecutionProvider'])
    step_session = ort.InferenceSession(
        os.path.join(out_dir, 'decoder_kv.onnx'), options, providers=['CPUExecutionProvider'])
    cross_onnx = cross_session.run(None, {'encoder_hidden_states': encoder_states.numpy()})[0]
    cross_torch = cross_kv.numpy()
    report['crossKvOnnxVsTorchMaxAbs'] = float(np.abs(cross_onnx - cross_torch).max())
    rng = np.random.default_rng(1)
    cases = []
    for beams, past_beams, past_length in [(4, 1, 1), (1, 1, 1), (4, 4, 2), (4, 4, 9), (4, 1, 5),
                                           (1, 1, 30), (4, 4, 64)]:
        ids = rng.integers(5, 6000, size=(beams, 1)).astype(np.int64)
        beam_idx = rng.integers(0, past_beams, size=(beams,)).astype(np.int64)
        past = rng.standard_normal((4, past_beams, HEADS, past_length, HEAD_DIM)).astype(np.float32)
        logits_onnx, present_onnx = step_session.run(None, {
            'input_ids': ids, 'beam_idx': beam_idx, 'past_key_values': past,
            'cross_key_values': cross_onnx,
        })
        with torch.no_grad():
            logits_torch, present_torch = step(
                torch.from_numpy(ids), torch.from_numpy(beam_idx), torch.from_numpy(past),
                torch.from_numpy(cross_torch))
        cases.append({
            'beams': beams, 'pastBeams': past_beams, 'pastLength': past_length,
            'logitsMaxAbs': float(np.abs(logits_onnx - logits_torch.numpy()).max()),
            'presentMaxAbs': float(np.abs(present_onnx - present_torch.numpy()).max()),
        })
    report['onnxVsTorch'] = cases
    worst = max([report['torchStepVsHfFullMaxAbs'], report['crossKvOnnxVsTorchMaxAbs']] +
                [c['logitsMaxAbs'] for c in cases])
    if worst > 1e-3:
        raise SystemExit(f'parity check failed: max abs diff {worst}')
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default='out')
    parser.add_argument('--revision', default=SOURCE_REVISION)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    torch.set_num_threads(4)
    model = load_model(args.revision)
    if not args.verify_only:
        export(model, args.out)
    import transformers

    report = {
        'source': {
            'repo': SOURCE_REPO, 'revision': args.revision, 'torch': torch.__version__,
            'transformers': transformers.__version__, 'onnxOpset': OPSET,
        },
        'graphs': [describe(os.path.join(args.out, name))
                   for name in ('cross_kv.onnx', 'decoder_kv.onnx')],
        'verify': verify(model, args.out),
    }
    with open(os.path.join(args.out, 'export_report.json'), 'w', encoding='utf-8') as handle:
        json.dump(report, handle, indent=1, ensure_ascii=False)
    json.dump(report, sys.stdout, indent=1, ensure_ascii=False)
    print()


if __name__ == '__main__':
    main()
