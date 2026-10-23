# Add service accounts while keeping the base image's accounts

The public `passwd` and `group` rules create complete files from their entry
lists. Use `accounts` when extending an existing image: it reads that base's
current `/etc/passwd` and `/etc/group`, then appends only the declared additions.
This addresses the base-preservation use case in
[issue #278](https://github.com/bazel-contrib/rules_distroless/issues/278).

```starlark
load("@rules_distroless//distroless:defs.bzl", "accounts")

accounts(
    name = "redis_accounts",
    base = ":base",
    architecture = "amd64",
    users = [{
        "username": "redis",
        "password": "x",
        "uid": 100,
        "gid": 101,
        "home": "/var/lib/redis",
        "shell": "/usr/sbin/nologin",
    }],
    groups = [{"name": "redis", "password": "x", "gid": 101}],
)
```

Add `:redis_accounts` to the child `oci_image.tars`, using the same `:base`.
For example, if the base has users `root` and `_apt`, the new image has `root`,
`_apt` and `redis`. Existing records retain their exact bytes. A newer base can
add users without needing a second account list in the child image.

The combined rule checks user primary groups and explicit group members against
both sets of additions; separate `passwd(base=...)` and `group(base=...)` calls
could not check that relationship without additional wiring. Existing standalone
`passwd`/`group` calls keep their behavior and remain useful for images assembled
from scratch.

An identical existing record is retained without duplication. Conflicting names
or numeric IDs fail the build: adding a new user with UID `0` cannot silently
share root's identity. Names such as `Debian-exim` and `monitor.agent` are preserved.
The base must have regular root-owned `0644` account files. Account-path ancestors
must be directories; a layer replacing `/etc` with a symlink or file is rejected.
OCI manifest/config/layer blob identities and the expected Linux architecture
are checked before reading account records. Later layers and OCI whiteouts are
honored, including deleted files; obsolete lower-layer records are not restored.

The merger runs with a declared Python execution toolchain. It uses the declared
BSD tar toolchain to read uncompressed, gzip, xz and zstd layers, and reuses the
existing account writers and TAR rule to produce the final layer. No programs
from the image run. Only `/etc/passwd` and `/etc/group` are changed; installing
packages, creating home directories and populating password databases remain
separate tasks.

`:redis_accounts.receipt` provides JSON containing the checked base manifest
digest, requested names and resulting account-file hashes. The tests in this
package cover preservation, conflicts, idempotency, whiteouts, architecture and
the public TAR interface for each supported compression format.
