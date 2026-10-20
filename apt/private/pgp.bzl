"OpenPGP verification utilities for APT repositories"

load(":util.bzl", "util")

_BOUNCYCASTLE_VERSION = "1.86"
_BOUNCYCASTLE_JARS = {
    "bcpg-jdk18on": "8a52ea45b2063f6d41b8ca94409f255a1f4604922f7451c18a7cfd3a3c5b85ab",
    "bcprov-jdk18on": "2af190b300cbb0b35e248ccf5f4a06b6072030aeb3da7a98ec73abe5b4cb371f",
    "bcutil-jdk18on": "1c268e15f785aafb1e4670d8d6e5f856f69475e96c162dadcd1ff9b350e9139f",
}

# The hermetic verifier is a JVM. Do not let options from the user's environment change its behavior.
_JAVA_ENVIRONMENT = {
    "JAVA_TOOL_OPTIONS": "",
    "JDK_JAVA_OPTIONS": "",
    "_JAVA_OPTIONS": "",
}

def _find_pgp_verifier(mctx):
    """Detect an OpenPGP verifier: sqv, then gpgv, then the hermetic java one."""
    if mctx.which("sqv"):
        return "sqv"
    if mctx.which("gpgv"):
        return "gpgv"
    return "java"

def _remotejdk_repo(mctx):
    """Name of the rules_java remote JDK 21 repo that matches the host."""
    os_name = mctx.os.name.lower()
    arch = mctx.os.arch.lower()
    if "mac" in os_name:
        os_part = "macos"
    elif "windows" in os_name:
        os_part = "win"
    elif "linux" in os_name:
        os_part = "linux"
    else:
        fail("No hermetic JDK for host OS '{}'. Install `sqv` or `gpgv` on PATH.".format(mctx.os.name))

    if arch in ["x86_64", "amd64"]:
        arch_part = ""
    elif arch in ["aarch64", "arm64"]:
        arch_part = "_arm64" if os_part == "win" else "_aarch64"
    elif arch in ["ppc64le", "s390x", "riscv64"]:
        arch_part = "_" + arch
    else:
        fail("No hermetic JDK for host architecture '{}'. Install `sqv` or `gpgv` on PATH.".format(mctx.os.arch))
    return "remotejdk21_{}{}".format(os_part, arch_part)

def _hermetic_java_cmd(mctx):
    """Command prefix that runs apt/private/Verify.java on a hermetic JDK with BouncyCastle.

    Used when neither sqv nor gpgv is on PATH so that building does not depend on host tools.
    The JDK comes from rules_java and the BouncyCastle jars are pinned by sha256.
    """
    repo = _remotejdk_repo(mctx)
    is_windows = "windows" in mctx.os.name.lower()
    java = mctx.path(Label("@{}//:bin/{}".format(repo, "java.exe" if is_windows else "java")))

    jars = []
    for (name, sha256) in _BOUNCYCASTLE_JARS.items():
        output = "bouncycastle/{}-{}.jar".format(name, _BOUNCYCASTLE_VERSION)
        mctx.download(
            url = "https://repo1.maven.org/maven2/org/bouncycastle/{name}/{version}/{name}-{version}.jar".format(
                name = name,
                version = _BOUNCYCASTLE_VERSION,
            ),
            output = output,
            sha256 = sha256,
        )
        jars.append(str(mctx.path(output)))

    verify_java = mctx.path(Label("//apt/private:Verify.java"))
    return [str(java), "-cp", (";" if is_windows else ":").join(jars), str(verify_java)]

def _format_verifier_output(res, verifier):
    details = []
    if res.stderr:
        details.append("stderr:\n" + res.stderr)
    if res.stdout:
        details.append("stdout:\n" + res.stdout)
    out_str = "\n".join(details) if details else "no output"
    prefix = ""
    if verifier == "java" and res.return_code != 1:
        prefix = "The hermetic OpenPGP verifier could not process its inputs. This is an error, not a bad signature.\n"
    return "{}{} exit code: {}\n{}".format(prefix, verifier, res.return_code, out_str)

def _execute_verifier(mctx, verifier, cmd):
    return mctx.execute(cmd, environment = _JAVA_ENVIRONMENT if verifier == "java" else {})

def _is_verification_success(res, verifier):
    """Evaluates whether the verifier execution resulted in a successful verification."""
    if res.return_code == 0:
        return True
    if verifier == "gpgv":
        # When an index is signed with multiple keys and the provided keyring only
        # contains a subset of them, gpgv returns non-zero (exit code 2) due to
        # missing public keys for the other signatures. With --status-fd 1, verify
        # that at least one trusted signature is good and no signature is bad.
        out = res.stdout
        has_good_sig = "[GNUPG:] GOODSIG " in out or "[GNUPG:] VALIDSIG " in out
        has_bad_sig = "[GNUPG:] BADSIG " in out
        if has_good_sig and not has_bad_sig:
            return True
    return False

