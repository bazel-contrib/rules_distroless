"""Inspect the public rule's output from real Distroless account additions."""

import json
import sys
import tarfile
from pathlib import Path

with tarfile.open(sys.argv[1]) as archive:
    files = {entry.name.removeprefix("./"): entry for entry in archive}
    assert set(files) == {"etc", "etc/passwd", "etc/group"}, files
    for name in ("etc/passwd", "etc/group"):
        assert files[name].uid == files[name].gid == 0 and files[name].mode == 0o644
    passwd = archive.extractfile(files["etc/passwd"]).read().decode()
    group = archive.extractfile(files["etc/group"]).read().decode()
    assert "_apt:x:42:65534::/nonexistent:/usr/sbin/nologin\n" in passwd
    assert "redis:x:100:101::/var/lib/redis:/usr/sbin/nologin\n" in passwd
    assert "redis:x:101:\n" in group and "_ssh:x:104:\n" in group
receipt = json.loads(Path(sys.argv[2]).read_text())
assert receipt["users"] == ["redis"] and receipt["groups"] == ["redis", "_ssh"]
