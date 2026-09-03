#!/usr/bin/env python3
"""Bit-exact reference model for the current cnn_acc_3 MNIST accelerator.

The model follows the intended fixed-point behavior of the RTL after the two
known correctness fixes:

1. Conv1's current bottom-right pixel is bypassed from ``data_in`` instead of
    reading the old value at the simultaneously written line-buffer address.
2. Conv2 biases are interpreted as signed INT8 values.

Channel 0 is packed in the least-significant bits of every output word, which
matches the current Verilog ``[channel * DATA_BITS +: DATA_BITS]`` convention.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Iterable, Sequence


CONV1_OUT_CHANNELS = 4
CONV2_OUT_CHANNELS = 8
ACT_BITS = 12


def wrap_signed(value: int, bits: int) -> int:
    """Wrap an integer to a two's-complement signed value of ``bits`` width."""
    mask = (1 << bits) - 1
    value &= mask
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def saturate_signed(value: int, bits: int) -> int:
    """Saturate an integer to the signed range represented by ``bits``."""
    lower = -(1 << (bits - 1))
    upper = (1 << (bits - 1)) - 1
    return min(upper, max(lower, value))


def read_hex_words(path: Path) -> list[int]:
    """Read whitespace-separated hexadecimal words from a text/mem file."""
    if not path.is_file():
        raise FileNotFoundError(f"Missing input file: {path}")

    words: list[int] = []
    for index, token in enumerate(path.read_text(encoding="utf-8").split()):
        try:
            words.append(int(token, 16))
        except ValueError as exc:
            raise ValueError(
                f"Invalid hexadecimal token #{index} {token!r} in {path}"
            ) from exc
    return words


def require_count(values: Sequence[object], expected: int, name: str) -> None:
    if len(values) != expected:
        raise ValueError(f"{name}: expected {expected} entries, got {len(values)}")


def read_signed8(path: Path, expected: int) -> list[int]:
    values = read_hex_words(path)
    require_count(values, expected, str(path))
    return [wrap_signed(value, 8) for value in values]


def load_image(path: Path) -> list[list[int]]:
    pixels = read_hex_words(path)
    require_count(pixels, 28 * 28, str(path))
    if any(pixel < 0 or pixel > 0xFF for pixel in pixels):
        raise ValueError(f"{path}: image pixels must be 8-bit unsigned values")
    return [pixels[row * 28 : (row + 1) * 28] for row in range(28)]


def load_conv1_parameters(param_dir: Path) -> tuple[list[list[int]], list[int]]:
    weights = [
        read_signed8(param_dir / f"conv1_weight_{channel}.mem", 9)
        for channel in range(CONV1_OUT_CHANNELS)
    ]
    bias = read_signed8(param_dir / "conv1_bias.mem", CONV1_OUT_CHANNELS)
    return weights, bias


def load_conv2_parameters(
    param_dir: Path, bias_mode: str
) -> tuple[list[list[int]], list[int]]:
    weights = [
        read_signed8(param_dir / f"conv2_weight_{channel}.mem", 4 * 3 * 3)
        for channel in range(CONV2_OUT_CHANNELS)
    ]
    raw_bias = read_hex_words(param_dir / "conv2_bias.mem")
    require_count(raw_bias, CONV2_OUT_CHANNELS, "conv2_bias.mem")

    if bias_mode == "signed8":
        bias = [wrap_signed(value, 8) for value in raw_bias]
    elif bias_mode == "zero_extend16":
        bias = [value & 0xFFFF for value in raw_bias]
    else:
        raise ValueError(f"Unsupported Conv2 bias mode: {bias_mode}")
    return weights, bias


def load_fc_parameters(param_dir: Path) -> tuple[list[list[list[int]]], list[int]]:
    rows = read_hex_words(param_dir / "fc_weight_wide.mem")
    require_count(rows, 10, "fc_weight_wide.mem")

    weights: list[list[list[int]]] = []
    for neuron, packed_row in enumerate(rows):
        if packed_row.bit_length() > 1600:
            raise ValueError(f"FC neuron {neuron}: weight row exceeds 1600 bits")

        neuron_weights: list[list[int]] = []
        for beat in range(25):
            channels = []
            for channel in range(8):
                shift = beat * 64 + channel * 8
                channels.append(wrap_signed((packed_row >> shift) & 0xFF, 8))
            neuron_weights.append(channels)
        weights.append(neuron_weights)

    bias = read_signed8(param_dir / "fc_bias_wide.mem", 10)
    return weights, bias


def conv1(
    image: Sequence[Sequence[int]],
    weights: Sequence[Sequence[int]],
    bias: Sequence[int],
) -> list[list[list[int]]]:
    """28x28x1 -> 26x26x4, matching conv1_calc's intended arithmetic."""
    output = [[[0 for _ in range(4)] for _ in range(26)] for _ in range(26)]

    for out_y in range(26):
        for out_x in range(26):
            window = [
                image[out_y + kernel_y][out_x + kernel_x]
                for kernel_y in range(3)
                for kernel_x in range(3)
            ]
            for out_channel in range(4):
                product_sum = sum(
                    pixel * weight
                    for pixel, weight in zip(window, weights[out_channel])
                )
                sum_20 = wrap_signed(product_sum, 20)
                shifted_12 = wrap_signed(sum_20 >> 8, 12)
                output[out_y][out_x][out_channel] = wrap_signed(
                    shifted_12 + bias[out_channel], 12
                )
    return output


