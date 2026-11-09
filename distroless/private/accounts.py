"""Add declared service accounts without replacing the base image's accounts."""

import argparse
import hashlib
import json
import re
import subprocess
import tarfile
import tempfile
from contextlib import contextmanager
from pathlib import Path, PurePosixPath
from typing import NamedTuple


class OciLayout(NamedTuple):
    """Validated image metadata and its hash-checked layer paths."""

    descriptor: dict
    manifest: dict
    config: dict
    layers: tuple[Path, ...]


def validate_layout(directory: Path, expected_platform: str) -> OciLayout:
    """Require one complete image and return its validated metadata and layers."""
    try:
        return _validate_layout(directory, expected_platform)
    except (AttributeError, KeyError, TypeError) as error:
        raise ValueError("invalid OCI layout metadata structure") from error


def _validate_layout(directory: Path, expected_platform: str) -> OciLayout:
    if len(expected_platform.split("/")) != 2 or not all(expected_platform.split("/")):
        raise ValueError("expected platform must be os/architecture")
    marker = json.loads((directory / "oci-layout").read_bytes())
    if marker.get("imageLayoutVersion") != "1.0.0":
        raise ValueError("unsupported OCI image layout version")
    index = json.loads((directory / "index.json").read_bytes())
    if index.get("schemaVersion") != 2 or len(index.get("manifests", [])) != 1:
        raise ValueError("expected a single OCI image for " + expected_platform)

    def blob(descriptor):
        digest = descriptor.get("digest", "")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise ValueError("invalid OCI SHA256 blob reference")
        path = directory / "blobs" / "sha256" / digest[7:]
        hasher = hashlib.sha256()
        size = 0
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                hasher.update(chunk)
                size += len(chunk)
        if hasher.hexdigest() != digest[7:] or size != descriptor.get("size"):
            raise ValueError("OCI blob digest or size mismatch: " + digest)
        return path

    descriptor = index["manifests"][0]
    manifest = json.loads(blob(descriptor).read_bytes())
    if manifest.get("schemaVersion") != 2:
        raise ValueError("unsupported OCI manifest schema")
    config = json.loads(blob(manifest["config"]).read_bytes())
    platforms = [config]
    if "platform" in descriptor:
        platforms.append(descriptor["platform"])
    for platform in platforms:
        actual = platform.get("os", "") + "/" + platform.get("architecture", "")
        if actual != expected_platform:
            raise ValueError(
                f"OCI image platform {actual!r} does not match {expected_platform!r}"
            )
    layers = manifest["layers"]
    rootfs = config.get("rootfs", {})
    if rootfs.get("type") != "layers" or len(rootfs.get("diff_ids", [])) != len(layers):
        raise ValueError("OCI layer count does not match image rootfs")
    return OciLayout(
        descriptor, manifest, config, tuple(blob(layer) for layer in layers)
    )


@contextmanager
def read_archive(path, bsdtar=None):
    """Use the declared BSD tar for compression, without extracting to disk."""
    if bsdtar is None:  # Unit fixtures use Python's uncompressed/gzip reader.
        with tarfile.open(path, "r:*") as archive:
            yield archive
        return
    # Re-emit a PAX stream so libarchive handles gzip, xz and zstd. The Python
    # standard library reads archive metadata; no files are extracted to disk.
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(
            [
                str(bsdtar),
                "--create",
                "--file",
                "-",
                "--format=pax",
                "--absolute-paths",
                "@" + str(path),
            ],
            stdout=subprocess.PIPE,
            stderr=errors,
        )
        try:
            with tarfile.open(fileobj=process.stdout, mode="r|") as archive:
                yield archive
            # Consume any final padding before checking the archiver's exit.
            while process.stdout.read(1024 * 1024):
                pass
            if process.wait() != 0:
                errors.seek(0)
                raise ValueError(
                    "Cannot read OCI account archive: "
                    + errors.read().decode(errors="replace")
                )
        finally:
            process.stdout.close()
            if process.poll() is None:
                process.kill()
                process.wait()


