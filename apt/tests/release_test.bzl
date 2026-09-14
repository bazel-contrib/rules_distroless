"unit tests for Release file parsing and PGP verification utilities"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:apt_deb_repository.bzl", "deb_repository")
load("//apt/private:util.bzl", "util")

_TEST_SUITE_PREFIX = "release/"

def _strip_pgp_armor_test(ctx):
    env = unittest.begin(ctx)

    clearsigned = """-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

Origin: Debian
Label: Debian
Suite: bookworm
- - A dash escaped line
Date: Sat, 10 Feb 2024 22:33:13 UTC
-----BEGIN PGP SIGNATURE-----

iQIzBAEBCAAdFiEE...
-----END PGP SIGNATURE-----"""

    stripped = util.strip_pgp_clearsign_armor(clearsigned)
    asserts.true(env, "Origin: Debian" in stripped)
    asserts.true(env, "- A dash escaped line" in stripped)
    asserts.false(env, "-----BEGIN PGP SIGNED MESSAGE-----" in stripped)
    asserts.false(env, "-----BEGIN PGP SIGNATURE-----" in stripped)

    # Unarmored text remains unchanged
    plain = "Origin: Debian\nSuite: bookworm"
    asserts.equals(env, plain, util.strip_pgp_clearsign_armor(plain))

    return unittest.end(env)

def _parse_release_file_test(ctx):
    env = unittest.begin(ctx)

    release_text = """Origin: Debian
Label: Debian
Suite: bullseye
Version: 11.9
Codename: bullseye
Date: Sat, 10 Feb 2024 22:33:13 UTC
Valid-Until: Sat, 17 Feb 2024 22:33:13 UTC
Architectures: amd64 arm64
Components: main contrib
MD5Sum:
 11111111111111111111111111111111 1234 main/binary-amd64/Packages.xz
SHA1:
 2222222222222222222222222222222222222222 1234 main/binary-amd64/Packages.xz
SHA256:
 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 main/binary-amd64/Packages
 8f434346648f6b96df89dda901c5176b10f6075361a446da52e96e204f947104 1234 main/binary-amd64/Packages.xz
 0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b 5678 main/Contents-amd64.gz
SHA512:
 33333333333333333333333333333333333333333333333333333333333333333333333333333333 1234 main/binary-amd64/Packages.xz
"""

    hashes = util.parse_release_file(release_text)
    asserts.equals(env, 3, len(hashes))
    asserts.equals(
        env,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hashes.get("main/binary-amd64/Packages"),
    )
    asserts.equals(
        env,
        "8f434346648f6b96df89dda901c5176b10f6075361a446da52e96e204f947104",
        hashes.get("main/binary-amd64/Packages.xz"),
    )
    asserts.equals(
        env,
        "0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b",
        hashes.get("main/Contents-amd64.gz"),
    )

    # Test tab-delimited and tab-indented Release file
    tab_release = """Origin: Debian
Suite: bookworm
SHA256:
\t1111111111111111111111111111111111111111111111111111111111111111\t100\tmain/binary-amd64/Packages.gz
\t2222222222222222222222222222222222222222222222222222222222222222   200\tmain/binary-arm64/Packages.xz
SHA512:
\t3333333333333333333333333333333333333333333333333333333333333333\t100\tmain/binary-amd64/Packages.gz
"""
    tab_hashes = util.parse_release_file(tab_release)
    asserts.equals(env, 2, len(tab_hashes))
    asserts.equals(
        env,
        "1111111111111111111111111111111111111111111111111111111111111111",
        tab_hashes.get("main/binary-amd64/Packages.gz"),
    )
    asserts.equals(
        env,
        "2222222222222222222222222222222222222222222222222222222222222222",
        tab_hashes.get("main/binary-arm64/Packages.xz"),
    )

    return unittest.end(env)

def _build_keyring_args_test(ctx):
    env = unittest.begin(ctx)

    args = util.build_keyring_args(["/path/to/key1.gpg", "/path/to/key2.asc"])
    asserts.equals(env, [
        "--keyring",
        "/path/to/key1.gpg",
        "--keyring",
        "/path/to/key2.asc",
    ], args)

    return unittest.end(env)

def _deb_repository_stores_gpg_keys_test(ctx):
    env = unittest.begin(ctx)

    repo = deb_repository.new()
    repo.add_source((
        ["https://deb.debian.org/debian"],
        "bookworm",
        ["main"],
        ["amd64"],
        ("@my_repo//:key.gpg", "@my_repo//:extra.asc"),
    ))
    repo.add_source((
        ["https://custom.repo.org/apt"],
        "custom",
        ["main"],
        ["amd64"],
        ("@my_repo//:custom.gpg",),
    ))

    sources = repo.sources()
    asserts.true(env, len(sources) > 0)
    for key, source in sources.items():
        (urls, dist, comp, arch, gpg_keys) = source
        if dist == "bookworm":
            asserts.equals(env, ("@my_repo//:key.gpg", "@my_repo//:extra.asc"), gpg_keys)
        elif dist == "custom":
            asserts.equals(env, ("@my_repo//:custom.gpg",), gpg_keys)

    return unittest.end(env)

def _is_ascii_armored_test(ctx):
    env = unittest.begin(ctx)

    # Realistic ASCII-armored public key block
    asc_key_sample = """-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v2

mQENBF2X...
=abcd
-----END PGP PUBLIC KEY BLOCK-----"""
    asserts.true(env, util.is_ascii_armored(asc_key_sample))

    # Armor file headers
    asserts.true(env, util.is_ascii_armored("-----BEGIN PGP ARMORED FILE-----\n..."))
    asserts.true(env, util.is_ascii_armored("-----BEGIN PGP SIGNED MESSAGE-----\n..."))

    # Binary OpenPGP data / non-armored files
    asserts.false(env, util.is_ascii_armored("binary-keyring-data-here"))
    asserts.false(env, util.is_ascii_armored("Suite: bookworm\nOrigin: Debian"))
    asserts.false(env, util.is_ascii_armored(""))

    return unittest.end(env)

strip_pgp_armor_test = unittest.make(_strip_pgp_armor_test)
parse_release_file_test = unittest.make(_parse_release_file_test)
build_keyring_args_test = unittest.make(_build_keyring_args_test)
deb_repository_stores_gpg_keys_test = unittest.make(_deb_repository_stores_gpg_keys_test)
is_ascii_armored_test = unittest.make(_is_ascii_armored_test)

def release_tests():
    strip_pgp_armor_test(name = _TEST_SUITE_PREFIX + "strip_pgp_armor")
    parse_release_file_test(name = _TEST_SUITE_PREFIX + "parse_release_file")
    build_keyring_args_test(name = _TEST_SUITE_PREFIX + "build_keyring_args")
    deb_repository_stores_gpg_keys_test(name = _TEST_SUITE_PREFIX + "deb_repository_stores_gpg_keys")
    is_ascii_armored_test(name = _TEST_SUITE_PREFIX + "is_ascii_armored")