def maxpool_relu(
    feature_map: Sequence[Sequence[Sequence[int]]],
) -> list[list[list[int]]]:
    """Apply per-channel ReLU followed by 2x2 stride-2 max pooling."""
    in_height = len(feature_map)
    in_width = len(feature_map[0])
    channels = len(feature_map[0][0])
    out_height = in_height // 2
    out_width = in_width // 2
    output = [
        [[0 for _ in range(channels)] for _ in range(out_width)]
        for _ in range(out_height)
    ]

    for out_y in range(out_height):
        for out_x in range(out_width):
            for channel in range(channels):
                candidates = [0]
                for delta_y in range(2):
                    for delta_x in range(2):
                        candidates.append(
                            feature_map[out_y * 2 + delta_y][out_x * 2 + delta_x][
                                channel
                            ]
                        )
                output[out_y][out_x][channel] = max(candidates)
    return output


def conv2(
    feature_map: Sequence[Sequence[Sequence[int]]],
    weights: Sequence[Sequence[int]],
    bias: Sequence[int],
) -> list[list[list[int]]]:
    """13x13x4 -> 11x11x8, matching conv2_calc's intended arithmetic."""
    output = [[[0 for _ in range(8)] for _ in range(11)] for _ in range(11)]

    for out_y in range(11):
        for out_x in range(11):
            for out_channel in range(8):
                per_input_channel_sums = []
                for in_channel in range(4):
                    channel_sum = 0
                    for kernel_y in range(3):
                        for kernel_x in range(3):
                            weight_index = in_channel * 9 + kernel_y * 3 + kernel_x
                            channel_sum += (
                                feature_map[out_y + kernel_y][out_x + kernel_x][
                                    in_channel
                                ]
                                * weights[out_channel][weight_index]
                            )
                    per_input_channel_sums.append(wrap_signed(channel_sum, 24))

                total_28 = wrap_signed(sum(per_input_channel_sums), 28)
                rounded_28 = wrap_signed(total_28 + 64, 28)
                scaled = rounded_28 >> 7
                output[out_y][out_x][out_channel] = saturate_signed(
                    scaled + bias[out_channel], 12
                )
    return output


def fully_connected(
    feature_map: Sequence[Sequence[Sequence[int]]],
    weights: Sequence[Sequence[Sequence[int]]],
    bias: Sequence[int],
) -> list[int]:
    """5x5x8 -> 10 logits, matching fully_connected.v's HWC traversal."""
    beats = [pixel for row in feature_map for pixel in row]
    require_count(beats, 25, "Pool2 feature-map beats")

    logits: list[int] = []
    for neuron in range(10):
        accumulator = 0
        for beat_index, activations in enumerate(beats):
            new_sum = sum(
                activations[channel] * weights[neuron][beat_index][channel]
                for channel in range(8)
            )
            new_sum = wrap_signed(new_sum, 28)
            accumulator = (
                new_sum
                if beat_index == 0
                else wrap_signed(accumulator + new_sum, 28)
            )

        scaled = accumulator >> 7
        logits.append(saturate_signed(scaled + bias[neuron], 12))
    return logits


def flatten_feature_map(
    feature_map: Sequence[Sequence[Sequence[int]]],
) -> list[list[int]]:
    return [list(pixel) for row in feature_map for pixel in row]


def pack_channels(channels: Sequence[int], bits: int) -> int:
    packed = 0
    mask = (1 << bits) - 1
    for channel, value in enumerate(channels):
        packed |= (value & mask) << (channel * bits)
    return packed


def write_packed_vectors(
    path: Path, rows: Iterable[Sequence[int]], bits: int
) -> None:
    materialized = [list(row) for row in rows]
    if not materialized:
        raise ValueError(f"Refusing to write empty vector file: {path}")
    channels = len(materialized[0])
    if any(len(row) != channels for row in materialized):
        raise ValueError(f"Inconsistent channel count while writing {path}")
    hex_width = (channels * bits + 3) // 4
    path.write_text(
        "".join(
            f"{pack_channels(row, bits):0{hex_width}x}\n" for row in materialized
        ),
        encoding="ascii",
    )


def write_scalar_vectors(path: Path, values: Sequence[int], bits: int) -> None:
    mask = (1 << bits) - 1
    hex_width = (bits + 3) // 4
    path.write_text(
        "".join(f"{value & mask:0{hex_width}x}\n" for value in values),
        encoding="ascii",
    )