def read_files(layers, names, bsdtar=None):
    result = {}
    ancestors = {
        str(parent) for name in names for parent in PurePosixPath(name).parents
    }
    for layer in layers:
        additions, removals = {}, set()
        with read_archive(layer, bsdtar) as archive:
            for member in archive:
                path = PurePosixPath(member.name)
                if path.is_absolute() or ".." in path.parts:
                    raise ValueError("unsafe OCI layer path: " + member.name)
                name = str(path)
                if name in names:
                    if not member.isfile():
                        raise ValueError("expected a regular OCI file: " + name)
                    additions[name] = (archive.extractfile(member).read(), member)
                elif name in ancestors and not member.isdir():
                    raise ValueError(
                        "expected a directory for OCI account file ancestor: " + name
                    )
                elif path.name == ".wh..wh..opq":
                    parent = str(path.parent)
                    removals.update(
                        n for n in names if parent == "." or n.startswith(parent + "/")
                    )
                elif path.name.startswith(".wh."):
                    hidden = str(path.parent / path.name[4:])
                    removals.update(
                        n for n in names if n == hidden or n.startswith(hidden + "/")
                    )
        for name in removals:
            result.pop(name, None)
        result.update(additions)
    return result


def require(value, message):
    if not value:
        raise ValueError(message)


def records(contents, kind):
    rows, numbers = {}, {}
    for line in contents.decode("utf-8").splitlines():
        if not line:
            continue
        fields = line.split(":")
        require(
            len(fields) == (7 if kind == "passwd" else 4), "invalid " + kind + " record"
        )
        name = fields[0]
        # Account files may contain names such as Debian-exim or service.name.
        # Validate their structure without imposing a user-creation policy.
        require(name, "invalid account name: empty name")
        require(
            name not in rows and "\x00" not in line,
            "duplicate or invalid account: " + name,
        )
        indexes = (2, 3) if kind == "passwd" else (2,)
        require(
            all(fields[i].isdigit() and int(fields[i]) < 2**32 - 1 for i in indexes),
            "invalid account ID: " + name,
        )
        rows[name] = fields
        numbers.setdefault(int(fields[2]), set()).add(name)
    return rows, numbers


def merge(original, additions, kind):
    existing, numbers = records(original, kind)
    requested, _ = records(additions, kind)
    lines = []
    for name, fields in requested.items():
        if name in existing:
            require(existing[name] == fields, "account differs from the base: " + name)
            continue
        number = int(fields[2])
        require(
            number not in numbers,
            "account ID already belongs to "
            + ",".join(sorted(numbers.get(number, []))),
        )
        numbers[number] = {name}
        existing[name] = fields
        lines.append(":".join(fields))
    if not lines:
        return original
    return (
        original
        + (b"\n" if original and not original.endswith(b"\n") else b"")
        + ("\n".join(lines) + "\n").encode()
    )


def build(base, users, groups, architecture, bsdtar=None):
    layout = validate_layout(base, "linux/" + architecture)
    names = {"etc/passwd", "etc/group"}
    original = read_files(layout.layers, names, bsdtar)
    require(set(original) == names, "base image lacks passwd or group")
    additions = read_files([users, groups], names, bsdtar)
    require(set(additions) == names, "account additions lack passwd or group")
    merged = {}
    for path in sorted(names):
        contents, member = original[path]
        require(
            member.uid == member.gid == 0 and member.mode == 0o644,
            "unsupported base account file ownership or mode: " + path,
        )
        merged[path] = merge(contents, additions[path][0], path.split("/")[-1])
    passwd, _ = records(merged["etc/passwd"], "passwd")
    group, _ = records(merged["etc/group"], "group")
    gids = {int(row[2]) for row in group.values()}
    requested, _ = records(additions["etc/passwd"][0], "passwd")
    require(
        all(int(row[3]) in gids for row in requested.values()),
        "service account primary group is absent",
    )
    requested_groups, _ = records(additions["etc/group"][0], "group")
    require(
        all(
            not row[3] or set(row[3].split(",")) <= set(passwd)
            for row in requested_groups.values()
        ),
        "service group contains an absent user",
    )
    receipt = {
        "_generated": "AUTO-GENERATED by rules_distroless/distroless/private/accounts.py. DO NOT EDIT MANUALLY.",
        "schema": 1,
        "architecture": architecture,
        "base_manifest_digest": layout.descriptor["digest"],
        "users": list(requested),
        "groups": list(requested_groups),
        "files": {
            path: {
                "base_sha256": hashlib.sha256(original[path][0]).hexdigest(),
                "sha256": hashlib.sha256(contents).hexdigest(),
                "uid": 0,
                "gid": 0,
                "mode": 0o644,
            }
            for path, contents in merged.items()
        },
    }
    return merged, receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("base", "users", "groups", "passwd-out", "group-out", "receipt"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--architecture", required=True)
    parser.add_argument("--bsdtar", required=True, type=Path)
    args = parser.parse_args()
    files, receipt = build(
        args.base, args.users, args.groups, args.architecture, args.bsdtar
    )
    args.passwd_out.write_bytes(files["etc/passwd"])
    args.group_out.write_bytes(files["etc/group"])
    args.receipt.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
