"apt extensions"

load("@bazel_tools//tools/build_defs/repo:utils.bzl", "read_netrc", "read_user_netrc", "use_netrc")
load("//apt/private:apt_deb_repository.bzl", "deb_repository")
load("//apt/private:apt_dep_resolver.bzl", "dependency_resolver")
load("//apt/private:deb_filemap.bzl", "deb_filemap")
load("//apt/private:deb_import.bzl", "deb_import")
load("//apt/private:lockfile.bzl", "lockfile")
load("//apt/private:translate_dependency_set.bzl", "translate_dependency_set")
load("//apt/private:util.bzl", "util")
load("//apt/private:version_constraint.bzl", "version_constraint")

# https://wiki.debian.org/SupportedArchitectures
ALL_SUPPORTED_ARCHES = ["armel", "armhf", "arm64", "i386", "amd64", "mips64el", "ppc64el", "x390x"]

ITERATION_MAX = 2147483646

def _get_auth(mctx, urls):
    """Given the list of URLs obtain the correct auth dict."""
    if "NETRC" in mctx.os.environ:
        netrc = read_netrc(mctx, mctx.os.environ["NETRC"])
    else:
        netrc = read_user_netrc(mctx)
    return use_netrc(netrc, urls, {})

def _find_pgp_verifier(mctx):
    """Detect available OpenPGP verifier, preferring sqv over gpgv."""
    if mctx.which("sqv"):
        return "sqv"
    if mctx.which("gpgv"):
        return "gpgv"
    return None

def _format_verifier_output(res, verifier):
    details = []
    if res.stderr:
        details.append("stderr:\n" + res.stderr)
    if res.stdout:
        details.append("stdout:\n" + res.stdout)
    out_str = "\n".join(details) if details else "no output"
    return "{} exit code: {}\n{}".format(verifier, res.return_code, out_str)

def _verifier_cmd(verifier, keyring_args, mode, sig_path, msg_path = None, out_path = None):
    """Builds execution command arguments for gpgv or sqv."""
    if verifier == "gpgv":
        if mode == "clearsigned":
            return ["gpgv"] + keyring_args + [str(sig_path)]
        return ["gpgv"] + keyring_args + [str(sig_path), str(msg_path)]
    elif verifier == "sqv":
        if mode == "clearsigned":
            return ["sqv"] + keyring_args + ["--cleartext", "--output", str(out_path), str(sig_path)]
        return ["sqv"] + keyring_args + ["--signature-file", str(sig_path), str(msg_path)]
    else:
        fail("No OpenPGP verifier found (gpgv or sqv).")

def _verify_inrelease(mctx, verifier, keyring_args, in_release_path, output_verified_path):
    """Verifies InRelease using gpgv or sqv and returns (success, content_or_error)."""

    # sqv creates its output with create_new(true) and fails with os error 17 if the output file already exists.
    # Since module_ctx lacks repository_ctx.delete(), we remove any leftover file from earlier runs.
    mctx.execute(["rm", "-f", str(mctx.path(output_verified_path))])

    cmd = _verifier_cmd(
        verifier,
        keyring_args,
        "clearsigned",
        mctx.path(in_release_path),
        out_path = mctx.path(output_verified_path),
    )
    res = mctx.execute(cmd)
    if res.return_code != 0:
        return (False, _format_verifier_output(res, verifier))
    if verifier == "gpgv":
        return (True, util.strip_pgp_clearsign_armor(mctx.read(in_release_path)))
    return (True, mctx.read(output_verified_path))

def _verify_detached_release(mctx, verifier, keyring_args, release_gpg_path, release_path):
    """Verifies detached Release.gpg signature against Release using gpgv or sqv."""
    cmd = _verifier_cmd(
        verifier,
        keyring_args,
        "detached",
        mctx.path(release_gpg_path),
        msg_path = mctx.path(release_path),
    )
    res = mctx.execute(cmd)
    if res.return_code != 0:
        return (False, _format_verifier_output(res, verifier))
    return (True, mctx.read(release_path))