def _verifier_cmd(verifier, keyring_args, mode, sig_path, msg_path = None, out_path = None, java_cmd = None):
    """Builds execution command arguments for gpgv, sqv or the hermetic java verifier."""
    if verifier == "java":
        if mode == "clearsigned":
            return java_cmd + ["clearsigned"] + keyring_args + ["--output", str(out_path), str(sig_path)]
        return java_cmd + ["detached"] + keyring_args + [str(sig_path), str(msg_path)]
    elif verifier == "gpgv":
        cmd = ["gpgv", "--status-fd", "1"] + keyring_args
        if mode == "clearsigned":
            return cmd + [str(sig_path)]
        return cmd + [str(sig_path), str(msg_path)]
    elif verifier == "sqv":
        if mode == "clearsigned":
            return ["sqv"] + keyring_args + ["--cleartext", "--output", str(out_path), str(sig_path)]
        return ["sqv"] + keyring_args + ["--signature-file", str(sig_path), str(msg_path)]
    else:
        fail("Unknown OpenPGP verifier '{}'.".format(verifier))

def _strip_pgp_clearsign_armor(content):
    """Strips PGP cleartext signature framing from InRelease content."""
    if "-----BEGIN PGP SIGNED MESSAGE-----" not in content:
        return content

    lines = content.splitlines()
    output_lines = []
    in_message = False
    in_header = False
    for line in lines:
        if line.startswith("-----BEGIN PGP SIGNED MESSAGE-----"):
            in_header = True
            continue
        if in_header:
            if line.strip() == "":
                in_header = False
                in_message = True
            continue
        if line.startswith("-----BEGIN PGP SIGNATURE-----"):
            in_message = False
            break
        if in_message:
            if line.startswith("- "):
                line = line[2:]
            output_lines.append(line)
    if not output_lines:
        fail("Malformed PGP clearsigned message: failed to extract signed content.")
    return "\n".join(output_lines)

def _build_keyring_args(key_paths):
    """Build repeated --keyring arguments for a list of keyring paths."""
    args = []
    for k in key_paths:
        args.extend(["--keyring", str(k)])
    return args

def _is_ascii_armored(content):
    """Returns True if the content is an ASCII-armored OpenPGP block."""
    return "-----BEGIN PGP" in content

def _verify_inrelease(mctx, verifier, keyring_args, in_release_path, output_verified_path, java_cmd = None):
    """Verifies InRelease using gpgv, sqv or java and returns (success, content_or_error)."""

    # sqv creates its output with create_new(true) and fails with os error 17 if the output file already exists.
    # Since module_ctx lacks repository_ctx.delete(), we remove any leftover file from earlier runs.
    if verifier != "java":
        mctx.execute(["rm", "-f", str(mctx.path(output_verified_path))])

    cmd = _verifier_cmd(
        verifier,
        keyring_args,
        "clearsigned",
        mctx.path(in_release_path),
        out_path = mctx.path(output_verified_path),
        java_cmd = java_cmd,
    )
    res = _execute_verifier(mctx, verifier, cmd)
    if not _is_verification_success(res, verifier):
        return (False, _format_verifier_output(res, verifier))
    if verifier == "gpgv":
        return (True, _strip_pgp_clearsign_armor(mctx.read(in_release_path)))
    return (True, mctx.read(output_verified_path))

def _verify_detached_release(mctx, verifier, keyring_args, release_gpg_path, release_path, java_cmd = None):
    """Verifies detached Release.gpg signature against Release using gpgv, sqv or java."""
    cmd = _verifier_cmd(
        verifier,
        keyring_args,
        "detached",
        mctx.path(release_gpg_path),
        msg_path = mctx.path(release_path),
        java_cmd = java_cmd,
    )
    res = _execute_verifier(mctx, verifier, cmd)
    if not _is_verification_success(res, verifier):
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
                if _is_ascii_armored(content):
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
    """Downloads InRelease (or Release + Release.gpg) and verifies with sqv, gpgv or the hermetic java verifier."""
    verifier = _find_pgp_verifier(mctx)
    java_cmd = _hermetic_java_cmd(mctx) if verifier == "java" else None

    keyring_paths = _prepare_keyring_paths(mctx, verifier, gpg_keys)
    keyring_args = _build_keyring_args(keyring_paths)
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
            ok, res = _verify_inrelease(mctx, verifier, keyring_args, in_release_path, verified_path, java_cmd)
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
                ok, res = _verify_detached_release(mctx, verifier, keyring_args, release_gpg_path, release_path, java_cmd)
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

pgp = struct(
    build_keyring_args = _build_keyring_args,
    download_and_verify_release = _download_and_verify_release,
    is_ascii_armored = _is_ascii_armored,
    is_verification_success = _is_verification_success,
    strip_clearsign_armor = _strip_pgp_clearsign_armor,
    verifier_cmd = _verifier_cmd,
)
