"""Keep inherited account bytes and reject conflicting service identities."""

import json
import tempfile
import unittest
from pathlib import Path

from distroless.private.accounts import build, merge
from distroless.tests.accounts.fixture import archive, layout


class AccountTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.passwd = b"root:x:0:0:root:/root:/bin/bash\n_apt:x:42:65534::/nonexistent:/usr/sbin/nologin\n"
        self.group = b"root:x:0:\nnogroup:x:65534:\n"
        self.original = archive(
            self.root / "base.tar", {"etc/passwd": self.passwd, "etc/group": self.group}
        )
        self.users = archive(
            self.root / "users.tar",
            {"etc/passwd": b"redis:x:100:101::/var/lib/redis:/usr/sbin/nologin\n"},
        )
        self.groups = archive(
            self.root / "groups.tar", {"etc/group": b"redis:x:101:\n"}
        )

    def run_build(self, layers=None, architecture="amd64"):
        base = layout(self.root / "image", layers or [self.original], architecture)
        return build(base, self.users, self.groups, architecture)

    def test_keeps_all_inherited_lines_and_adds_only_service_accounts(self):
        for architecture in ("amd64", "arm64"):
            with self.subTest(architecture=architecture):
                files, receipt = self.run_build(architecture=architecture)
                self.assertEqual(
                    files["etc/passwd"],
                    self.passwd
                    + b"redis:x:100:101::/var/lib/redis:/usr/sbin/nologin\n",
                )
                self.assertEqual(files["etc/group"], self.group + b"redis:x:101:\n")
                self.assertEqual(receipt["architecture"], architecture)
                self.assertEqual(receipt["users"], ["redis"])
                self.assertEqual(receipt["files"]["etc/passwd"]["mode"], 0o644)

    def test_new_base_accounts_survive_without_changing_additions(self):
        added = b"newservice:x:200:65534::/:/usr/sbin/nologin\n"
        self.original = archive(
            self.root / "new-base.tar",
            {
                "etc/passwd": self.passwd + added,
                "etc/group": self.group,
            },
        )
        files, _ = self.run_build()
        self.assertEqual(
            files["etc/passwd"],
            self.passwd
            + added
            + b"redis:x:100:101::/var/lib/redis:/usr/sbin/nologin\n",
        )

    def test_newline_is_added_only_when_needed(self):
        self.assertEqual(
            merge(b"root:x:0:0:root:/root:/bin/bash", b"", "passwd"),
            b"root:x:0:0:root:/root:/bin/bash",
        )
        self.assertEqual(
            merge(
                b"root:x:0:0:root:/root:/bin/bash",
                b"redis:x:100:101::/var/lib/redis:/usr/sbin/nologin\n",
                "passwd",
            ),
            self.passwd.splitlines(keepends=True)[0]
            + b"redis:x:100:101::/var/lib/redis:/usr/sbin/nologin\n",
        )

    def test_existing_service_account_is_not_duplicated(self):
        row = b"redis:x:100:101::/var/lib/redis:/usr/sbin/nologin\n"
        self.original = archive(
            self.root / "existing.tar",
            {
                "etc/passwd": self.passwd + row,
                "etc/group": self.group + b"redis:x:101:\n",
            },
        )
        files, _ = self.run_build()
        self.assertEqual(files["etc/passwd"], self.passwd + row)
        self.assertEqual(files["etc/group"], self.group + b"redis:x:101:\n")

    def test_existing_group_name_and_numeric_id_are_preserved(self):
        for row in (b"root:x:1:\n", b"service:x:0:\n"):
            with self.subTest(row=row), self.assertRaises(ValueError):
                merge(self.group, row, "group")

    def test_identical_account_is_idempotent_and_preserves_bytes(self):
        self.assertEqual(merge(self.passwd, self.passwd, "passwd"), self.passwd)

    def test_preserves_distribution_account_names_and_group_references(self):
        inherited_user = b"Debian-exim:x:200:200::/nonexistent:/usr/sbin/nologin\n"
        inherited_group = b"Debian-exim:x:200:Debian-exim\n"
        new_user = b"monitor.agent:x:201:200::/nonexistent:/usr/sbin/nologin\n"
        new_group = b"Ops.Team:x:201:Debian-exim,monitor.agent\n"
        self.original = archive(
            self.root / "distribution.tar",
            {
                "etc/passwd": self.passwd + inherited_user,
                "etc/group": self.group + inherited_group,
            },
        )
        self.users = archive(self.root / "users.tar", {"etc/passwd": new_user})
        self.groups = archive(self.root / "groups.tar", {"etc/group": new_group})
        files, _ = self.run_build()
        self.assertEqual(files["etc/passwd"], self.passwd + inherited_user + new_user)
        self.assertEqual(files["etc/group"], self.group + inherited_group + new_group)
        for kind in ("passwd", "group"):
            original = files["etc/" + kind]
            self.assertEqual(merge(original, original, kind), original)

    def test_rejects_empty_names_nul_and_record_delimiters(self):
        for name in ("", "bad\x00name", "bad:name", "bad\nname"):
            for kind, row in (
                ("passwd", f"{name}:x:200:200::/:/bin/false\n"),
                ("group", f"{name}:x:200:\n"),
            ):
                with self.subTest(name=name, kind=kind), self.assertRaises(ValueError):
                    merge(b"", row.encode(), kind)

    def test_different_definition_or_same_id_is_rejected(self):
        for row in (
            b"root:x:0:0:changed:/root:/bin/bash\n",
            b"service:x:0:0::/:/bin/false\n",
        ):
            with self.subTest(row=row), self.assertRaises(ValueError):
                merge(self.passwd, row, "passwd")

    def test_new_users_cannot_share_numeric_identity(self):
        with self.assertRaisesRegex(ValueError, "already belongs"):
            merge(
                self.passwd,
                b"one:x:100:0::/:/bin/false\ntwo:x:100:0::/:/bin/false\n",
                "passwd",
            )

    def test_primary_group_must_exist(self):
        self.groups = archive(self.root / "groups.tar", {"etc/group": b""})
        with self.assertRaisesRegex(ValueError, "primary group"):
            self.run_build()

    def test_group_members_must_exist(self):
        self.groups = archive(
            self.root / "groups.tar", {"etc/group": b"redis:x:101:missing\n"}
        )
        with self.assertRaisesRegex(ValueError, "absent user"):
            self.run_build()

    def test_rejects_changed_base_account_mode(self):
        self.original = archive(
            self.root / "base.tar",
            {"etc/passwd": (self.passwd, 0o600), "etc/group": self.group},
        )
        with self.assertRaisesRegex(ValueError, "ownership or mode"):
            self.run_build()

    def test_whiteout_cannot_resurrect_lower_accounts(self):
        for name in ("etc/.wh.passwd", "etc/.wh..wh..opq", ".wh.etc"):
            with self.subTest(name=name):
                removed = archive(self.root / "removed.tar", {name: b""})
                with self.assertRaisesRegex(ValueError, "lacks passwd or group"):
                    self.run_build([self.original, removed])

    def test_same_layer_replacement_survives_whiteout(self):
        replaced = archive(
            self.root / "replaced.tar",
            {"etc/.wh.passwd": b"", "etc/passwd": self.passwd},
        )
        self.assertEqual(
            self.run_build([self.original, replaced])[0]["etc/passwd"].splitlines()[0],
            self.passwd.splitlines()[0],
        )

    def test_latest_layer_supplies_the_base_records(self):
        updated = self.passwd.replace(b"/bin/bash", b"/bin/sh")
        replacement = archive(self.root / "newer.tar", {"etc/passwd": updated})
        files, _ = self.run_build(layers=[self.original, replacement])
        self.assertTrue(files["etc/passwd"].startswith(updated))
        self.assertNotIn(b"/bin/bash", files["etc/passwd"])

    def test_wrong_architecture_is_rejected(self):
        base = layout(self.root / "image", [self.original], "arm64")
        with self.assertRaisesRegex(ValueError, "platform"):
            build(base, self.users, self.groups, "amd64")

    def test_nonregular_base_account_file_is_rejected(self):
        import tarfile

        bad = self.root / "symlink.tar"
        with tarfile.open(bad, "w") as output:
            item = tarfile.TarInfo("etc/passwd")
            item.type = tarfile.SYMTYPE
            item.linkname = "elsewhere"
            output.addfile(item)
        with self.assertRaisesRegex(ValueError, "regular"):
            self.run_build(layers=[self.original, bad])

    def test_non_directory_ancestor_cannot_reuse_lower_accounts(self):
        import tarfile

        for kind in (tarfile.SYMTYPE, tarfile.REGTYPE):
            with self.subTest(kind=kind):
                bad = self.root / "replaced-etc.tar"
                with tarfile.open(bad, "w") as output:
                    item = tarfile.TarInfo("etc")
                    item.type = kind
                    if kind == tarfile.SYMTYPE:
                        item.linkname = "other-etc"
                    output.addfile(item)
                with self.assertRaisesRegex(ValueError, "directory.*ancestor"):
                    self.run_build(layers=[self.original, bad])

    def test_hash_mismatch_is_rejected(self):
        base = layout(self.root / "image", [self.original])
        index = json.loads((base / "index.json").read_text())
        digest = index["manifests"][0]["digest"].split(":")[1]
        (base / "blobs/sha256" / digest).write_text("changed")
        with self.assertRaisesRegex(ValueError, "digest or size"):
            build(base, self.users, self.groups, "amd64")


if __name__ == "__main__":
    unittest.main()