def _prepare_keyring_paths(mctx, verifier, gpg_keys):
    """Prepares keyring file paths, automatically dearmoring ASCII keys if using gpgv."""
    paths = []
    for key_label in gpg_keys:
        key_path = mctx.path(key_label)
        if verifier == "gpgv":
            key_str = str(key_path)

            # Binary keyrings (.gpg, .kbx) require no dearmoring; avoid reading raw binary data
            if not key_str.endswith(".gpg") and not key_str.endswith(".kbx"):
                content = mctx.read(key_path)
                if util.is_ascii_armored(content):
                    dearmored_rel_path = "dearmored_key_{}.gpg".format(util.sanitize(str(key_label)))
                    dearmored_path = mctx.path(dearmored_rel_path)

                    gpg_bin = mctx.which("gpg")
                    sq_bin = mctx.which("sq")
                    if gpg_bin:
                        res = mctx.execute([
                            "gpg",
                            "--dearmor",
                            "--batch",
                            "--yes",
                            "-o",
                            str(dearmored_path),
                            str(key_path),
                        ])
                        if res.return_code != 0:
                            fail("Failed to dearmor ASCII key '{}' with gpg:\n{}\nPlease ensure a modern version of `gpg` (GnuPG 2.x) is installed on PATH.".format(key_label, res.stderr))
                        paths.append(str(dearmored_path))
                        continue
                    elif sq_bin:
                        res = mctx.execute([
                            "sq",
                            "--overwrite",
                            "packet",
                            "dearmor",
                            "--output",
                            str(dearmored_path),
                            str(key_path),
                        ])
                        if res.return_code != 0:
                            fail("Failed to dearmor ASCII key '{}' with sq:\n{}\nPlease ensure a modern version of `sq` (Sequoia PGP >= 1.0 supporting `sq packet dearmor`) is installed on PATH.".format(key_label, res.stderr))
                        paths.append(str(dearmored_path))
                        continue
                    else:
                        fail("Key '{}' is ASCII-armored, but `gpgv` requires binary OpenPGP format. Please install a modern version of `gpg` (GnuPG 2.x) or `sq` (Sequoia PGP >= 1.0) on PATH to auto-dearmor, or provide binary .gpg keyrings.".format(key_label))
        paths.append(str(key_path))
    return paths

def _download_and_verify_release(mctx, urls, dist, gpg_keys):
    """Downloads InRelease (or Release + Release.gpg) and verifies with gpgv/sqv."""
    verifier = _find_pgp_verifier(mctx)
    if not verifier:
        fail("GPG verification requested for dist '{}', but neither `gpgv` nor `sqv` was found on PATH. Please install a modern version of `gpgv` (GnuPG 2.x) or `sqv` (Sequoia PGP >= 1.0).".format(dist))

    keyring_paths = _prepare_keyring_paths(mctx, verifier, gpg_keys)
    keyring_args = util.build_keyring_args(keyring_paths)
    errors = []

    for (url_idx, url) in enumerate(urls):
        in_release_url = "{}/dists/{}/InRelease".format(url, dist)
        in_release_path = "inrelease/{}/{}/InRelease".format(dist, url_idx)
        verified_path = "inrelease/{}/{}/Release.verified".format(dist, url_idx)

        mctx.report_progress("Downloading InRelease from {}".format(in_release_url))
        download = mctx.download(
            url = in_release_url,
            output = in_release_path,
            allow_fail = True,
        )
        if download.success:
            mctx.report_progress("Verifying InRelease signature using {}".format(verifier))
            ok, res = _verify_inrelease(mctx, verifier, keyring_args, in_release_path, verified_path)
            if ok:
                return res
            fail("GPG verification failed for InRelease from {}:\n{}".format(in_release_url, res))
        else:
            errors.append("Failed to download InRelease from {}".format(in_release_url))

        # Fallback to Release + Release.gpg
        release_url = "{}/dists/{}/Release".format(url, dist)
        release_gpg_url = "{}/dists/{}/Release.gpg".format(url, dist)
        release_path = "inrelease/{}/{}/Release".format(dist, url_idx)
        release_gpg_path = "inrelease/{}/{}/Release.gpg".format(dist, url_idx)

        mctx.report_progress("Downloading Release from {}".format(release_url))
        dl_rel = mctx.download(url = release_url, output = release_path, allow_fail = True)
        if dl_rel.success:
            mctx.report_progress("Downloading Release.gpg from {}".format(release_gpg_url))
            dl_gpg = mctx.download(url = release_gpg_url, output = release_gpg_path, allow_fail = True)
            if dl_gpg.success:
                mctx.report_progress("Verifying Release signature using {}".format(verifier))
                ok, res = _verify_detached_release(mctx, verifier, keyring_args, release_gpg_path, release_path)
                if ok:
                    return res
                fail("GPG verification failed for Release from {}:\n{}".format(release_url, res))
            else:
                errors.append("Failed to download Release.gpg from {}".format(release_gpg_url))
        else:
            errors.append("Failed to download Release from {}".format(release_url))

    fail("Failed to fetch or verify repository Release/InRelease for dist '{}':\n{}".format(
        dist,
        "\n".join(errors),
    ))

