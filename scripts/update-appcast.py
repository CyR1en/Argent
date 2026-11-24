#!/usr/bin/env python3
"""Updates Argent's Sparkle 2 appcast.xml from per-release JSON manifests.

Two-channel model:
  - Stable releases (vN.N.N): default channel (no <sparkle:channel> element), keyed by
    guid `argent-release-<version>`, keeping the newest `--keep-stable` releases.
  - Nightly builds (main pushes) and pre-release tags (vN.N.N-suffix): `<sparkle:channel>nightly</sparkle:channel>`.
    The rolling nightly is keyed by guid `argent-nightly` and replaced when a build is at least
    as new as the recorded one; pre-release tags use `argent-release-<version>` and keep the newest
    `--keep-prerelease` items.

When `--manifests-dir` is given, every published release's manifest is stored as
`<manifests-dir>/<guid>.json` and `appcast.xml` is rebuilt deterministically from all stored
manifests, so concurrent publishes on different refs never overwrite each other's XML edits.

Usage:
    python3 scripts/update-appcast.py --manifests-dir pages/manifests --manifest dist/update-manifest.json --appcast pages/appcast.xml
    python3 scripts/update-appcast.py --appcast pages/appcast.xml --manifest dist/update-manifest.json
"""

from __future__ import annotations

import argparse
import html
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)

REQUIRED_FIELDS = (
    "kind",
    "version",
    "short_version",
    "build_number",
    "channel",
    "title",
    "pub_date",
    "min_system_version",
    "url",
    "ed_signature",
    "length",
)


