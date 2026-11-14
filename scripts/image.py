#!/usr/bin/env python3
"""Build and publish the lagerkoll container image (linux/amd64) without Docker.

    scripts/image.py build   --repository REPO --ca-bundle FILE               zig-out/image/lagerkoll-<version>.tar
    scripts/image.py publish --repository REPO --ca-bundle FILE --crane BIN   push it as REPO:<version>

REPO is the image repository without a tag, e.g. registry.example.org/lagerkoll.

The image holds two files: the static binary (/bin/lagerkoll, x86_64-linux-musl, ReleaseSafe)
and a CA bundle (/etc/ssl/certs/ca-certificates.crt, where Zig's std looks on Linux). It runs as
65534:65534. The archive is a `docker save` tarball with fixed timestamps and owners, so the same
tree and the same CA bundle give the same digest. `crane push` uploads it unchanged.

publish only runs on a clean `main` whose version has a CHANGELOG.md section, and never pushes a
tag that already exists in the registry.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NAME = "lagerkoll"
REPOSITORY_RE = re.compile(r"^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$")
TARGET = "x86_64-linux-musl"
PREFIX = ROOT / "zig-out" / "linux-amd64"
OUT_DIR = ROOT / "zig-out" / "image"


class ImageError(Exception):
    pass


def run(*args: str, capture: bool = False) -> str:
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=capture)
    if result.returncode:
        detail = (result.stderr or "").strip() if capture else ""
        raise ImageError(f"{' '.join(args[:3])} … failed ({result.returncode}) {detail}".strip())
    return result.stdout if capture else ""


def version() -> str:
    text = (ROOT / "build.zig.zon").read_text()
    match = re.search(r'^\s*\.version\s*=\s*"([^"]+)",', text, re.MULTILINE)
    if not match:
        raise ImageError("no .version in build.zig.zon")
    return match.group(1)


def build_binary() -> Path:
    run("mise", "x", "--", "zig", "build", "-Doptimize=ReleaseSafe", f"-Dtarget={TARGET}", "-Dcpu=baseline",
        "--prefix", str(PREFIX))
    binary = PREFIX / "bin" / NAME
    head = binary.read_bytes()[:20]
    # ELF, 64-bit, little endian, e_machine 0x3e (x86-64)
    if head[:4] != b"\x7fELF" or head[4] != 2 or head[5] != 1 or head[18:20] != b"\x3e\x00":
        raise ImageError(f"{binary} is not an x86-64 ELF binary")
    return binary


def tar_entry(tar: tarfile.TarFile, name: str, data: bytes | None, mode: int) -> None:
    info = tarfile.TarInfo(name)
    info.mtime = 0
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mode = mode
    if data is None:
        info.type = tarfile.DIRTYPE
        tar.addfile(info)
    else:
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))


def layer(binary: bytes, ca_bundle: bytes) -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for d in ("bin", "etc", "etc/ssl", "etc/ssl/certs", "tmp"):
            tar_entry(tar, d + "/", None, 0o1777 if d == "tmp" else 0o755)
        tar_entry(tar, f"bin/{NAME}", binary, 0o755)
        tar_entry(tar, "etc/ssl/certs/ca-certificates.crt", ca_bundle, 0o644)
    return buf.getvalue()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def archive(binary: bytes, ca_bundle: bytes, ver: str, revision: str, repository: str) -> bytes:
    layer_tar = layer(binary, ca_bundle)
    diff_id = sha256(layer_tar)
    config = {
        "architecture": "amd64",
        "os": "linux",
        "created": "1970-01-01T00:00:00Z",
        "config": {
            "Entrypoint": [f"/bin/{NAME}"],
            "User": "65534:65534",
            "Env": ["PATH=/bin"],
            "WorkingDir": "/",
            "Labels": {
                "org.opencontainers.image.title": NAME,
                "org.opencontainers.image.version": ver,
                "org.opencontainers.image.revision": revision,
            },
        },
        "rootfs": {"type": "layers", "diff_ids": [f"sha256:{diff_id}"]},
        "history": [{"created": "1970-01-01T00:00:00Z", "created_by": "scripts/image.py"}],
    }
    config_bytes = json.dumps(config, sort_keys=True, separators=(",", ":")).encode()
    config_name = f"{sha256(config_bytes)}.json"
    layer_name = f"{diff_id}/layer.tar"
    manifest = [{"Config": config_name, "RepoTags": [f"{repository}:{ver}"], "Layers": [layer_name]}]
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        tar_entry(tar, f"{diff_id}/", None, 0o755)
        tar_entry(tar, layer_name, layer_tar, 0o644)
        tar_entry(tar, config_name, config_bytes, 0o644)
        tar_entry(tar, "manifest.json", json.dumps(manifest, separators=(",", ":")).encode(), 0o644)
    return buf.getvalue()


def build(ca_bundle_path: Path, released: bool, repository: str) -> tuple[Path, str]:
    ca_bundle = ca_bundle_path.read_bytes()
    if b"-----BEGIN CERTIFICATE-----" not in ca_bundle or len(ca_bundle) < 10_000:
        raise ImageError(f"{ca_bundle_path} does not look like a CA bundle")
    ver = version()
    revision = run("git", "rev-parse", "HEAD", capture=True).strip()
    dirty = bool(run("git", "status", "--porcelain", capture=True).strip())
    if dirty and released:
        raise ImageError("the working tree is dirty; publish only a committed release")
    binary = build_binary().read_bytes()
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out = OUT_DIR / f"{NAME}-{ver}.tar"
    out.write_bytes(archive(binary, ca_bundle, ver, revision + ("-dirty" if dirty else ""), repository))
    return out, ver


def check_release(ver: str) -> None:
    branch = run("git", "branch", "--show-current", capture=True).strip()
    if branch != "main":
        raise ImageError(f"publish runs on main, not {branch or 'a detached HEAD'}")
    pending = [p for p in (ROOT / ".changeset").glob("*.md") if p.name != "README.md"]
    if pending:
        raise ImageError(f"{len(pending)} pending changesets: release first (make version)")
    if not re.search(rf"^## {re.escape(ver)} - ", (ROOT / "CHANGELOG.md").read_text(), re.MULTILINE):
        raise ImageError(f"CHANGELOG.md has no section for {ver}: release first (make version)")


def registry_digest(crane: str, ref: str) -> str | None:
    result = subprocess.run([crane, "digest", ref], text=True, capture_output=True)
    if result.returncode == 0 and result.stdout.strip().startswith("sha256:"):
        return result.stdout.strip()
    if "MANIFEST_UNKNOWN" in result.stderr or "NAME_UNKNOWN" in result.stderr:
        return None
    raise ImageError(f"registry lookup of {ref} failed: {result.stderr.strip()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=["build", "publish"])
    parser.add_argument("--repository", required=True, help="image repository without tag")
    parser.add_argument("--ca-bundle", required=True, type=Path)
    parser.add_argument("--crane", help="crane binary (publish)")
    args = parser.parse_args()
    try:
        if not REPOSITORY_RE.match(args.repository):
            raise ImageError(f"--repository {args.repository!r} is not host[:port]/path without a tag")
        if args.mode == "build":
            out, _ = build(args.ca_bundle, released=False, repository=args.repository)
            print(out)
            return 0
        if not args.crane:
            raise ImageError("publish needs --crane")
        ver = version()
        check_release(ver)
        ref = f"{args.repository}:{ver}"
        existing = registry_digest(args.crane, ref)
        if existing:
            print(f"{ref} already exists as {existing}; not pushing again", file=sys.stderr)
            print(f"{args.repository}@{existing}")
            return 0
        out, _ = build(args.ca_bundle, released=True, repository=args.repository)
        run(args.crane, "push", str(out), ref)
        config = json.loads(run(args.crane, "config", ref, capture=True))
        if (config.get("os"), config.get("architecture")) != ("linux", "amd64"):
            raise ImageError("the pushed image is not linux/amd64")
        digest = registry_digest(args.crane, ref)
        print(f"pushed {ref}", file=sys.stderr)
        print(f"{args.repository}@{digest}")
        return 0
    except ImageError as err:
        print(f"image: {err}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
