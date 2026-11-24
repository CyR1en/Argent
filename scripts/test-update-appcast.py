#!/usr/bin/env python3
"""Unit tests for scripts/update-appcast.py."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "update_appcast", Path(__file__).resolve().parent / "update-appcast.py"
)
assert SPEC and SPEC.loader
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

SP = f"{{{MOD.SPARKLE_NS}}}"


def make_manifest(**overrides):
    base = {
        "kind": "release",
        "version": "0.2.0",
        "short_version": "0.2.0",
        "build_number": "120",
        "commit": "abc1234",
        "channel": "stable",
        "title": "Argent 0.2.0",
        "pub_date": "Tue, 24 Nov 2026 02:15:00 +0000",
        "min_system_version": "27.0",
        "url": "https://github.com/CyR1en/Argent/releases/download/v0.2.0/Argent-0.2.0.dmg",
        "ed_signature": "ZmFrZXNpZw==",
        "length": 98765432,
        "release_notes_url": "https://github.com/CyR1en/Argent/releases/tag/v0.2.0",
    }
    base.update(overrides)
    return base


class UpdateAppcastTests(unittest.TestCase):
    def test_creates_fresh_appcast_and_adds_stable_and_nightly(self):
        with tempfile.TemporaryDirectory() as tmp:
            appcast = Path(tmp) / "appcast.xml"
            MOD.update_appcast(appcast, make_manifest())
            MOD.update_appcast(
                appcast,
                make_manifest(
                    kind="nightly",
                    version="0.2.0",
                    short_version="0.2.0 nightly (def5678)",
                    build_number="125",
                    channel="nightly",
                    title="Nightly 2026-11-24 (def5678)",
                    url="https://github.com/CyR1en/Argent/releases/download/nightly/Argent-nightly.dmg",
                    release_notes_url="https://github.com/CyR1en/Argent/releases/tag/nightly",
                ),
            )
            root = ET.parse(appcast).getroot()
            items = root.findall("channel/item")
            self.assertEqual(len(items), 2)
            # Sorted newest build first.
            self.assertEqual(items[0].findtext("guid"), "argent-nightly")
            self.assertEqual(items[0].findtext(f"{SP}channel"), "nightly")
            self.assertEqual(items[0].findtext(f"{SP}version"), "125")
            self.assertEqual(items[1].findtext("guid"), "argent-release-0.2.0")
            self.assertIsNone(items[1].find(f"{SP}channel"))
            self.assertEqual(items[1].findtext(f"{SP}version"), "120")
            enc = items[1].find("enclosure")
            self.assertIsNotNone(enc)
            self.assertEqual(enc.attrib[f"{SP}edSignature"], "ZmFrZXNpZw==")
            self.assertEqual(enc.attrib["length"], "98765432")

    def test_nightly_replaces_in_place_without_dropping_stable_or_prerelease(self):
        with tempfile.TemporaryDirectory() as tmp:
            appcast = Path(tmp) / "appcast.xml"
            MOD.update_appcast(appcast, make_manifest(version="0.2.0", build_number="120"))
            MOD.update_appcast(
                appcast,
                make_manifest(
                    kind="release",
                    version="0.3.0-beta.1",
                    short_version="0.3.0-beta.1",
                    build_number="130",
                    channel="nightly",
                    title="Argent 0.3.0-beta.1",
                    url="https://github.com/CyR1en/Argent/releases/download/v0.3.0-beta.1/Argent-0.3.0-beta.1.dmg",
                ),
            )
            MOD.update_appcast(
                appcast,
                make_manifest(
                    kind="nightly",
                    build_number="131",
                    channel="nightly",
                    title="Nightly 1",
                    url="https://github.com/CyR1en/Argent/releases/download/nightly/Argent-nightly.dmg",
                ),
            )
            MOD.update_appcast(
                appcast,
                make_manifest(
                    kind="nightly",
                    build_number="132",
                    channel="nightly",
                    title="Nightly 2",
                    url="https://github.com/CyR1en/Argent/releases/download/nightly/Argent-nightly.dmg",
                ),
            )
            items = ET.parse(appcast).getroot().findall("channel/item")
            self.assertEqual(
                [(i.findtext("guid"), i.findtext(f"{SP}version"), i.findtext(f"{SP}channel")) for i in items],
                [
                    ("argent-nightly", "132", "nightly"),
                    ("argent-release-0.3.0-beta.1", "130", "nightly"),
                    ("argent-release-0.2.0", "120", None),
                ],
            )

    def test_idempotent_rerun_and_retention_cap(self):
        with tempfile.TemporaryDirectory() as tmp:
            appcast = Path(tmp) / "appcast.xml"
            for idx in range(1, 6):
                MOD.update_appcast(
                    appcast,
                    make_manifest(version=f"0.{idx}.0", short_version=f"0.{idx}.0", build_number=str(100 + idx)),
                    keep_stable=3,
                )
            # Re-running the same version replaces in place.
            MOD.update_appcast(
                appcast,
                make_manifest(version="0.5.0", short_version="0.5.0", build_number="105", ed_signature="bmV3c2ln"),
                keep_stable=3,
            )
            items = ET.parse(appcast).getroot().findall("channel/item")
            self.assertEqual([i.findtext("guid") for i in items], ["argent-release-0.5.0", "argent-release-0.4.0", "argent-release-0.3.0"])
            self.assertEqual(items[0].find("enclosure").attrib[f"{SP}edSignature"], "bmV3c2ln")

    def test_nightly_never_downgrades_to_older_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            appcast = Path(tmp) / "appcast.xml"
            MOD.update_appcast(
                appcast,
                make_manifest(
                    kind="nightly",
                    build_number="140",
                    channel="nightly",
                    title="Nightly 140",
                    url="https://github.com/CyR1en/Argent/releases/download/nightly/Argent-nightly.dmg",
                ),
            )
            MOD.update_appcast(
                appcast,
                make_manifest(
                    kind="nightly",
                    build_number="135",
                    channel="nightly",
                    title="Nightly 135",
                    url="https://github.com/CyR1en/Argent/releases/download/nightly/Argent-nightly.dmg",
                ),
            )
            items = ET.parse(appcast).getroot().findall("channel/item")
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0].findtext(f"{SP}version"), "140")

    def test_manifests_dir_rebuilds_from_all_releases_and_preserves_same_commit_promotion_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifests = Path(tmp) / "manifests"
            appcast = Path(tmp) / "appcast.xml"
            # Same commit (412): nightly (4120) -> beta (4121) -> stable (4122) -> next commit nightly (4130).
            MOD.upsert_manifest_and_rebuild(
                manifests,
                appcast,
                make_manifest(
                    kind="nightly",
                    version="0.1.0",
                    short_version="0.1.0 nightly (aaa1111)",
                    build_number="4120",
                    channel="nightly",
                    title="Nightly 412",
                    url="https://github.com/CyR1en/Argent/releases/download/nightly/Argent-nightly.dmg",
                ),
            )
            MOD.upsert_manifest_and_rebuild(
                manifests,
                appcast,
                make_manifest(
                    kind="release",
                    version="0.2.0-beta.1",
                    short_version="0.2.0-beta.1",
                    build_number="4121",
                    channel="nightly",
                    title="Argent 0.2.0-beta.1",
                    url="https://github.com/CyR1en/Argent/releases/download/v0.2.0-beta.1/Argent-0.2.0-beta.1.dmg",
                ),
            )
            MOD.upsert_manifest_and_rebuild(
                manifests,
                appcast,
                make_manifest(
                    kind="release",
                    version="0.2.0",
                    short_version="0.2.0",
                    build_number="4122",
                    channel="stable",
                    title="Argent 0.2.0",
                    url="https://github.com/CyR1en/Argent/releases/download/v0.2.0/Argent-0.2.0.dmg",
                ),
            )
            items = ET.parse(appcast).getroot().findall("channel/item")
            # Stable 4122 strictly beats same-commit beta 4121 and nightly 4120.
            self.assertEqual(
                [(i.findtext("guid"), i.findtext(f"{SP}version"), i.findtext(f"{SP}channel")) for i in items],
                [
                    ("argent-release-0.2.0", "4122", None),
                    ("argent-release-0.2.0-beta.1", "4121", "nightly"),
                    ("argent-nightly", "4120", "nightly"),
                ],
            )
            # Next commit on main advances nightly to 4130, strictly above 4122.
            MOD.upsert_manifest_and_rebuild(
                manifests,
                appcast,
                make_manifest(
                    kind="nightly",
                    version="0.2.0",
                    short_version="0.2.0 nightly (bbb2222)",
                    build_number="4130",
                    channel="nightly",
                    title="Nightly 413",
                    url="https://github.com/CyR1en/Argent/releases/download/nightly/Argent-nightly.dmg",
                ),
            )
            # Older nightly rerun must not downgrade 4130 back to 4120.
            MOD.upsert_manifest_and_rebuild(
                manifests,
                appcast,
                make_manifest(
                    kind="nightly",
                    version="0.1.0",
                    short_version="0.1.0 nightly (aaa1111)",
                    build_number="4120",
                    channel="nightly",
                    title="Nightly 412",
                    url="https://github.com/CyR1en/Argent/releases/download/nightly/Argent-nightly.dmg",
                ),
            )
            items = ET.parse(appcast).getroot().findall("channel/item")
            self.assertEqual(
                [(i.findtext("guid"), i.findtext(f"{SP}version"), i.findtext(f"{SP}channel")) for i in items],
                [
                    ("argent-nightly", "4130", "nightly"),
                    ("argent-release-0.2.0", "4122", None),
                    ("argent-release-0.2.0-beta.1", "4121", "nightly"),
                ],
            )

    def test_rejects_invalid_manifests(self):
        with tempfile.TemporaryDirectory() as tmp:
            appcast = Path(tmp) / "appcast.xml"
            with self.assertRaises(ValueError):
                MOD.update_appcast(appcast, make_manifest(url="http://insecure.example/Argent.dmg"))
            with self.assertRaises(ValueError):
                MOD.update_appcast(appcast, make_manifest(ed_signature=""))
            with self.assertRaises(ValueError):
                MOD.update_appcast(appcast, make_manifest(build_number="not-a-number"))


if __name__ == "__main__":
    unittest.main()
