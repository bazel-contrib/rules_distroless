"unit tests for reading a base image's installed packages"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:oci_base.bzl", "debian_architecture", "installed_stanzas")

_TEST_SUITE_PREFIX = "oci_base/"

def _debian_architecture_test(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "amd64", debian_architecture({"architecture": "amd64", "os": "linux"}))
    asserts.equals(env, "arm64", debian_architecture({"architecture": "arm64", "variant": "v8"}))
    asserts.equals(env, "armhf", debian_architecture({"architecture": "arm", "variant": "v7"}))
    asserts.equals(env, "armel", debian_architecture({"architecture": "arm", "variant": "v6"}))
    asserts.equals(env, "i386", debian_architecture({"architecture": "386"}))
    asserts.equals(env, "ppc64el", debian_architecture({"architecture": "ppc64le"}))

    return unittest.end(env)

debian_architecture_test = unittest.make(_debian_architecture_test)

def _installed_stanzas_test(ctx):
    env = unittest.begin(ctx)

    status = "\n\n".join([
        "Package: bash\nStatus: install ok installed\nVersion: 5.2\nDescription: GNU Bourne Again SHell\n Bash is an sh-compatible command language interpreter.",
        "Package: nano\nStatus: deinstall ok config-files\nVersion: 7.2",
        "Package: vim\nStatus: install ok half-configured\nVersion: 9.1",
        "Package: zlib1g\nStatus: hold ok installed\nVersion: 1.3",
    ]) + "\n"

    asserts.equals(env, [
        "Package: bash\nStatus: install ok installed\nVersion: 5.2\nDescription: GNU Bourne Again SHell\n Bash is an sh-compatible command language interpreter.",
        "Package: zlib1g\nStatus: hold ok installed\nVersion: 1.3",
    ], installed_stanzas(status))

    return unittest.end(env)

installed_stanzas_test = unittest.make(_installed_stanzas_test)

def oci_base_tests():
    debian_architecture_test(name = _TEST_SUITE_PREFIX + "debian_architecture")
    installed_stanzas_test(name = _TEST_SUITE_PREFIX + "installed_stanzas")
