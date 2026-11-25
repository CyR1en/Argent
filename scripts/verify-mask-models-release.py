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
import datetime
import email.utils
import hashlib
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time


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


class _StreamError(RuntimeError):
    def __init__(self, message: str, *, retryable: bool, retry_after: float | None = None) -> None:
        super().__init__(message)
        self.retryable = retryable
        self.retry_after = retry_after


def _parse_final_response_headers(raw: str) -> tuple[int | None, float | None]:
    status: int | None = None
    retry_after: float | None = None
    for line in raw.splitlines():
        low = line.lower()
        if low.startswith("http/"):
            parts = line.split()
            status = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else None
            retry_after = None
        elif low.startswith("retry-after:"):
            value = line.split(":", 1)[1].strip()
            if value.isdigit():
                retry_after = float(value)
            else:
                try:
                    dt = email.utils.parsedate_to_datetime(value)
                    if dt.tzinfo is None:
                        dt = dt.replace(tzinfo=datetime.timezone.utc)
                    delta = (dt - datetime.datetime.now(datetime.timezone.utc)).total_seconds()
                    retry_after = max(0.0, delta)
                except (TypeError, ValueError):
                    retry_after = None
    return status, retry_after


def _stream_once(url: str) -> tuple[int, str]:
    # Never pass --retry to streaming curl: a mid-transfer retry appends fresh bytes
    # to the same stdout stream, corrupting the byte count and SHA-256. Retries are
    # handled per attempt in stream_verify so each retry starts with a fresh hash.
    fd, header_path = tempfile.mkstemp(prefix="mask-models-headers-", suffix=".txt")
    os.close(fd)
    try:
        proc = subprocess.Popen(
            [
                "curl",
                "-fsSL",
                "-D",
                header_path,
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
            raw_headers = pathlib.Path(header_path).read_text(encoding="latin-1", errors="replace")
            status, retry_after = _parse_final_response_headers(raw_headers)
            # Retry transport/partial errors (including non-zero curl exit after 2xx), 408, 429, and 5xx;
            # fail fast on permanent 4xx (e.g. 404).
            retryable = status is None or status < 400 or status in (408, 429) or status >= 500
            raise _StreamError(
                f"failed downloading {url}: {stderr_text or f'curl exited with {returncode}'}",
                retryable=retryable,
                retry_after=retry_after,
            )
        return actual_bytes, digest.hexdigest()
    finally:
        try:
            os.unlink(header_path)
        except OSError:
            pass


def stream_verify(
    url: str,
    expected_bytes: int,
    expected_sha256: str,
    attempts: int = 3,
    retry_delay: float = 2.0,
    max_retry_delay: float = 120.0,
) -> None:
    head_len = head_content_length(url)
    if head_len is not None and head_len != expected_bytes:
        raise RuntimeError(
            f"hosted mask models pack Content-Length is {head_len} bytes, expected {expected_bytes} ({url})"
        )

    last_error: _StreamError | None = None
    for attempt in range(1, attempts + 1):
        try:
            actual_bytes, actual_sha256 = _stream_once(url)
            break
        except _StreamError as exc:
            last_error = exc
            if not exc.retryable or attempt >= attempts:
                raise
            backoff = retry_delay * (2 ** (attempt - 1))
            wait = exc.retry_after if exc.retry_after is not None else backoff
            time.sleep(min(max(wait, retry_delay), max_retry_delay))
    else:
        assert last_error is not None
        raise last_error

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