def _start_downloads(mctx, urls, dist, comp, arch, integrity, index_type, source_id, cached_format = None, hashes = None):
    """Initiate all format downloads for a given index type with block=False.

    If cached_format is set, only that extension is attempted — avoiding
    404 warnings for formats the remote doesn't serve.
    """
    target_triple = "{}/{}/{}".format(dist, comp, arch)

    # See https://linux.die.net/man/1/xz , https://linux.die.net/man/1/gzip , and https://linux.die.net/man/1/bzip2
    #  --keep       -> keep the original file (Bazel might be still committing the output to the cache)
    #  --force      -> overwrite the output if it exists
    #  --decompress -> decompress
    # Order of these matter, we want to try the one that is most likely first.
    if index_type == "Packages":
        extensions = [
            (".xz", ["xz", "--decompress", "--keep", "--force"]),
            (".gz", ["gzip", "--decompress", "--keep", "--force"]),
            (".bz2", ["bzip2", "--decompress", "--keep", "--force"]),
            ("", ["true"]),
        ]
    else:
        extensions = [
            (".gz", ["gzip", "--decompress", "--keep", "--force"]),
            (".xz", ["xz", "--decompress", "--keep", "--force"]),
            (".bz2", ["bzip2", "--decompress", "--keep", "--force"]),
            ("", ["true"]),
        ]

    # Filter extensions if we have verified hashes from Release file
    if hashes != None:
        available_extensions = []
        for (ext, cmd) in extensions:
            if index_type == "Packages":
                path = "{}/binary-{}/{}{}".format(comp, arch, index_type, ext)
            else:
                path = "{}/Contents-{}{}".format(comp, arch, ext)
            if path in hashes:
                available_extensions.append((ext, cmd))
        extensions = available_extensions
        if not extensions:
            if index_type == "Packages":
                fail("No Packages index found in Release file for suite '{}', component '{}', arch '{}'".format(dist, comp, arch))
            else:
                return []

    if cached_format != None:
        extensions = [(ext, cmd) for (ext, cmd) in extensions if ext == cached_format]

    base_auth = _get_auth(mctx, urls)
    tokens = []

    for (url_idx, url) in enumerate(urls):
        for (ext, cmd) in extensions:
            # Each (url, ext) gets a unique output directory to prevent
            # concurrent downloads from clobbering each other's files.
            # Without this, the uncompressed variant ("") and a decompressed
            # .xz/.gz/.bz2 would both write to the same final path.
            ext_name = ext.lstrip(".") if ext else "raw"
            output = "{}/{}/{}/{}/{}{}".format(source_id, target_triple, url_idx, ext_name, index_type, ext)
            if index_type == "Packages":
                path = "{}/binary-{}/{}{}".format(comp, arch, index_type, ext)
                dist_url = "{}/dists/{}/{}".format(url, dist, path)
            else:
                path = "{}/Contents-{}{}".format(comp, arch, ext)
                dist_url = "{}/dists/{}/{}".format(url, dist, path)

            auth = {}
            if url in base_auth:
                auth = {dist_url: base_auth[url]}

            sha256 = ""
            if hashes != None:
                if path not in hashes:
                    fail("Missing SHA256 checksum in Release file for '{}' (suite '{}', component '{}', arch '{}')".format(
                        path,
                        dist,
                        comp,
                        arch,
                    ))
                sha256 = hashes[path]

            token = mctx.download(
                url = dist_url,
                output = output,
                integrity = integrity if hashes == None else "",
                sha256 = sha256,
                allow_fail = True,
                auth = auth,
                block = False,
            )
            tokens.append((ext, cmd, url, url_idx, ext_name, output, token))
    return tokens

def _resolve_downloads(mctx, tokens, index_type, dist, comp, arch):
    """Wait on tokens in priority order, decompress the first success.

    Returns (output_path, url, integrity, ext) on success.
    Returns None for optional Contents when all attempts fail.
    """
    failed_attempts = []
    result = None
    for (ext, cmd, url, url_idx, ext_name, output, token) in tokens:
        download = token.wait()
        decompress_r = None
        if result != None:
            continue
        if download.success:
            decompress_r = mctx.execute(cmd + [output])
            if decompress_r.return_code == 0:
                result = (output.removesuffix(ext) if ext else output, url, download.integrity, ext)
                continue
        failed_attempts.append((url + "/.../" + index_type + ext, download, decompress_r))
    if result != None:
        return result

    if index_type == "Contents":
        # Contents files are optional; some repositories (e.g. packages.cloud.google.com/apt)
        # don't provide them. Print a warning and return None instead of failing.
        print("Warning: Could not fetch Contents index for {}/{}/{}. Contents files are optional.".format(dist, comp, arch))
        return None

    # For Packages, fail with details
    attempt_messages = []
    for (failed_url, download, decompress) in failed_attempts:
        reason = "unknown"
        if not download.success:
            reason = "Download failed. See warning above for details."
        elif decompress.return_code != 0:
            reason = "Decompression failed with non-zero exit code.\n\n{}\n{}".format(decompress.stderr, decompress.stdout)
        attempt_messages.append("""\n*) Failed '{}'\n\n{}""".format(failed_url, reason))

    fail("""
** Tried to download {} different package indices and all failed.

{}
        """.format(len(failed_attempts), "\n".join(attempt_messages)))

