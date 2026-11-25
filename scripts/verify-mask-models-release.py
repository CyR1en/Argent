#!/usr/bin/env python3
"""Verify that the mask models pack pinned in MaskModelPack.current is publicly
downloadable and matches MaskModelPackPins's byte count and SHA-256.

Streams the archive directly from the pinned HTTPS URL without authentication
headers (so draft or private assets fail) and without writing the archive to
disk. Used by .github/workflows/release.yml to prevent publishing a nightly or
release whose pinned pack is missing or mismatched.
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import subprocess
import sys


def parse_pins(repo_root: pathlib.Path) -> tuple[str, int, str]:
    pack_swift = (repo_root / "Sources/ArgentRoll/MaskModelPack.swift").read_text(encoding="utf-8")
    pins_swift = (repo_root / "Sources/ArgentRoll/MaskModelPackPins.swift").read_text(encoding="utf-8")

    current_match = re.search(
        r"public\s+static\s+let\s+current\s*=\s*MaskModelPack\s*\((?:[^()]|\([^()]*\))*\)",
        pack_swift,
    )
    if not current_match:
        raise ValueError("could not find MaskModelPack.current in Sources/ArgentRoll/MaskModelPack.swift")

    url_match = re.search(r'url:\s*URL\s*\(\s*string:\s*"([^"]+)"\s*\)', current_match.group(0))
    if not url_match:
        raise ValueError("could not find pinned URL in MaskModelPack.current")
    url = url_match.group(1)
    if not url.startswith("https://"):
        raise ValueError(f"pinned URL must use https://, got {url!r}")

    bytes_match = re.search(r"static\s+let\s+bytes\s*:\s*Int64\s*=\s*([0-9_]+)", pins_swift)
    sha_match = re.search(r'static\s+let\s+sha256\s*=\s*"([0-9a-f]{64})"', pins_swift)
    if not bytes_match or not sha_match:
        raise ValueError("could not find bytes or sha256 in Sources/ArgentRoll/MaskModelPackPins.swift")

    expected_bytes = int(bytes_match.group(1).replace("_", ""))
    expected_sha256 = sha_match.group(1)
    if expected_bytes <= 0:
        raise ValueError(f"pinned bytes must be positive, got {expected_bytes}")
    return url, expected_bytes, expected_sha256


def head_content_length(url: str) -> int | None:
    proc = subprocess.run(
        [
            "curl",
            "-fsSIL",
            "--retry",
            "3",
            "--retry-delay",
            "2",
            "--connect-timeout",
            "30",
            "--max-time",
            "60",
            url,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or f"curl exited with {proc.returncode}"
        raise RuntimeError(f"pinned mask models pack is not publicly downloadable at {url}: {detail}")

    # Follow redirect blocks: take the Content-Length from the final response.
    length: int | None = None
    for line in proc.stdout.splitlines():
        if line.lower().startswith("http/"):
            length = None
        elif line.lower().startswith("content-length:"):
            raw = line.split(":", 1)[1].strip()
            if raw.isdigit():
                length = int(raw)
    return length


def stream_verify(url: str, expected_bytes: int, expected_sha256: str) -> None:
    head_len = head_content_length(url)
    if head_len is not None and head_len != expected_bytes:
        raise RuntimeError(
            f"hosted mask models pack Content-Length is {head_len} bytes, expected {expected_bytes} ({url})"
        )

    proc = subprocess.Popen(
        [
            "curl",
            "-fsSL",
            "--retry",
            "3",
            "--retry-delay",
            "2",
            "--connect-timeout",
            "30",
            "--max-time",
            "600",
            url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdout is not None and proc.stderr is not None

    digest = hashlib.sha256()
    actual_bytes = 0
    chunk_size = 8 << 20
    while True:
        chunk = proc.stdout.read(chunk_size)
        if not chunk:
            break
        actual_bytes += len(chunk)
        digest.update(chunk)

    stderr_text = proc.stderr.read().decode("utf-8", errors="replace").strip()
    returncode = proc.wait()
    if returncode != 0:
        raise RuntimeError(f"failed downloading {url}: {stderr_text or f'curl exited with {returncode}'}")

    actual_sha256 = digest.hexdigest()
    if actual_bytes != expected_bytes:
        raise RuntimeError(f"hosted mask models pack size is {actual_bytes} bytes, expected {expected_bytes} ({url})")
    if actual_sha256 != expected_sha256:
        raise RuntimeError(
            f"hosted mask models pack SHA-256 is {actual_sha256}, expected {expected_sha256} ({url})"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify the hosted mask models release asset against code pins.")
    parser.add_argument(
        "--repo-root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
        help="Path to the Argent repository root.",
    )
    args = parser.parse_args()

    try:
        url, expected_bytes, expected_sha256 = parse_pins(args.repo_root)
        stream_verify(url, expected_bytes, expected_sha256)
    except Exception as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1

    print(f"verified {url}: {expected_bytes} bytes, sha256 {expected_sha256}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
