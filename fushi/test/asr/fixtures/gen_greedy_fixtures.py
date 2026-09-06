"""生成 `asr_greedy_graph_test.dart` 用的极小合成 decoder / joiner ONNX 夹具。

结构与 ReazonSpeech k2-v2 的 sherpa-onnx 导出同构（IO 名、dtype、秩、ir_version 7、
opset 13、initializer 走 raw_data），只是维度缩到几 KB：

    decoder : y[N,2] int64                          -> decoder_out[N,4] float32
              Gather(emb[6,4], y) -> Reshape [N,8] -> Gemm(W[8,4]^T) -> decoder_out
    joiner  : encoder_out[N,4] f32, decoder_out[N,4] -> logit[N,6] float32
              Add -> Tanh -> Gemm(W[6,4]^T, b[6]) -> logit

词表 6：<blk>=0，<unk>=5，其余 1..4 是可发射符号。权重固定种子。
metadata_props 也照真模型写 context_size / vocab_size。

运行环境：Python 3.11，onnx 1.22。

    python gen_greedy_fixtures.py

产出 greedy_tiny_decoder.onnx / greedy_tiny_joiner.onnx（同目录）。
"""

from __future__ import annotations

import os

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

HERE = os.path.dirname(os.path.abspath(__file__))
CONTEXT = 2
VOCAB = 6
DIM = 4


def _model(graph: onnx.GraphProto, meta: dict[str, str]) -> onnx.ModelProto:
    model = helper.make_model(
        graph,
        producer_name="fushi-greedy-fixture",
        opset_imports=[helper.make_opsetid("", 13)],
    )
    model.ir_version = 7
    for k, v in meta.items():
        p = model.metadata_props.add()
        p.key, p.value = k, v
    onnx.checker.check_model(model, full_check=True)
    return model


def make_decoder(rng: np.random.Generator) -> onnx.ModelProto:
    emb = numpy_helper.from_array(
        rng.standard_normal((VOCAB, DIM)).astype(np.float32), "decoder.embedding.weight"
    )
    w = numpy_helper.from_array(
        (rng.standard_normal((DIM, CONTEXT * DIM)) * 0.5).astype(np.float32),
        "decoder.linear.weight",
    )
    shape = numpy_helper.from_array(np.array([0, CONTEXT * DIM], dtype=np.int64), "reshape_shape")
    nodes = [
        helper.make_node("Gather", ["decoder.embedding.weight", "y"], ["/decoder/Gather_output_0"], name="/decoder/Gather", axis=0),
        helper.make_node("Reshape", ["/decoder/Gather_output_0", "reshape_shape"], ["/decoder/Reshape_output_0"], name="/decoder/Reshape"),
        helper.make_node(
            "Gemm",
            ["/decoder/Reshape_output_0", "decoder.linear.weight"],
            ["decoder_out"],
            name="/decoder/linear/Gemm",
            alpha=1.0,
            beta=1.0,
            transB=1,
        ),
    ]
    graph = helper.make_graph(
        nodes,
        "main_graph",
        [helper.make_tensor_value_info("y", TensorProto.INT64, ["N", CONTEXT])],
        [helper.make_tensor_value_info("decoder_out", TensorProto.FLOAT, ["N", DIM])],
        initializer=[emb, w, shape],
    )
    return _model(graph, {"context_size": str(CONTEXT), "vocab_size": str(VOCAB)})


def make_joiner(rng: np.random.Generator) -> onnx.ModelProto:
    w = numpy_helper.from_array(
        rng.standard_normal((VOCAB, DIM)).astype(np.float32), "output_linear.weight"
    )
    b = numpy_helper.from_array(
        (rng.standard_normal(VOCAB) * 0.3).astype(np.float32), "output_linear.bias"
    )
    nodes = [
        helper.make_node("Add", ["encoder_out", "decoder_out"], ["/Add_output_0"], name="/Add"),
        helper.make_node("Tanh", ["/Add_output_0"], ["/Tanh_output_0"], name="/Tanh"),
        helper.make_node(
            "Gemm",
            ["/Tanh_output_0", "output_linear.weight", "output_linear.bias"],
            ["logit"],
            name="/output_linear/Gemm",
            alpha=1.0,
            beta=1.0,
            transB=1,
        ),
    ]
    graph = helper.make_graph(
        nodes,
        "main_graph",
        [
            helper.make_tensor_value_info("encoder_out", TensorProto.FLOAT, ["N", DIM]),
            helper.make_tensor_value_info("decoder_out", TensorProto.FLOAT, ["N", DIM]),
        ],
        [helper.make_tensor_value_info("logit", TensorProto.FLOAT, ["N", VOCAB])],
        initializer=[w, b],
    )
    return _model(graph, {"joiner_dim": str(DIM)})


def main() -> None:
    rng = np.random.default_rng(20260905)
    dec = make_decoder(rng)
    joi = make_joiner(rng)
    onnx.save(dec, os.path.join(HERE, "greedy_tiny_decoder.onnx"))
    onnx.save(joi, os.path.join(HERE, "greedy_tiny_joiner.onnx"))
    print("decoder", dec.ByteSize(), "bytes; joiner", joi.ByteSize(), "bytes")


if __name__ == "__main__":
    main()