def _sp(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def validate_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    missing = [k for k in REQUIRED_FIELDS if k not in manifest or manifest[k] in (None, "")]
    if missing:
        raise ValueError(f"manifest missing required fields: {', '.join(missing)}")
    if manifest["kind"] not in ("nightly", "release"):
        raise ValueError(f"invalid kind: {manifest['kind']!r}")
    if manifest["channel"] not in ("stable", "nightly"):
        raise ValueError(f"invalid channel: {manifest['channel']!r}")
    try:
        build_num = int(str(manifest["build_number"]))
        if build_num <= 0:
            raise ValueError
    except ValueError as exc:
        raise ValueError(f"build_number must be a positive integer, got {manifest['build_number']!r}") from exc
    try:
        length = int(manifest["length"])
        if length <= 0:
            raise ValueError
    except (TypeError, ValueError) as exc:
        raise ValueError(f"length must be a positive integer, got {manifest['length']!r}") from exc
    url = str(manifest["url"])
    if not url.startswith("https://"):
        raise ValueError(f"enclosure url must use https://, got {url!r}")
    return manifest


def create_empty_tree() -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Argent"
    ET.SubElement(channel, "link").text = "https://github.com/CyR1en/Argent"
    ET.SubElement(channel, "description").text = "Updates for Argent."
    ET.SubElement(channel, "language").text = "en"
    return ET.ElementTree(rss)


def load_or_create_tree(appcast_path: Path) -> ET.ElementTree:
    if appcast_path.exists() and appcast_path.read_text(encoding="utf-8").strip():
        tree = ET.parse(appcast_path)
        root = tree.getroot()
        if root.tag != "rss" or root.find("channel") is None:
            raise ValueError(f"{appcast_path} is not a valid RSS appcast")
        return tree
    return create_empty_tree()


def guid_for(manifest: dict[str, Any]) -> str:
    if manifest["kind"] == "nightly":
        return "argent-nightly"
    return f"argent-release-{manifest['version']}"


def build_item(manifest: dict[str, Any]) -> ET.Element:
    item = ET.Element("item")
    ET.SubElement(item, "title").text = str(manifest["title"])
    guid = ET.SubElement(item, "guid", {"isPermaLink": "false"})
    guid.text = guid_for(manifest)
    ET.SubElement(item, "pubDate").text = str(manifest["pub_date"])
    if manifest["channel"] != "stable":
        ET.SubElement(item, _sp("channel")).text = str(manifest["channel"])
    ET.SubElement(item, _sp("version")).text = str(manifest["build_number"])
    ET.SubElement(item, _sp("shortVersionString")).text = str(manifest["short_version"])
    ET.SubElement(item, _sp("minimumSystemVersion")).text = str(manifest["min_system_version"])

    notes_url = manifest.get("release_notes_url")
    if notes_url:
        safe_url = html.escape(str(notes_url), quote=True)
        safe_title = html.escape(str(manifest["title"]))
        ET.SubElement(item, "description").text = (
            f'<p>{safe_title} — <a href="{safe_url}">View release notes on GitHub</a>.</p>'
        )

    ET.SubElement(
        item,
        "enclosure",
        {
            "url": str(manifest["url"]),
            "length": str(int(manifest["length"])),
            "type": "application/octet-stream",
            _sp("edSignature"): str(manifest["ed_signature"]),
        },
    )
    return item


def item_version_key(item: ET.Element) -> int:
    text = item.findtext(_sp("version")) or "0"
    try:
        return int(text)
    except ValueError:
        return 0


def item_channel(item: ET.Element) -> str:
    return item.findtext(_sp("channel")) or "stable"


def _write_tree(appcast_path: Path, tree: ET.ElementTree, items: list[ET.Element], keep_stable: int, keep_prerelease: int) -> None:
    channel_el = tree.getroot().find("channel")
    assert channel_el is not None
    for item in list(channel_el.findall("item")):
        channel_el.remove(item)

    stable_items = [i for i in items if item_channel(i) == "stable"]
    rolling_nightly = [i for i in items if (i.findtext("guid") or "") == "argent-nightly"]
    prerelease_items = [
        i for i in items if item_channel(i) != "stable" and (i.findtext("guid") or "") != "argent-nightly"
    ]

    stable_items.sort(key=item_version_key, reverse=True)
    prerelease_items.sort(key=item_version_key, reverse=True)

    final_items = stable_items[:keep_stable] + rolling_nightly + prerelease_items[:keep_prerelease]
    final_items.sort(key=item_version_key, reverse=True)

    for item in final_items:
        channel_el.append(item)

    ET.indent(tree, space="  ")
    xml_bytes = ET.tostring(tree.getroot(), encoding="utf-8", xml_declaration=True)
    # Re-parse to verify well-formed XML before touching disk.
    ET.fromstring(xml_bytes)

    appcast_path.parent.mkdir(parents=True, exist_ok=True)
    appcast_path.write_bytes(xml_bytes + b"\n")


def update_appcast(
    appcast_path: Path,
    manifest: dict[str, Any],
    keep_stable: int = 20,
    keep_prerelease: int = 10,
) -> None:
    validate_manifest(manifest)
    tree = load_or_create_tree(appcast_path)
    channel_el = tree.getroot().find("channel")
    assert channel_el is not None

    target_guid = guid_for(manifest)
    existing_items = list(channel_el.findall("item"))
    if manifest["kind"] == "nightly":
        incoming_build = int(str(manifest["build_number"]))
        for item in existing_items:
            if (item.findtext("guid") or "") == target_guid and item_version_key(item) > incoming_build:
                return

    kept = [item for item in existing_items if (item.findtext("guid") or "") != target_guid]
    kept.append(build_item(manifest))
    _write_tree(appcast_path, tree, kept, keep_stable=keep_stable, keep_prerelease=keep_prerelease)


def upsert_manifest_and_rebuild(
    manifests_dir: Path,
    appcast_path: Path,
    manifest: dict[str, Any] | None = None,
    keep_stable: int = 20,
    keep_prerelease: int = 10,
) -> None:
    manifests_dir.mkdir(parents=True, exist_ok=True)
    if manifest is not None:
        validate_manifest(manifest)
        guid = guid_for(manifest)
        dest = manifests_dir / f"{guid}.json"
        write_manifest = True
        if manifest["kind"] == "nightly" and dest.exists():
            current = validate_manifest(json.loads(dest.read_text(encoding="utf-8")))
            if int(str(current["build_number"])) > int(str(manifest["build_number"])):
                write_manifest = False
        if write_manifest:
            dest.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    items: list[ET.Element] = []
    for path in sorted(manifests_dir.glob("*.json")):
        entry = validate_manifest(json.loads(path.read_text(encoding="utf-8")))
        items.append(build_item(entry))

    _write_tree(appcast_path, create_empty_tree(), items, keep_stable=keep_stable, keep_prerelease=keep_prerelease)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Update Argent's Sparkle 2 appcast.xml")
    parser.add_argument("--appcast", required=True, type=Path, help="Path to appcast.xml")
    parser.add_argument("--manifest", type=Path, help="Path to update-manifest.json to upsert")
    parser.add_argument("--manifests-dir", type=Path, help="Directory of per-release JSON manifests")
    parser.add_argument("--keep-stable", type=int, default=20, help="Max stable items to keep")
    parser.add_argument("--keep-prerelease", type=int, default=10, help="Max prerelease items to keep")
    args = parser.parse_args(argv)

    if args.manifests_dir is None and args.manifest is None:
        parser.error("at least one of --manifest or --manifests-dir is required")

    manifest = json.loads(args.manifest.read_text(encoding="utf-8")) if args.manifest else None
    if args.manifests_dir is not None:
        upsert_manifest_and_rebuild(
            args.manifests_dir,
            args.appcast,
            manifest=manifest,
            keep_stable=args.keep_stable,
            keep_prerelease=args.keep_prerelease,
        )
    else:
        assert manifest is not None
        update_appcast(args.appcast, manifest, keep_stable=args.keep_stable, keep_prerelease=args.keep_prerelease)
    return 0


if __name__ == "__main__":
    sys.exit(main())