def _fetch_and_parse_sources(mctx, repo, glock, snapshot_indices, formats):
    """Fetch all package indices and contents in parallel, then parse them.

    Returns the set (as a dict) of fact keys that belong to the current sources,
    so the caller can prune stale facts left behind by previous URLs.
    """
    pending = []
    seen = {}
    used_keys = {}
    verified_releases = {}

    def get_release_hashes(dist, urls, gpg_keys):
        cache_key = (dist, tuple(urls), tuple([str(k) for k in gpg_keys]))
        if cache_key in verified_releases:
            return verified_releases[cache_key]
        release_content = _download_and_verify_release(mctx, urls, dist, gpg_keys)
        hashes = util.parse_release_file(release_content)
        verified_releases[cache_key] = hashes
        return hashes

    for source_key, source in repo.sources().items():
        (urls, dist, component, architecture, gpg_keys) = source

        # Deduplicate: multiple dict entries can map to the same logical source
        # (one entry per URL in the urls list). Only process each unique
        # (URLs, dist, component, architecture) combination once.
        dedup_key = util.index_fact_key(dist, component, architecture, "Packages", urls)
        if dedup_key in seen:
            continue
        seen[dedup_key] = True

        # We assume that `url` does not contain a trailing forward slash when passing to
        # functions below. If one is present, remove it. Some HTTP servers do not handle
        # redirects properly when a path contains "//"
        urls = [url.rstrip("/") for url in urls]

        pkg_fact_key = util.index_fact_key(dist, component, architecture, "Packages", urls)
        cnt_fact_key = util.index_fact_key(dist, component, architecture, "Contents", urls)
        used_keys[pkg_fact_key] = True
        used_keys[cnt_fact_key] = True
        if urls and all([util.is_snapshot_uri(url) for url in urls]):
            snapshot_indices[pkg_fact_key] = True
            snapshot_indices[cnt_fact_key] = True

        # Check cached format info to avoid 404 warnings on subsequent runs
        cached_pkg_format = formats.get(pkg_fact_key)
        cached_cnt_format = formats.get(cnt_fact_key)

        hashes = None
        if gpg_keys:
            hashes = get_release_hashes(dist, urls, gpg_keys)

        # Pass 1: Initiate all downloads with block=False
        # For snapshot suites, integrity hashes from facts enable instant cache hits.
        # Cached formats narrow downloads to only the known-good extension.
        mctx.report_progress("starting downloads: {}/{} for {}".format(dist, component, architecture))
        pkg_tokens = _start_downloads(
            mctx,
            urls,
            dist,
            component,
            architecture,
            glock.facts().get(pkg_fact_key, ""),
            "Packages",
            source_id = len(seen),
            cached_format = cached_pkg_format,
            hashes = hashes,
        )

        cnt_tokens = None
        if cached_cnt_format != "unavailable":
            cnt_tokens = _start_downloads(
                mctx,
                urls,
                dist,
                component,
                architecture,
                glock.facts().get(cnt_fact_key, ""),
                "Contents",
                source_id = len(seen),
                cached_format = cached_cnt_format,
                hashes = hashes,
            )

        pending.append((
            urls,
            dist,
            component,
            architecture,
            pkg_tokens,
            cnt_tokens,
            pkg_fact_key,
            cnt_fact_key,
        ))

    # Pass 2: Wait, decompress, parse
    for (urls, dist, comp, arch, pkg_tokens, cnt_tokens, pkg_fk, cnt_fk) in pending:
        if not pkg_tokens:
            continue
        mctx.report_progress("resolving Package indices: {}/{} for {}".format(dist, comp, arch))
        (output, url, integrity, ext) = _resolve_downloads(mctx, pkg_tokens, "Packages", dist, comp, arch)
        if pkg_fk in snapshot_indices:
            glock.facts()[pkg_fk] = integrity
        formats[pkg_fk] = ext

        mctx.report_progress("parsing Package indices: {}/{} for {}".format(dist, comp, arch))
        repo.parse_package_index(mctx.read(output), urls, dist)

        if cnt_tokens:
            mctx.report_progress("resolving Contents: {}/{} for {}".format(dist, comp, arch))
            contents_result = _resolve_downloads(mctx, cnt_tokens, "Contents", dist, comp, arch)
        else:
            contents_result = None

        if contents_result != None:
            (output, url, integrity, ext) = contents_result
            if cnt_fk in snapshot_indices:
                glock.facts()[cnt_fk] = integrity
            formats[cnt_fk] = ext

            mctx.report_progress("parsing Contents: {}/{} for {}".format(dist, comp, arch))
            repo.parse_contents(mctx.read(output), arch)
        else:
            formats[cnt_fk] = "unavailable"

    return used_keys

