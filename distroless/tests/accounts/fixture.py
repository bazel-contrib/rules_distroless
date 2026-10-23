"""Create synthetic OCI layers for metadata tests; no packages are built."""

import hashlib
import io
import json
import subprocess
import tarfile
from pathlib import Path


def archive(path, entries):
    with tarfile.open(path, "w") as output:
        for name, value in entries.items():
            data, mode = value if isinstance(value, tuple) else (value, 0o644)
            item = tarfile.TarInfo(name)
            item.size, item.mode = len(data), mode
            output.addfile(item, io.BytesIO(data))
    return path


def layout(root, layers, architecture="amd64", diff_ids=None):
    directory = root / "blobs/sha256"
    directory.mkdir(parents=True, exist_ok=True)

    def blob(contents):
        digest = hashlib.sha256(contents).hexdigest()
        (directory / digest).write_bytes(contents)
        return {"digest": "sha256:" + digest, "size": len(contents)}

    descriptors = [blob(layer.read_bytes()) for layer in layers]
    config = {
        "architecture": architecture,
        "os": "linux",
        "rootfs": {
            "type": "layers",
            "diff_ids": diff_ids or [entry["digest"] for entry in descriptors],
        },
    }
    manifest = {
        "schemaVersion": 2,
        "config": blob(json.dumps(config).encode()),
        "layers": descriptors,
    }
    descriptor = blob(json.dumps(manifest).encode())
    (root / "index.json").write_text(
        json.dumps({"schemaVersion": 2, "manifests": [descriptor]})
    )
    (root / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}')
    return root


if __name__ == "__main__":
    import argparse
    import tempfile

    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--architecture", required=True)
    parser.add_argument(
        "--compression", choices=("none", "gzip", "xz", "zstd"), default="none"
    )
    parser.add_argument("--bsdtar", required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        layer = archive(
            Path(temporary) / "base.tar",
            {
                "etc/passwd": b"root:x:0:0:root:/root:/bin/bash\n_apt:x:42:65534::/nonexistent:/usr/sbin/nologin\n",
                "etc/group": b"root:x:0:\nnogroup:x:65534:\n",
            },
        )
        diff_ids = ["sha256:" + hashlib.sha256(layer.read_bytes()).hexdigest()]
        if args.compression != "none":
            compressed = Path(temporary) / ("base.tar." + args.compression)
            subprocess.run(
                [
                    args.bsdtar,
                    "--create",
                    "--file",
                    str(compressed),
                    "--" + args.compression,
                    "@" + str(layer),
                ],
                check=True,
            )
            layer = compressed
        layout(args.output, [layer], args.architecture, diff_ids)
