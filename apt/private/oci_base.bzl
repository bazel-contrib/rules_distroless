"""Reads what a base image has installed, for `apt.install(bases = ...)`.

A base is the `index.json` of a single-platform OCI image layout, which is
what `oci.pull` from rules_oci makes for each platform it pulls (for example
`@ubuntu_linux_amd64//:index.json`). Works from a module extension and from a
repository rule alike.
"""

load(":deb_archive.bzl", "host_bsdtar")

_STATUS = "var/lib/dpkg/status"
_STATUS_D = "var/lib/dpkg/status.d/"

# OCI's `architecture` (and `variant`) as Debian names it.
# https://github.com/opencontainers/image-spec/blob/main/image-index.md#platform-variants
_DEBIAN_ARCHITECTURES = {
    "amd64": "amd64",
    "arm64": "arm64",
    "arm/v5": "armel",
    "arm/v6": "armel",
    "arm/v7": "armhf",
    "386": "i386",
    "mips64le": "mips64el",
    "ppc64le": "ppc64el",
    "riscv64": "riscv64",
    "s390x": "s390x",
}

def debian_architecture(config):
    """The Debian architecture of an image.

    Args:
        config: the image's config.

    Returns:
        The architecture as Debian names it, such as `armhf` for arm/v7.
    """
    platform = config["architecture"]
    if platform == "arm":
        platform += "/" + config.get("variant", "v7")
    if platform not in _DEBIAN_ARCHITECTURES:
        fail("Base image architecture %s has no Debian equivalent." % platform)
    return _DEBIAN_ARCHITECTURES[platform]

def installed_stanzas(status):
    """The stanzas of a dpkg status file whose package is installed.

    Args:
        status: the contents of a dpkg status file.

    Returns:
        A list of stanzas, leaving out packages removed but for their config
        files, and any half-installed or half-configured.
    """
    stanzas = []
    for stanza in status.split("\n\n"):
        for line in stanza.split("\n"):
            if line.startswith("Status: ") and line.endswith(" installed"):
                stanzas.append(stanza.strip("\n"))
                break
    return stanzas

def stanza_field(stanza, field):
    for line in stanza.split("\n"):
        if line.startswith(field + ": "):
            return line[len(field) + 2:]
    return None

def _blob(layout, digest):
    (algorithm, hex) = digest.split(":", 1)
    return layout.get_child("blobs").get_child(algorithm).get_child(hex)

def _name(entry):
    return entry.removeprefix("./")

def _whiteout(entry):
    """What a whiteout entry deletes, or None if it is not one."""
    (parent, _, base) = entry.rpartition("/")
    if base == ".wh..wh..opq":
        return parent + "/"
    if base.startswith(".wh."):
        return parent + "/" + base.removeprefix(".wh.")
    return None

def _is_status(name):
    return name == _STATUS or (name.startswith(_STATUS_D) and not name.endswith(".md5sums") and name != _STATUS_D)

def read_base(ctx, label):
    """The Debian architecture of a base image, and its installed packages.

    Args:
        ctx: repository_ctx or module_ctx.
        label: the `index.json` of a single-platform OCI image layout.

    Returns:
        struct(architecture, stanzas): stanzas is the dpkg status of every
        package installed, from /var/lib/dpkg/status and, as distroless images
        keep it, /var/lib/dpkg/status.d/.
    """
    index_json = ctx.path(label)
    layout = index_json.dirname
    manifests = json.decode(ctx.read(index_json))["manifests"]
    if len(manifests) != 1:
        fail("%s: a base is a single-platform image, and this layout has %d manifests." % (label, len(manifests)))
    manifest = json.decode(ctx.read(_blob(layout, manifests[0]["digest"])))
    if "layers" not in manifest:
        fail("%s: a base is a single-platform image; this is an index. Use the repository oci.pull makes for one platform, such as @<name>_linux_amd64." % label)
    config = json.decode(ctx.read(_blob(layout, manifest["config"]["digest"])))

    tar = host_bsdtar(ctx)

    # The files that make up the status, from the bottom layer to the top, as
    # overlayfs would see them: a layer's file replaces one below it, and a
    # whiteout deletes one.
    files = {}
    for layer in manifest["layers"]:
        blob = _blob(layout, layer["digest"])
        listing = ctx.execute([tar, "-tf", blob])
        if listing.return_code:
            fail("failed to list %s of %s: %s" % (layer["digest"], label, listing.stderr))
        entries = listing.stdout.splitlines()

        for entry in entries:
            deleted = _whiteout(_name(entry))
            if deleted == None:
                continue
            for name in files.keys():
                if name == deleted or (deleted.endswith("/") and name.startswith(deleted)):
                    files.pop(name)

        for entry in entries:
            if not _is_status(_name(entry)):
                continue
            extract = ctx.execute([tar, "-xOf", blob, entry])
            if extract.return_code:
                fail("failed to extract %s from %s of %s: %s" % (entry, layer["digest"], label, extract.stderr))
            files[_name(entry)] = extract.stdout

    stanzas = []
    for name in sorted(files.keys()):
        if name == _STATUS:
            stanzas.extend(installed_stanzas(files[name]))
        else:
            # status.d has one file per package, installed by being there.
            stanzas.extend([s.strip("\n") for s in files[name].split("\n\n") if s.strip()])

    return struct(
        architecture = debian_architecture(config),
        stanzas = stanzas,
    )
