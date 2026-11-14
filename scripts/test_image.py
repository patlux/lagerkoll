#!/usr/bin/env python3
"""Tests for scripts/image.py: archive layout, determinism, image config."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import sys
import tarfile
import unittest
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location("image", Path(__file__).with_name("image.py"))
assert _SPEC and _SPEC.loader
image = importlib.util.module_from_spec(_SPEC)
sys.modules["image"] = image
_SPEC.loader.exec_module(image)

BINARY = b"\x7fELF" + b"\x00" * 60
REPO = "registry.example.org/lagerkoll"
CA = b"-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"


def members(data: bytes) -> dict[str, tuple[tarfile.TarInfo, bytes | None]]:
    out = {}
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        for info in tar.getmembers():
            f = tar.extractfile(info) if info.isfile() else None
            out[info.name] = (info, f.read() if f else None)
    return out


class ArchiveTests(unittest.TestCase):
    def test_same_input_same_bytes(self) -> None:
        a = image.archive(BINARY, CA, "0.1.0", "abc", REPO)
        b = image.archive(BINARY, CA, "0.1.0", "abc", REPO)
        self.assertEqual(hashlib.sha256(a).hexdigest(), hashlib.sha256(b).hexdigest())
        self.assertNotEqual(a, image.archive(BINARY, CA, "0.1.1", "abc", REPO))

    def test_docker_save_layout_and_config(self) -> None:
        outer = members(image.archive(BINARY, CA, "0.1.0", "abc", REPO))
        manifest = json.loads(outer["manifest.json"][1])
        self.assertEqual(manifest[0]["RepoTags"], ["registry.example.org/lagerkoll:0.1.0"])
        config_bytes = outer[manifest[0]["Config"]][1]
        self.assertEqual(manifest[0]["Config"], hashlib.sha256(config_bytes).hexdigest() + ".json")
        config = json.loads(config_bytes)
        self.assertEqual((config["os"], config["architecture"]), ("linux", "amd64"))
        self.assertEqual(config["config"]["Entrypoint"], ["/bin/lagerkoll"])
        self.assertEqual(config["config"]["User"], "65534:65534")
        self.assertNotIn("/nix/store", json.dumps(config))
        self.assertEqual(config["config"]["Labels"]["org.opencontainers.image.revision"], "abc")

        layer_bytes = outer[manifest[0]["Layers"][0]][1]
        self.assertEqual(config["rootfs"]["diff_ids"], ["sha256:" + hashlib.sha256(layer_bytes).hexdigest()])
        layer = members(layer_bytes)
        info, data = layer["bin/lagerkoll"]
        self.assertEqual((data, info.mode, info.uid, info.mtime), (BINARY, 0o755, 0, 0))
        info, data = layer["etc/ssl/certs/ca-certificates.crt"]
        self.assertEqual((data, info.mode), (CA, 0o644))
        self.assertEqual(layer["tmp"][0].mode, 0o1777)


class RepositoryTests(unittest.TestCase):
    def test_accepts_registry_paths_without_tag(self) -> None:
        for good in ("registry.example.org/lagerkoll", "localhost:5000/a/b", "ghcr.io/user/lagerkoll"):
            self.assertRegex(good, image.REPOSITORY_RE)
        for bad in ("lagerkoll", "registry.example.org/lagerkoll:0.1.0", "https://x/y", "Reg/x", ""):
            self.assertNotRegex(bad, image.REPOSITORY_RE)


if __name__ == "__main__":
    unittest.main()