def tensor_stats(rows: Sequence[Sequence[int]]) -> dict[str, int]:
    values = [value for row in rows for value in row]
    return {
        "entries": len(values),
        "minimum": min(values),
        "maximum": max(values),
        "negative": sum(value < 0 for value in values),
        "zero": sum(value == 0 for value in values),
        "saturated_min": sum(value == -2048 for value in values),
        "saturated_max": sum(value == 2047 for value in values),
    }


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="28x28 hex image")
    parser.add_argument(
        "--params-dir", required=True, type=Path, help="Directory containing .mem files"
    )
    parser.add_argument(
        "--output-dir", required=True, type=Path, help="Directory for generated vectors"
    )
    parser.add_argument("--prefix", default="9", help="Filename prefix for outputs")
    parser.add_argument(
        "--conv2-bias-mode",
        choices=("signed8", "zero_extend16"),
        default="signed8",
        help="Use signed8 for the corrected/intended design",
    )
    parser.add_argument(
        "--expect-decision",
        type=int,
        default=None,
        help="Fail if argmax differs from this class",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_path = args.input.resolve()
    param_dir = args.params_dir.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    image = load_image(input_path)
    conv1_weights, conv1_bias = load_conv1_parameters(param_dir)
    conv2_weights, conv2_bias = load_conv2_parameters(
        param_dir, args.conv2_bias_mode
    )
    fc_weights, fc_bias = load_fc_parameters(param_dir)

    c1 = conv1(image, conv1_weights, conv1_bias)
    p1 = maxpool_relu(c1)
    c2 = conv2(p1, conv2_weights, conv2_bias)
    p2 = maxpool_relu(c2)
    logits = fully_connected(p2, fc_weights, fc_bias)
    decision = max(range(len(logits)), key=lambda index: logits[index])

    c1_rows = flatten_feature_map(c1)
    p1_rows = flatten_feature_map(p1)
    c2_rows = flatten_feature_map(c2)
    p2_rows = flatten_feature_map(p2)

    require_count(c1_rows, 676, "Conv1 output beats")
    require_count(p1_rows, 169, "Pool1 output beats")
    require_count(c2_rows, 121, "Conv2 output beats")
    require_count(p2_rows, 25, "Pool2 output beats")
    require_count(logits, 10, "FC logits")

    files = {
        "conv1": output_dir / f"c1_{args.prefix}_bit_exact.mem",
        "pool1": output_dir / f"p1_{args.prefix}_bit_exact.mem",
        "conv2": output_dir / f"c2_{args.prefix}_bit_exact.mem",
        "pool2": output_dir / f"p2_{args.prefix}_bit_exact.mem",
        "fc": output_dir / f"fc_{args.prefix}_bit_exact.mem",
        "decision": output_dir / f"decision_{args.prefix}.txt",
        "summary": output_dir / f"reference_{args.prefix}_summary.json",
    }

    write_packed_vectors(files["conv1"], c1_rows, ACT_BITS)
    write_packed_vectors(files["pool1"], p1_rows, ACT_BITS)
    write_packed_vectors(files["conv2"], c2_rows, ACT_BITS)
    write_packed_vectors(files["pool2"], p2_rows, ACT_BITS)
    write_scalar_vectors(files["fc"], logits, ACT_BITS)
    files["decision"].write_text(f"{decision}\n", encoding="ascii")

    parameter_names = [
        *(f"conv1_weight_{index}.mem" for index in range(4)),
        "conv1_bias.mem",
        *(f"conv2_weight_{index}.mem" for index in range(8)),
        "conv2_bias.mem",
        "fc_weight_wide.mem",
        "fc_bias_wide.mem",
    ]
    summary = {
        "model": "cnn_acc_3 bit-exact intended arithmetic",
        "input": str(input_path),
        "input_sha256": sha256_file(input_path),
        "parameter_sha256": {
            name: sha256_file(param_dir / name) for name in parameter_names
        },
        "conv2_bias_mode": args.conv2_bias_mode,
        "shapes": {
            "conv1": [26, 26, 4],
            "pool1": [13, 13, 4],
            "conv2": [11, 11, 8],
            "pool2": [5, 5, 8],
            "fc": [10],
        },
        "statistics": {
            "conv1": tensor_stats(c1_rows),
            "pool1": tensor_stats(p1_rows),
            "conv2": tensor_stats(c2_rows),
            "pool2": tensor_stats(p2_rows),
            "fc": tensor_stats([[value] for value in logits]),
        },
        "logits": logits,
        "decision": decision,
        "outputs": {name: path.name for name, path in files.items() if name != "summary"},
    }
    files["summary"].write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print("cnn_acc_3 bit-exact reference completed")
    print(f"input        : {input_path}")
    print(f"bias mode    : {args.conv2_bias_mode}")
    print(f"beats        : c1={len(c1_rows)}, p1={len(p1_rows)}, c2={len(c2_rows)}, p2={len(p2_rows)}")
    print(f"fc logits    : {logits}")
    print(f"decision     : {decision}")
    print(f"output dir   : {output_dir}")

    if args.expect_decision is not None and decision != args.expect_decision:
        raise SystemExit(
            f"Decision mismatch: expected {args.expect_decision}, got {decision}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
