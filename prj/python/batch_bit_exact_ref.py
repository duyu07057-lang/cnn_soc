#!/usr/bin/env python3
"""Generate bit-exact FC logits and decisions for a concatenated image batch."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import bit_exact_ref as ref


PIXELS_PER_IMAGE = 28 * 28


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--params-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--num-images", type=int, default=1000)
    parser.add_argument(
        "--label-mode",
        choices=("none", "cyclic"),
        default="cyclic",
        help="cyclic means labels repeat 0,1,...,9",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.num_images <= 0:
        raise ValueError("--num-images must be positive")

    pixels = ref.read_hex_words(args.input.resolve())
    expected_pixels = args.num_images * PIXELS_PER_IMAGE
    ref.require_count(pixels, expected_pixels, str(args.input))
    if any(pixel < 0 or pixel > 0xFF for pixel in pixels):
        raise ValueError("Batch input pixels must be 8-bit unsigned values")

    param_dir = args.params_dir.resolve()
    conv1_weights, conv1_bias = ref.load_conv1_parameters(param_dir)
    conv2_weights, conv2_bias = ref.load_conv2_parameters(param_dir, "signed8")
    fc_weights, fc_bias = ref.load_fc_parameters(param_dir)

    decisions: list[int] = []
    logits_per_image: list[list[int]] = []

    for image_index in range(args.num_images):
        begin = image_index * PIXELS_PER_IMAGE
        flat_image = pixels[begin : begin + PIXELS_PER_IMAGE]
        image = [
            flat_image[row * 28 : (row + 1) * 28]
            for row in range(28)
        ]

        conv1_output = ref.conv1(image, conv1_weights, conv1_bias)
        pool1_output = ref.maxpool_relu(conv1_output)
        conv2_output = ref.conv2(pool1_output, conv2_weights, conv2_bias)
        pool2_output = ref.maxpool_relu(conv2_output)
        logits = ref.fully_connected(pool2_output, fc_weights, fc_bias)
        decision = max(range(10), key=lambda index: logits[index])

        logits_per_image.append(logits)
        decisions.append(decision)

        if (image_index + 1) % 100 == 0 or image_index + 1 == args.num_images:
            print(f"processed {image_index + 1}/{args.num_images}")

    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    decisions_path = output_dir / "decision_1000_bit_exact.mem"
    logits_path = output_dir / "fc_logits_1000_bit_exact.mem"
    labels_path = output_dir / "labels_1000_cyclic.mem"
    summary_path = output_dir / "batch_1000_summary.json"

    decisions_path.write_text(
        "".join(f"{decision:x}\n" for decision in decisions),
        encoding="ascii",
    )
    ref.write_packed_vectors(logits_path, logits_per_image, 12)

    labels: list[int] | None = None
    accuracy: float | None = None
    correct: int | None = None
    if args.label_mode == "cyclic":
        labels = [index % 10 for index in range(args.num_images)]
        labels_path.write_text(
            "".join(f"{label:x}\n" for label in labels),
            encoding="ascii",
        )
        correct = sum(
            decision == label for decision, label in zip(decisions, labels)
        )
        accuracy = correct / args.num_images

    histogram = {
        str(class_index): decisions.count(class_index)
        for class_index in range(10)
    }
    summary = {
        "input": str(args.input.resolve()),
        "num_images": args.num_images,
        "pixels_per_image": PIXELS_PER_IMAGE,
        "conv2_bias_mode": "signed8",
        "decision_histogram": histogram,
        "label_mode": args.label_mode,
        "correct": correct,
        "accuracy": accuracy,
        "outputs": {
            "decisions": str(decisions_path),
            "packed_logits": str(logits_path),
            "labels": str(labels_path) if labels is not None else None,
        },
    }
    summary_path.write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    print(f"decisions : {decisions_path}")
    print(f"logits    : {logits_path}")
    if accuracy is not None and correct is not None:
        print(f"accuracy  : {correct}/{args.num_images} = {accuracy:.2%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