def compute_package_repo_modes(packages, roots_by_mode):
    modes = {}

    for (mergedusr, roots) in roots_by_mode.items():
        pending = roots.keys()
        seen = {}

        for _ in range(len(packages)):
            if not pending:
                break

            current = pending
            pending = []
            for package_key in current:
                if package_key in seen:
                    continue
                if package_key not in packages:
                    fail("illegal state: package %s is not in lockfile" % package_key)

                seen[package_key] = True
                modes.setdefault(package_key, {})[mergedusr] = True
                pending.extend(packages[package_key]["depends_on"])

        if pending:
            fail("dependency traversal for package repository generation did not converge")

    return modes

def _distroless_extension(mctx):
    # Detect facts API availability
    use_facts = hasattr(mctx, "facts")
    cached_facts = mctx.facts if use_facts else {}

    # Seed glock from facts or lockfile
    if use_facts:
        glock = lockfile.empty(mctx)
        for (k, v) in cached_facts.get("indices", {}).items():
            glock.facts()[k] = v
    else:
        # as-in-mach 9
        glock = lockfile.merge(mctx, [
            lockfile.from_json(mctx, mctx.read(lock.into))
            for mod in mctx.modules
            for lock in mod.tags.lock
        ])

    snapshot_indices = {}

    repo = deb_repository.new()
    resolver = dependency_resolver.new(repo)

    for mod in mctx.modules:
        # TODO: also enfore that every module explicitly lists their sources_list
        # otherwise they'll break if the sources_list that the module depends on
        # magically disappears.
        for sl in mod.tags.sources_list:
            uris = [uri.removeprefix("mirror+") for uri in sl.uris]
            architectures = sl.architectures
            gpg_keys = list(sl.gpg_keys)

            if gpg_keys and sl.allow_unsigned:
                fail(
                    "\n\nRepository source for suite(s) {} from {} specified both GPG keyring(s) and `allow_unsigned = True`.\n\n".format(sl.suites, sl.uris) +
                    "These options are mutually exclusive. Either remove `allow_unsigned = True` to enable signature verification, or remove `gpg_keys` to allow unsigned repositories.\n",
                )

            if not gpg_keys and not sl.allow_unsigned:
                fail(
                    "\n\nRepository source for suite(s) {} from {} has no GPG/OpenPGP keyring specified (`gpg_keys`).\n\n".format(sl.suites, sl.uris) +
                    "Cryptographic OpenPGP signature verification is required by default to guarantee repository integrity.\n" +
                    "To resolve this, either:\n" +
                    "  1 - Provide the repository GPG keyring(s) via `gpg_keys = [\"//keys:debian.gpg\"]` (or `.asc`).\n" +
                    "  2 - Explicitly allow unsigned repositories by setting `allow_unsigned = True` in `apt.sources_list`.\n",
                )

            for suite in sl.suites:
                glock.add_source(
                    suite,
                    uris = uris,
                    types = sl.types,
                    components = sl.components,
                    architectures = architectures,
                )

                repo.add_source(
                    (uris, suite, sl.components, architectures, tuple(gpg_keys)),
                )

    # Seed cached formats from facts (which extensions each remote serves)
    formats = dict(cached_facts.get("formats", {}))

    # Fetch all sources_list in parallel and parse them. `used_keys` is the set
    # of fact keys for the current sources, used below to prune stale facts.
    used_keys = _fetch_and_parse_sources(mctx, repo, glock, snapshot_indices, formats)

    sources = glock.sources()
    dependency_sets = glock.dependency_sets()

    resolution_queue = []
    already_resolved = {}
    dependency_set_mergedusr = {}
    package_repo_roots = {
        False: {},
        True: {},
    }

    for mod in mctx.modules:
        for install in mod.tags.install:
            if install.dependency_set:
                current_mergedusr = dependency_set_mergedusr.get(install.dependency_set, False)
                dependency_set_mergedusr[install.dependency_set] = current_mergedusr or install.mergedusr

            for dep_constraint in install.packages:
                constraint = version_constraint.parse_dep(dep_constraint)
                architectures = constraint["arch"]
                if not architectures:
                    # For cases where architecture for the package is not specified we need
                    # to first find out which source contains the package. in order to do
                    # that we first need to resolve the package for amd64 architecture.
                    # Once the repository is found, then resolve the package for all the
                    # architectures the repository supports.
                    (package, warning) = resolver.resolve_package(
                        name = constraint["name"],
                        version = constraint["version"],
                        arch = "amd64",
                        suites = install.suites,
                    )
                    if warning:
                        util.warning(mctx, warning)

                    # If the package is not found then add the package
                    # to the resolution_queue to let the resolver handle
                    # the error messages.
                    if not package:
                        resolution_queue.append((
                            install.dependency_set,
                            constraint["name"],
                            constraint["version"],
                            "amd64",
                            install.suites,
                            install.mergedusr,
                            False,
                        ))
                        continue

                    source = sources[package["Dist"]]
                    architectures = source["architectures"]

                for arch in architectures:
                    resolution_queue.append((
                        install.dependency_set,
                        constraint["name"],
                        constraint["version"],
                        arch,
                        install.suites,
                        install.mergedusr,
                        False,
                    ))

    for i in range(0, ITERATION_MAX + 1):
        if not len(resolution_queue):
            break
        if i == ITERATION_MAX:
            fail("apt.install exhausted, please file a bug")

        (dependency_set_name, name, version, arch, suites, mergedusr, is_transitive_dependency) = resolution_queue.pop()

        mctx.report_progress("Resolving %s:%s" % (name, arch))

        # TODO: Flattening approach of resolving dependencies has to change.
        (package, dependencies, unmet_dependencies, warnings) = resolver.resolve_all(
            name = name,
            version = version,
            arch = arch,
            include_transitive = True,
            suites = suites,
        )

        if not package:
            suite_msg = " in suite(s) [%s]" % ", ".join(suites) if suites else ""
            version_str = "".join(version)
            fail(
                "\n\nUnable to locate package `%s` at version `%s` for %s%s. It may only exist for specific set of architectures or suites. \n" % (name, version_str, arch, suite_msg) +
                "   1 - Ensure that the package is available for the specified architecture. \n" +
                "   2 - Ensure that the specified version of the package is available for the specified architecture. \n" +
                "   3 - Ensure that an apt.sources_list is added for the specified architecture.\n" +
                "   4 - If using suite constraints, ensure the package exists in the specified suite(s).",
            )

        for warning in warnings:
            util.warning(mctx, warning)

        if len(unmet_dependencies):
            util.warning(
                mctx,
                "Following dependencies could not be resolved for %s: %s (dependency set %s)" % (
                    name,
                    ",".join([up[0] for up in unmet_dependencies]),
                    dependency_set_name,
                ),
            )

        # Key every package by the architecture we are resolving for, not by the
        # package's own `Architecture` field.
        # For arch-specific packages these are the same.
        # For `Architecture: all` packages this "expands" them into one entry per target architecture,
        # so each carries its own arch-specific dependency closure instead of a single frozen one shared across arches.
        # This solves the cases where an `Architecture: all` package depends on a per-architecture package
        # (e.g. bullseye ucf: https://packages.debian.org/bullseye/ucf).
        #
        # TODO:
        # Ensure following statements are true.
        #  1- Package was resolved from a source that module listed explicitly.
        #  2- Package resolution was skipped because some other module asked for this package.
        #  3- 1) is enforced even if 2) is the case.
        glock.add_package(package, arch)

        package_key = lockfile.package_key(package, arch)
        if not is_transitive_dependency:
            package_repo_roots[mergedusr][package_key] = True

        pkg_short_key = lockfile.short_package_key(package, arch)

        already_resolved[pkg_short_key] = True

        for dep in dependencies:
            glock.add_package(dep, arch)
            dep_key = lockfile.short_package_key(dep, arch)
            if dep_key not in already_resolved:
                resolution_queue.append((
                    None,
                    dep["Package"],
                    ("=", dep["Version"]),
                    arch,
                    suites,
                    mergedusr,
                    True,
                ))
            glock.add_package_dependency(package, dep, arch)

        # Add it to dependency set
        if dependency_set_name:
            dependency_set = dependency_sets.setdefault(dependency_set_name, {
                "sets": {},
            })
            arch_set = dependency_set["sets"].setdefault(arch, {})
            arch_set[pkg_short_key] = package["Version"]

    # Generate a hub repo for every dependency set
    lock_content = glock.as_json()
    package_repo_modes = compute_package_repo_modes(glock.packages(), package_repo_roots)
    for depset_name in dependency_sets.keys():
        depset_mergedusr = dependency_set_mergedusr.get(depset_name, False)
        translate_dependency_set(
            name = depset_name,
            depset_name = depset_name,
            lock_content = lock_content,
            mergedusr = depset_mergedusr,
        )

    # Generate a repo per package which will be aliased by hub repo.
    for (package_key, package) in glock.packages().items():
        (suite, name, arch, version) = lockfile.parse_package_key(package_key)

        # Each package publishes its own file list in a leaf repo to avoid circular deps.
        # Storing these in a file instead of passing filemaps as attributes cuts down lockfile size considerably.
        deb_filemap(
            name = util.sanitize(package_key) + "_filemap",
            files = json.encode(repo.filemap(name = name, arch = arch) or []),
        )

        modes = package_repo_modes.get(package_key, {False: True})
        repo_variants = [(util.package_repo_name(package_key), False if False in modes else True)]
        if True in modes:
            repo_variants.append((util.package_repo_name(package_key, mergedusr = True), True))

        for (repo_name, mergedusr) in repo_variants:
            deb_import(
                name = repo_name,
                target_name = repo_name,
                urls = package["urls"],
                sha256 = package["sha256"],
                mergedusr = mergedusr,
                depends_on = package["depends_on"],
                # Label of each dependency's own filemap, in depends_on order,
                # so deb_import can rebuild the {file: dependency} index by lookup.
                dep_filemaps = [
                    "@" + util.sanitize(dep) + "_filemap//:filemap.json"
                    for dep in package["depends_on"]
                ],
                package_name = package["name"],
            )

    if not use_facts:
        for mod in mctx.modules:
            if not mod.is_root:
                continue

            if len(mod.tags.lock) > 1:
                fail("There can only be one apt.lock per module.")
            elif len(mod.tags.lock) == 1:
                lock = mod.tags.lock[0]
                lock_tmp = mctx.path("apt.lock.json")
                glock.write(lock_tmp)
                lockf_wksp = mctx.path(lock.into)
                mctx.execute(
                    ["cp", "-f", lock_tmp, lockf_wksp],
                )

    if use_facts:
        (cacheable_indices, cacheable_formats) = util.prune_uncacheable_facts(
            glock.facts(),
            formats,
            used_keys,
            snapshot_indices,
        )
        return mctx.extension_metadata(
            facts = {"indices": cacheable_indices, "formats": cacheable_formats},
        )

