"""Offline fixture coverage for the local Reel installer safety gates."""

import importlib.util
import hashlib
import json
import os
import plistlib
from pathlib import Path
import select
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import unittest
import zipfile
from unittest import mock


SCRIPT = Path(__file__).with_name("manage-local-install.py")
SPEC = importlib.util.spec_from_file_location("manage_local_install", SCRIPT)
manage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manage)


def make_app(path, *, version, build, commit):
    contents = path / "Contents"
    executable_folder = contents / "MacOS"
    executable_folder.mkdir(parents=True)
    (executable_folder / "Reel").write_bytes(b"fixture executable")
    info = {
        "CFBundleIdentifier": manage.IDENTIFIER,
        "CFBundleExecutable": "Reel",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
        manage.BUILD_COMMIT_KEY: commit,
        manage.BUILD_CONFIGURATION_KEY: "Release",
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    return info


def make_open_in_extension(app):
    extension = app / "Contents/PlugIns/OpenInIINA.appex"
    info_path = extension / "Contents/Info.plist"
    info_path.parent.mkdir(parents=True)
    info_path.write_bytes(plistlib.dumps({
        "CFBundleIdentifier": manage.IDENTIFIER + ".OpenInIINA",
        "CFBundleVersion": "172",
    }))
    return extension


def set_fixture_xattr(path, name, value):
    """Set only synthetic fixture metadata through the system xattr utility."""
    tool = "/usr/bin/xattr"
    if not Path(tool).is_file():
        raise unittest.SkipTest("macOS xattr utility is unavailable")
    result = subprocess.run(
        [tool, "-w", name, value, str(path)], capture_output=True, text=True, timeout=10,
    )
    if result.returncode:
        raise AssertionError(result.stderr.strip()[:300] or "Could not set synthetic fixture xattr")


def write_bundle_archive(app, destination, *, omit=()):
    omitted = set(omit)
    inventory = manage.bundle_inventory(app)
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for member, (kind, mode, _, _metadata) in inventory.items():
            if member in omitted:
                continue
            path = app if member == f"{app.name}/" else app / member.removeprefix(f"{app.name}/").rstrip("/")
            if kind == "directory":
                entry = zipfile.ZipInfo(member)
                entry.external_attr = (stat.S_IFDIR | mode) << 16 | 0x10
                archive.writestr(entry, b"")
            elif kind == "symlink":
                entry = zipfile.ZipInfo(member)
                entry.external_attr = (stat.S_IFLNK | mode) << 16
                archive.writestr(entry, os.readlink(path).encode("utf-8", "surrogateescape"))
            else:
                archive.write(path, member)
    manage.ensure_appledouble_metadata(destination, app, inventory)


def apple_double_payload(payload):
    header = struct.pack(">II16sH", 0x00051607, 0x00020000, b"Mac OS X" + b" " * 8, 1)
    entry = struct.pack(">III", 2, 38, len(payload))
    return header + entry + payload


def rewrite_central_directory_file_size(path, member_name, new_size):
    with zipfile.ZipFile(path) as archive:
        local_header_offset = archive.getinfo(member_name).header_offset
    data = bytearray(Path(path).read_bytes())
    if data[local_header_offset:local_header_offset + 4] != b"PK\x03\x04":
        raise AssertionError(f"Local header not found: {member_name}")
    struct.pack_into("<I", data, local_header_offset + 22, new_size)
    cursor = 0
    while True:
        cursor = data.find(b"PK\x01\x02", cursor)
        if cursor < 0:
            raise AssertionError(f"Central directory member not found: {member_name}")
        name_length, extra_length, comment_length = struct.unpack_from("<HHH", data, cursor + 28)
        name_start = cursor + 46
        name = bytes(data[name_start:name_start + name_length]).decode("utf-8")
        if name == member_name:
            struct.pack_into("<I", data, cursor + 24, new_size)
            Path(path).write_bytes(data)
            return
        cursor = name_start + name_length + extra_length + comment_length


def rewrite_directory_member_as_hidden_payload(path, member_name):
    """Make both headers claim an empty directory while retaining one stored byte."""
    with zipfile.ZipFile(path) as archive:
        member = archive.getinfo(member_name)
        local_offset = member.header_offset
    data = bytearray(Path(path).read_bytes())
    if data[local_offset:local_offset + 4] != b"PK\x03\x04":
        raise AssertionError(f"Local header not found: {member_name}")
    struct.pack_into("<I", data, local_offset + 14, 0)  # local CRC
    struct.pack_into("<I", data, local_offset + 22, 0)  # local uncompressed size
    cursor = 0
    while True:
        cursor = data.find(b"PK\x01\x02", cursor)
        if cursor < 0:
            raise AssertionError(f"Central directory member not found: {member_name}")
        name_length, extra_length, comment_length = struct.unpack_from("<HHH", data, cursor + 28)
        name_start = cursor + 46
        name = bytes(data[name_start:name_start + name_length]).decode("utf-8")
        if name == member_name:
            struct.pack_into("<I", data, cursor + 16, 0)  # central CRC
            struct.pack_into("<I", data, cursor + 24, 0)  # central uncompressed size
            Path(path).write_bytes(data)
            return
        cursor = name_start + name_length + extra_length + comment_length


def add_zip64_end_records(path, *, entry_count=None, central_size=None):
    """Convert a small single-disk ZIP trailer to a fixed-size Zip64 form."""
    data = Path(path).read_bytes()
    eocd = data.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise AssertionError("Classic ZIP end record not found")
    fields = struct.unpack_from("<IHHHHIIH", data, eocd)
    (signature, disk, central_disk, entries_on_disk, entries, size, offset,
     comment_length) = fields
    if signature != 0x06054B50 or eocd + 22 + comment_length != len(data):
        raise AssertionError("Classic ZIP end record is malformed")
    if entry_count is None:
        entry_count = entries
    if central_size is None:
        central_size = size
    zip64_offset = eocd
    zip64_record = struct.pack(
        "<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0,
        entry_count, entry_count, central_size, offset,
    )
    locator = struct.pack("<IIQI", 0x07064B50, 0, zip64_offset, 1)
    classic_record = struct.pack(
        "<IHHHHIIH", 0x06054B50, disk, central_disk, 0xFFFF, 0xFFFF,
        0xFFFFFFFF, 0xFFFFFFFF, comment_length,
    )
    Path(path).write_bytes(data[:eocd] + zip64_record + locator + classic_record + data[eocd + 22:])


def rewrite_classic_central_directory_size(path, new_size):
    data = bytearray(Path(path).read_bytes())
    eocd = data.rfind(b"PK\x05\x06")
    if eocd < 0:
        raise AssertionError("ZIP end record not found")
    struct.pack_into("<I", data, eocd + 12, new_size)
    Path(path).write_bytes(data)


def archive_manifest_record(archive_path=None):
    return {
        "original": "/Applications/Reel.app",
        "archive": str(archive_path or Path("/tmp/Reel-backup.zip")),
        "version": "1.5.0",
        "build": "172",
        "executableSHA256": "a" * 64,
        "archiveSHA256": "b" * 64,
    }


class LocalInstallFixtures(unittest.TestCase):
    def test_info_plist_exposes_build_metadata_under_reel_bundle_identifier(self):
        info_path = SCRIPT.parent.parent / "iina/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        for field in ("branch", "commit", "configuration", "date", "sdk", "xcode"):
            with self.subTest(field=field):
                self.assertIn(f"{manage.IDENTIFIER}.build.{field}", info)
                self.assertEqual(
                    info[f"{manage.IDENTIFIER}.build.{field}"],
                    info[f"com.colliderli.iina.build.{field}"],
                )

    def test_identity_rejects_symlink_fifo_oversized_and_malformed_info_plists(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            info = app / "Contents/Info.plist"
            valid = root / "valid-info.plist"
            valid.write_bytes(info.read_bytes())

            info.unlink()
            info.symlink_to(valid)
            with self.assertRaisesRegex(RuntimeError, "regular file|safely"):
                manage.identity(app)

            info.unlink()
            os.mkfifo(info)
            with self.assertRaisesRegex(RuntimeError, "regular file"):
                manage.identity(app)

            info.unlink()
            info.write_bytes(b"x" * (manage.MAX_INFO_PLIST_BYTES + 1))
            with self.assertRaisesRegex(RuntimeError, "no larger than"):
                manage.identity(app)

            info.write_bytes(b"not a plist")
            with self.assertRaisesRegex(RuntimeError, "malformed"):
                manage.identity(app)

    def test_bundle_and_zip_inventory_enforce_entry_and_uncompressed_byte_caps(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            with mock.patch.object(manage, "MAX_BUNDLE_ENTRIES", 4):
                with self.assertRaisesRegex(RuntimeError, "100,000-entry"):
                    manage.bundle_inventory(app)
            with mock.patch.object(manage, "MAX_BUNDLE_TOTAL_BYTES", 1):
                with self.assertRaisesRegex(RuntimeError, "16 GiB total-byte"):
                    manage.bundle_inventory(app)

            archive_path = root / "bounded.zip"
            write_bundle_archive(app, archive_path)
            with zipfile.ZipFile(archive_path) as archive:
                with mock.patch.object(manage, "MAX_BACKUP_ENTRIES", 1):
                    with self.assertRaisesRegex(RuntimeError, "100,000 ZIP-entry"):
                        manage.verify_archive_bundle(archive, app)
                with mock.patch.object(manage, "MAX_BACKUP_UNCOMPRESSED_BYTES", 1):
                    with self.assertRaisesRegex(RuntimeError, "16.5 GiB total-uncompressed"):
                        manage.verify_archive_bundle(archive, app)

    def test_archive_stream_enforces_actual_aggregate_decompressed_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            archive_path = root / "underreported.zip"
            write_bundle_archive(app, archive_path)
            with zipfile.ZipFile(archive_path) as archive:
                entries = [item for item in archive.infolist()
                           if item.filename in manage.bundle_inventory(app)
                           and not item.filename.endswith("/")]
                target = max(entries, key=lambda item: item.file_size)
                actual_total = sum(item.file_size for item in archive.infolist())
                self.assertGreater(target.file_size, 1)
                self.assertGreater(actual_total, target.file_size)

            # Both ZIP headers claim this member is empty, while its compressed
            # stream still expands to the complete fixture file.
            rewrite_central_directory_file_size(archive_path, target.filename, 0)
            declared_total = actual_total - target.file_size
            with zipfile.ZipFile(archive_path) as archive:
                self.assertLessEqual(sum(item.file_size for item in archive.infolist()), declared_total)
                with mock.patch.object(manage, "MAX_BACKUP_UNCOMPRESSED_BYTES", declared_total):
                    with self.assertRaisesRegex(RuntimeError, "aggregate limit while streaming actual"):
                        manage.verify_archive_bundle(archive, app)

    def test_zip_metadata_is_preflighted_for_classic_and_zip64_directories(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            classic_path = root / "classic.zip"
            with zipfile.ZipFile(classic_path, "w") as archive:
                archive.writestr("one", b"1")
                archive.writestr("two", b"2")
            with classic_path.open("rb") as stream:
                with mock.patch.object(manage, "MAX_BACKUP_ENTRIES", 1):
                    with self.assertRaisesRegex(RuntimeError, "ZIP-entry limit"):
                        manage.preflight_zip_central_directory(stream)

            zip64_path = root / "zip64.zip"
            with zipfile.ZipFile(zip64_path, "w") as archive:
                archive.writestr("one", b"1")
                archive.writestr("two", b"2")
            add_zip64_end_records(zip64_path)
            with zip64_path.open("rb") as stream:
                manage.preflight_zip_central_directory(stream)
            with zip64_path.open("rb") as stream:
                with mock.patch.object(manage, "MAX_BACKUP_ENTRIES", 1):
                    with self.assertRaisesRegex(RuntimeError, "ZIP-entry limit"):
                        manage.preflight_zip_central_directory(stream)

            oversized_path = root / "oversized-central-directory.zip"
            with zipfile.ZipFile(oversized_path, "w") as archive:
                archive.writestr("one", b"1")
            rewrite_classic_central_directory_size(
                oversized_path, manage.MAX_BACKUP_CENTRAL_DIRECTORY_BYTES + 1,
            )
            with oversized_path.open("rb") as stream:
                with self.assertRaisesRegex(RuntimeError, "128 MiB metadata limit"):
                    manage.preflight_zip_central_directory(stream)

    def test_zip_data_descriptors_validate_classic_and_zip64_forms(self):
        import importlib.util
        import struct
        import sys
        import tempfile
        import zipfile
        from pathlib import Path

        installer_path = Path(__file__).with_name("manage-local-install.py")
        spec = importlib.util.spec_from_file_location(
            "manage_local_install_descriptor_test", installer_path
        )
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        installer = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = installer
        spec.loader.exec_module(installer)

        payload = b"small descriptor fixture"

        def make_descriptor_archive(path, *, zip64=False, signature=False,
                                    corrupt_crc=False, local_crc_conflict=False):
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as output:
                output.writestr("payload.bin", payload)

            data = bytearray(Path(path).read_bytes())
            end_offset = data.rfind(b"PK\x05\x06")
            central_offset = struct.unpack_from("<I", data, end_offset + 16)[0]
            self.assertEqual(data[central_offset:central_offset + 4], b"PK\x01\x02")
            local_offset = struct.unpack_from("<I", data, central_offset + 42)[0]
            local_name_size, local_extra_size = struct.unpack_from("<HH", data, local_offset + 26)
            local_extra_start = local_offset + 30 + local_name_size
            data_start = local_extra_start + local_extra_size

            local_zip64_extra = b"\x01\x00\x10\x00" + b"\x00" * 16 if zip64 else b""
            if local_zip64_extra:
                data[local_offset + 28:local_offset + 30] = struct.pack("<H", len(local_zip64_extra))
                data[local_extra_start:local_extra_start] = local_zip64_extra
                data_start += len(local_zip64_extra)

            crc = struct.unpack_from("<I", data, central_offset + len(local_zip64_extra) + 16)[0]
            compressed_size, uncompressed_size = struct.unpack_from(
                "<II", data, central_offset + len(local_zip64_extra) + 20
            )
            descriptor_crc = crc ^ 1 if corrupt_crc else crc
            if zip64:
                descriptor = struct.pack("<IQQ", descriptor_crc, compressed_size, uncompressed_size)
            else:
                descriptor = struct.pack("<III", descriptor_crc, compressed_size, uncompressed_size)
            if signature:
                descriptor = b"PK\x07\x08" + descriptor

            data_end = data_start + compressed_size
            data[data_end:data_end] = descriptor
            new_central_offset = central_offset + len(local_zip64_extra) + len(descriptor)
            central = new_central_offset
            local_flags = struct.unpack_from("<H", data, local_offset + 6)[0] | 0x08
            central_flags = struct.unpack_from("<H", data, central + 8)[0] | 0x08
            struct.pack_into("<H", data, local_offset + 6, local_flags)
            struct.pack_into("<H", data, central + 8, central_flags)
            struct.pack_into("<I", data, local_offset + 14, crc ^ 1 if local_crc_conflict else 0)
            placeholder = 0xFFFFFFFF if zip64 else 0
            struct.pack_into("<II", data, local_offset + 18, placeholder, placeholder)

            new_end_offset = end_offset + len(local_zip64_extra) + len(descriptor)
            struct.pack_into("<I", data, new_end_offset + 16, new_central_offset)
            Path(path).write_bytes(data)
            return new_central_offset

        with tempfile.TemporaryDirectory() as directory:
            cases = (
                (False, False),
                (False, True),
                (True, False),
                (True, True),
            )
            for index, (zip64, signature) in enumerate(cases):
                path = Path(directory) / f"valid-{index}.zip"
                central_offset = make_descriptor_archive(
                    path, zip64=zip64, signature=signature
                )
                with zipfile.ZipFile(path) as archive:
                    member = archive.infolist()[0]
                    self.assertEqual(
                        installer._zip_member_data_offset(archive, member),
                        member.header_offset + 30 + len(member.filename.encode("utf-8"))
                        + (20 if zip64 else 0),
                    )

            malformed_cases = (
                {"signature": True, "corrupt_crc": True},
                {"local_crc_conflict": True},
            )
            for index, options in enumerate(malformed_cases):
                path = Path(directory) / f"invalid-{index}.zip"
                central_offset = make_descriptor_archive(path, **options)
                with zipfile.ZipFile(path) as archive:
                    with self.assertRaises(RuntimeError):
                        installer._zip_member_data_offset(
                            archive, archive.infolist()[0]
                        )

    def test_archive_rejects_directory_with_hidden_actual_body(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            directory_name = "Reel.app/"
            expected = {directory_name: ("directory", 0o755, None, ())}
            valid_path = root / "empty-directory.zip"
            with zipfile.ZipFile(valid_path, "w") as archive:
                entry = zipfile.ZipInfo(directory_name)
                entry.compress_type = zipfile.ZIP_STORED
                entry.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
                archive.writestr(entry, b"")
            with zipfile.ZipFile(valid_path) as archive:
                manage.verify_archive_bundle(archive, app, expected_inventory=expected)

            archive_path = root / "directory-payload.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                entry = zipfile.ZipInfo(directory_name)
                entry.compress_type = zipfile.ZIP_STORED
                entry.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
                archive.writestr(entry, b"X")
            # The local and central records now claim an empty body, but the
            # one stored payload byte remains inside this directory member.
            rewrite_directory_member_as_hidden_payload(archive_path, directory_name)
            with zipfile.ZipFile(archive_path) as archive:
                self.assertEqual(archive.getinfo(directory_name).file_size, 0)
                with self.assertRaisesRegex(RuntimeError, "uncompressed read limit"):
                    manage.verify_archive_bundle(archive, app, expected_inventory=expected)

    def test_archive_cleans_only_bounded_marker_backed_temp_artifacts(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            support = root / "Support"
            backups = support / "Backups"
            backups.mkdir(parents=True)
            generated_name = "Reel-20261011T123456789012Z-abcdef123456-12345678.zip"
            directory_fd = manage.open_backup_directory(support)
            try:
                owned_name, owned_fd, _ = manage.create_archive_temporary_directory(
                    directory_fd, "Reel", generated_name,
                )
                os.close(owned_fd)
                (backups / owned_name / generated_name).write_bytes(b"partial synthetic archive")

                unmarked_name = ".Reel-archive-" + "a" * 32
                os.mkdir(unmarked_name, 0o700, dir_fd=directory_fd)
                (backups / unmarked_name / "user-sentinel").write_bytes(b"keep")

                occupied_name, occupied_fd, _ = manage.create_archive_temporary_directory(
                    directory_fd, "Reel", "Reel-20261011T123456789013Z-abcdef123456-12345678.zip",
                )
                os.close(occupied_fd)
                (backups / occupied_name / "user-sentinel").write_bytes(b"keep")

                hardlink_name, hardlink_fd, _ = manage.create_archive_temporary_directory(
                    directory_fd, "Reel", "Reel-20261011T123456789014Z-abcdef123456-12345678.zip",
                )
                os.close(hardlink_fd)
                outside_payload = backups / "synthetic-user-payload"
                outside_payload.write_bytes(b"keep hardlinked fixture")
                os.link(outside_payload, backups / hardlink_name /
                        "Reel-20261011T123456789014Z-abcdef123456-12345678.zip")

                symlink_name = ".Reel-archive-" + "b" * 32
                symlink_target = backups / "synthetic-user-directory"
                symlink_target.mkdir()
                (symlink_target / "user-sentinel").write_bytes(b"keep")
                (backups / symlink_name).symlink_to(symlink_target, target_is_directory=True)

                unmatched_name = ".Reel-archive-not-an-installer-token"
                (backups / unmatched_name).mkdir()
                (backups / unmatched_name / "user-sentinel").write_bytes(b"keep")

                manage.cleanup_stale_archive_temporary_directories(directory_fd, "Reel")
            finally:
                os.close(directory_fd)

            self.assertFalse((backups / owned_name).exists())
            self.assertEqual((backups / unmarked_name / "user-sentinel").read_bytes(), b"keep")
            self.assertEqual((backups / occupied_name / "user-sentinel").read_bytes(), b"keep")
            self.assertEqual((backups / unmatched_name / "user-sentinel").read_bytes(), b"keep")
            self.assertTrue((backups / hardlink_name).is_dir())
            self.assertEqual((backups / "synthetic-user-payload").read_bytes(), b"keep hardlinked fixture")
            self.assertTrue((backups / symlink_name).is_symlink())
            self.assertEqual((symlink_target / "user-sentinel").read_bytes(), b"keep")

    def test_archive_temp_cleanup_candidate_bound_fails_before_removal(self):
        with tempfile.TemporaryDirectory() as folder:
            support = Path(folder) / "Support"
            backups = support / "Backups"
            backups.mkdir(parents=True)
            directory_fd = manage.open_backup_directory(support)
            names = [".Reel-archive-" + f"{index:032x}" for index in range(2)]
            try:
                for name in names:
                    os.mkdir(name, 0o700, dir_fd=directory_fd)
                with mock.patch.object(manage, "MAX_ARCHIVE_TEMP_CANDIDATES", 1):
                    with self.assertRaisesRegex(RuntimeError, "more than 1 temporary-artifact"):
                        manage.cleanup_stale_archive_temporary_directories(directory_fd, "Reel")
            finally:
                os.close(directory_fd)
            self.assertTrue(all((backups / name).is_dir() for name in names))

    def test_archive_manifest_rejects_unsafe_backup_directories_and_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            record = archive_manifest_record()
            support = root / "symlink-directory-support"
            support.mkdir()
            outside = root / "outside-backups"
            outside.mkdir()
            (support / "Backups").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "Backup folder must be a real"):
                manage.append_archive_manifest(support, record)
            self.assertEqual(list(outside.iterdir()), [])

            unsafe_modes = root / "unsafe-mode-support"
            (unsafe_modes / "Backups").mkdir(parents=True)
            (unsafe_modes / "Backups").chmod(0o777)
            with self.assertRaisesRegex(RuntimeError, "without group/world write access"):
                manage.append_archive_manifest(unsafe_modes, record)

            nonowner_support = root / "nonowner-support"
            (nonowner_support / "Backups").mkdir(parents=True)
            real_geteuid = os.geteuid
            with mock.patch.object(manage.os, "geteuid", side_effect=[real_geteuid(), real_geteuid() + 1]):
                with self.assertRaisesRegex(
                    RuntimeError, "owner-owned directory without group/world write access",
                ):
                    manage.append_archive_manifest(nonowner_support, record)

    def test_archive_manifest_rejects_symlink_hardlink_nonowner_and_malformed_files(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            record = archive_manifest_record()
            outside = root / "outside-manifest.jsonl"
            outside.write_text("untouched\n")

            symlink_support = root / "symlink-support"
            (symlink_support / "Backups").mkdir(parents=True)
            (symlink_support / "Backups/archive-manifest.jsonl").symlink_to(outside)
            with self.assertRaisesRegex(RuntimeError, "safely open|single-link"):
                manage.append_archive_manifest(symlink_support, record)
            self.assertEqual(outside.read_text(), "untouched\n")

            hardlink_support = root / "hardlink-support"
            hardlink_backups = hardlink_support / "Backups"
            hardlink_backups.mkdir(parents=True)
            manifest = hardlink_backups / "archive-manifest.jsonl"
            manifest.write_text(json.dumps(archive_manifest_record()) + "\n")
            os.link(manifest, root / "manifest-hardlink")
            with self.assertRaisesRegex(RuntimeError, "single-link regular file"):
                manage.append_archive_manifest(hardlink_support, record)

            malformed_support = root / "malformed-support"
            malformed_backups = malformed_support / "Backups"
            malformed_backups.mkdir(parents=True)
            (malformed_backups / "archive-manifest.jsonl").write_bytes(b"{broken json}\n")
            with self.assertRaisesRegex(RuntimeError, "malformed JSON"):
                manage.append_archive_manifest(malformed_support, record)

            oversized_support = root / "oversized-support"
            oversized_backups = oversized_support / "Backups"
            oversized_backups.mkdir(parents=True)
            oversized_manifest = oversized_backups / "archive-manifest.jsonl"
            oversized_manifest.write_bytes(b"x" * (manage.MAX_ARCHIVE_MANIFEST_BYTES + 1))
            oversized_manifest.chmod(0o600)
            with self.assertRaisesRegex(RuntimeError, "size limit"):
                manage.append_archive_manifest(oversized_support, record)

            nonowner_support = root / "nonowner-manifest-support"
            nonowner_backups = nonowner_support / "Backups"
            nonowner_backups.mkdir(parents=True)
            (nonowner_backups / "archive-manifest.jsonl").write_text(
                json.dumps(archive_manifest_record()) + "\n"
            )
            real_geteuid = os.geteuid
            with mock.patch.object(
                    manage.os, "geteuid",
                    side_effect=[real_geteuid()] * 4 + [real_geteuid() + 1]):
                with self.assertRaisesRegex(RuntimeError, "owner-owned single-link"):
                    manage.append_archive_manifest(nonowner_support, record)

    def test_archive_manifest_appends_validated_records_and_rejects_partial_write_state(self):
        with tempfile.TemporaryDirectory() as folder:
            support = Path(folder) / "Support"
            record = archive_manifest_record()
            manage.append_archive_manifest(support, record)
            manage.append_archive_manifest(support, dict(record, archiveSHA256="c" * 64))
            manifest = support / "Backups/archive-manifest.jsonl"
            lines = manifest.read_bytes().splitlines()
            self.assertEqual(len(lines), 2)
            self.assertEqual(json.loads(lines[0]), record)
            self.assertEqual(stat.S_IMODE(manifest.stat().st_mode), 0o600)

            malformed_support = Path(folder) / "partial-support"
            malformed_backups = malformed_support / "Backups"
            malformed_backups.mkdir(parents=True)
            (malformed_backups / "archive-manifest.jsonl").write_bytes(b'{"partial":')
            with self.assertRaisesRegex(RuntimeError, "incomplete|malformed"):
                manage.append_archive_manifest(malformed_support, record)

    def test_archive_manifest_publication_is_atomic_when_write_or_replace_is_interrupted(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            record = archive_manifest_record()
            existing_support = root / "existing"
            manage.append_archive_manifest(existing_support, record)
            manifest = existing_support / "Backups/archive-manifest.jsonl"
            original = manifest.read_bytes()

            real_write = os.write
            interrupted = False

            def partial_write(descriptor, payload):
                nonlocal interrupted
                if not interrupted:
                    interrupted = True
                    real_write(descriptor, payload[:max(1, len(payload) // 2)])
                    raise OSError("fixture interrupted journal write")
                return real_write(descriptor, payload)

            with mock.patch.object(manage.os, "write", side_effect=partial_write):
                with self.assertRaisesRegex(OSError, "interrupted journal write"):
                    manage.append_archive_manifest(
                        existing_support, dict(record, archiveSHA256="c" * 64),
                    )
            self.assertEqual(manifest.read_bytes(), original)
            self.assertEqual(manage.validate_archive_manifest(existing_support), [record])
            self.assertEqual(list(manifest.parent.glob(".archive-manifest.jsonl.tmp-*")), [])

            with mock.patch.object(manage.os, "replace", side_effect=OSError("fixture interruption")):
                with self.assertRaisesRegex(OSError, "fixture interruption"):
                    manage.append_archive_manifest(
                        existing_support, dict(record, archiveSHA256="c" * 64),
                    )
            self.assertEqual(manifest.read_bytes(), original)
            self.assertEqual(manage.validate_archive_manifest(existing_support), [record])
            self.assertEqual(list(manifest.parent.glob(".archive-manifest.jsonl.tmp-*")), [])

            new_support = root / "new"
            with mock.patch.object(manage.os, "replace", side_effect=OSError("fixture interruption")):
                with self.assertRaisesRegex(OSError, "fixture interruption"):
                    manage.append_archive_manifest(new_support, record)
            self.assertFalse((new_support / "Backups/archive-manifest.jsonl").exists())
            self.assertEqual(manage.validate_archive_manifest(new_support), [])
            self.assertEqual(
                list((new_support / "Backups").glob(".archive-manifest.jsonl.tmp-*")), [],
            )

    def test_evidence_preserves_existing_validation_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            support = Path(folder) / "Support"
            validation = support / "Validation"
            validation.mkdir(parents=True)
            validation.chmod(0o755)

            evidence = manage.write_evidence({"registrationClean": True}, support)

            self.assertEqual(stat.S_IMODE(validation.stat().st_mode), 0o755)
            self.assertEqual(stat.S_IMODE(evidence.stat().st_mode), 0o600)
            self.assertTrue(evidence.is_file())

    def test_evidence_rejects_symlinked_validation_directory_without_chmodding_target(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            support = root / "Support"
            support.mkdir()
            target = root / "other-directory"
            target.mkdir()
            target.chmod(0o755)
            (support / "Validation").symlink_to(target, target_is_directory=True)

            with self.assertRaisesRegex(RuntimeError, "real directory"):
                manage.write_evidence({"registrationClean": True}, support)

            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)
            self.assertEqual(list(target.iterdir()), [])

    def test_complete_archive_verification_detects_missing_resources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            resources = app / "Contents/Resources"
            resources.mkdir()
            (resources / "Player.strings").write_bytes(b"localized player strings")
            (resources / "Current.lproj").symlink_to("../Resources")
            complete = root / "complete.zip"
            write_bundle_archive(app, complete)
            with zipfile.ZipFile(complete) as archive:
                self.assertIsNone(archive.testzip())
                manage.verify_archive_bundle(archive, app)

            missing = root / "missing-resource.zip"
            write_bundle_archive(app, missing, omit={"Reel.app/Contents/Resources/Player.strings"})
            with zipfile.ZipFile(missing) as archive:
                with self.assertRaisesRegex(RuntimeError, "inventory differs"):
                    manage.verify_archive_bundle(archive, app)

    def test_backup_verifier_rejects_duplicate_foreign_and_traversal_members(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            member = "Reel.app/Contents/MacOS/Reel"
            cases = [
                (member, b"duplicate executable"),
                ("Other.app/Contents/Info.plist", b"foreign bundle"),
                ("../outside.txt", b"path traversal"),
                ("__MACOSX/Reel.app/Contents/Resources/._unrelated", b"stray sidecar"),
                ("__MACOSX/Reel.app/Contents/MacOS/._Reel", b"not an AppleDouble header"),
            ]
            for index, (extra_name, payload) in enumerate(cases):
                with self.subTest(extra_name=extra_name):
                    archive_path = root / f"unsafe-{index}.zip"
                    write_bundle_archive(app, archive_path)
                    with zipfile.ZipFile(archive_path, "a", compression=zipfile.ZIP_DEFLATED) as archive:
                        if extra_name == member:
                            with self.assertWarnsRegex(UserWarning, "Duplicate name"):
                                archive.writestr(extra_name, payload)
                        else:
                            archive.writestr(extra_name, payload)
                    with zipfile.ZipFile(archive_path) as archive:
                        with self.assertRaisesRegex(RuntimeError, "duplicate|unexpected|unsafe|invalid|truncated"):
                            manage.verify_archive_bundle(archive, app)

    @unittest.skipUnless(sys.platform == "darwin", "ditto AppleDouble archives are macOS-specific")
    def test_backup_verifier_accepts_ditto_resource_fork_and_xattr_sidecars(self):
        xattr = shutil.which("/usr/bin/xattr") or shutil.which("xattr")
        ditto = "/usr/bin/ditto"
        if not xattr or not Path(ditto).is_file():
            self.skipTest("macOS xattr or ditto tool is unavailable")
        with tempfile.TemporaryDirectory(prefix="reel-ditto-fixture-") as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            payload = app / "Contents/Resources/payload.bin"
            payload.parent.mkdir(parents=True)
            payload.write_bytes(b"synthetic bundle resource")

            for arguments in (
                ("-w", "org.example.reel-fixture", "synthetic-xattr", str(payload)),
                ("-wx", "com.apple.ResourceFork", "73796e7468657469632d666f726b", str(payload)),
            ):
                result = subprocess.run([xattr, *arguments], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr.strip()[:300])

            archive_path = root / "ditto-fixture.zip"
            result = subprocess.run(
                [ditto, "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive_path)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr.strip()[:300])
            inventory = manage.bundle_inventory(app)
            manage.ensure_appledouble_metadata(archive_path, app, inventory)
            with zipfile.ZipFile(archive_path) as archive:
                self.assertIsNone(archive.testzip())
                self.assertIn(
                    "__MACOSX/Reel.app/Contents/Resources/._payload.bin",
                    archive.namelist(),
                )
                manage.verify_archive_bundle(archive, app)

    @unittest.skipUnless(sys.platform == "darwin", "renamex_np is a macOS API")
    def test_atomic_swap_exchanges_both_directory_contents(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            installed = root / "Reel.app"
            staged = root / "Reel.bundle-stage"
            installed.mkdir()
            staged.mkdir()
            (installed / "version").write_text("old")
            (staged / "version").write_text("new")

            manage.atomic_swap_paths(staged, installed)

            self.assertEqual((installed / "version").read_text(), "new")
            self.assertEqual((staged / "version").read_text(), "old")

    def test_install_and_repair_wait_on_the_same_target_lock_before_preflight(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            installed = root / "Applications/Reel.app"
            installed.parent.mkdir()
            make_app(installed, version="1.5.0", build="172", commit="a" * 40)
            first_preflight = threading.Event()
            release_first = threading.Event()
            second_preflight = threading.Event()
            second_lock_attempt = threading.Event()
            second_lock_acquired = threading.Event()
            failures = []
            original_flock = manage.fcntl.flock

            def first_checkout_gate():
                first_preflight.set()
                if not release_first.wait(timeout=5):
                    raise RuntimeError("fixture timed out waiting to release install")
                raise RuntimeError("fixture stops after lock acquisition")

            def repair_identity(_app):
                second_preflight.set()
                raise RuntimeError("fixture stops after lock acquisition")

            def observed_flock(descriptor, operation):
                is_repair_lock = (threading.current_thread().name == "repairer"
                                  and operation == manage.fcntl.LOCK_EX)
                if is_repair_lock:
                    second_lock_attempt.set()
                result = original_flock(descriptor, operation)
                if is_repair_lock:
                    second_lock_acquired.set()
                return result

            def call_install():
                try:
                    manage.install(root / "unused-source.app", root / "Support")
                except Exception as error:
                    failures.append(error)

            def call_repair():
                try:
                    manage.repair(root / "Support")
                except Exception as error:
                    failures.append(error)

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "ensure_clean_checkout", side_effect=first_checkout_gate), \
                    mock.patch.object(manage, "identity", side_effect=repair_identity), \
                    mock.patch.object(manage.fcntl, "flock", side_effect=observed_flock):
                installer = threading.Thread(target=call_install, name="installer")
                repairer = threading.Thread(target=call_repair, name="repairer")
                installer.start()
                self.assertTrue(first_preflight.wait(timeout=2))
                repairer.start()
                self.assertTrue(second_lock_attempt.wait(timeout=2))
                self.assertFalse(second_lock_acquired.wait(timeout=0.1),
                                 "repair must block on install's target lock")
                self.assertFalse(second_preflight.is_set(), "repair must wait while install owns the lock")
                release_first.set()
                installer.join(timeout=3)
                repairer.join(timeout=3)

            self.assertFalse(installer.is_alive())
            self.assertFalse(repairer.is_alive())
            self.assertTrue(second_preflight.is_set())
            self.assertEqual(len(failures), 2)
            self.assertTrue(all("fixture stops after lock acquisition" in str(error) for error in failures))

    def test_installation_lock_serializes_a_separate_process(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            installed = root / "Applications/Reel.app"
            installed.parent.mkdir()
            child = '''
import importlib.util
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("manage_local_install", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print("waiting", flush=True)
with module.installation_lock(Path(sys.argv[2])):
    print("acquired", flush=True)
'''
            process = None
            try:
                with manage.installation_lock(installed):
                    process = subprocess.Popen(
                        [sys.executable, "-c", child, str(SCRIPT), str(installed)],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
                    )
                    self.assertEqual(process.stdout.readline().strip(), "waiting")
                    readable, _, _ = select.select([process.stdout], [], [], 0.1)
                    self.assertFalse(readable, "a second process must block until the target lock is released")
                self.assertEqual(process.stdout.readline().strip(), "acquired")
                _, stderr = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, stderr)
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=3)

    def test_installer_waits_for_desktop_launcher_handoff_lock(self):
        with tempfile.TemporaryDirectory() as folder:
            installed = Path(folder) / "Applications/Reel.app"
            installed.parent.mkdir()
            preflight_started = threading.Event()
            failures = []

            def stop_after_transition_lock():
                preflight_started.set()
                raise RuntimeError("fixture stops after transition lock acquisition")

            def call_install():
                try:
                    manage.install(Path(folder) / "unused-source.app", Path(folder) / "Support")
                except Exception as error:
                    failures.append(error)

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "REEL_LAUNCH_LOCK", Path(folder) / "launcher-transition.lock"), \
                    mock.patch.object(manage, "ensure_clean_checkout", side_effect=stop_after_transition_lock):
                installer = threading.Thread(target=call_install, name="installer")
                with manage.launcher_transition_lock():
                    installer.start()
                    self.assertFalse(preflight_started.wait(timeout=0.15),
                                     "installer must wait while the Desktop launcher hands off to Reel")
                self.assertTrue(preflight_started.wait(timeout=2))
                installer.join(timeout=3)

            self.assertFalse(installer.is_alive())
            self.assertEqual(len(failures), 1)
            self.assertIn("fixture stops after transition lock acquisition", str(failures[0]))

    def test_timed_out_handoff_blocks_install_and_repair_through_late_launch(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            cache = root / "Library/Caches"
            cache.mkdir(parents=True, mode=0o700)
            cache.chmod(0o700)
            installed = root / "Applications/Reel.app"
            installed.parent.mkdir()
            transition_lock = cache / ".reel-install-transition.lock"
            handoff = cache / ".reel-launch-handoff.json"
            late_child = root / "late-reel-child-started"
            record = {"version": 1, "state": "pending", "pid": 1234, "created_ns": 1}

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "REEL_LAUNCH_LOCK", transition_lock), \
                    mock.patch.object(manage, "REEL_LAUNCH_HANDOFF", handoff), \
                    mock.patch.object(manage, "_install_locked", side_effect=AssertionError("install must not mutate")), \
                    mock.patch.object(manage, "_repair_locked", side_effect=AssertionError("repair must not mutate")):
                # The launcher releases the flock after its bounded wait but
                # leaves the durable pending marker before LaunchServices has
                # actually started Reel.
                with manage.launcher_transition_lock():
                    handoff.write_text(json.dumps(record))
                    handoff.chmod(0o600)

                for action in ("install", "repair"):
                    with self.subTest(action=action):
                        with self.assertRaisesRegex(RuntimeError, "has not confirmed startup"):
                            if action == "install":
                                manage.install(root / "Unused.app", root / "Support")
                            else:
                                manage.repair(root / "Support")
                        self.assertEqual(json.loads(handoff.read_text()), record)

                # A late child does not prove that the old LaunchServices
                # request has been resolved, so the marker remains fail-closed.
                late_child.touch()
                with self.assertRaisesRegex(RuntimeError, "has not confirmed startup"):
                    manage.install(root / "Unused.app", root / "Support")
                self.assertTrue(late_child.exists())
                self.assertEqual(json.loads(handoff.read_text()), record)

                confirmed = dict(record, state="confirmed")
                handoff.write_text(json.dumps(confirmed))
                handoff.chmod(0o600)
                with manage.launcher_transition_lock():
                    manage.check_launcher_handoff()
                self.assertFalse(handoff.exists(), "only confirmed startup records may be cleared")

    def test_handoff_rejects_symlink_corrupt_and_oversized_records(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            cache = root / "Library/Caches"
            cache.mkdir(parents=True, mode=0o700)
            cache.chmod(0o700)
            handoff = cache / ".reel-launch-handoff.json"
            outside = root / "outside"
            outside.write_text("keep")
            with mock.patch.object(manage, "REEL_LAUNCH_HANDOFF", handoff):
                handoff.symlink_to(outside)
                with self.assertRaisesRegex(RuntimeError, "unsafe"):
                    manage.check_launcher_handoff()
                self.assertEqual(outside.read_text(), "keep")
                handoff.unlink()
                for payload in (b"{broken", b" " * (manage.MAX_LAUNCH_HANDOFF_BYTES + 1)):
                    with self.subTest(size=len(payload)):
                        handoff.write_bytes(payload)
                        handoff.chmod(0o600)
                        with self.assertRaises(RuntimeError):
                            manage.check_launcher_handoff()
                        handoff.unlink()

    def test_repair_holds_target_lock_through_evidence_publication(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            installed = root / "Applications/Reel.app"
            installed.parent.mkdir()
            evidence_started = threading.Event()
            release_evidence = threading.Event()
            install_lock_attempt = threading.Event()
            install_lock_acquired = threading.Event()
            install_preflight = threading.Event()
            failures = []
            original_flock = manage.fcntl.flock

            def write_fixture_evidence(result, _support):
                evidence_started.set()
                if not release_evidence.wait(timeout=5):
                    raise RuntimeError("fixture timed out waiting to release evidence")
                result["evidence"] = str(root / "registration.json")
                return Path(result["evidence"])

            def stop_install_preflight():
                install_preflight.set()
                raise RuntimeError("fixture stops after lock acquisition")

            def observed_flock(descriptor, operation):
                is_install_lock = (threading.current_thread().name == "installer"
                                   and operation == manage.fcntl.LOCK_EX)
                if is_install_lock:
                    install_lock_attempt.set()
                result = original_flock(descriptor, operation)
                if is_install_lock:
                    install_lock_acquired.set()
                return result

            def call_repair():
                try:
                    manage.repair(root / "Support")
                except Exception as error:
                    failures.append(error)

            def call_install():
                try:
                    manage.install(root / "unused-source.app", root / "Support")
                except Exception as error:
                    failures.append(error)

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "_repair_locked", return_value={"registrationClean": True}), \
                    mock.patch.object(manage, "write_evidence", side_effect=write_fixture_evidence), \
                    mock.patch.object(manage, "ensure_clean_checkout", side_effect=stop_install_preflight), \
                    mock.patch.object(manage.fcntl, "flock", side_effect=observed_flock):
                repairer = threading.Thread(target=call_repair, name="repairer")
                installer = threading.Thread(target=call_install, name="installer")
                repairer.start()
                self.assertTrue(evidence_started.wait(timeout=2))
                installer.start()
                self.assertTrue(install_lock_attempt.wait(timeout=2))
                self.assertFalse(install_lock_acquired.wait(timeout=0.1),
                                 "install must wait until repair evidence publication completes")
                self.assertFalse(install_preflight.is_set())
                release_evidence.set()
                repairer.join(timeout=3)
                installer.join(timeout=3)

            self.assertFalse(repairer.is_alive())
            self.assertFalse(installer.is_alive())
            self.assertTrue(install_lock_acquired.is_set())
            self.assertTrue(install_preflight.is_set())
            self.assertEqual(len(failures), 1)
            self.assertIn("fixture stops after lock acquisition", str(failures[0]))

    def test_checkout_gate_rejects_tracked_edits(self):
        manage.ensure_clean_checkout("")
        with self.assertRaisesRegex(RuntimeError, "uncommitted tracked changes"):
            manage.ensure_clean_checkout(" M iina/PlayerCore.swift\n")

    def test_registration_parser_streams_above_generic_subprocess_limit(self):
        with tempfile.TemporaryDirectory(prefix="reel-lsregister-stream-") as folder:
            fixture = Path(folder) / "lsregister-fixture"
            fixture.write_text(
                f"#!{sys.executable}\n"
                "import sys\n"
                "stream = sys.stdout.buffer\n"
                "chunk = b'x' * 4096 + b'\\n'\n"
                "for _ in range(2300): stream.write(chunk)\n"
                "separator = b'-' * 80 + b'\\n'\n"
                "stream.write(separator)\n"
                "stream.write(b'identifier: com.colliderli.iina\\n')\n"
                "stream.write(b'path: /Applications/IINA.app (0x100)\\n')\n"
                "stream.write(separator)\n"
                "stream.write(b'identifier: io.github.tverma101.reel\\n')\n"
                "stream.write(b'path: /Applications/Reel.app (0x101)\\n')\n",
                encoding="utf-8",
            )
            fixture.chmod(0o755)
            with mock.patch.object(manage, "LSREGISTER", str(fixture)):
                self.assertEqual(manage.registrations(), [Path("/Applications/Reel.app")])

    def test_registration_parser_enforces_streamed_dump_size_limit(self):
        with tempfile.TemporaryDirectory(prefix="reel-lsregister-limit-") as folder:
            fixture = Path(folder) / "lsregister-fixture"
            fixture.write_text(
                f"#!{sys.executable}\n"
                "import sys\n"
                "sys.stdout.buffer.write(b'x' * 4096 + b'\\n')\n",
                encoding="utf-8",
            )
            fixture.chmod(0o755)
            with mock.patch.object(manage, "LSREGISTER", str(fixture)), \
                    mock.patch.object(manage, "MAX_LSREGISTER_DUMP_BYTES", 1024):
                with self.assertRaisesRegex(RuntimeError, "output limit"):
                    manage.registrations()

    def test_subprocess_output_is_capped_across_stdout_and_stderr(self):
        script = "import sys; sys.stdout.write('o' * 50); sys.stderr.write('e' * 50)"
        with mock.patch.object(manage, "MAX_PROCESS_OUTPUT_BYTES", 64):
            with self.assertRaisesRegex(RuntimeError, "64-byte output limit"):
                manage.run(sys.executable, "-c", script)

    @unittest.skipUnless(sys.platform == "darwin", "extended-attribute copying is macOS-specific")
    def test_install_rejects_xattr_mutation_before_signing(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            installed, source, commit = self._install_fixture(root)
            resource = source / "Contents/Resources/payload.bin"
            resource.parent.mkdir(parents=True)
            resource.write_bytes(b"synthetic resource")
            set_fixture_xattr(resource, "org.example.reel-fixture", "source-metadata")
            calls = []

            def fake_run(*args):
                calls.append(args)
                if args[0] == "/usr/bin/ditto":
                    shutil.copytree(args[1], args[2], symlinks=True)
                    staged = Path(args[2]) / "Contents/Resources/payload.bin"
                    set_fixture_xattr(staged, "org.example.reel-fixture", "changed-metadata")
                return ""

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "current_checkout_commit", return_value=commit), \
                    mock.patch.object(manage, "ensure_clean_checkout"), \
                    mock.patch.object(manage, "is_ancestor", return_value=True), \
                    mock.patch.object(manage, "run", side_effect=fake_run), \
                    mock.patch.object(manage, "audit", return_value={"running": []}):
                with self.assertRaisesRegex(RuntimeError, "inventory differs"):
                    manage._install_locked(source, root / "Support")

            self.assertTrue(source.exists())
            self.assertFalse(any(call[0] == "/usr/bin/codesign" and "--force" in call
                                 for call in calls))

    @unittest.skipUnless(sys.platform == "darwin", "AppleDouble xattr archives are macOS-specific")
    def test_archive_verification_rejects_omitted_and_changed_metadata_payloads(self):
        xattr = shutil.which("/usr/bin/xattr") or shutil.which("xattr")
        ditto = "/usr/bin/ditto"
        if not xattr or not Path(ditto).is_file():
            self.skipTest("macOS xattr or ditto tool is unavailable")
        with tempfile.TemporaryDirectory(prefix="reel-appledouble-mismatch-") as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            resource = app / "Contents/Resources/payload.bin"
            resource.parent.mkdir(parents=True)
            resource.write_bytes(b"synthetic payload")
            for arguments in (
                ("-w", "org.example.reel-fixture", "synthetic-xattr", str(resource)),
                ("-wx", "com.apple.ResourceFork", "73796e7468657469632d666f726b", str(resource)),
            ):
                result = subprocess.run([xattr, *arguments], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr.strip()[:300])

            source_inventory = manage.bundle_inventory(app)
            valid_path = root / "valid.zip"
            result = subprocess.run(
                [ditto, "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(valid_path)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stderr.strip()[:300])
            manage.ensure_appledouble_metadata(valid_path, app, source_inventory)
            sidecar = "__MACOSX/Reel.app/Contents/Resources/._payload.bin"
            with zipfile.ZipFile(valid_path) as archive:
                manage.verify_archive_bundle(archive, app, expected_inventory=source_inventory)
                self.assertIn(sidecar, archive.namelist())

            for changed, omit_sidecar in ((False, True), (True, False)):
                with self.subTest(changed=changed, omit_sidecar=omit_sidecar):
                    unsafe_path = root / f"unsafe-{int(changed)}-{int(omit_sidecar)}.zip"
                    with zipfile.ZipFile(valid_path) as original, zipfile.ZipFile(
                            unsafe_path, "w", compression=zipfile.ZIP_DEFLATED) as rewritten:
                        for member in original.infolist():
                            if omit_sidecar and member.filename == sidecar:
                                continue
                            payload = original.read(member)
                            if changed and member.filename == sidecar:
                                payload = payload[:-1] + bytes([payload[-1] ^ 1])
                            rewritten.writestr(member, payload)
                    with zipfile.ZipFile(unsafe_path) as archive:
                        with self.assertRaisesRegex(RuntimeError, "AppleDouble (payload|inventory) differs"):
                            manage.verify_archive_bundle(
                                archive, app, expected_inventory=source_inventory,
                            )

    def test_archive_recovers_verified_post_rename_pre_journal_debris_without_deleting_it(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            support = root / "Support"
            ditto_calls = []

            def write_ditto_archive(*args):
                if args[0] == "/usr/bin/ditto":
                    ditto_calls.append(args)
                    write_bundle_archive(app, Path(args[-1]))
                return ""

            with mock.patch.object(manage, "run", side_effect=write_ditto_archive), \
                    mock.patch.object(manage, "append_archive_manifest",
                                      side_effect=OSError("fixture crash before journal publication")):
                with self.assertRaisesRegex(OSError, "before journal publication"):
                    manage.archive(app, support)

            backups = support / "Backups"
            orphaned = list(backups.glob("Reel-*.zip"))
            self.assertEqual(len(orphaned), 1)
            original_bytes = orphaned[0].read_bytes()
            self.assertEqual(manage.validate_archive_manifest(support), [])

            ditto_calls.clear()
            with mock.patch.object(manage, "run", side_effect=write_ditto_archive):
                recovered = manage.archive(app, support)

            self.assertEqual(Path(recovered["archive"]), orphaned[0])
            self.assertEqual(orphaned[0].read_bytes(), original_bytes)
            self.assertEqual(len(manage.validate_archive_manifest(support)), 1)
            self.assertEqual(ditto_calls, [], "retry should adopt the verified orphan without another copy")

    def test_backup_member_hash_is_streamed_and_matches_source(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root / "Reel"
            member = "Reel.app/Contents/MacOS/Reel"
            source.write_bytes((b"Reel fixture executable\n" * 150000))
            archive_path = root / "Reel.zip"
            with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.write(source, member)
            with source.open("rb") as source_stream:
                expected_digest = hashlib.sha256()
                while True:
                    chunk = source_stream.read(128 * 1024)
                    if not chunk:
                        break
                    expected_digest.update(chunk)
                expected = expected_digest.hexdigest()
            with zipfile.ZipFile(archive_path) as archive:
                self.assertEqual(manage.archive_member_sha256(archive, member), expected)

    def test_archive_preflights_bundle_cap_before_hashing_executable_or_running_ditto(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            support = root / "Support"
            calls = []

            with mock.patch.object(manage, "MAX_BUNDLE_TOTAL_BYTES", 1), \
                    mock.patch.object(manage, "sha256", side_effect=AssertionError("hash must not run")), \
                    mock.patch.object(manage, "run", side_effect=lambda *args: calls.append(args)):
                with self.assertRaisesRegex(RuntimeError, "16 GiB total-byte limit"):
                    manage.archive(app, support)

            self.assertFalse(any(call[0] == "/usr/bin/ditto" for call in calls),
                             "bundle byte cap must be proven before archive creation")
            self.assertFalse(support.exists(), "oversized bundle must be rejected before creating backup storage")

    def test_backup_reuse_scan_bounds_entries_and_matching_candidates(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backups = root / "Backups"
            backups.mkdir()
            for index in range(4):
                (backups / f"unrelated-{index}").write_text("x")
            descriptor = os.open(backups, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                with mock.patch.object(manage, "MAX_BACKUP_REUSE_SCAN_ENTRIES", 3):
                    with self.assertRaisesRegex(RuntimeError, "3-entry reuse-scan limit"):
                        manage.scan_backup_reuse_candidates(descriptor, "Reel-", "-deadbeefcafe.zip")

                names = list(backups.iterdir())
                for path in names:
                    path.unlink()
                for index in range(3):
                    candidate = backups / f"Reel-{index}-deadbeefcafe.zip"
                    candidate.write_bytes(b"zip fixture")
                    candidate.chmod(0o600)
                with mock.patch.object(manage, "MAX_BACKUP_REUSE_CANDIDATES", 2):
                    with self.assertRaisesRegex(RuntimeError, "more than 2 matching reuse candidates"):
                        manage.scan_backup_reuse_candidates(descriptor, "Reel-", "-deadbeefcafe.zip")
            finally:
                os.close(descriptor)

    def test_backup_reuse_scan_rejects_symlink_special_and_nonowner_candidates(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            backups = root / "Backups"
            backups.mkdir(mode=0o700)
            outside = root / "outside.zip"
            outside.write_bytes(b"synthetic archive")
            descriptor = os.open(backups, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                symlink_name = "Reel-20261011T000000000000Z-deadbeefcafe.zip"
                (backups / symlink_name).symlink_to(outside)
                with self.assertRaisesRegex(RuntimeError, "safe bounded archive"):
                    manage.scan_backup_reuse_candidates(descriptor, "Reel-", "-deadbeefcafe.zip")
                self.assertEqual(outside.read_bytes(), b"synthetic archive")
                (backups / symlink_name).unlink()

                fifo_name = "Reel-20261011T000001000000Z-deadbeefcafe.zip"
                os.mkfifo(backups / fifo_name)
                with self.assertRaisesRegex(RuntimeError, "safe bounded archive"):
                    manage.scan_backup_reuse_candidates(descriptor, "Reel-", "-deadbeefcafe.zip")
                (backups / fifo_name).unlink()

                regular_name = "Reel-20261011T000002000000Z-deadbeefcafe.zip"
                regular = backups / regular_name
                regular.write_bytes(b"synthetic archive")
                regular.chmod(0o600)
                candidates = manage.scan_backup_reuse_candidates(
                    descriptor, "Reel-", "-deadbeefcafe.zip",
                )
                expected_identity = next(identity for name, identity in candidates if name == regular_name)
                regular.unlink()
                regular.symlink_to(outside)
                with self.assertRaisesRegex(RuntimeError, "changed during the bounded directory scan"):
                    manage.open_backup_reuse_candidate(descriptor, regular_name, expected_identity)
                self.assertEqual(outside.read_bytes(), b"synthetic archive")

                regular.unlink()
                regular.write_bytes(b"synthetic archive")
                regular.chmod(0o600)
                actual_uid = os.geteuid()
                with mock.patch.object(manage.os, "geteuid", return_value=actual_uid + 1):
                    with self.assertRaisesRegex(RuntimeError, "safe bounded archive"):
                        manage.scan_backup_reuse_candidates(descriptor, "Reel-", "-deadbeefcafe.zip")
            finally:
                os.close(descriptor)

    def test_archive_reuses_only_a_bounded_safe_matching_backup(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            inventory = manage.bundle_inventory(app)
            executable_hash, _ = manage.bundle_executable_identity(app, inventory)
            support = root / "Support"
            backups = support / "Backups"
            backups.mkdir(parents=True, mode=0o700)
            candidate = backups / f"Reel-20261011T000000000000Z-{executable_hash[:12]}.zip"
            write_bundle_archive(app, candidate)
            candidate.chmod(0o600)
            record = archive_manifest_record(candidate)
            record["executableSHA256"] = executable_hash
            record["archiveSHA256"] = manage.sha256(candidate)
            manage.append_archive_manifest(support, record)
            calls = []

            with mock.patch.object(manage, "run", side_effect=lambda *args: calls.append(args)):
                result = manage.archive(app, support)

            self.assertEqual(Path(result["archive"]), candidate)
            self.assertFalse(any(call[0] == "/usr/bin/ditto" for call in calls),
                             "verified safe candidate should avoid writing another archive")

    def test_archive_reuse_rejects_sidecar_tampering_against_recorded_archive_digest(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Reel.app"
            make_app(app, version="1.5.0", build="172", commit="a" * 40)
            resource = app / "Contents/Resources/payload.bin"
            resource.parent.mkdir(parents=True)
            resource.write_bytes(b"synthetic resource")
            inventory = manage.bundle_inventory(app)
            executable_hash, _ = manage.bundle_executable_identity(app, inventory)
            support = root / "Support"
            backups = support / "Backups"
            backups.mkdir(parents=True, mode=0o700)
            candidate = backups / f"Reel-20261011T000000000000Z-{executable_hash[:12]}.zip"
            write_bundle_archive(app, candidate)
            sidecar = "__MACOSX/Reel.app/Contents/Resources/._payload.bin"
            with zipfile.ZipFile(candidate) as archive:
                self.assertIn(sidecar, archive.namelist())

            record = archive_manifest_record(candidate)
            record["executableSHA256"] = executable_hash
            record["archiveSHA256"] = manage.sha256(candidate)
            manage.append_archive_manifest(support, record)

            tampered = root / "tampered.zip"
            with zipfile.ZipFile(candidate, "r") as original, zipfile.ZipFile(
                    tampered, "w", compression=zipfile.ZIP_DEFLATED) as rewritten:
                for item in original.infolist():
                    contents = original.read(item)
                    if item.filename == sidecar:
                        contents = contents[:-1] + bytes([contents[-1] ^ 1])
                    rewritten.writestr(item, contents)
            tampered.replace(candidate)
            candidate.chmod(0o600)
            calls = []

            def fake_run(*args):
                calls.append(args)
                if args[0] == "/usr/bin/ditto":
                    write_bundle_archive(app, Path(args[-1]))
                return ""

            with mock.patch.object(manage, "run", side_effect=fake_run):
                result = manage.archive(app, support)

            self.assertNotEqual(Path(result["archive"]), candidate)
            self.assertTrue(any(call[0] == "/usr/bin/ditto" for call in calls))

    def test_hidden_stage_identity_is_explicitly_allowed(self):
        with tempfile.TemporaryDirectory() as folder:
            stage = Path(folder) / "Reel.bundle-stage"
            make_app(stage, version="1.5.0-beta2", build="172", commit="a" * 40)
            with self.assertRaisesRegex(RuntimeError, "Not an ordinary Reel app bundle"):
                manage.identity(stage)
            self.assertEqual(manage.identity(stage, allow_stage=True)["CFBundleIdentifier"], manage.IDENTIFIER)

    def test_check_rejects_live_and_dangling_install_symlinks_before_audit(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            real_app = root / "Real Reel.app"
            make_app(real_app, version="1.5.0", build="172", commit="a" * 40)
            installed = root / "Applications/Reel.app"
            installed.parent.mkdir()

            for target in (real_app, root / "missing-target.app"):
                with self.subTest(target=target):
                    if os.path.lexists(installed):
                        installed.unlink()
                    installed.symlink_to(target, target_is_directory=True)
                    with mock.patch.object(manage, "INSTALLED", installed), \
                            mock.patch.object(sys, "argv", [str(SCRIPT), "check"]), \
                            mock.patch.object(manage, "audit", side_effect=AssertionError("audit must not run")):
                        with self.assertRaisesRegex(RuntimeError, "Not an ordinary Reel app bundle"):
                            manage.main()

    def test_initial_install_rejects_live_and_dangling_install_symlinks(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            configured = manage.configured_build_metadata()
            source = root / "Build/Products/Reel.app"
            make_app(source, version=configured["MARKETING_VERSION"],
                     build=configured["CURRENT_PROJECT_VERSION"], commit="a" * 40)
            real_app = root / "Real Reel.app"
            make_app(real_app, version="1.5.0", build="172", commit="b" * 40)
            installed = root / "Applications/Reel.app"
            installed.parent.mkdir()

            for target in (real_app, root / "missing-target.app"):
                with self.subTest(target=target):
                    if os.path.lexists(installed):
                        installed.unlink()
                    installed.symlink_to(target, target_is_directory=True)
                    with mock.patch.object(manage, "INSTALLED", installed), \
                            mock.patch.object(manage, "ensure_clean_checkout"), \
                            mock.patch.object(manage, "audit", side_effect=AssertionError("audit must not run")):
                        with self.assertRaisesRegex(RuntimeError, "Not an ordinary Reel app bundle"):
                            manage.install(source, root / "Support")
                    self.assertTrue(installed.is_symlink())

    def test_candidate_must_match_checkout_config_and_not_downgrade(self):
        configured = manage.configured_build_metadata()
        commit = manage.current_checkout_commit()
        candidate = {
            "CFBundleShortVersionString": configured["MARKETING_VERSION"],
            "CFBundleVersion": configured["CURRENT_PROJECT_VERSION"],
            manage.BUILD_COMMIT_KEY: commit,
            manage.BUILD_CONFIGURATION_KEY: "Release",
        }
        installed = dict(candidate)
        installed["CFBundleShortVersionString"] = "99.0"
        with self.assertRaisesRegex(RuntimeError, "Refusing a downgrade"):
            manage.validate_candidate(candidate, installed, checkout_commit=commit)

        newer_marketing = dict(candidate)
        newer_marketing["CFBundleShortVersionString"] = "1.6.0"
        newer_marketing["CFBundleVersion"] = "173"
        older_build_installed = dict(installed)
        older_build_installed["CFBundleShortVersionString"] = "1.5.0"
        older_build_installed["CFBundleVersion"] = "500"
        with mock.patch.object(manage, "configured_build_metadata",
                               return_value={"MARKETING_VERSION": "1.6.0", "CURRENT_PROJECT_VERSION": "173"}):
            with self.assertRaisesRegex(RuntimeError, "non-monotonic build"):
                manage.validate_candidate(newer_marketing, older_build_installed,
                                          checkout_commit=commit)

        same_build_new_commit = dict(newer_marketing)
        same_build_installed = {
            "CFBundleShortVersionString": "1.5.0",
            "CFBundleVersion": "173",
            manage.BUILD_COMMIT_KEY: "c" * 40,
        }
        with mock.patch.object(manage, "configured_build_metadata",
                               return_value={"MARKETING_VERSION": "1.6.0", "CURRENT_PROJECT_VERSION": "173"}):
            with self.assertRaisesRegex(RuntimeError, "must increase CURRENT_PROJECT_VERSION"):
                manage.validate_candidate(same_build_new_commit, same_build_installed,
                                          checkout_commit=commit)

        stale = dict(candidate)
        stale[manage.BUILD_COMMIT_KEY] = "b" * 40
        with self.assertRaisesRegex(RuntimeError, "Build product is stale"):
            manage.validate_candidate(stale, checkout_commit=commit)

        debug_build = dict(candidate)
        debug_build[manage.BUILD_CONFIGURATION_KEY] = "Debug"
        with self.assertRaisesRegex(RuntimeError, "not a Release configuration"):
            manage.validate_candidate(debug_build, checkout_commit=commit)

    def test_candidate_commit_must_follow_installed_commit(self):
        configured = manage.configured_build_metadata()
        commit = manage.current_checkout_commit()
        candidate = {
            "CFBundleShortVersionString": configured["MARKETING_VERSION"],
            "CFBundleVersion": configured["CURRENT_PROJECT_VERSION"],
            manage.BUILD_COMMIT_KEY: commit,
            manage.BUILD_CONFIGURATION_KEY: "Release",
        }
        installed = {
            "CFBundleShortVersionString": "1.4.0",
            "CFBundleVersion": "100",
            manage.BUILD_COMMIT_KEY: "c" * 40,
        }
        with self.assertRaisesRegex(RuntimeError, "not an ancestor"):
            manage.validate_candidate(candidate, installed, checkout_commit=commit, ancestor_check=lambda *_: False)

    def test_repair_only_prunes_missing_registrations_and_preserves_live_copies(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            installed = root / "Applications/Reel.app"
            extra = root / "Other/Reel.app"
            missing_app = root / "Deleted/Reel.app"
            missing_plugin = root / "Deleted/OpenInReel.appex"
            live_plugin = extra / "Contents/PlugIns/OpenInReel.appex"
            make_app(installed, version="1.5.0-beta2", build="172", commit="a" * 40)
            make_app(extra, version="1.4.0", build="100", commit="c" * 40)
            installed_plugin = make_open_in_extension(installed)
            live_plugin.mkdir(parents=True)

            calls = []

            def fake_run(*args):
                calls.append(args)
                return ""

            before = {"running": [], "copies": [str(installed), str(extra)], "preferred": str(installed)}
            after = dict(before)
            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "run", side_effect=fake_run), \
                    mock.patch.object(manage, "audit", side_effect=[before, after]), \
                    mock.patch.object(manage, "registrations", side_effect=[
                        {installed, missing_app}, {installed, extra}, {installed, extra},
                    ]), \
                    mock.patch.object(manage, "registered_plugins", side_effect=[
                        {missing_plugin, live_plugin}, {live_plugin, installed_plugin},
                    ]), \
                    mock.patch.object(manage, "discoverable_copies", side_effect=[
                        [installed, extra], [installed, extra], [installed, extra],
                    ]):
                result = manage.repair(root / "Support")

            self.assertTrue(extra.exists())
            self.assertTrue(live_plugin.exists())
            self.assertEqual(result["preservedLiveCopies"], [str(extra)])
            self.assertFalse(result["onlyInstalledCopy"])
            self.assertTrue(result["canonicalSelectionReady"])
            self.assertTrue(result["registrationClean"])
            self.assertFalse(result["destructiveChanges"])
            self.assertIn(("/usr/bin/pluginkit", "-r", str(missing_plugin)), calls)
            self.assertIn(("/usr/bin/pluginkit", "-a", str(installed_plugin)), calls)
            self.assertIn((manage.LSREGISTER, "-u", str(missing_app)), calls)
            self.assertNotIn(("/usr/bin/pluginkit", "-r", str(live_plugin)), calls)
            self.assertNotIn((manage.LSREGISTER, "-u", str(extra)), calls)

    def test_canonical_selection_allows_dormant_duplicates_but_rejects_conflicting_running_copy(self):
        installed = Path("/Applications/Reel.app")
        other = Path("/Users/test/DerivedData/Reel.app")
        base = {
            "preferred": str(installed),
            "copies": [str(other), str(installed)],
            "registered": [str(installed), str(other)],
            "running": [],
        }
        self.assertTrue(manage.canonical_selection_ready(base, installed))

        base["running"] = [str(other)]
        self.assertFalse(manage.canonical_selection_ready(base, installed))

        base["running"] = ["NONE"]
        self.assertFalse(manage.canonical_selection_ready(base, installed))

    def _install_fixture(self, temp_root):
        configured = manage.configured_build_metadata()
        commit = manage.current_checkout_commit()
        installed = temp_root / "Applications/Reel.app"
        source = temp_root / "Build/Products/Reel.app"
        make_app(installed, version=configured["MARKETING_VERSION"], build=configured["CURRENT_PROJECT_VERSION"], commit=commit)
        make_app(source, version=configured["MARKETING_VERSION"], build=configured["CURRENT_PROJECT_VERSION"], commit=commit)
        return installed, source, commit

    def test_running_process_recheck_keeps_old_bundle_before_swap(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            installed, source, commit = self._install_fixture(root)
            audits = [{"running": []}, {"running": [str(installed)]}]

            def fake_run(*args):
                if args[0] == "/usr/bin/ditto":
                    shutil.copytree(args[1], args[2], symlinks=True)
                return ""

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "current_checkout_commit", return_value=commit), \
                    mock.patch.object(manage, "ensure_clean_checkout"), \
                    mock.patch.object(manage, "is_ancestor", return_value=True), \
                    mock.patch.object(manage, "run", side_effect=fake_run), \
                    mock.patch.object(manage, "audit", side_effect=audits), \
                    mock.patch.object(manage, "archive", return_value={"archive": "fixture.zip"}), \
                    mock.patch.object(manage, "write_evidence"):
                with self.assertRaisesRegex(RuntimeError, "during install preparation"):
                    manage.install(source, root / "Support")

            self.assertEqual(manage.identity(installed)["CFBundleIdentifier"], manage.IDENTIFIER)
            self.assertTrue(source.exists())
            self.assertFalse((installed.parent / "Reel.bundle-stage").exists())

    def test_install_rejects_non_executable_resource_mutation_before_signing(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            installed, source, commit = self._install_fixture(root)
            resource = source / "Contents/Resources/Player.strings"
            resource.parent.mkdir(parents=True)
            resource.write_bytes(b"source resource")
            calls = []

            def fake_run(*args):
                calls.append(args)
                if args[0] == "/usr/bin/ditto":
                    shutil.copytree(args[1], args[2], symlinks=True)
                    (Path(args[2]) / "Contents/Resources/Player.strings").write_bytes(b"altered resource")
                return ""

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "current_checkout_commit", return_value=commit), \
                    mock.patch.object(manage, "ensure_clean_checkout"), \
                    mock.patch.object(manage, "is_ancestor", return_value=True), \
                    mock.patch.object(manage, "run", side_effect=fake_run), \
                    mock.patch.object(manage, "audit", return_value={"running": []}):
                with self.assertRaisesRegex(RuntimeError, "inventory differs"):
                    manage._install_locked(source, root / "Support")

            self.assertTrue(source.exists())
            self.assertFalse(any(call[0] == "/usr/bin/codesign" and "--force" in call
                                 for call in calls))
            self.assertEqual(manage.identity(installed)["CFBundleVersion"],
                             manage.configured_build_metadata()["CURRENT_PROJECT_VERSION"])

    def test_evidence_failure_rolls_back_new_bundle_and_restores_old_bundle(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            installed, source, commit = self._install_fixture(root)
            audits = [
                {"running": []},
                {"running": []},
                {"running": [], "preferred": str(installed), "copies": [str(installed)]},
            ]

            def fake_run(*args):
                if args[0] == "/usr/bin/ditto":
                    shutil.copytree(args[1], args[2], symlinks=True)
                return ""

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "current_checkout_commit", return_value=commit), \
                    mock.patch.object(manage, "ensure_clean_checkout"), \
                    mock.patch.object(manage, "is_ancestor", return_value=True), \
                    mock.patch.object(manage, "run", side_effect=fake_run), \
                    mock.patch.object(manage, "audit", side_effect=audits), \
                    mock.patch.object(manage, "registrations", return_value=[installed]), \
                    mock.patch.object(manage, "registered_plugins", return_value=[]), \
                    mock.patch.object(manage, "discoverable_copies", return_value=[installed]), \
                    mock.patch.object(manage, "archive", return_value={"archive": "fixture.zip"}), \
                    mock.patch.object(manage, "write_evidence", side_effect=OSError("fixture evidence failure")):
                with self.assertRaisesRegex(OSError, "fixture evidence failure"):
                    manage.install(source, root / "Support")

            self.assertEqual(manage.identity(installed)["CFBundleVersion"], manage.configured_build_metadata()["CURRENT_PROJECT_VERSION"])
            self.assertTrue(source.exists())

    def test_bad_launch_services_postcondition_restores_previous_bundle(self):
        with tempfile.TemporaryDirectory(dir=Path.home()) as folder:
            root = Path(folder)
            installed, source, commit = self._install_fixture(root)
            (installed / "previous-build-marker").write_text("old")
            (source / "previous-build-marker").write_text("candidate")
            restored_plugin = make_open_in_extension(installed)
            make_open_in_extension(source)
            audits = [
                {"running": []},
                {"running": []},
                {"running": [], "preferred": str(source), "copies": [str(source)]},
            ]

            calls = []

            def fake_run(*args):
                calls.append(args)
                if args[0] == "/usr/bin/ditto":
                    shutil.copytree(args[1], args[2], symlinks=True)
                return ""

            def fake_swap(first, second):
                temporary = second.parent / ".fixture-swap"
                first.rename(temporary)
                second.rename(first)
                temporary.rename(second)

            with mock.patch.object(manage, "INSTALLED", installed), \
                    mock.patch.object(manage, "current_checkout_commit", return_value=commit), \
                    mock.patch.object(manage, "ensure_clean_checkout"), \
                    mock.patch.object(manage, "atomic_swap_paths", side_effect=fake_swap), \
                    mock.patch.object(manage, "run", side_effect=fake_run), \
                    mock.patch.object(manage, "audit", side_effect=audits), \
                    mock.patch.object(manage, "registrations", return_value=[source]), \
                    mock.patch.object(manage, "registered_plugins", return_value=[]), \
                    mock.patch.object(manage, "discoverable_copies", return_value=[source]), \
                    mock.patch.object(manage, "archive", return_value={"archive": "fixture.zip"}):
                with self.assertRaisesRegex(RuntimeError, "restoring the previous bundle"):
                    manage.install(source, root / "Support")

            self.assertEqual((installed / "previous-build-marker").read_text(), "old")
            self.assertTrue(source.exists())
            extension_path = str(installed / "Contents/PlugIns/OpenInIINA.appex")
            self.assertEqual(calls.count(("/usr/bin/pluginkit", "-a", extension_path)), 2)
            self.assertIn(("/usr/bin/pluginkit", "-r", extension_path), calls)
            self.assertIn((manage.LSREGISTER, "-f", str(installed)), calls)
            self.assertTrue(restored_plugin.is_dir())


if __name__ == "__main__":
    unittest.main()