_doc = """
Module extension to create Debian repositories.

Create Debian repositories with packages "installed" in them and available
to use in Bazel.


Here's an example how to create a Debian repo:

```starlark
apt = use_extension("@rules_distroless//apt:extensions.bzl", "apt")
apt.sources_list(
    types = ["deb"],
    uris = [
        "https://snapshot.ubuntu.com/ubuntu/20240301T030400Z",
        "mirror+https://snapshot.ubuntu.com/ubuntu/20240301T030400Z"
    ],
    suites = ["noble", "noble-security", "noble-updates"],
    components = ["main"],
    architectures = ["all"]
)
apt.install(
    # dependency set isolates these installs into their own scope.
    dependency_set = "noble",
    suites = ["noble", "noble-security", "noble-updates"],
    packages = [
        "ncurses-base",
        "libncurses6",
        "tzdata",
        "coreutils:arm64",
        "libstdc++6:i386"
    ]
)
```


`apt.install` generates a package repository for each package and architecture
combination in the form of `@<TARGET_RELEASE>_<PKG_NAME>_<PKG_ARCH>`.

Each `<PACKAGE>/<ARCH>` has two targets that match the usual structure of a
Debian package: `data` and `control`.

You can use the package like so: `@<REPO>//<PACKAGE>/<ARCH>:<TARGET>`.

E.g. for the previous example, you could use `@bullseye//perl/amd64:data`.

### Lockfiles

As mentioned, the macro can be used without a lock because the lock will be
generated internally on-demand. However, this comes with the cost of
performing a new package resolution on repository cache misses.

The lockfile can be generated by running `bazel run @bullseye//:lock`. This
will generate a `.lock.json` file of the same name and in the same path as
the YAML `manifest` file.

If you explicitly want to run without a lock and avoid the warning messages
set the `nolock` argument to `True`.

### Best Practice: use snapshot archive URLs

While we strongly encourage users to check in the generated lockfile, it's
not always possible because Debian repositories are rolling by default.
Therefore, a lockfile generated today might not work later if the upstream
repository removes or publishes a new version of a package.

To avoid this problems and increase the reproducibility it's recommended to
avoid using normal Debian mirrors and use snapshot archives instead.

Snapshot archives provide a way to access Debian package mirrors at a point
in time. Basically, it's a "wayback machine" that allows access to (almost)
all past and current packages based on dates and version numbers.

Debian has had snapshot archives for [10+
years](https://lists.debian.org/debian-announce/2010/msg00002.html). Ubuntu
began providing a similar service recently and has packages available since
March 1st 2023.

To use this services simply use a snapshot URL in the manifest. Here's two
examples showing how to do this for Debian and Ubuntu:
  * [/examples/debian_snapshot](https://github.com/bazel-contrib/rules_distroless/tree/main/examples/debian_snapshot)
  * [/examples/ubuntu_snapshot](https://github.com/bazel-contrib/rules_distroless/tree/main/examples/ubuntu_snapshot)

For more infomation, please check https://snapshot.debian.org and/or
https://snapshot.ubuntu.com.

### GPG / OpenPGP Signature Verification

`rules_distroless` supports verifying the cryptographic OpenPGP signatures on repository
indices (`InRelease` or `Release` + `Release.gpg`) before downloading package indexes.

You can specify keyring files using `gpg_keys`:

```starlark
apt.sources_list(
    architectures = ["amd64", "arm64"],
    components = ["main"],
    gpg_keys = ["//keys:debian-archive-keyring.gpg"],
    suites = ["bookworm"],
    types = ["deb"],
    uris = ["https://deb.debian.org/debian"],
)
```

The extension auto-detects `gpgv` or `sqv` (Sequoia PGP) on `PATH`:
- Verifies `InRelease` clearsigned files (or `Release.gpg` detached signatures).
- Extracts the verified `SHA256:` checksum table for index files (`Packages.xz`, `Contents-*.gz`).
- Passes SHA256 hashes to Bazel download actions to guarantee end-to-end repository integrity.

> **Keyring Formats**: Both binary OpenPGP keyrings (`.gpg` / `.kbx`) and ASCII-armored
> keyrings (`.asc`) are supported. When using `gpgv`, ASCII-armored keyrings are
> automatically converted to binary format using `gpg --dearmor` if needed.

> **Valid-Until & Expiration Notice**: `Valid-Until` timestamps in `Release` files are
> intentionally not enforced. Bazel's execution model is hermetic (no host clock in Starlark),
> snapshot archives have expired dates by definition, and wall-clock enforcement would cause
> reproducible builds to spontaneously fail ("time bombs") when evaluated in the future.
>
> **Security Implication**: Snapshot repositories (`snapshot.debian.org`, `snapshot.ubuntu.com`)
> are immutably tied to a point-in-time snapshot, mitigating rollback and freeze attacks.
> However, for rolling suites (such as `deb.debian.org/debian bookworm`), an active network
> attacker or compromised mirror could theoretically serve a stale-but-validly-signed `Release`
> file without being detected by `rules_distroless`. Users requiring protection against freeze
> attacks should use snapshot archive URLs.

If you are using an unsigned internal repository or do not wish to verify signatures,
you must explicitly opt in with `allow_unsigned = True`:

```starlark
apt.sources_list(
    allow_unsigned = True,
    architectures = ["amd64"],
    components = ["main"],
    suites = ["custom"],
    types = ["deb"],
    uris = ["https://internal.repo.corp.example.com"],
)
```
"""

sources_list = tag_class(
    attrs = {
        "allow_unsigned": attr.bool(
            default = False,
            doc = "Allow unverified/unsigned repository indices without GPG keys.",
        ),
        "architectures": attr.string_list(),
        "components": attr.string_list(),
        "gpg_keys": attr.label_list(
            allow_files = True,
            doc = "Optional list of GPG/OpenPGP keyring files (.gpg or .asc) for repository signature verification.",
        ),
        "sources": attr.string_list(
            # mandatory = True,
        ),
        "suites": attr.string_list(),
        "types": attr.string_list(),
        "uris": attr.string_list(),
    },
)

install = tag_class(
    attrs = {
        "packages": attr.string_list(
            mandatory = True,
            allow_empty = False,
        ),
        "dependency_set": attr.string(),
        "suites": attr.string_list(),
        "include_transitive": attr.bool(default = True),
        "mergedusr": attr.bool(default = False),
    },
)

lock = tag_class(
    attrs = {
        "into": attr.label(
            mandatory = True,
        ),
    },
)

apt = module_extension(
    doc = _doc,
    implementation = _distroless_extension,
    tag_classes = {
        "install": install,
        "sources_list": sources_list,
        "lock": lock,
    },
)
