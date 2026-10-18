#!/usr/bin/env python3
"""Manage /Applications/Reel.app and its Launch Services registrations."""

import argparse
import ctypes
from contextlib import contextmanager
import fcntl
import hashlib
import json
import locale
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone
import zipfile
import uuid
import zlib


IDENTIFIER = "io.github.tverma101.reel"
BUILD_COMMIT_KEY = "com.colliderli.iina.build.commit"
BUILD_CONFIGURATION_KEY = "com.colliderli.iina.build.configuration"
INSTALLED = Path("/Applications/Reel.app")
REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
APP_ENTITLEMENTS = REPOSITORY_ROOT / "iina/IINA.entitlements"
OPEN_IN_EXTENSION_ENTITLEMENTS = REPOSITORY_ROOT / "OpenInIINA/OpenInIINA.entitlements"
REEL_LAUNCH_LOCK = Path.home() / "Library/Caches/.reel-install-transition.lock"
REEL_LAUNCH_HANDOFF = REEL_LAUNCH_LOCK.with_name(".reel-launch-handoff.json")
MAX_LAUNCH_HANDOFF_BYTES = 1024
MAX_PROCESS_OUTPUT_BYTES = 8 * 1024 * 1024
MAX_LSREGISTER_DUMP_BYTES = 64 * 1024 * 1024
MAX_LSREGISTER_DUMP_LINE_BYTES = 64 * 1024
MAX_REGISTERED_APP_PATHS = 4096
RENAME_SWAP = 0x00000002
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
AUDIT_SWIFT = '''import AppKit
let workspace = NSWorkspace.shared
let result: [String: Any] = [
  "preferred": workspace.urlForApplication(withBundleIdentifier: "io.github.tverma101.reel")?.path ?? "NONE",
  "copies": workspace.urlsForApplications(withBundleIdentifier: "io.github.tverma101.reel").map(\\.path),
  "running": workspace.runningApplications.filter { $0.bundleIdentifier == "io.github.tverma101.reel" }.map { $0.bundleURL?.path ?? "NONE" }
]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
'''


def run(*args):
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    captures = {"stdout": bytearray(), "stderr": bytearray()}
    captured_bytes = 0
    output_exceeded = threading.Event()
    capture_lock = threading.Lock()

    def drain(name, stream):
        nonlocal captured_bytes
        while True:
            try:
                chunk = stream.read(64 * 1024)
            except (OSError, ValueError):
                return
            if not chunk:
                return
            with capture_lock:
                remaining = MAX_PROCESS_OUTPUT_BYTES - captured_bytes
                if remaining > 0:
                    accepted = chunk[:remaining]
                    captures[name].extend(accepted)
                    captured_bytes += len(accepted)
                if len(chunk) > max(remaining, 0):
                    output_exceeded.set()

    readers = [
        threading.Thread(target=drain, args=(name, stream), daemon=True)
        for name, stream in (("stdout", process.stdout), ("stderr", process.stderr))
    ]
    for reader in readers:
        reader.start()
    try:
        returncode = process.wait(timeout=120)
    except subprocess.TimeoutExpired as error:
        process.kill()
        process.wait()
        for reader in readers:
            reader.join(timeout=1)
        process.stdout.close()
        process.stderr.close()
        raise RuntimeError(f"{args[0]} timed out after 120 seconds.") from error
    for reader in readers:
        reader.join(timeout=5)
    process.stdout.close()
    process.stderr.close()
    if any(reader.is_alive() for reader in readers):
        raise RuntimeError(f"{args[0]} did not close its output streams after exiting.")

    encoding = locale.getpreferredencoding(False) or "utf-8"
    stdout = captures["stdout"].decode(encoding, errors="replace")
    stderr = captures["stderr"].decode(encoding, errors="replace")
    if output_exceeded.is_set():
        raise RuntimeError(f"{args[0]} exceeded the {MAX_PROCESS_OUTPUT_BYTES}-byte output limit.")
    if returncode:
        raise RuntimeError(f"{args[0]} failed ({returncode}): {stderr.strip() or stdout.strip()}")
    return stdout


@contextmanager
def installation_lock(installed=INSTALLED):
    """Serialize install/repair transactions for one target bundle."""
    installed = Path(installed)
    lock_path = installed.parent / f".{installed.name}.install.lock"
    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise RuntimeError(f"Could not open the Reel installation lock at {lock_path}: {error}") from error

    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077):
            raise RuntimeError(f"The Reel installation lock is not a private, owner-owned regular file: {lock_path}")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        locked_info = os.fstat(descriptor)
        try:
            path_info = os.stat(lock_path, follow_symlinks=False)
        except OSError as error:
            raise RuntimeError(f"The Reel installation lock path changed while waiting: {lock_path}") from error
        if (not stat.S_ISREG(locked_info.st_mode) or locked_info.st_nlink != 1
                or locked_info.st_uid != os.geteuid() or stat.S_IMODE(locked_info.st_mode) & 0o077
                or stat.S_ISLNK(path_info.st_mode) or path_info.st_dev != locked_info.st_dev
                or path_info.st_ino != locked_info.st_ino):
            raise RuntimeError(f"The Reel installation lock path changed while waiting: {lock_path}")
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


@contextmanager
def launcher_transition_lock():
    """Serialize app replacement with the Desktop launcher handoff lock."""
    lock_path = REEL_LAUNCH_LOCK
    home = Path.home()
    cache_directory = home / "Library/Caches"
    for directory in (home, home / "Library", cache_directory):
        try:
            info = directory.lstat()
        except OSError as error:
            raise RuntimeError(f"Cannot validate Reel launch-lock directory {directory}: {error}") from error
        if (stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode)
                or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o022):
            raise RuntimeError(f"Reel launch-lock ancestor is not a safe user-owned directory: {directory}")

    try:
        cache_info = cache_directory.lstat()
    except OSError as error:
        raise RuntimeError(f"Cannot validate Reel launch-lock directory {cache_directory}: {error}") from error
    if (stat.S_ISLNK(cache_info.st_mode) or not stat.S_ISDIR(cache_info.st_mode)
            or cache_info.st_uid != os.geteuid() or stat.S_IMODE(cache_info.st_mode) & 0o077):
        raise RuntimeError(f"Reel launch-lock directory must be a private user-owned directory: {cache_directory}")

    flags = os.O_CREAT | os.O_RDWR
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError as error:
        raise RuntimeError(f"Could not open the shared Reel launcher lock at {lock_path}: {error}") from error
    try:
        opened = os.fstat(descriptor)
        current = lock_path.lstat()
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) & 0o077
                or stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode)
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
            raise RuntimeError(f"Shared Reel launcher lock is not a private owner-owned regular file: {lock_path}")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        opened = os.fstat(descriptor)
        current = lock_path.lstat()
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) & 0o077
                or stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode)
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
            raise RuntimeError(f"Shared Reel launcher lock path changed while waiting: {lock_path}")
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def check_launcher_handoff():
    """Fail closed on an unresolved Desktop open; clear only confirmed records.

    Call this only while holding launcher_transition_lock(). The Desktop
    command publishes a complete, owner-only record before invoking open and
    changes it to confirmed only after the canonical Reel process is observed.
    """
    path = REEL_LAUNCH_HANDOFF
    try:
        before = path.lstat()
    except FileNotFoundError:
        return
    if (stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid() or before.st_nlink != 1
            or stat.S_IMODE(before.st_mode) & 0o077
            or stat.S_IMODE(before.st_mode) & 0o600 != 0o600
            or before.st_size <= 0 or before.st_size > MAX_LAUNCH_HANDOFF_BYTES):
        raise RuntimeError("The Desktop Reel launch handoff record is unsafe; install/repair is blocked.")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise RuntimeError(f"Could not safely read the Desktop Reel launch handoff record: {error}") from error
    try:
        opened = os.fstat(descriptor)
        if ((opened.st_dev, opened.st_ino, opened.st_size) !=
                (before.st_dev, before.st_ino, before.st_size)
                or not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or opened.st_nlink != 1):
            raise RuntimeError("The Desktop Reel launch handoff record changed while opening; install/repair is blocked.")
        raw = os.read(descriptor, MAX_LAUNCH_HANDOFF_BYTES + 1)
        after = os.fstat(descriptor)
        path_after = path.lstat()
        if (len(raw) > MAX_LAUNCH_HANDOFF_BYTES or len(raw) != opened.st_size
                or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
                != (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
                or (path_after.st_dev, path_after.st_ino) != (opened.st_dev, opened.st_ino)):
            raise RuntimeError("The Desktop Reel launch handoff record changed or exceeded its limit; install/repair is blocked.")
    finally:
        os.close(descriptor)
    try:
        record = json.loads(raw.decode("utf-8"))
    except (UnicodeError, ValueError) as error:
        raise RuntimeError("The Desktop Reel launch handoff record is corrupt; install/repair is blocked.") from error
    if (not isinstance(record, dict)
            or set(record) != {"version", "state", "pid", "created_ns"}
            or type(record.get("version")) is not int or record["version"] != 1
            or record.get("state") not in ("pending", "confirmed")
            or type(record.get("pid")) is not int or record["pid"] <= 0
            or type(record.get("created_ns")) is not int or record["created_ns"] <= 0):
        raise RuntimeError("The Desktop Reel launch handoff record is invalid; install/repair is blocked.")
    if record["state"] == "pending":
        raise RuntimeError(
            "A Desktop Reel launch has not confirmed startup. Install/repair is blocked while a delayed "
            "LaunchServices request may still be using the playlist."
        )

    # A confirmed record can remain if the launcher was interrupted after
    # observing Reel but before removing the marker. Revalidate its pathname
    # before unlinking; pending or corrupt records are never cleared here.
    current = path.lstat()
    if (stat.S_ISLNK(current.st_mode) or not stat.S_ISREG(current.st_mode)
            or (current.st_dev, current.st_ino) != (opened.st_dev, opened.st_ino)):
        raise RuntimeError("The Desktop Reel launch handoff changed before cleanup; install/repair is blocked.")
    os.unlink(path)
    directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                           | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def sha256(path, *, maximum_bytes=None):
    """Hash a stable, no-follow regular file without reading past its cap."""
    if maximum_bytes is None:
        maximum_bytes = MAX_BACKUP_ARCHIVE_BYTES
    path = Path(path)
    try:
        before = path.lstat()
    except OSError as error:
        raise RuntimeError(f"Cannot inspect file before hashing {path}: {error}") from error
    if (stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode)
            or before.st_size < 0 or before.st_size > maximum_bytes):
        raise RuntimeError(f"File to hash is not a bounded regular file: {path}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if stable_file_identity(opened) != stable_file_identity(before):
            raise RuntimeError(f"File changed while opening for hashing: {path}")
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, maximum_bytes - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise RuntimeError(f"File exceeds the {maximum_bytes}-byte hash limit: {path}")
            digest.update(chunk)
        after = os.fstat(descriptor)
        path_after = path.lstat()
        if (total != opened.st_size or stable_file_identity(after) != stable_file_identity(opened)
                or stable_file_identity(path_after) != stable_file_identity(opened)):
            raise RuntimeError(f"File changed or was incomplete while hashing: {path}")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def sha256_open_regular_stream(stream, *, maximum_bytes):
    """Hash the already-open, bounded archive descriptor used for verification."""
    descriptor = stream.fileno()
    before = os.fstat(descriptor)
    if (not stat.S_ISREG(before.st_mode) or before.st_size <= 0
            or before.st_size > maximum_bytes):
        raise RuntimeError("Backup archive is not a bounded regular file.")
    stream.seek(0)
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = stream.read(min(1024 * 1024, maximum_bytes - total + 1))
        if not chunk:
            break
        total += len(chunk)
        if total > maximum_bytes:
            raise RuntimeError("Backup archive exceeds its size limit while hashing.")
        digest.update(chunk)
    after = os.fstat(descriptor)
    if total != before.st_size or stable_file_identity(after) != stable_file_identity(before):
        raise RuntimeError("Backup archive changed or was incomplete while hashing.")
    stream.seek(0)
    return digest.hexdigest()


def consume_archive_stream_budget(budget, amount):
    if budget is None:
        return
    if amount > budget["remaining"]:
        raise RuntimeError("Backup exceeds the aggregate limit while streaming actual uncompressed bytes.")
    budget["remaining"] -= amount


def preflight_zip_central_members(archive_stream, central_offset, central_size, entry_count):
    """Bound decoded names and copied extra fields without materializing entries."""
    central_end = central_offset + central_size
    archive_stream.seek(central_offset)
    name_bytes = 0
    extra_bytes = 0
    for _index in range(entry_count):
        header = archive_stream.read(46)
        if len(header) != 46:
            raise RuntimeError("Backup ZIP central-directory record is truncated.")
        fields = struct.unpack("<IHHHHHHIIIHHHHHII", header)
        if fields[0] != 0x02014B50:
            raise RuntimeError("Backup ZIP central-directory record has an invalid signature.")
        member_name_length, member_extra_length, member_comment_length = fields[10:13]
        next_record = archive_stream.tell() + member_name_length + member_extra_length + member_comment_length
        if next_record > central_end:
            raise RuntimeError("Backup ZIP central-directory record exceeds its declared range.")
        name_bytes += member_name_length
        extra_bytes += member_extra_length + member_comment_length
        if name_bytes > MAX_BACKUP_CENTRAL_NAME_BYTES:
            raise RuntimeError("Backup ZIP member names exceed the 16 MiB metadata limit.")
        if extra_bytes > MAX_BACKUP_CENTRAL_EXTRA_BYTES:
            raise RuntimeError("Backup ZIP extra fields and comments exceed the 8 MiB metadata limit.")
        archive_stream.seek(next_record)
    if archive_stream.tell() != central_end:
        raise RuntimeError("Backup ZIP central-directory size does not match its entry records.")


def preflight_zip_central_directory(archive_stream):
    """Bound ZIP directory metadata before zipfile allocates one object per entry."""
    original_offset = archive_stream.tell()
    try:
        archive_info = os.fstat(archive_stream.fileno())
        if not stat.S_ISREG(archive_info.st_mode) or archive_info.st_size < 22:
            raise RuntimeError("Backup archive is not a regular ZIP file with a complete trailer.")
        file_size = archive_info.st_size
        tail_size = min(file_size, 22 + 65_535)
        archive_stream.seek(file_size - tail_size)
        tail = archive_stream.read(tail_size)
        if len(tail) != tail_size:
            raise RuntimeError("Backup ZIP trailer is truncated.")

        positions = []
        search_end = len(tail)
        while True:
            position = tail.rfind(b"PK\x05\x06", 0, search_end)
            if position < 0:
                break
            search_end = position
            if position + 22 > len(tail):
                continue
            fields = struct.unpack_from("<IHHHHIIH", tail, position)
            if position + 22 + fields[7] == len(tail):
                positions.append((position, fields))
        if len(positions) != 1:
            raise RuntimeError("Backup ZIP has a missing or ambiguous end-of-directory record.")

        eocd_position, eocd = positions[0]
        eocd_offset = file_size - tail_size + eocd_position
        (_signature, disk_number, central_disk, entries_on_disk, entry_count,
         central_size, central_offset, _comment_length) = eocd
        if disk_number != 0 or central_disk != 0:
            raise RuntimeError("Multi-disk backup ZIP archives are unsupported.")

        zip64_start = None
        locator_offset = eocd_offset - 20
        locator = b""
        if locator_offset >= 0:
            archive_stream.seek(locator_offset)
            candidate_locator = archive_stream.read(20)
            if len(candidate_locator) == 20 and candidate_locator[:4] == b"PK\x06\x07":
                locator = candidate_locator
        has_zip64_locator = bool(locator)
        needs_zip64 = (entries_on_disk == 0xFFFF or entry_count == 0xFFFF
                       or central_size == 0xFFFFFFFF or central_offset == 0xFFFFFFFF)
        if needs_zip64 and not has_zip64_locator:
            raise RuntimeError("Backup ZIP is missing its required Zip64 directory records.")

        if has_zip64_locator:
            (_locator_signature, locator_disk, zip64_start, total_disks) = struct.unpack("<IIQI", locator)
            if locator_disk != 0 or total_disks != 1:
                raise RuntimeError("Multi-disk or malformed Zip64 backup archives are unsupported.")
            if zip64_start + 56 > locator_offset:
                raise RuntimeError("Backup ZIP Zip64 end record is out of range.")
            archive_stream.seek(zip64_start)
            zip64_header = archive_stream.read(56)
            if len(zip64_header) != 56:
                raise RuntimeError("Backup ZIP Zip64 end record is truncated.")
            (zip64_signature, zip64_record_size, _made_by, _needed, zip64_disk,
             zip64_central_disk, zip64_entries_on_disk, zip64_entry_count,
             zip64_central_size, zip64_central_offset) = struct.unpack(
                "<IQHHIIQQQQ", zip64_header,
            )
            # The fixed Zip64 record is 56 bytes. Reject optional extensible
            # data records instead of reading or asking zipfile to parse them.
            if (zip64_signature != 0x06064B50 or zip64_record_size != 44
                    or zip64_start + 56 != locator_offset
                    or zip64_disk != 0 or zip64_central_disk != 0
                    or zip64_entries_on_disk != zip64_entry_count):
                raise RuntimeError("Backup ZIP has an unsupported or malformed Zip64 end record.")
            if ((entries_on_disk != 0xFFFF and entries_on_disk != zip64_entries_on_disk)
                    or (entry_count != 0xFFFF and entry_count != zip64_entry_count)
                    or (central_size != 0xFFFFFFFF and central_size != zip64_central_size)
                    or (central_offset != 0xFFFFFFFF and central_offset != zip64_central_offset)):
                raise RuntimeError("Backup ZIP classic and Zip64 directory records disagree.")
            entry_count = zip64_entry_count
            entries_on_disk = zip64_entries_on_disk
            central_size = zip64_central_size
            central_offset = zip64_central_offset
        elif entries_on_disk != entry_count:
            raise RuntimeError("Backup ZIP has inconsistent entry counts.")

        if entry_count > MAX_BACKUP_ENTRIES:
            raise RuntimeError("Backup bundle exceeds the 100,000 ZIP-entry limit.")
        if central_size > MAX_BACKUP_CENTRAL_DIRECTORY_BYTES:
            raise RuntimeError("Backup ZIP central directory exceeds the 128 MiB metadata limit.")
        if entry_count > central_size // 46:
            raise RuntimeError("Backup ZIP entry count cannot fit in its declared central directory.")
        directory_end = central_offset + central_size
        expected_directory_end = zip64_start if has_zip64_locator else eocd_offset
        if (directory_end < central_offset or directory_end != expected_directory_end
                or directory_end > file_size):
            raise RuntimeError("Backup ZIP central directory has an unsupported or malformed range.")
        preflight_zip_central_members(
            archive_stream, central_offset, central_size, entry_count,
        )
    finally:
        archive_stream.seek(original_offset)


def verify_empty_directory_member(bundle, member, aggregate_budget):
    """Consume and validate the actual body of a ZIP directory entry as empty."""
    if member.file_size != 0:
        raise RuntimeError(f"Backup directory entry has an unexpected payload: {member.filename!r}")
    if member.compress_size > MAX_EMPTY_DIRECTORY_COMPRESSED_BYTES:
        raise RuntimeError(f"Backup directory entry has an oversized compressed payload: {member.filename!r}")
    for _chunk in iter_zip_member_uncompressed(
            bundle, member, maximum_bytes=0, aggregate_budget=aggregate_budget):
        pass


def _verify_zip_data_descriptor(archive_stream, member, data_end, central_directory_offset):
    """Match one bounded classic or Zip64 descriptor against central metadata."""
    available = central_directory_offset - data_end
    if available <= 0:
        raise RuntimeError(f"Backup ZIP data descriptor is missing: {member.filename}")
    archive_stream.seek(data_end)
    raw = archive_stream.read(min(24, available))
    matches = []
    for has_signature in (False, True):
        cursor = 0
        if has_signature:
            if raw[:4] != b"PK\x07\x08":
                continue
            cursor = 4
        if len(raw) < cursor + 4:
            continue
        crc = struct.unpack_from("<I", raw, cursor)[0]
        cursor += 4
        for zip64 in (False, True):
            width = 8 if zip64 else 4
            descriptor_size = cursor + width * 2
            if len(raw) < descriptor_size:
                continue
            if zip64:
                compressed_size, uncompressed_size = struct.unpack_from("<QQ", raw, cursor)
            else:
                compressed_size, uncompressed_size = struct.unpack_from("<II", raw, cursor)
            if (crc == member.CRC and compressed_size == member.compress_size
                    and uncompressed_size == member.file_size):
                matches.append((has_signature, zip64))
    if len(matches) != 1:
        raise RuntimeError(f"Backup ZIP data descriptor is malformed or ambiguous: {member.filename}")


def _zip_member_data_offset(bundle, member):
    """Validate a ZIP local header and return the bounded compressed-data offset."""
    archive_stream = bundle.fp
    if archive_stream is None:
        raise RuntimeError("Backup archive is closed while verifying a member.")
    original_offset = archive_stream.tell()
    try:
        archive_stream.seek(member.header_offset)
        header = archive_stream.read(30)
        if len(header) != 30:
            raise RuntimeError(f"Backup ZIP local header is truncated: {member.filename}")
        (signature, _version, flags, method, _mtime, _mdate, local_crc,
         local_compressed, local_uncompressed, name_length, extra_length) = struct.unpack(
            "<IHHHHHIIIHH", header,
        )
        if signature != 0x04034B50 or flags != member.flag_bits or method != member.compress_type:
            raise RuntimeError(f"Backup ZIP local header differs from its directory entry: {member.filename}")
        if flags & 0x0001:
            raise RuntimeError(f"Encrypted backup entries are unsupported: {member.filename}")
        name_bytes = archive_stream.read(name_length)
        extra = archive_stream.read(extra_length)
        if len(name_bytes) != name_length or len(extra) != extra_length:
            raise RuntimeError(f"Backup ZIP local header fields are truncated: {member.filename}")
        try:
            local_name = name_bytes.decode("utf-8" if flags & 0x0800 else "cp437")
        except UnicodeError as error:
            raise RuntimeError(f"Backup ZIP member name is malformed: {member.filename}") from error
        if local_name != member.filename:
            raise RuntimeError(f"Backup ZIP local member name differs: {member.filename}")

        if not flags & 0x0008:  # No trailing data descriptor: local sizes must agree.
            zip64_values = None
            offset = 0
            while offset + 4 <= len(extra):
                tag, length = struct.unpack_from("<HH", extra, offset)
                offset += 4
                if offset + length > len(extra):
                    raise RuntimeError(f"Backup ZIP local extra field is truncated: {member.filename}")
                if tag == 0x0001:
                    if zip64_values is not None:
                        raise RuntimeError(f"Backup ZIP local header has duplicate Zip64 fields: {member.filename}")
                    zip64_values = extra[offset:offset + length]
                offset += length
            if offset != len(extra):
                raise RuntimeError(f"Backup ZIP local extra field is malformed: {member.filename}")
            zip64_offset = 0
            if local_uncompressed == 0xFFFFFFFF or local_compressed == 0xFFFFFFFF:
                if zip64_values is None:
                    raise RuntimeError(f"Backup ZIP local header is missing Zip64 sizes: {member.filename}")
                if local_uncompressed == 0xFFFFFFFF:
                    if zip64_offset + 8 > len(zip64_values):
                        raise RuntimeError(f"Backup ZIP local Zip64 size is truncated: {member.filename}")
                    local_uncompressed = struct.unpack_from("<Q", zip64_values, zip64_offset)[0]
                    zip64_offset += 8
                if local_compressed == 0xFFFFFFFF:
                    if zip64_offset + 8 > len(zip64_values):
                        raise RuntimeError(f"Backup ZIP local Zip64 size is truncated: {member.filename}")
                    local_compressed = struct.unpack_from("<Q", zip64_values, zip64_offset)[0]
            if (local_crc != member.CRC or local_compressed != member.compress_size
                    or local_uncompressed != member.file_size):
                raise RuntimeError(f"Backup ZIP local sizes differ from the directory entry: {member.filename}")
        else:
            # Bit 3 permits placeholders, but any values supplied by the local
            # header must agree with the central record. Validate its extras
            # before relying on the following data descriptor.
            zip64_values = None
            offset = 0
            while offset + 4 <= len(extra):
                tag, length = struct.unpack_from("<HH", extra, offset)
                offset += 4
                if offset + length > len(extra):
                    raise RuntimeError(f"Backup ZIP local extra field is truncated: {member.filename}")
                if tag == 0x0001:
                    if zip64_values is not None:
                        raise RuntimeError(f"Backup ZIP local header has duplicate Zip64 fields: {member.filename}")
                    zip64_values = extra[offset:offset + length]
                offset += length
            if offset != len(extra):
                raise RuntimeError(f"Backup ZIP local extra field is malformed: {member.filename}")
            zip64_offset = 0
            if local_uncompressed == 0xFFFFFFFF:
                if zip64_values is None or zip64_offset + 8 > len(zip64_values):
                    raise RuntimeError(f"Backup ZIP local Zip64 size is truncated: {member.filename}")
                local_uncompressed = struct.unpack_from("<Q", zip64_values, zip64_offset)[0]
                zip64_offset += 8
            if local_compressed == 0xFFFFFFFF:
                if zip64_values is None or zip64_offset + 8 > len(zip64_values):
                    raise RuntimeError(f"Backup ZIP local Zip64 size is truncated: {member.filename}")
                local_compressed = struct.unpack_from("<Q", zip64_values, zip64_offset)[0]
            if (local_crc not in (0, member.CRC)
                    or local_compressed not in (0, member.compress_size)
                    or local_uncompressed not in (0, member.file_size)):
                raise RuntimeError(f"Backup ZIP local sizes differ from the directory entry: {member.filename}")

        data_offset = archive_stream.tell()
        archive_info = os.fstat(archive_stream.fileno())
        data_end = data_offset + member.compress_size
        if (member.compress_size < 0 or member.compress_size > MAX_BACKUP_ARCHIVE_BYTES
                or data_end < data_offset or data_end > archive_info.st_size
                or data_end > bundle.start_dir):
            raise RuntimeError(f"Backup ZIP compressed data range is unsafe: {member.filename}")
        if flags & 0x0008:
            _verify_zip_data_descriptor(
                archive_stream, member, data_end, bundle.start_dir,
            )
        return data_offset
    finally:
        archive_stream.seek(original_offset)


def iter_zip_member_uncompressed(bundle, member, *, maximum_bytes, aggregate_budget=None):
    """Yield actual decompressed bytes without using central-directory file_size as a read cap."""
    data_offset = _zip_member_data_offset(bundle, member)
    archive_stream = bundle.fp
    original_offset = archive_stream.tell()
    digest_crc = 0
    total = 0

    def account(data):
        nonlocal digest_crc, total
        total += len(data)
        if total > maximum_bytes:
            raise RuntimeError(f"Backup entry exceeds the uncompressed read limit: {member.filename}")
        consume_archive_stream_budget(aggregate_budget, len(data))
        digest_crc = zlib.crc32(data, digest_crc)
        return data

    try:
        archive_stream.seek(data_offset)
        compressed_remaining = member.compress_size
        if member.compress_type == zipfile.ZIP_STORED:
            while compressed_remaining:
                amount = min(1024 * 1024, compressed_remaining)
                chunk = archive_stream.read(amount)
                if len(chunk) != amount:
                    raise RuntimeError(f"Backup ZIP member data is truncated: {member.filename}")
                compressed_remaining -= len(chunk)
                yield account(chunk)
        elif member.compress_type == zipfile.ZIP_DEFLATED:
            decoder = zlib.decompressobj(-zlib.MAX_WBITS)
            while compressed_remaining:
                amount = min(1024 * 1024, compressed_remaining)
                compressed = archive_stream.read(amount)
                if len(compressed) != amount:
                    raise RuntimeError(f"Backup ZIP member data is truncated: {member.filename}")
                compressed_remaining -= len(compressed)
                pending = compressed
                while pending:
                    output_limit = min(1024 * 1024, maximum_bytes - total + 1)
                    if aggregate_budget is not None:
                        output_limit = min(output_limit, aggregate_budget["remaining"] + 1)
                    before_pending = len(pending)
                    try:
                        output = decoder.decompress(pending, output_limit)
                    except zlib.error as error:
                        raise RuntimeError(f"Backup ZIP deflate stream is malformed: {member.filename}") from error
                    if decoder.unused_data:
                        raise RuntimeError(f"Backup ZIP member has trailing compressed data: {member.filename}")
                    pending = decoder.unconsumed_tail
                    if output:
                        yield account(output)
                    if pending and len(pending) == before_pending and not output:
                        raise RuntimeError(f"Backup ZIP decompressor made no progress: {member.filename}")
                    if decoder.eof and (pending or compressed_remaining):
                        raise RuntimeError(f"Backup ZIP member has trailing compressed data: {member.filename}")
            if not decoder.eof:
                raise RuntimeError(f"Backup ZIP deflate stream is incomplete: {member.filename}")
        else:
            raise RuntimeError(f"Unsupported backup ZIP compression method: {member.filename}")

        if total != member.file_size or digest_crc & 0xFFFFFFFF != member.CRC:
            raise RuntimeError(f"Backup ZIP actual size or CRC differs from its directory entry: {member.filename}")
    finally:
        archive_stream.seek(original_offset)


def archive_member_sha256(archive, member, *, maximum_bytes=16 * 1024 * 1024 * 1024,
                          aggregate_budget=None):
    if isinstance(member, str):
        member = archive.getinfo(member)
    digest = hashlib.sha256()
    for chunk in iter_zip_member_uncompressed(
            archive, member, maximum_bytes=maximum_bytes, aggregate_budget=aggregate_budget):
        digest.update(chunk)
    return digest.hexdigest()


def scan_backup_reuse_candidates(directory_fd, prefix, suffix):
    """Return a bounded list of safe archive snapshots matching prefix and suffix."""
    candidates = []
    scanned = 0
    with os.scandir(directory_fd) as entries:
        for entry in entries:
            scanned += 1
            if scanned > MAX_BACKUP_REUSE_SCAN_ENTRIES:
                raise RuntimeError(
                    f"Backup folder exceeds the {MAX_BACKUP_REUSE_SCAN_ENTRIES}-entry reuse-scan limit."
                )
            name = entry.name
            suffix_match = suffix.search(name) is not None if hasattr(suffix, "search") else name.endswith(suffix)
            if not (name.startswith(prefix) and suffix_match):
                continue
            info = entry.stat(follow_symlinks=False)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) & 0o077
                    or info.st_size <= 0 or info.st_size > MAX_BACKUP_ARCHIVE_BYTES):
                raise RuntimeError(f"Matching backup candidate is not a safe bounded archive: {name}")
            candidates.append((name, stable_file_identity(info)))
            if len(candidates) > MAX_BACKUP_REUSE_CANDIDATES:
                raise RuntimeError(
                    f"Backup folder has more than {MAX_BACKUP_REUSE_CANDIDATES} matching reuse candidates."
                )
    return candidates


def open_backup_reuse_candidate(directory_fd, name, expected_identity):
    """Open an archive by name relative to a pinned Backups fd, never following links."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        path_before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as error:
        raise RuntimeError(f"Backup candidate changed before open: {name}") from error
    if stable_file_identity(path_before) != expected_identity:
        raise RuntimeError(f"Backup candidate changed during the bounded directory scan: {name}")
    try:
        descriptor = os.open(name, flags, dir_fd=directory_fd)
    except OSError as error:
        raise RuntimeError(f"Cannot safely open backup candidate {name}: {error}") from error
    try:
        opened = os.fstat(descriptor)
        path_after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) & 0o077
                or opened.st_size <= 0 or opened.st_size > MAX_BACKUP_ARCHIVE_BYTES
                or stable_file_identity(opened) != expected_identity
                or stable_file_identity(path_after) != expected_identity):
            raise RuntimeError(f"Backup candidate changed or is unsafe: {name}")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def verify_backup_reuse_candidate_unchanged(directory_fd, descriptor, name, expected_identity):
    opened = os.fstat(descriptor)
    path_after = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    if (stable_file_identity(opened) != expected_identity
            or stable_file_identity(path_after) != expected_identity):
        raise RuntimeError(f"Backup candidate changed while verifying: {name}")


MAX_APPLEDOUBLE_MEMBER_SIZE = 128 * 1024 * 1024
MAX_APPLEDOUBLE_TOTAL_SIZE = 512 * 1024 * 1024
# Probe xattrs with Darwin's size-query APIs before allocating their values.
# The smaller payload cap leaves room for AppleDouble headers and names under
# MAX_APPLEDOUBLE_TOTAL_SIZE.
MAX_XATTR_VALUE_SIZE = MAX_APPLEDOUBLE_MEMBER_SIZE
MAX_XATTR_TOTAL_VALUE_BYTES = 480 * 1024 * 1024
MAX_XATTR_LIST_BYTES = 64 * 1024
MAX_XATTR_NAME_BYTES = 127
MAX_XATTRS_PER_ENTRY = 256
MAX_XATTR_TOTAL_COUNT = 65_536
MAX_XATTR_TOTAL_NAME_BYTES = 16 * 1024 * 1024
MAX_INFO_PLIST_BYTES = 1024 * 1024
MAX_BUNDLE_ENTRIES = 100_000
MAX_BUNDLE_TOTAL_BYTES = 16 * 1024 * 1024 * 1024
MAX_BACKUP_ENTRIES = MAX_BUNDLE_ENTRIES
MAX_BACKUP_UNCOMPRESSED_BYTES = MAX_BUNDLE_TOTAL_BYTES + MAX_APPLEDOUBLE_TOTAL_SIZE
# The ZIP central directory and local headers add bounded overhead beyond
# uncompressed bytes. Refuse backups larger than 17 GiB on disk.
MAX_BACKUP_ARCHIVE_BYTES = 17 * 1024 * 1024 * 1024
# zipfile materializes every central-directory record as a ZipInfo object.
# Bound that metadata before opening an archive, independently of its bodies.
MAX_BACKUP_CENTRAL_DIRECTORY_BYTES = 128 * 1024 * 1024
MAX_BACKUP_CENTRAL_NAME_BYTES = 16 * 1024 * 1024
MAX_BACKUP_CENTRAL_EXTRA_BYTES = 8 * 1024 * 1024
# These aggregates assume installer-produced names come from the actual Reel
# filesystem tree and ZIP extras stay small. Path-heavy or metadata-heavy
# bundles near the broad source-byte limits may now be rejected to bound
# ZipInfo allocations.
# An empty directory may use a tiny DEFLATE stream, but never needs a large
# compressed body. This keeps malformed empty streams cheap to validate.
MAX_EMPTY_DIRECTORY_COMPRESSED_BYTES = 1024
# Backups are retained indefinitely. Scan at most 4096 directory entries and
# retain at most 64 matching names; verify only the newest candidate, capped
# by MAX_BACKUP_UNCOMPRESSED_BYTES, before creating a fresh archive.
MAX_BACKUP_REUSE_SCAN_ENTRIES = 4096
MAX_BACKUP_REUSE_CANDIDATES = 64
MAX_ARCHIVE_TEMP_SCAN_ENTRIES = MAX_BACKUP_REUSE_SCAN_ENTRIES
MAX_ARCHIVE_TEMP_CANDIDATES = MAX_BACKUP_REUSE_CANDIDATES
MAX_ARCHIVE_TEMP_MARKER_BYTES = 4096
ARCHIVE_TEMP_MARKER = ".reel-archive-owner.json"
MAX_ARCHIVE_MANIFEST_BYTES = 4 * 1024 * 1024
MAX_ARCHIVE_MANIFEST_RECORDS = 4096
MAX_ARCHIVE_MANIFEST_RECORD_BYTES = 4096


def bounded_xattr_inventory(path, budget, expected_info=None):
    """Hash one object's xattrs using bounded Darwin size-probe/read calls."""
    if sys.platform != "darwin":
        raise RuntimeError("Extended-attribute verification requires Darwin's bounded xattr APIs.")
    path = Path(path)
    try:
        before = path.lstat() if expected_info is None else expected_info
        path_before = path.lstat()
    except OSError as error:
        raise RuntimeError(f"Cannot safely inspect extended attributes for {path}: {error}") from error
    if (not stat.S_ISLNK(path_before.st_mode) and not stat.S_ISREG(path_before.st_mode)
            and not stat.S_ISDIR(path_before.st_mode)):
        raise RuntimeError(f"Cannot inspect extended attributes on a special bundle entry: {path}")
    if stable_file_identity(path_before) != stable_file_identity(before):
        raise RuntimeError(f"Bundle entry changed before extended-attribute inspection: {path}")

    try:
        libc = ctypes.CDLL(None, use_errno=True)
        listxattr = libc.listxattr
        getxattr = libc.getxattr
    except (AttributeError, OSError) as error:
        raise RuntimeError("Darwin's extended-attribute size-query APIs are unavailable.") from error
    listxattr.argtypes = (ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int)
    listxattr.restype = ctypes.c_ssize_t
    getxattr.argtypes = (
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
        ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int,
    )
    getxattr.restype = ctypes.c_ssize_t
    encoded_path = os.fsencode(path)
    nofollow = 0x0001  # XATTR_NOFOLLOW from <sys/xattr.h>.

    ctypes.set_errno(0)
    names_size = listxattr(encoded_path, None, 0, nofollow)
    if names_size < 0:
        error_number = ctypes.get_errno()
        raise RuntimeError(
            f"Cannot size-probe extended attributes for {path}: "
            f"{os.strerror(error_number) if error_number else 'unknown Darwin error'}"
        )
    if names_size > MAX_XATTR_LIST_BYTES:
        raise RuntimeError("Reel app extended-attribute names exceed the bounded size limit.")
    if names_size == 0:
        names = []
    else:
        name_buffer = (ctypes.c_char * names_size)()
        ctypes.set_errno(0)
        actual_size = listxattr(encoded_path, name_buffer, names_size, nofollow)
        if actual_size != names_size:
            raise RuntimeError(f"Extended-attribute list changed while reading: {path}")
        raw_names = bytes(name_buffer[:actual_size])
        if not raw_names.endswith(b"\0"):
            raise RuntimeError(f"Extended-attribute list is malformed: {path}")
        names = raw_names[:-1].split(b"\0")
        if any(not name or len(name) > MAX_XATTR_NAME_BYTES for name in names):
            raise RuntimeError(f"Extended-attribute name is empty or oversized: {path}")
        if len(names) > MAX_XATTRS_PER_ENTRY:
            raise RuntimeError(f"Bundle entry has too many extended attributes: {path}")
        if len(names) != len(set(names)):
            raise RuntimeError(f"Extended-attribute list contains duplicate names: {path}")
        if names_size > MAX_XATTR_TOTAL_NAME_BYTES - budget["name_bytes"]:
            raise RuntimeError("Reel app extended-attribute names exceed the aggregate size limit.")
        budget["name_bytes"] += names_size

    if len(names) > MAX_XATTR_TOTAL_COUNT - budget["count"]:
        raise RuntimeError("Reel app has too many extended attributes.")
    attributes = []
    for name in sorted(names):
        ctypes.set_errno(0)
        value_size = getxattr(encoded_path, name, None, 0, 0, nofollow)
        if value_size < 0:
            error_number = ctypes.get_errno()
            raise RuntimeError(
                f"Cannot size-probe extended attribute {name!r} on {path}: "
                f"{os.strerror(error_number) if error_number else 'unknown Darwin error'}"
            )
        if (value_size > MAX_XATTR_VALUE_SIZE
                or value_size > MAX_XATTR_TOTAL_VALUE_BYTES - budget["value_bytes"]):
            raise RuntimeError("Reel app extended-attribute values exceed the bounded size limit.")
        value_buffer = (ctypes.c_char * max(1, value_size))()
        ctypes.set_errno(0)
        actual_size = getxattr(
            encoded_path, name, value_buffer, value_size, 0, nofollow,
        )
        if actual_size != value_size:
            raise RuntimeError(f"Extended attribute changed while reading: {name!r} on {path}")
        digest = hashlib.sha256(memoryview(value_buffer)[:value_size]).hexdigest()
        attributes.append((name, value_size, digest))
        budget["count"] += 1
        budget["value_bytes"] += value_size

    try:
        path_after = path.lstat()
    except OSError as error:
        raise RuntimeError(f"Bundle entry changed during extended-attribute inspection: {path}") from error
    if stable_file_identity(path_after) != stable_file_identity(path_before):
        raise RuntimeError(f"Bundle entry changed during extended-attribute inspection: {path}")
    return tuple(attributes)


def appledouble_inventory(expected):
    """Return sidecars only for entries whose bounded xattr inventory is nonempty."""
    sidecars = set()
    for name, item in expected.items():
        if len(item) < 4 or not item[3]:
            continue
        sidecars.add(appledouble_sidecar_name(name))
    directories = {"__MACOSX/"}
    for sidecar in sidecars:
        components = sidecar.split("/")[:-1]
        for index in range(1, len(components) + 1):
            directories.add("/".join(components[:index]) + "/")
    return sidecars, directories


def appledouble_sidecar_name(name):
    relative = name.rstrip("/")
    parent, _, basename = relative.rpartition("/")
    return "/".join(part for part in ("__MACOSX", parent, f"._{basename}") if part)


def verify_appledouble_member(bundle, entry, *, aggregate_budget=None):
    """Validate a bounded AppleDouble v1/v2 file without extracting it."""
    if entry.file_size < 26 or entry.file_size > MAX_APPLEDOUBLE_MEMBER_SIZE:
        raise RuntimeError(f"Backup AppleDouble metadata has an invalid size: {entry.filename}")
    mode = entry.external_attr >> 16
    unsafe_mode = stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX | 0o111 | 0o022
    if stat.S_IFMT(mode) != stat.S_IFREG or stat.S_IMODE(mode) & unsafe_mode:
        raise RuntimeError(f"Backup AppleDouble metadata has unsafe file attributes: {entry.filename}")

    digest = hashlib.sha256()
    with tempfile.TemporaryFile() as payload:
        total = 0
        for chunk in iter_zip_member_uncompressed(
                bundle, entry, maximum_bytes=MAX_APPLEDOUBLE_MEMBER_SIZE,
                aggregate_budget=aggregate_budget):
            total += len(chunk)
            payload.write(chunk)
            digest.update(chunk)
        if total < 26 or total > MAX_APPLEDOUBLE_MEMBER_SIZE:
            raise RuntimeError(f"Backup AppleDouble metadata has an invalid size: {entry.filename}")
        payload.seek(0)
        header = payload.read(26)
        if len(header) != 26:
            raise RuntimeError(f"Backup AppleDouble metadata has a truncated header: {entry.filename}")
        magic = int.from_bytes(header[0:4], "big")
        version = int.from_bytes(header[4:8], "big")
        filler = header[8:24]
        count = int.from_bytes(header[24:26], "big")
        if (magic != 0x00051607 or version not in (0x00010000, 0x00020000)
                or filler not in (bytes(16), b"Mac OS X" + b" " * 8) or count == 0):
            raise RuntimeError(f"Backup AppleDouble metadata has an invalid header: {entry.filename}")
        table_size = 26 + count * 12
        if table_size > total:
            raise RuntimeError(f"Backup AppleDouble metadata has a truncated entry table: {entry.filename}")
        table = payload.read(count * 12)
        if len(table) != count * 12:
            raise RuntimeError(f"Backup AppleDouble metadata has a truncated entry table: {entry.filename}")

        ranges = []
        entry_ids = set()
        for offset in range(0, len(table), 12):
            entry_id = int.from_bytes(table[offset:offset + 4], "big")
            data_offset = int.from_bytes(table[offset + 4:offset + 8], "big")
            data_length = int.from_bytes(table[offset + 8:offset + 12], "big")
            data_end = data_offset + data_length
            if entry_id in entry_ids:
                raise RuntimeError(f"Backup AppleDouble metadata has duplicate entries: {entry.filename}")
            entry_ids.add(entry_id)
            if data_offset < table_size or data_end > total:
                raise RuntimeError(f"Backup AppleDouble metadata has an unsafe entry range: {entry.filename}")
            if data_length:
                ranges.append((data_offset, data_end))
        ranges.sort()
        if any(previous_end > next_start for (_, previous_end), (next_start, _) in zip(ranges, ranges[1:])):
            raise RuntimeError(f"Backup AppleDouble metadata has overlapping entries: {entry.filename}")
    return total, digest.hexdigest()


def expected_appledouble_inventory(app, expected):
    """Build canonical bounded AppleDouble sidecars with Darwin copyfile for comparison."""
    if sys.platform != "darwin":
        if any(len(item) >= 4 and item[3] for item in expected.values()):
            raise RuntimeError("AppleDouble payload verification requires Darwin's copyfile packer.")
        return {}
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        copyfile = libc.copyfile
    except (AttributeError, OSError) as error:
        raise RuntimeError("Darwin's copyfile AppleDouble packer is unavailable.") from error
    copyfile.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32)
    copyfile.restype = ctypes.c_int
    result = {}
    aggregate_size = 0
    with tempfile.TemporaryDirectory(prefix="reel-appledouble-verify-") as scratch:
        scratch_path = Path(scratch)
        budget = {"count": 0, "name_bytes": 0, "value_bytes": 0}
        for index, (name, item) in enumerate(expected.items()):
            if len(item) < 4 or not item[3]:
                continue
            relative = name.rstrip("/")
            root = f"{Path(app).name}/"
            if name == root:
                source = Path(app)
            elif name.startswith(root):
                source = Path(app) / relative[len(root):]
            else:
                raise RuntimeError(f"Bundle inventory contains a path outside its root: {name!r}")
            actual_attributes = bounded_xattr_inventory(source, budget)
            if actual_attributes != item[3]:
                raise RuntimeError(f"Extended attributes changed since the bundle inventory: {source}")
            sidecar_name = appledouble_sidecar_name(name)
            packed = scratch_path / f"sidecar-{index:06d}"
            size, digest = pack_appledouble_sidecar(copyfile, source, packed)
            aggregate_size += size
            if aggregate_size > MAX_APPLEDOUBLE_TOTAL_SIZE:
                raise RuntimeError("Expected AppleDouble metadata exceeds the aggregate size limit.")
            if bounded_xattr_inventory(source, {"count": 0, "name_bytes": 0, "value_bytes": 0}) != item[3]:
                raise RuntimeError(f"Extended attributes changed while packing {source}")
            result[sidecar_name] = (size, digest)
    return result


def pack_appledouble_sidecar(copyfile, source, packed):
    """Pack one source object's metadata to a bounded private AppleDouble file."""
    # COPYFILE_ALL | COPYFILE_PACK | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST.
    flags = 0x0000000F | 0x00400000 | 0x000C0000
    ctypes.set_errno(0)
    status = copyfile(os.fsencode(source), os.fsencode(packed), None, flags)
    if status != 0:
        error_number = ctypes.get_errno()
        raise RuntimeError(
            f"Cannot create bounded AppleDouble verification payload for {source}: "
            f"{os.strerror(error_number) if error_number else 'unknown Darwin error'}"
        )
    try:
        info = packed.lstat()
    except OSError as error:
        raise RuntimeError(f"AppleDouble packer did not create a sidecar for {source}: {error}") from error
    if (stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.geteuid() or info.st_nlink != 1
            or info.st_size < 26 or info.st_size > MAX_APPLEDOUBLE_MEMBER_SIZE):
        raise RuntimeError(f"AppleDouble packer created an unsafe sidecar for {source}")
    digest, size = hash_bounded_regular_file(packed, info, MAX_APPLEDOUBLE_MEMBER_SIZE)
    return size, digest


def ensure_appledouble_metadata(archive_path, app, expected):
    """Fill only missing source metadata sidecars using canonical Darwin packing."""
    expected_sidecars = expected_appledouble_inventory(app, expected)
    if not expected_sidecars:
        return
    sidecars, sidecar_directories = appledouble_inventory(expected)
    sidecar_sources = {
        appledouble_sidecar_name(name): name
        for name, item in expected.items() if len(item) >= 4 and item[3]
    }
    archive_path = Path(archive_path)
    try:
        with archive_path.open("rb") as preflight_stream:
            preflight_zip_central_directory(preflight_stream)
        with zipfile.ZipFile(archive_path) as bundle:
            entries = bundle.infolist()
            if len(entries) > MAX_BACKUP_ENTRIES:
                raise RuntimeError("Backup bundle exceeds the 100,000 ZIP-entry limit.")
            names = [entry.filename for entry in entries]
            if len(names) != len(set(names)):
                raise RuntimeError("Backup bundle contains duplicate ZIP member names.")
            total_uncompressed = sum(entry.file_size for entry in entries)
            if (total_uncompressed < 0
                    or total_uncompressed > MAX_BACKUP_UNCOMPRESSED_BYTES):
                raise RuntimeError("Backup bundle exceeds the 16.5 GiB total-uncompressed-byte limit.")
    except (OSError, zipfile.BadZipFile) as error:
        raise RuntimeError(f"Cannot inspect the freshly created Reel backup: {error}") from error

    names_set = set(names)
    missing_sidecars = sorted(set(expected_sidecars) - names_set)
    missing_directories = sorted(sidecar_directories - names_set)
    if not missing_sidecars and not missing_directories:
        return
    additional_entries = len(missing_sidecars) + len(missing_directories)
    if additional_entries > MAX_BACKUP_ENTRIES - len(names):
            raise RuntimeError("Backup bundle exceeds the 100,000 ZIP-entry limit while preserving metadata.")
    additional_bytes = sum(expected_sidecars[name][0] for name in missing_sidecars)
    if additional_bytes > MAX_BACKUP_UNCOMPRESSED_BYTES - total_uncompressed:
        raise RuntimeError("Backup bundle exceeds the total-uncompressed-byte limit while preserving metadata.")

    try:
        libc = ctypes.CDLL(None, use_errno=True)
        copyfile = libc.copyfile
    except (AttributeError, OSError) as error:
        raise RuntimeError("Darwin's copyfile AppleDouble packer is unavailable.") from error
    copyfile.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32)
    copyfile.restype = ctypes.c_int
    root = f"{Path(app).name}/"
    with tempfile.TemporaryDirectory(prefix="reel-appledouble-write-") as scratch:
        scratch_path = Path(scratch)
        with zipfile.ZipFile(archive_path, "a", compression=zipfile.ZIP_DEFLATED) as bundle:
            for directory in missing_directories:
                entry = zipfile.ZipInfo(directory)
                entry.compress_type = zipfile.ZIP_STORED
                entry.external_attr = (stat.S_IFDIR | 0o700) << 16 | 0x10
                bundle.writestr(entry, b"")
            for index, sidecar_name in enumerate(missing_sidecars):
                original_name = sidecar_sources.get(sidecar_name)
                if original_name is None:
                    raise RuntimeError(f"Cannot map expected AppleDouble sidecar to a bundle entry: {sidecar_name}")
                relative = original_name.rstrip("/")
                source = Path(app) if original_name == root else Path(app) / relative[len(root):]
                item = expected[original_name]
                if len(item) < 4 or not item[3]:
                    raise RuntimeError(f"Expected AppleDouble sidecar has no xattr source: {sidecar_name}")
                if bounded_xattr_inventory(source, {"count": 0, "name_bytes": 0, "value_bytes": 0}) != item[3]:
                    raise RuntimeError(f"Extended attributes changed before packing {source}")
                packed = scratch_path / f"sidecar-{index:06d}"
                size, digest = pack_appledouble_sidecar(copyfile, source, packed)
                if (size, digest) != expected_sidecars[sidecar_name]:
                    raise RuntimeError(f"Source metadata changed while packing {source}")
                if bounded_xattr_inventory(source, {"count": 0, "name_bytes": 0, "value_bytes": 0}) != item[3]:
                    raise RuntimeError(f"Extended attributes changed while packing {source}")
                entry = zipfile.ZipInfo(sidecar_name)
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = (stat.S_IFREG | 0o600) << 16
                with packed.open("rb") as source_stream, bundle.open(entry, "w") as archive_stream:
                    while True:
                        chunk = source_stream.read(1024 * 1024)
                        if not chunk:
                            break
                        archive_stream.write(chunk)


def stable_file_identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def hash_bounded_regular_file(path, expected_info, remaining_bytes):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode)
                or stable_file_identity(before) != stable_file_identity(expected_info)):
            raise RuntimeError(f"Bundle entry changed or is not a regular file: {path}")
        if before.st_size < 0 or before.st_size > remaining_bytes:
            raise RuntimeError("Reel app bundle exceeds the 16 GiB total-byte limit.")
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024 * 1024, remaining_bytes - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > remaining_bytes:
                raise RuntimeError("Reel app bundle exceeds the 16 GiB total-byte limit.")
            digest.update(chunk)
        after = os.fstat(descriptor)
        path_after = os.stat(path, follow_symlinks=False)
        if (total != before.st_size or stable_file_identity(after) != stable_file_identity(before)
                or stable_file_identity(path_after) != stable_file_identity(before)):
            raise RuntimeError(f"Bundle entry changed while hashing: {path}")
        return digest.hexdigest(), total
    finally:
        os.close(descriptor)


def bundle_inventory(app):
    """Inventory bundle bytes and xattrs, capped by entry, byte, name, and count limits."""
    app = Path(app)
    try:
        root_info = app.lstat()
    except OSError as error:
        raise RuntimeError(f"Cannot inventory Reel app bundle {app}: {error}") from error
    if stat.S_ISLNK(root_info.st_mode) or not stat.S_ISDIR(root_info.st_mode):
        raise RuntimeError(f"Reel app bundle is not an ordinary directory: {app}")
    inventory = {}
    visited_entries = 1
    total_bytes = 0
    xattr_budget = {"count": 0, "name_bytes": 0, "value_bytes": 0}
    inventory[f"{app.name}/"] = (
        "directory", stat.S_IMODE(root_info.st_mode), None,
        bounded_xattr_inventory(app, xattr_budget, root_info),
    )
    pending = [(app, root_info)]
    while pending:
        parent, parent_info = pending.pop()
        try:
            with os.scandir(parent) as children:
                for child in children:
                    visited_entries += 1
                    if visited_entries > MAX_BUNDLE_ENTRIES:
                        raise RuntimeError("Reel app bundle exceeds the 100,000-entry limit.")
                    path = parent / child.name
                    relative = path.relative_to(app).as_posix()
                    try:
                        info = child.stat(follow_symlinks=False)
                    except OSError as error:
                        raise RuntimeError(f"Cannot safely inspect bundle entry {path}: {error}") from error
                    if stat.S_ISLNK(info.st_mode):
                        target = os.readlink(path).encode("utf-8", "surrogateescape")
                        if stable_file_identity(path.lstat()) != stable_file_identity(info):
                            raise RuntimeError(f"Bundle symlink changed while inventorying: {path}")
                        total_bytes += len(target)
                        if total_bytes > MAX_BUNDLE_TOTAL_BYTES:
                            raise RuntimeError("Reel app bundle exceeds the 16 GiB total-byte limit.")
                        inventory[f"{app.name}/{relative}"] = (
                            "symlink", stat.S_IMODE(info.st_mode), hashlib.sha256(target).hexdigest(),
                            bounded_xattr_inventory(path, xattr_budget, info),
                        )
                    elif stat.S_ISDIR(info.st_mode):
                        inventory[f"{app.name}/{relative}/"] = (
                            "directory", stat.S_IMODE(info.st_mode), None,
                            bounded_xattr_inventory(path, xattr_budget, info),
                        )
                        pending.append((path, info))
                    elif stat.S_ISREG(info.st_mode):
                        digest, size = hash_bounded_regular_file(
                            path, info, MAX_BUNDLE_TOTAL_BYTES - total_bytes,
                        )
                        total_bytes += size
                        inventory[f"{app.name}/{relative}"] = (
                            "file", stat.S_IMODE(info.st_mode), digest,
                            bounded_xattr_inventory(path, xattr_budget, info),
                        )
                    else:
                        raise RuntimeError(f"Bundle contains an unsupported special file: {path}")
            if stable_file_identity(parent.lstat()) != stable_file_identity(parent_info):
                raise RuntimeError(f"Bundle directory changed while inventorying: {parent}")
        except OSError as error:
            raise RuntimeError(f"Cannot safely inventory Reel app bundle {app}: {error}") from error
    return inventory


def normalized_bundle_inventory(app, inventory):
    """Compare bundle contents while ignoring only the staged root directory name."""
    root = f"{Path(app).name}/"
    normalized = {}
    for name, entry in inventory.items():
        if name == root:
            relative = ""
        elif name.startswith(root):
            relative = name[len(root):]
        else:
            raise RuntimeError(f"Bundle inventory contains a path outside its root: {name!r}")
        if relative in normalized:
            raise RuntimeError(f"Bundle inventory contains a duplicate normalized path: {relative!r}")
        normalized[relative] = entry
    if "" not in normalized:
        raise RuntimeError("Bundle inventory is missing its root directory entry.")
    return normalized


def bundle_executable_identity(app, inventory, info=None, *, allow_stage=False):
    """Return an executable digest already covered by the bounded bundle scan."""
    app = Path(app)
    info = identity(app, allow_stage=allow_stage) if info is None else info
    executable_name = info.get("CFBundleExecutable")
    if (not isinstance(executable_name, str) or not executable_name
            or executable_name in (".", "..") or Path(executable_name).name != executable_name
            or "/" in executable_name or "\\" in executable_name or "\x00" in executable_name):
        raise RuntimeError("Reel bundle has an unsafe CFBundleExecutable name.")
    key = f"{app.name}/Contents/MacOS/{executable_name}"
    entry = inventory.get(key)
    if entry is None or entry[0] != "file" or not isinstance(entry[2], str):
        raise RuntimeError("Reel executable is not a regular file inside the bounded app inventory.")
    return entry[2], key


def verify_archive_bundle(bundle, app, *, expected_inventory=None):
    """Verify every entry and body within 100,000 entries and 16.5 GiB uncompressed."""
    if bundle.fp is None:
        raise RuntimeError("Backup archive is closed while verifying its directory.")
    preflight_zip_central_directory(bundle.fp)
    expected = bundle_inventory(app) if expected_inventory is None else expected_inventory
    expected_sidecars = expected_appledouble_inventory(app, expected)
    sidecars, sidecar_directories = appledouble_inventory(expected)
    entries = bundle.infolist()
    if len(entries) > MAX_BACKUP_ENTRIES:
        raise RuntimeError("Backup bundle exceeds the 100,000 ZIP-entry limit.")
    total_uncompressed = 0
    for item in entries:
        if item.file_size < 0:
            raise RuntimeError(f"Backup bundle has a negative uncompressed size: {item.filename!r}")
        total_uncompressed += item.file_size
        if total_uncompressed > MAX_BACKUP_UNCOMPRESSED_BYTES:
            raise RuntimeError("Backup bundle exceeds the 16.5 GiB total-uncompressed-byte limit.")
    names = [item.filename for item in entries]
    if len(names) != len(set(names)):
        raise RuntimeError("Backup bundle contains duplicate ZIP member names.")
    actual = {item.filename: item for item in entries}
    actual_bundle = {}
    sidecar_total_size = 0
    found_sidecars = {}
    actual_stream_budget = {"remaining": MAX_BACKUP_UNCOMPRESSED_BYTES}
    for name in names:
        normalized = name.rstrip("/")
        components = normalized.split("/")
        if (not normalized or name.startswith("/") or "\\" in name
                or any(component in ("", ".", "..") for component in components)):
            raise RuntimeError(f"Backup bundle contains an unsafe ZIP member path: {name!r}")
        if name in expected:
            if expected[name][0] == "directory":
                verify_empty_directory_member(bundle, actual[name], actual_stream_budget)
            actual_bundle[name] = actual[name]
            continue
        if name in sidecars:
            if actual[name].file_size > MAX_APPLEDOUBLE_TOTAL_SIZE - sidecar_total_size:
                raise RuntimeError("Backup AppleDouble metadata exceeds the aggregate size limit.")
            size, digest = verify_appledouble_member(
                bundle, actual[name], aggregate_budget=actual_stream_budget,
            )
            expected_sidecar = expected_sidecars.get(name)
            if expected_sidecar is None or expected_sidecar != (size, digest):
                raise RuntimeError(f"Backup AppleDouble payload differs from its source metadata: {name}")
            sidecar_total_size += size
            found_sidecars[name] = (size, digest)
            continue
        if name in sidecar_directories:
            directory_mode = actual[name].external_attr >> 16
            if (not name.endswith("/") or stat.S_IFMT(directory_mode) != stat.S_IFDIR
                    or actual[name].file_size != 0):
                raise RuntimeError(f"Backup AppleDouble metadata directory is unsafe: {name!r}")
            verify_empty_directory_member(bundle, actual[name], actual_stream_budget)
            continue
        raise RuntimeError(f"Backup bundle contains an unexpected ZIP member: {name!r}")
    if set(actual_bundle) != set(expected):
        missing = sorted(set(expected) - set(actual_bundle))
        extra = sorted(set(actual_bundle) - set(expected))
        raise RuntimeError(f"Backup bundle inventory differs (missing={missing[:3]}, extra={extra[:3]}).")
    if found_sidecars != expected_sidecars:
        missing = sorted(set(expected_sidecars) - set(found_sidecars))
        extra = sorted(set(found_sidecars) - set(expected_sidecars))
        raise RuntimeError(
            f"Backup AppleDouble inventory differs (missing={missing[:3]}, extra={extra[:3]})."
        )
    for name, (kind, mode, digest, _attributes) in expected.items():
        entry = actual_bundle[name]
        archived_mode = entry.external_attr >> 16
        archived_kind = stat.S_IFMT(archived_mode)
        expected_kind = {
            "directory": stat.S_IFDIR,
            "file": stat.S_IFREG,
            "symlink": stat.S_IFLNK,
        }[kind]
        if archived_kind != expected_kind or stat.S_IMODE(archived_mode) != mode:
            raise RuntimeError(f"Backup entry type or permissions differ: {name}")
        if kind != "directory" and archive_member_sha256(
                bundle, name, aggregate_budget=actual_stream_budget) != digest:
            raise RuntimeError(f"Backup entry contents differ: {name}")


def atomic_swap_paths(first, second):
    """Atomically exchange two paths on a macOS volume that supports RENAME_SWAP."""
    if sys.platform != "darwin":
        raise RuntimeError("Safe Reel installation requires macOS directory-swap support.")
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        renamex_np = libc.renamex_np
    except AttributeError as error:
        raise RuntimeError("This macOS runtime does not provide renamex_np; Reel was not replaced.") from error
    renamex_np.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    renamex_np.restype = ctypes.c_int
    result = renamex_np(os.fsencode(first), os.fsencode(second), RENAME_SWAP)
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), f"{first} <-> {second}")


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def ensure_clean_checkout(status=None):
    """Ensure the app was built from committed tracked source, excluding unrelated user files."""
    if status is None:
        status = run("git", "-C", str(REPOSITORY_ROOT), "status", "--porcelain", "--untracked-files=no")
    if status.strip():
        raise RuntimeError(
            "Refusing to install a build from a checkout with uncommitted tracked changes. "
            "Commit the intended source first, rebuild, and retry."
        )


def read_bounded_regular_file(path, limit, label):
    path = Path(path)
    try:
        before = path.lstat()
    except OSError as error:
        raise RuntimeError(f"Cannot safely read {label}: {error}") from error
    if (stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode)
            or before.st_size <= 0 or before.st_size > limit):
        raise RuntimeError(f"{label} must be a non-empty regular file no larger than {limit} bytes.")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise RuntimeError(f"Cannot safely open {label}: {error}") from error
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode)
                or stable_file_identity(opened) != stable_file_identity(before)):
            raise RuntimeError(f"{label} changed while opening.")
        chunks = []
        size = 0
        while True:
            block = os.read(descriptor, min(65_536, limit + 1 - size))
            if not block:
                break
            size += len(block)
            if size > limit:
                raise RuntimeError(f"{label} exceeds the {limit}-byte limit.")
            chunks.append(block)
        after = os.fstat(descriptor)
        path_after = path.lstat()
        if (size != opened.st_size or stable_file_identity(after) != stable_file_identity(opened)
                or stable_file_identity(path_after) != stable_file_identity(opened)):
            raise RuntimeError(f"{label} changed or was incomplete while reading.")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def identity(app, *, allow_stage=False):
    app = Path(app)
    if app.is_symlink():
        raise RuntimeError(f"Not an ordinary Reel app bundle: {app}")
    try:
        app_info = app.lstat()
        contents_info = (app / "Contents").lstat()
    except OSError as error:
        raise RuntimeError(f"Not an ordinary Reel app bundle: {app}") from error
    if (stat.S_ISLNK(app_info.st_mode) or not stat.S_ISDIR(app_info.st_mode)
            or stat.S_ISLNK(contents_info.st_mode) or not stat.S_ISDIR(contents_info.st_mode)):
        raise RuntimeError(f"Not an ordinary Reel app bundle: {app}")
    info_path = app / "Contents/Info.plist"
    raw_info = read_bounded_regular_file(info_path, MAX_INFO_PLIST_BYTES, "Reel Info.plist")
    try:
        info = plistlib.loads(raw_info)
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError) as error:
        raise RuntimeError(f"Reel Info.plist is malformed: {error}") from error
    if not isinstance(info, dict):
        raise RuntimeError("Reel Info.plist must contain a property-list dictionary.")
    is_app = app.suffix == ".app"
    is_stage = allow_stage and app.name == "Reel.bundle-stage"
    if info.get("CFBundleIdentifier") != IDENTIFIER or not (is_app or is_stage):
        raise RuntimeError(f"Not an ordinary Reel app bundle: {app}")
    return info


def audit():
    with tempfile.TemporaryDirectory(prefix="iina-registration-") as folder:
        source = Path(folder) / "audit.swift"
        source.write_text(AUDIT_SWIFT)
        return json.loads(run("/usr/bin/xcrun", "swift", str(source)))


def registrations():
    process = subprocess.Popen(
        [LSREGISTER, "-dump"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    stderr = bytearray()
    stderr_exceeded = threading.Event()
    stream_errors = []
    paths = []
    seen = set()

    def drain_stderr():
        while True:
            try:
                chunk = process.stderr.read(64 * 1024)
            except (OSError, ValueError):
                return
            if not chunk:
                return
            remaining = MAX_PROCESS_OUTPUT_BYTES - len(stderr)
            if remaining > 0:
                stderr.extend(chunk[:remaining])
            if len(chunk) > max(remaining, 0):
                stderr_exceeded.set()

    def commit_block(identifier_matches, path):
        if not identifier_matches or path is None or path in seen:
            return
        if len(paths) >= MAX_REGISTERED_APP_PATHS:
            raise RuntimeError(
                f"Launch Services dump contains more than {MAX_REGISTERED_APP_PATHS} Reel registrations.")
        seen.add(path)
        paths.append(path)

    def parse_stdout():
        total_bytes = 0
        identifier_matches = False
        path = None
        separator = b"-" * 80
        encoding = locale.getpreferredencoding(False) or "utf-8"
        try:
            while True:
                raw_line = process.stdout.readline(MAX_LSREGISTER_DUMP_LINE_BYTES + 1)
                if not raw_line:
                    break
                if len(raw_line) > MAX_LSREGISTER_DUMP_LINE_BYTES:
                    raise RuntimeError(
                        f"Launch Services dump contains a line larger than "
                        f"{MAX_LSREGISTER_DUMP_LINE_BYTES} bytes.")
                total_bytes += len(raw_line)
                if total_bytes > MAX_LSREGISTER_DUMP_BYTES:
                    raise RuntimeError(
                        f"Launch Services dump exceeded the {MAX_LSREGISTER_DUMP_BYTES}-byte output limit.")
                if raw_line.rstrip(b"\r\n") == separator:
                    commit_block(identifier_matches, path)
                    identifier_matches = False
                    path = None
                    continue
                line = raw_line.decode(encoding, errors="replace")
                if line.startswith("identifier:"):
                    identifier_matches = line.partition(":")[2].strip() == IDENTIFIER
                elif path is None and line.startswith("path:"):
                    match = re.match(r"^path:\s+(.*?) \(0x", line)
                    if match:
                        path = Path(match[1])
            commit_block(identifier_matches, path)
        except Exception as error:
            stream_errors.append(error)
            try:
                process.kill()
            except OSError:
                pass

    readers = [
        threading.Thread(target=parse_stdout, name="lsregister-parser", daemon=True),
        threading.Thread(target=drain_stderr, name="lsregister-stderr", daemon=True),
    ]
    for reader in readers:
        reader.start()
    try:
        returncode = process.wait(timeout=120)
    except subprocess.TimeoutExpired as error:
        process.kill()
        process.wait()
        for reader in readers:
            reader.join(timeout=1)
        process.stdout.close()
        process.stderr.close()
        raise RuntimeError(f"{LSREGISTER} timed out after 120 seconds.") from error
    for reader in readers:
        reader.join(timeout=5)
    if any(reader.is_alive() for reader in readers):
        process.stdout.close()
        process.stderr.close()
        raise RuntimeError(f"{LSREGISTER} did not close its output streams after exiting.")
    process.stdout.close()
    process.stderr.close()
    if stream_errors:
        raise stream_errors[0]
    if stderr_exceeded.is_set():
        raise RuntimeError(f"{LSREGISTER} exceeded the {MAX_PROCESS_OUTPUT_BYTES}-byte stderr limit.")
    encoding = locale.getpreferredencoding(False) or "utf-8"
    stderr_text = stderr.decode(encoding, errors="replace").strip()
    if returncode:
        raise RuntimeError(f"{LSREGISTER} failed ({returncode}): {stderr_text}")
    return paths


def discoverable_copies():
    paths = run("/usr/bin/mdfind", f'kMDItemCFBundleIdentifier == "{IDENTIFIER}"').splitlines()
    return [Path(p) for p in paths if Path(p).exists()]


def plugin_matches(*options, usable_only=False):
    output = run("/usr/bin/pluginkit", "-m", *options, "-v", "-i", IDENTIFIER + ".OpenInIINA")
    matches = set()
    for line in output.splitlines():
        election = line[0] if line and line[0] in "+-=!?" else None
        match = re.search(r"\t(/.*?)(?: \(0x[0-9a-fA-F]+\))?$", line)
        if not match:
            continue
        path = match.group(1)
        # An absent tag is PlugInKit's default election. Only that state and an explicit
        # `use` election are eligible for ordinary extension discovery; `ignore`, debugger,
        # superseded, and unknown states must not make installation appear successful.
        if usable_only and election not in (None, "+"):
            continue
        matches.add(Path(path))
    return matches


def registered_plugins():
    # The full inventory is needed to prune only registrations whose paths disappeared.
    return plugin_matches("-A", "-D")


def default_discovered_plugins():
    # Without -A/-D, PlugInKit applies its normal version/instance reduction. Also reject
    # matches that are ignored, debugger-only, superseded, or have an unknown election state.
    return plugin_matches(usable_only=True)


def same_path(first, second):
    try:
        return Path(first).resolve() == Path(second).resolve()
    except OSError:
        return False


def embedded_open_in_extension(app):
    return Path(app) / "Contents/PlugIns/OpenInIINA.appex"


def register_embedded_open_in_extension(app):
    extension = embedded_open_in_extension(app)
    try:
        info = extension.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"Embedded Open In extension is not a real directory: {extension}")
    run("/usr/bin/pluginkit", "-a", str(extension))


def unregister_embedded_open_in_extension(app):
    extension = embedded_open_in_extension(app)
    try:
        info = extension.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"Embedded Open In extension is not a real directory: {extension}")
    run("/usr/bin/pluginkit", "-r", str(extension))


def signed_entitlements(bundle):
    """Read the entitlements actually sealed into a code signature."""
    output = run("/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle))
    try:
        value = plistlib.loads(output.encode("utf-8"))
    except (ValueError, plistlib.InvalidFileException) as error:
        raise RuntimeError(f"Could not read signed entitlements for {bundle}.") from error
    if not isinstance(value, dict):
        raise RuntimeError(f"Signed entitlements are not a property list dictionary: {bundle}")
    return value


def verify_signed_entitlements(bundle, entitlement_file):
    """Require the signature to preserve the target's source entitlements exactly."""
    entitlement_file = Path(entitlement_file)
    try:
        expected = plistlib.loads(entitlement_file.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise RuntimeError(f"Could not read target entitlements {entitlement_file}.") from error
    actual = signed_entitlements(bundle)
    if actual != expected:
        raise RuntimeError(
            f"The staged signature does not preserve target entitlements from {entitlement_file}."
        )


def sign_staged_bundle(app):
    """Ad-hoc sign a Release bundle with hardened runtime and target entitlements."""
    app = Path(app)
    extension = embedded_open_in_extension(app)

    # The build product is linker-signed. First sign nested code so the copy has
    # complete signatures, then re-sign the extension and app separately: their
    # sandbox and plug-in entitlements differ, and the outer app must be sealed last.
    run("/usr/bin/codesign", "--force", "--deep", "--options", "runtime", "--sign", "-", str(app))
    try:
        extension_info = extension.lstat()
    except FileNotFoundError:
        extension_info = None
    if extension_info is not None:
        if not stat.S_ISDIR(extension_info.st_mode):
            raise RuntimeError(f"Embedded Open In extension is not a real directory: {extension}")
        run(
            "/usr/bin/codesign", "--force", "--options", "runtime",
            "--entitlements", str(OPEN_IN_EXTENSION_ENTITLEMENTS), "--sign", "-", str(extension),
        )
        run("/usr/bin/codesign", "--verify", "--strict", str(extension))
        verify_signed_entitlements(extension, OPEN_IN_EXTENSION_ENTITLEMENTS)

    run(
        "/usr/bin/codesign", "--force", "--options", "runtime",
        "--entitlements", str(APP_ENTITLEMENTS), "--sign", "-", str(app),
    )
    verify_signed_entitlements(app, APP_ENTITLEMENTS)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))


def repair_plan():
    before = audit()
    if before["running"]:
        raise RuntimeError("Quit Reel before changing its registrations.")
    registered_apps = set(registrations())
    plugins = registered_plugins()
    stale_apps = {path for path in registered_apps if not path.exists()}
    stale_plugins = {path for path in plugins if not path.exists()}
    return before, stale_apps, stale_plugins


def canonical_selection_ready(snapshot, installed=INSTALLED):
    """Whether Launch Services prefers the installed app and no other copy is running."""
    def is_installed(path):
        if not path or path == "NONE":
            return False
        try:
            return Path(path).resolve() == Path(installed).resolve()
        except OSError:
            return False

    return (
        is_installed(snapshot.get("preferred"))
        and any(is_installed(path) for path in snapshot.get("copies", []))
        and any(is_installed(path) for path in snapshot.get("registered", []))
        and all(is_installed(path) for path in snapshot.get("running", []))
    )


def current_checkout_commit():
    return run("git", "-C", str(REPOSITORY_ROOT), "rev-parse", "HEAD").strip()


def is_ancestor(ancestor, descendant):
    result = subprocess.run(
        ["git", "-C", str(REPOSITORY_ROOT), "merge-base", "--is-ancestor", ancestor, descendant],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode not in (0, 1):
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"Could not compare build commits: {detail or result.returncode}")
    return result.returncode == 0


def _release_key(value, label):
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?\s*", str(value or ""))
    if not match:
        raise RuntimeError(f"Missing or unsupported {label}: {value!r}")
    release = [int(part) for part in match.group(1).split(".")]
    while len(release) > 1 and release[-1] == 0:
        release.pop()
    prerelease = match.group(2)
    if prerelease is None:
        pre_key = (1, ())  # A final release sorts after its prereleases.
    else:
        tokens = re.findall(r"[0-9]+|[A-Za-z]+", prerelease)
        if not tokens or "".join(tokens).lower() != re.sub(r"[.-]", "", prerelease).lower():
            raise RuntimeError(f"Unsupported prerelease in {label}: {value!r}")
        pre_key = (0, tuple((0, int(token)) if token.isdigit() else (1, token.lower()) for token in tokens))
    return tuple(release), pre_key


def _build_key(value):
    if not re.fullmatch(r"\d+(?:\.\d+)*", str(value or "")):
        raise RuntimeError(f"Missing or unsupported CFBundleVersion: {value!r}")
    parts = [int(part) for part in str(value).split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def _build_commit(info, label):
    commit = info.get(BUILD_COMMIT_KEY)
    if not isinstance(commit, str) or not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", commit):
        raise RuntimeError(f"{label} has no resolved 40- or 64-character build commit ({BUILD_COMMIT_KEY}).")
    return commit.lower()


def configured_build_metadata():
    config = (REPOSITORY_ROOT / "Configs/Deployment.xcconfig").read_text()
    values = {}
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        match = re.search(rf"^\s*{key}\s*=\s*([^\s/]+)", config, re.M)
        if not match:
            raise RuntimeError(f"Could not read {key} from Configs/Deployment.xcconfig.")
        values[key] = match.group(1)
    return values


def validate_candidate(candidate_info, installed_info=None, *, checkout_commit=None, ancestor_check=None):
    """Reject stale products and candidates that cannot be proven forward of the installation."""
    candidate_commit = _build_commit(candidate_info, "Build product")
    checkout_commit = (checkout_commit or current_checkout_commit()).lower()
    if candidate_commit != checkout_commit:
        raise RuntimeError(
            "Build product is stale: its embedded commit "
            f"{candidate_commit[:12]} does not match this checkout at {checkout_commit[:12]}. Rebuild first."
        )
    candidate_configuration = candidate_info.get(BUILD_CONFIGURATION_KEY)
    if candidate_configuration != "Release":
        raise RuntimeError(
            "Build product is not a Release configuration: "
            f"{candidate_configuration!r}. Rebuild with -configuration Release."
        )
    candidate_version = _release_key(candidate_info.get("CFBundleShortVersionString"), "CFBundleShortVersionString")
    candidate_build = _build_key(candidate_info.get("CFBundleVersion"))
    configured = configured_build_metadata()
    if (candidate_version != _release_key(configured["MARKETING_VERSION"], "configured MARKETING_VERSION")
            or candidate_build != _build_key(configured["CURRENT_PROJECT_VERSION"])):
        raise RuntimeError(
            "Build product is stale: it embeds version/build "
            f"{candidate_info.get('CFBundleShortVersionString')} ({candidate_info.get('CFBundleVersion')}), "
            f"but this checkout is configured for {configured['MARKETING_VERSION']} ({configured['CURRENT_PROJECT_VERSION']}). Rebuild first."
        )
    if installed_info is None:
        return candidate_commit

    installed_commit = _build_commit(installed_info, "Installed Reel")
    installed_version = _release_key(installed_info.get("CFBundleShortVersionString"), "installed CFBundleShortVersionString")
    installed_build = _build_key(installed_info.get("CFBundleVersion"))
    if candidate_version < installed_version or candidate_build < installed_build:
        raise RuntimeError(
            "Refusing a downgrade or non-monotonic build: build product "
            f"{candidate_info.get('CFBundleShortVersionString')} ({candidate_info.get('CFBundleVersion')}) is older than "
            f"installed Reel {installed_info.get('CFBundleShortVersionString')} ({installed_info.get('CFBundleVersion')})."
        )
    if candidate_commit != installed_commit:
        if candidate_build == installed_build:
            raise RuntimeError(
                "A new Reel commit must increase CURRENT_PROJECT_VERSION; build number "
                f"{candidate_build} is already installed."
            )
        checker = ancestor_check or is_ancestor
        if not checker(installed_commit, candidate_commit):
            raise RuntimeError(
                "Refusing an unproven build update: the installed commit is not an ancestor of the candidate commit. "
                f"Installed {installed_commit[:12]}, candidate {candidate_commit[:12]}."
            )
    return candidate_commit


ARCHIVE_MANIFEST_NAME = "archive-manifest.jsonl"
ARCHIVE_MANIFEST_LOCK_NAME = ".archive-manifest.lock"
ARCHIVE_MANIFEST_KEYS = {
    "original", "archive", "version", "build", "executableSHA256", "archiveSHA256",
}


def validate_archive_manifest_record(record):
    if (not isinstance(record, dict) or set(record) != ARCHIVE_MANIFEST_KEYS
            or not isinstance(record.get("original"), str) or not Path(record["original"]).is_absolute()
            or not isinstance(record.get("archive"), str) or not Path(record["archive"]).is_absolute()
            or any(record.get(key) is not None and not isinstance(record.get(key), str)
                   for key in ("version", "build"))
            or any(not isinstance(record.get(key), str)
                   or re.fullmatch(r"[0-9a-f]{64}", record[key]) is None
                   for key in ("executableSHA256", "archiveSHA256"))):
        raise RuntimeError("Backup archive manifest contains a malformed record.")
    return record


def reject_duplicate_json_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_archive_manifest(raw):
    if not raw or len(raw) > MAX_ARCHIVE_MANIFEST_BYTES or not raw.endswith(b"\n"):
        raise RuntimeError("Backup archive manifest is empty, incomplete, or oversized.")
    lines = raw.split(b"\n")[:-1]
    if not lines or len(lines) > MAX_ARCHIVE_MANIFEST_RECORDS:
        raise RuntimeError("Backup archive manifest has an invalid record count.")
    records = []
    for line in lines:
        if not line or len(line) > MAX_ARCHIVE_MANIFEST_RECORD_BYTES:
            raise RuntimeError("Backup archive manifest contains an empty or oversized record.")
        try:
            record = json.loads(line.decode("utf-8"), object_pairs_hook=reject_duplicate_json_keys)
        except (UnicodeError, ValueError) as error:
            raise RuntimeError("Backup archive manifest contains malformed JSON.") from error
        records.append(validate_archive_manifest_record(record))
    return records


def open_backup_directory(support):
    support = Path(support)
    try:
        support.mkdir(mode=0o700, parents=True, exist_ok=True)
        support_before = support.lstat()
    except OSError as error:
        raise RuntimeError(f"Cannot safely create or inspect backup parent {support}: {error}") from error
    if (stat.S_ISLNK(support_before.st_mode) or not stat.S_ISDIR(support_before.st_mode)
            or support_before.st_uid != os.geteuid() or stat.S_IMODE(support_before.st_mode) & 0o022):
        raise RuntimeError(f"Backup parent is not a safe owner-owned directory: {support}")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        support_fd = os.open(support, flags)
    except OSError as error:
        raise RuntimeError(f"Cannot safely open backup parent {support}: {error}") from error
    try:
        support_opened = os.fstat(support_fd)
        if ((support_opened.st_dev, support_opened.st_ino) !=
                (support_before.st_dev, support_before.st_ino)):
            raise RuntimeError(f"Backup parent changed while opening: {support}")
        try:
            os.mkdir("Backups", 0o700, dir_fd=support_fd)
        except FileExistsError:
            pass
        backup_before = os.stat("Backups", dir_fd=support_fd, follow_symlinks=False)
        if (stat.S_ISLNK(backup_before.st_mode) or not stat.S_ISDIR(backup_before.st_mode)
                or backup_before.st_uid != os.geteuid() or stat.S_IMODE(backup_before.st_mode) & 0o022):
            raise RuntimeError("Backup folder must be a real owner-owned directory without group/world write access.")
        backup_fd = os.open("Backups", flags, dir_fd=support_fd)
        backup_opened = os.fstat(backup_fd)
        if ((backup_opened.st_dev, backup_opened.st_ino) !=
                (backup_before.st_dev, backup_before.st_ino)):
            os.close(backup_fd)
            raise RuntimeError("Backup folder changed while opening.")
        return backup_fd
    finally:
        os.close(support_fd)


@contextmanager
def archive_manifest_lock(directory_fd):
    """Lock a stable sidecar inode while replacing the manifest atomically."""
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(ARCHIVE_MANIFEST_LOCK_NAME, flags, 0o600, dir_fd=directory_fd)
    except OSError as error:
        raise RuntimeError(f"Cannot safely open the backup archive manifest lock: {error}") from error
    try:
        opened = os.fstat(descriptor)
        current = os.stat(ARCHIVE_MANIFEST_LOCK_NAME, dir_fd=directory_fd, follow_symlinks=False)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) & 0o077
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
            raise RuntimeError("Backup archive manifest lock is not a private owner-owned regular file.")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        opened = os.fstat(descriptor)
        current = os.stat(ARCHIVE_MANIFEST_LOCK_NAME, dir_fd=directory_fd, follow_symlinks=False)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) & 0o077
                or (opened.st_dev, opened.st_ino) != (current.st_dev, current.st_ino)):
            raise RuntimeError("Backup archive manifest lock changed while waiting.")
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def read_archive_manifest_at(directory_fd, *, allow_missing=True):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(ARCHIVE_MANIFEST_NAME, flags, dir_fd=directory_fd)
    except FileNotFoundError:
        if allow_missing:
            return b"", []
        raise
    except OSError as error:
        raise RuntimeError(f"Cannot safely open the backup archive manifest: {error}") from error
    try:
        before = os.fstat(descriptor)
        path_before = os.stat(ARCHIVE_MANIFEST_NAME, dir_fd=directory_fd, follow_symlinks=False)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.geteuid()
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) & 0o022
                or before.st_size <= 0
                or (before.st_dev, before.st_ino) != (path_before.st_dev, path_before.st_ino)):
            raise RuntimeError("Backup archive manifest is not a bounded owner-owned single-link regular file.")
        if before.st_size > MAX_ARCHIVE_MANIFEST_BYTES:
            raise RuntimeError("Backup archive manifest exceeds its size limit.")
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65_536, MAX_ARCHIVE_MANIFEST_BYTES + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_ARCHIVE_MANIFEST_BYTES:
                raise RuntimeError("Backup archive manifest exceeds its size limit.")
            chunks.append(chunk)
        after = os.fstat(descriptor)
        path_after = os.stat(ARCHIVE_MANIFEST_NAME, dir_fd=directory_fd, follow_symlinks=False)
        raw = b"".join(chunks)
        if (total != before.st_size
                or stable_file_identity(after) != stable_file_identity(before)
                or (path_after.st_dev, path_after.st_ino) != (before.st_dev, before.st_ino)):
            raise RuntimeError("Backup archive manifest changed while it was being read.")
    finally:
        os.close(descriptor)
    return raw, parse_archive_manifest(raw)


def validate_archive_manifest(support):
    directory_fd = open_backup_directory(support)
    try:
        _, records = read_archive_manifest_at(directory_fd)
        return records
    finally:
        os.close(directory_fd)


def append_archive_manifest(support, record):
    record = validate_archive_manifest_record(record)
    directory_fd = open_backup_directory(support)
    try:
        with archive_manifest_lock(directory_fd):
            try:
                original_info = os.stat(
                    ARCHIVE_MANIFEST_NAME, dir_fd=directory_fd, follow_symlinks=False,
                )
            except FileNotFoundError:
                original_info = None
            raw, records = read_archive_manifest_at(directory_fd)
            if original_info is not None:
                after_read = os.stat(
                    ARCHIVE_MANIFEST_NAME, dir_fd=directory_fd, follow_symlinks=False,
                )
                if stable_file_identity(after_read) != stable_file_identity(original_info):
                    raise RuntimeError("Backup archive manifest changed while it was being read.")
            elif raw or records:
                raise RuntimeError("Backup archive manifest appeared while it was being read.")
            if len(records) >= MAX_ARCHIVE_MANIFEST_RECORDS:
                raise RuntimeError("Backup archive manifest reached its record limit.")
            encoded = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
            if len(encoded) > MAX_ARCHIVE_MANIFEST_RECORD_BYTES:
                raise RuntimeError("Backup archive manifest record exceeds its size limit.")
            updated = raw + encoded
            if len(updated) > MAX_ARCHIVE_MANIFEST_BYTES:
                raise RuntimeError("Backup archive manifest reached its size limit.")

            temporary_name = f".{ARCHIVE_MANIFEST_NAME}.tmp-{uuid.uuid4().hex}"
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
            descriptor = None
            temporary_created = False
            temporary_identity = None
            try:
                descriptor = os.open(temporary_name, flags, 0o600, dir_fd=directory_fd)
                temporary_created = True
                temporary_info = os.fstat(descriptor)
                temporary_identity = (temporary_info.st_dev, temporary_info.st_ino)
                if (not stat.S_ISREG(temporary_info.st_mode)
                        or temporary_info.st_uid != os.geteuid()
                        or temporary_info.st_nlink != 1
                        or stat.S_IMODE(temporary_info.st_mode) & 0o077):
                    raise RuntimeError("Temporary backup archive manifest is not a private owner-owned file.")
                os.fchmod(descriptor, 0o600)
                offset = 0
                while offset < len(updated):
                    written = os.write(descriptor, updated[offset:])
                    if written <= 0:
                        raise OSError("short write while publishing backup archive manifest")
                    offset += written
                os.fsync(descriptor)
                after_write = os.fstat(descriptor)
                temporary_path_info = os.stat(
                    temporary_name, dir_fd=directory_fd, follow_symlinks=False,
                )
                if (not stat.S_ISREG(after_write.st_mode)
                        or after_write.st_uid != os.geteuid() or after_write.st_nlink != 1
                        or stat.S_IMODE(after_write.st_mode) & 0o077
                        or (after_write.st_dev, after_write.st_ino) !=
                           (temporary_info.st_dev, temporary_info.st_ino)
                        or (temporary_path_info.st_dev, temporary_path_info.st_ino)
                        != (temporary_info.st_dev, temporary_info.st_ino)
                        or after_write.st_size != len(updated)):
                    raise RuntimeError("Temporary backup archive manifest changed before publication.")

                if original_info is None:
                    try:
                        os.stat(ARCHIVE_MANIFEST_NAME, dir_fd=directory_fd, follow_symlinks=False)
                    except FileNotFoundError:
                        pass
                    else:
                        raise RuntimeError("Backup archive manifest appeared before publication.")
                else:
                    current_info = os.stat(
                        ARCHIVE_MANIFEST_NAME, dir_fd=directory_fd, follow_symlinks=False,
                    )
                    if stable_file_identity(current_info) != stable_file_identity(original_info):
                        raise RuntimeError("Backup archive manifest changed before publication.")
                os.replace(
                    temporary_name, ARCHIVE_MANIFEST_NAME,
                    src_dir_fd=directory_fd, dst_dir_fd=directory_fd,
                )
                os.fsync(directory_fd)
            finally:
                if descriptor is not None:
                    os.close(descriptor)
                if temporary_created:
                    try:
                        temporary_path_info = os.stat(
                            temporary_name, dir_fd=directory_fd, follow_symlinks=False,
                        )
                        if (stat.S_ISREG(temporary_path_info.st_mode)
                                and temporary_path_info.st_uid == os.geteuid()
                                and temporary_path_info.st_nlink == 1
                                and (temporary_path_info.st_dev, temporary_path_info.st_ino)
                                == temporary_identity):
                            os.unlink(temporary_name, dir_fd=directory_fd)
                            os.fsync(directory_fd)
                    except FileNotFoundError:
                        pass
    finally:
        os.close(directory_fd)


def generated_archive_name(stem, name):
    return re.fullmatch(
        re.escape(stem) + r"-\d{8}T\d{12}Z-[0-9a-f]{12}-[0-9a-f]{8}\.zip",
        name,
    ) is not None


def archive_temporary_directory_name(stem, token):
    return f".{stem}-archive-{token}"


def _safe_archive_temp_directory_fd(parent_fd, name, expected_identity=None):
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        descriptor = os.open(name, flags, dir_fd=parent_fd)
    except OSError:
        return None, None
    opened = os.fstat(descriptor)
    try:
        after = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError:
        os.close(descriptor)
        return None, None
    identity = (opened.st_dev, opened.st_ino)
    if (stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode)
            or before.st_uid != os.geteuid() or stat.S_IMODE(before.st_mode) & 0o077
            or not stat.S_ISDIR(opened.st_mode) or opened.st_uid != os.geteuid()
            or stat.S_IMODE(opened.st_mode) & 0o077
            or identity != (before.st_dev, before.st_ino)
            or identity != (after.st_dev, after.st_ino)
            or (expected_identity is not None and identity != expected_identity)):
        os.close(descriptor)
        return None, None
    return descriptor, identity


def _read_archive_temp_marker(directory_fd, token):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        before = os.stat(ARCHIVE_TEMP_MARKER, dir_fd=directory_fd, follow_symlinks=False)
        descriptor = os.open(ARCHIVE_TEMP_MARKER, flags, dir_fd=directory_fd)
    except OSError:
        return None, None
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or opened.st_nlink != 1 or stat.S_IMODE(opened.st_mode) != 0o600
                or opened.st_mode & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX)
                or opened.st_size <= 0 or opened.st_size > MAX_ARCHIVE_TEMP_MARKER_BYTES
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)):
            return None, None
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(1024, MAX_ARCHIVE_TEMP_MARKER_BYTES + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_ARCHIVE_TEMP_MARKER_BYTES:
                return None, None
            chunks.append(chunk)
        after = os.fstat(descriptor)
        path_after = os.stat(ARCHIVE_TEMP_MARKER, dir_fd=directory_fd, follow_symlinks=False)
        if (total != opened.st_size or stable_file_identity(after) != stable_file_identity(opened)
                or (path_after.st_dev, path_after.st_ino) != (opened.st_dev, opened.st_ino)):
            return None, None
        try:
            record = json.loads(b"".join(chunks).decode("utf-8"),
                                object_pairs_hook=reject_duplicate_json_keys)
        except (UnicodeError, ValueError):
            return None, None
        if (not isinstance(record, dict) or set(record) != {"archive", "schema", "token"}
                or type(record.get("schema")) is not int or record.get("schema") != 1
                or record.get("token") != token
                or not isinstance(record.get("archive"), str)):
            return None, None
        return record, (opened.st_dev, opened.st_ino)
    finally:
        os.close(descriptor)


def cleanup_archive_temporary_directory(parent_fd, name, stem, *, expected_identity=None):
    """Remove only a private, marker-backed temp directory with the exact generated shape."""
    match = re.fullmatch(rf"\.{re.escape(stem)}-archive-([0-9a-f]{{32}})", name)
    if match is None:
        return False
    token = match.group(1)
    directory_fd, identity = _safe_archive_temp_directory_fd(parent_fd, name, expected_identity)
    if directory_fd is None:
        return False
    try:
        with os.scandir(directory_fd) as iterator:
            children = []
            for entry in iterator:
                children.append(entry.name)
                if len(children) > 2:
                    return False
        if not children:
            if expected_identity is None:
                return False
            os.close(directory_fd)
            directory_fd = None
            current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != identity:
                return False
            os.rmdir(name, dir_fd=parent_fd)
            os.fsync(parent_fd)
            return True
        if ARCHIVE_TEMP_MARKER not in children or len(children) not in (1, 2):
            return False
        marker, marker_identity = _read_archive_temp_marker(directory_fd, token)
        if marker is None or not generated_archive_name(stem, marker["archive"]):
            return False
        archive_name = marker["archive"]
        archive_identity = None
        if archive_name in children:
            try:
                before = os.stat(archive_name, dir_fd=directory_fd, follow_symlinks=False)
                flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
                archive_fd = os.open(archive_name, flags, dir_fd=directory_fd)
            except OSError:
                return False
            try:
                opened = os.fstat(archive_fd)
                after = os.stat(archive_name, dir_fd=directory_fd, follow_symlinks=False)
                archive_identity = (opened.st_dev, opened.st_ino)
                if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                        or opened.st_nlink != 1 or opened.st_size < 0
                        or opened.st_size > MAX_BACKUP_ARCHIVE_BYTES
                        or archive_identity != (before.st_dev, before.st_ino)
                        or archive_identity != (after.st_dev, after.st_ino)):
                    return False
            finally:
                os.close(archive_fd)
        elif len(children) != 1:
            return False

        # Unlink only the two names proven to belong to this exact marker-backed
        # transaction. Any unexpected child keeps the whole directory intact.
        if archive_identity is not None:
            current = os.stat(archive_name, dir_fd=directory_fd, follow_symlinks=False)
            if (current.st_dev, current.st_ino) != archive_identity:
                return False
            os.unlink(archive_name, dir_fd=directory_fd)
        current_marker = os.stat(ARCHIVE_TEMP_MARKER, dir_fd=directory_fd, follow_symlinks=False)
        if (current_marker.st_dev, current_marker.st_ino) != marker_identity:
            return False
        os.unlink(ARCHIVE_TEMP_MARKER, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except OSError:
        return False
    finally:
        if directory_fd is not None:
            os.close(directory_fd)

    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != identity:
            return False
        os.rmdir(name, dir_fd=parent_fd)
        os.fsync(parent_fd)
        return True
    except OSError:
        return False


def cleanup_stale_archive_temporary_directories(parent_fd, stem):
    """Clean at most 64 exact installer temp dirs within a 4096-entry scan."""
    pattern = re.compile(rf"\.{re.escape(stem)}-archive-[0-9a-f]{{32}}$")
    names = []
    scanned = 0
    with os.scandir(parent_fd) as entries:
        for entry in entries:
            scanned += 1
            if scanned > MAX_ARCHIVE_TEMP_SCAN_ENTRIES:
                raise RuntimeError(
                    f"Backup folder exceeds the {MAX_ARCHIVE_TEMP_SCAN_ENTRIES}-entry temporary-artifact scan limit."
                )
            if pattern.fullmatch(entry.name):
                names.append(entry.name)
                if len(names) > MAX_ARCHIVE_TEMP_CANDIDATES:
                    raise RuntimeError(
                        f"Backup folder has more than {MAX_ARCHIVE_TEMP_CANDIDATES} temporary-artifact candidates."
                    )
    for name in names:
        cleanup_archive_temporary_directory(parent_fd, name, stem)


def create_archive_temporary_directory(parent_fd, stem, archive_name):
    """Create a private UUID directory and durable marker before ditto writes."""
    if not generated_archive_name(stem, archive_name):
        raise RuntimeError("Refusing to create a temporary archive with an unexpected generated name.")
    token = uuid.uuid4().hex
    name = archive_temporary_directory_name(stem, token)
    created = False
    directory_fd = None
    created_identity = None
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
        created = True
        created_info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (stat.S_ISLNK(created_info.st_mode) or not stat.S_ISDIR(created_info.st_mode)
                or created_info.st_uid != os.geteuid() or stat.S_IMODE(created_info.st_mode) & 0o077):
            raise RuntimeError("New archive temporary directory is not private and owner-owned.")
        created_identity = (created_info.st_dev, created_info.st_ino)
        directory_fd, identity = _safe_archive_temp_directory_fd(
            parent_fd, name, expected_identity=created_identity,
        )
        if directory_fd is None:
            raise RuntimeError("Could not safely open the new private archive temporary directory.")
        os.fchmod(directory_fd, 0o700)
        record = {"archive": archive_name, "schema": 1, "token": token}
        encoded = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        if len(encoded) > MAX_ARCHIVE_TEMP_MARKER_BYTES:
            raise RuntimeError("Archive temporary ownership marker exceeds its size limit.")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        marker_fd = os.open(ARCHIVE_TEMP_MARKER, flags, 0o600, dir_fd=directory_fd)
        try:
            os.fchmod(marker_fd, 0o600)
            marker_info = os.fstat(marker_fd)
            if (not stat.S_ISREG(marker_info.st_mode) or marker_info.st_uid != os.geteuid()
                    or marker_info.st_nlink != 1 or stat.S_IMODE(marker_info.st_mode) != 0o600
                    or marker_info.st_mode & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX)):
                raise RuntimeError("Archive temporary ownership marker is not a private regular file.")
            offset = 0
            while offset < len(encoded):
                written = os.write(marker_fd, encoded[offset:])
                if written <= 0:
                    raise OSError("short write while creating archive temporary ownership marker")
                offset += written
            os.fsync(marker_fd)
        finally:
            os.close(marker_fd)
        os.fsync(directory_fd)
        os.fsync(parent_fd)
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        if (current.st_dev, current.st_ino) != identity:
            raise RuntimeError("Archive temporary directory changed during creation.")
        return name, directory_fd, identity
    except BaseException:
        if directory_fd is not None:
            os.close(directory_fd)
        # Creation failures may leave only this newly generated empty directory.
        # Never recursively remove partially initialized or unrecognized content.
        try:
            if not created:
                raise RuntimeError("Temporary directory was not created by this invocation.")
            current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            if (stat.S_ISDIR(current.st_mode) and current.st_uid == os.geteuid()
                    and created_identity == (current.st_dev, current.st_ino)):
                opened_fd, opened_identity = _safe_archive_temp_directory_fd(
                    parent_fd, name, expected_identity=created_identity,
                )
                if opened_fd is not None:
                    try:
                        with os.scandir(opened_fd) as entries:
                            is_empty = next(entries, None) is None
                        if is_empty and opened_identity == (current.st_dev, current.st_ino):
                            os.rmdir(name, dir_fd=parent_fd)
                            os.fsync(parent_fd)
                    finally:
                        os.close(opened_fd)
        except OSError:
            pass
        raise


def archive(app, support):
    info = identity(app)
    # Complete the bounded source walk before hashing an executable or asking
    # ditto to copy/archive this bundle. Its returned map contains the
    # executable digest, so no unbounded second read is needed.
    inventory = bundle_inventory(app)
    executable_hash, _ = bundle_executable_identity(app, inventory, info)
    backup_folder = Path(support) / "Backups"
    # Validate the directory and any existing journal before considering a
    # reuse path or creating a new recovery archive.
    manifest_records = validate_archive_manifest(support)
    # Scan directory entries incrementally and verify at most the newest safe
    # candidate. A corrupt newest candidate causes a fresh archive; older
    # candidates are retained, but never make startup work grow without bound.
    directory_fd = open_backup_directory(support)
    try:
        cleanup_stale_archive_temporary_directories(directory_fd, app.stem)
        prefix = f"{app.stem}-"
        # Accept both historical names and current UUID-qualified names while
        # counting all matches against the same hard 64-candidate bound.
        suffix = re.compile(rf"-{re.escape(executable_hash[:12])}(?:-[0-9a-f]{{8}})?\.zip$")
        candidates = scan_backup_reuse_candidates(directory_fd, prefix, suffix)
        candidate = max(candidates, key=lambda item: item[0], default=None)
        if candidate is not None:
            candidate_name, expected_identity = candidate
            descriptor = open_backup_reuse_candidate(directory_fd, candidate_name, expected_identity)
            reusable = False
            reusable_record = None
            try:
                with os.fdopen(descriptor, "rb") as candidate_stream:
                    descriptor = None
                    verification_error = None
                    try:
                        candidate_path = str(backup_folder / candidate_name)
                        matching_records = [
                            record for record in manifest_records
                            if record["archive"] == candidate_path
                        ]
                        if len(matching_records) > 1:
                            raise RuntimeError("Multiple archive digest records exist for one candidate.")
                        actual_archive_hash = sha256_open_regular_stream(
                            candidate_stream, maximum_bytes=MAX_BACKUP_ARCHIVE_BYTES,
                        )
                        if (matching_records
                                and (matching_records[0]["executableSHA256"] != executable_hash
                                     or actual_archive_hash != matching_records[0]["archiveSHA256"])):
                            raise RuntimeError("Backup archive digest differs from its manifest record.")
                        preflight_zip_central_directory(candidate_stream)
                        with zipfile.ZipFile(candidate_stream) as bundle:
                            verify_archive_bundle(bundle, app, expected_inventory=inventory)
                        if matching_records:
                            reusable_record = matching_records[0]
                        else:
                            # A crash may occur after the verified archive is renamed
                            # into Backups but before its manifest record is published.
                            # Adopt only an exact generated-name candidate that fully
                            # verifies against the current bundle; never delete or
                            # rewrite the orphan, and keep the existing 64-candidate cap.
                            generated_name = re.fullmatch(
                                re.escape(app.stem)
                                + r"-\d{8}T\d{12}Z-[0-9a-f]{12}-[0-9a-f]{8}\.zip",
                                candidate_name,
                            )
                            if not generated_name:
                                raise RuntimeError("Unjournaled archive does not have an installer-generated name.")
                            reusable_record = {
                                "original": str(app),
                                "archive": candidate_path,
                                "version": info.get("CFBundleShortVersionString"),
                                "build": info.get("CFBundleVersion"),
                                "executableSHA256": executable_hash,
                                "archiveSHA256": actual_archive_hash,
                            }
                            append_archive_manifest(support, reusable_record)
                            manifest_records.append(reusable_record)
                    except (KeyError, OSError, RuntimeError, zipfile.BadZipFile) as error:
                        verification_error = error
                    verify_backup_reuse_candidate_unchanged(
                        directory_fd, candidate_stream.fileno(), candidate_name, expected_identity,
                    )
                    reusable = verification_error is None
            finally:
                if descriptor is not None:
                    os.close(descriptor)
            if reusable:
                candidate_path = backup_folder / candidate_name
                print(f"Reusing verified backup: {candidate_path}", flush=True)
                return {
                    "original": str(app), "archive": str(candidate_path),
                    "version": info.get("CFBundleShortVersionString"),
                    "build": info.get("CFBundleVersion"),
                    "executableSHA256": executable_hash,
                    "archiveSHA256": reusable_record["archiveSHA256"],
                }
            print(f"Ignoring an invalid previous backup: {candidate_name}", flush=True)
    finally:
        os.close(directory_fd)

    name = (f"{app.stem}-{datetime.now(timezone.utc):%Y%m%dT%H%M%S%fZ}-"
            f"{executable_hash[:12]}-{uuid.uuid4().hex[:8]}.zip")
    destination = backup_folder / name
    temporary_parent_fd = open_backup_directory(support)
    try:
        temporary_folder_name, temporary_folder_fd, temporary_folder_identity = (
            create_archive_temporary_directory(temporary_parent_fd, app.stem, name)
        )
    except BaseException:
        os.close(temporary_parent_fd)
        raise
    temporary_folder = backup_folder / temporary_folder_name
    temporary_archive = temporary_folder / name
    try:
        # ditto retains resource forks, extended attributes, permissions, and bundle symlinks.
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(temporary_archive))
        ensure_appledouble_metadata(temporary_archive, app, inventory)
        with temporary_archive.open("rb") as preflight_stream:
            preflight_zip_central_directory(preflight_stream)
        with zipfile.ZipFile(temporary_archive) as bundle:
            verify_archive_bundle(bundle, app, expected_inventory=inventory)
        archive_flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        archive_descriptor = os.open(temporary_archive, archive_flags)
        try:
            archive_info = os.fstat(archive_descriptor)
            archive_path_info = temporary_archive.lstat()
            if (not stat.S_ISREG(archive_info.st_mode) or archive_info.st_uid != os.geteuid()
                    or archive_info.st_nlink != 1 or stat.S_ISLNK(archive_path_info.st_mode)
                    or (archive_info.st_dev, archive_info.st_ino) !=
                       (archive_path_info.st_dev, archive_path_info.st_ino)):
                raise RuntimeError(f"Backup archive changed or is not a private regular file: {temporary_archive}")
            os.fchmod(archive_descriptor, 0o600)
            os.fsync(archive_descriptor)
        finally:
            os.close(archive_descriptor)
        archive_hash = sha256(temporary_archive)
        os.replace(temporary_archive, destination)
        directory_fd = os.open(backup_folder, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        record = {"original": str(app), "archive": str(destination),
                  "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
                  "executableSHA256": executable_hash, "archiveSHA256": archive_hash}
        append_archive_manifest(support, record)
        print(f"Verified backup: {destination}", flush=True)
        return record
    finally:
        os.close(temporary_folder_fd)
        cleanup_archive_temporary_directory(
            temporary_parent_fd, temporary_folder_name, app.stem,
            expected_identity=temporary_folder_identity,
        )
        os.close(temporary_parent_fd)


def repair(support):
    with installation_lock(INSTALLED), launcher_transition_lock():
        check_launcher_handoff()
        result = _repair_locked(support)
        write_evidence(result, support)
        return result


def _repair_locked(support):
    identity(INSTALLED)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(INSTALLED))
    before, stale_apps, stale_plugins = repair_plan()
    # Missing registrations can be pruned independently and safely retried. Live app
    # copies and their extension registrations are deliberately left untouched.
    for plugin in sorted(stale_plugins):
        run("/usr/bin/pluginkit", "-r", str(plugin))
    for app in sorted(stale_apps):
        run(LSREGISTER, "-u", str(app))
    run(LSREGISTER, "-f", "-R", "-trusted", str(INSTALLED))
    register_embedded_open_in_extension(INSTALLED)
    after = audit()
    after["registered"] = [str(p) for p in registrations()]
    after["registeredPlugins"] = sorted(str(p) for p in registered_plugins())
    after["defaultDiscoveredPlugins"] = sorted(str(p) for p in default_discovered_plugins())
    after["discoverable"] = [str(path) for path in discoverable_copies()]
    copies_after = {Path(path) for path in after["copies"]}
    live_extras = sorted({
        path for path in [*(Path(p) for p in after["copies"]), *discoverable_copies(), *registrations()]
        if path != INSTALLED and path.exists()
    })
    # Other dormant development builds are preserved. They do not make the Desktop launcher
    # ambiguous when Launch Services prefers the canonical app and no alternate copy is running;
    # the launcher itself checks every active same-ID process before sending it a playlist.
    expected_open_plugin = embedded_open_in_extension(INSTALLED)
    extension_present = expected_open_plugin.exists()
    extension_registered = extension_present and any(
        same_path(path, expected_open_plugin) for path in after["registeredPlugins"]
    )
    extension_default_discovered = extension_present and any(
        same_path(path, expected_open_plugin) for path in after["defaultDiscoveredPlugins"]
    )
    plugin_check_passed = not extension_present or (extension_registered and extension_default_discovered)
    registered_plugin_paths_present = all(Path(path).exists() for path in after["registeredPlugins"])
    app_selection_ready = canonical_selection_ready(after, INSTALLED)
    registration_clean = app_selection_ready and plugin_check_passed and registered_plugin_paths_present
    return {
        "before": before,
        "after": after,
        "removedStaleAppRegistrations": sorted(str(path) for path in stale_apps),
        "removedStalePluginRegistrations": sorted(str(path) for path in stale_plugins),
        "preservedLiveCopies": [str(path) for path in live_extras],
        "onlyInstalledCopy": not live_extras and copies_after == {INSTALLED},
        "canonicalSelectionReady": app_selection_ready,
        "openExtensionPresent": extension_present,
        "openExtensionRegistered": extension_registered,
        "openExtensionDefaultDiscovered": extension_default_discovered,
        "registeredPluginPathsPresent": registered_plugin_paths_present,
        "registrationClean": registration_clean,
        "destructiveChanges": False,
    }


def write_evidence(result, support):
    folder = support / "Validation"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory_flags = os.O_RDONLY
    directory_flags |= getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory_flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        directory_fd = os.open(folder, directory_flags)
    except OSError as error:
        raise RuntimeError(f"The validation evidence path is not a real directory: {folder}") from error

    directory_info = os.fstat(directory_fd)
    try:
        path_info = os.stat(folder, follow_symlinks=False)
    except OSError:
        os.close(directory_fd)
        raise
    if (not stat.S_ISDIR(directory_info.st_mode) or directory_info.st_uid != os.geteuid()
            or stat.S_ISLNK(path_info.st_mode) or not stat.S_ISDIR(path_info.st_mode)
            or directory_info.st_dev != path_info.st_dev or directory_info.st_ino != path_info.st_ino):
        os.close(directory_fd)
        raise RuntimeError(f"The validation evidence path changed or is not owner-owned: {folder}")

    evidence = folder / (
        f"registration-{datetime.now(timezone.utc):%Y%m%dT%H%M%S%fZ}-{uuid.uuid4().hex[:8]}.json"
    )
    result["evidence"] = str(evidence)
    temporary_name = f".registration-{uuid.uuid4().hex}.tmp"
    file_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    file_flags |= getattr(os, "O_NOFOLLOW", 0)
    file_flags |= getattr(os, "O_CLOEXEC", 0)
    descriptor = None
    published = False
    try:
        descriptor = os.open(temporary_name, file_flags, 0o600, dir_fd=directory_fd)
        with os.fdopen(descriptor, "w") as stream:
            descriptor = None
            stream.write(json.dumps(result, indent=2) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, evidence.name,
                   src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        published = True
        os.fsync(directory_fd)
        return evidence
    except Exception:
        if published:
            try:
                os.unlink(evidence.name, dir_fd=directory_fd)
            except OSError:
                pass
        raise
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temporary_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        os.close(directory_fd)


def install(source, support):
    with installation_lock(INSTALLED), launcher_transition_lock():
        check_launcher_handoff()
        return _install_locked(source, support)


def _install_locked(source, support):
    ensure_clean_checkout()
    source = Path(source).expanduser()
    if source.is_symlink():
        raise RuntimeError("Build source must be an ordinary Reel.app bundle, not a symlink.")
    source = source.resolve()
    source_info = identity(source)
    source_inventory = bundle_inventory(source)
    source_executable_hash, _ = bundle_executable_identity(source, source_inventory, source_info)
    if source == INSTALLED:
        raise RuntimeError("Build source must differ from /Applications/Reel.app.")
    if not source.is_relative_to(Path.home()):
        raise RuntimeError("Local build source must be in the current user's home folder.")
    installed_info = None
    if os.path.lexists(INSTALLED):
        installed_info = identity(INSTALLED)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(INSTALLED))
    candidate_commit = validate_candidate(source_info, installed_info)
    before = audit()
    if before["running"]:
        raise RuntimeError("Close every running Reel copy before replacing /Applications/Reel.app.")
    # A stage without the .app suffix avoids introducing another discoverable application.
    with tempfile.TemporaryDirectory(prefix=".reel-install-", dir=INSTALLED.parent) as folder:
        stage = Path(folder) / "Reel.bundle-stage"
        run("/usr/bin/ditto", str(source), str(stage))
        copied_inventory = bundle_inventory(stage)
        if (normalized_bundle_inventory(source, source_inventory)
                != normalized_bundle_inventory(stage, copied_inventory)):
            raise RuntimeError("Copied Reel bundle inventory differs from the validated build source.")
        copied_executable_hash, _ = bundle_executable_identity(
            stage, copied_inventory, allow_stage=True,
        )
        if copied_executable_hash != source_executable_hash:
            raise RuntimeError("Copied Reel executable differs from the bounded build-source inventory.")
        sign_staged_bundle(stage)
        staged_info = identity(stage, allow_stage=True)
        staged_inventory = bundle_inventory(stage)
        validate_candidate(staged_info, installed_info, checkout_commit=candidate_commit)
        if (staged_info.get("CFBundleVersion") != source_info.get("CFBundleVersion")
                or staged_info.get("CFBundleShortVersionString") != source_info.get("CFBundleShortVersionString")
                or _build_commit(staged_info, "Staged build") != candidate_commit):
            raise RuntimeError("Staged Reel metadata differs from the validated build product.")
        staged_executable_hash, _ = bundle_executable_identity(stage, staged_inventory, staged_info)
        swapped = False
        new_created = False
        backup = None
        try:
            if os.path.lexists(INSTALLED):
                identity(INSTALLED)
                run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(INSTALLED))
                backup = archive(INSTALLED, support)
                if audit()["running"]:
                    raise RuntimeError("A Reel process started during install preparation; the target was not swapped.")
                # Exchange the complete directories in one filesystem operation. The previous app
                # remains at `stage` until verification and registration have succeeded, and there
                # is never a point where the Desktop launcher cannot find /Applications/Reel.app.
                atomic_swap_paths(stage, INSTALLED)
                swapped = True
                fsync_directory(INSTALLED.parent)
            else:
                if audit()["running"]:
                    raise RuntimeError("A Reel process started immediately before initial installation.")
                if os.path.lexists(INSTALLED):
                    raise RuntimeError("A path appeared at /Applications/Reel.app immediately before installation.")
                stage.rename(INSTALLED)
                new_created = True
                fsync_directory(INSTALLED.parent)
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(INSTALLED))
            installed_info = identity(INSTALLED)
            installed_inventory = bundle_inventory(INSTALLED)
            installed_executable_hash, _ = bundle_executable_identity(
                INSTALLED, installed_inventory, installed_info,
            )
            if (installed_executable_hash != staged_executable_hash
                    or installed_info.get("CFBundleVersion") != staged_info.get("CFBundleVersion")
                    or installed_info.get("CFBundleShortVersionString") != staged_info.get("CFBundleShortVersionString")):
                raise RuntimeError("Installed Reel does not match the verified staged build.")
            run(LSREGISTER, "-f", "-R", "-trusted", str(INSTALLED))
            register_embedded_open_in_extension(INSTALLED)
            after = audit()
            after["registered"] = [str(path) for path in registrations()]
            after["registeredPlugins"] = sorted(str(path) for path in registered_plugins())
            after["defaultDiscoveredPlugins"] = sorted(str(path) for path in default_discovered_plugins())
            after["discoverable"] = [str(path) for path in discoverable_copies()]
            plugin_registrations = after["registeredPlugins"]
            default_plugin_matches = after["defaultDiscoveredPlugins"]
            expected_open_plugin = INSTALLED / "Contents/PlugIns/OpenInIINA.appex"
            extension_present = expected_open_plugin.exists()
            extension_registered = extension_present and any(
                same_path(path, expected_open_plugin) for path in plugin_registrations
            )
            extension_default_discovered = extension_present and any(
                same_path(path, expected_open_plugin) for path in default_plugin_matches
            )
            registered_plugin_paths_present = all(Path(path).exists() for path in plugin_registrations)
            registration_ready = (
                canonical_selection_ready(after, INSTALLED)
                and registered_plugin_paths_present
                and (not extension_present or (extension_registered and extension_default_discovered))
            )
            if not registration_ready:
                diagnostic = {
                    "preferred": after.get("preferred"),
                    "canonicalAppRegistered": any(
                        Path(path).resolve() == INSTALLED.resolve()
                        for path in after["registered"]
                    ),
                    "running": after.get("running", []),
                    "openExtensionPresent": extension_present,
                    "openExtensionRegistered": extension_registered,
                    "openExtensionDefaultDiscovered": extension_default_discovered,
                    "registeredExtensionPathsPresent": registered_plugin_paths_present,
                    "registeredExtensionCount": len(plugin_registrations),
                    "defaultDiscoveredExtensionCount": len(default_plugin_matches),
                }
                raise RuntimeError(
                    "The new Reel bundle was swapped, but Launch Services or PlugInKit default "
                    "discovery did not select the canonical app and embedded extension at "
                    "/Applications/Reel.app. "
                    "The installer is restoring the previous bundle. Registration state: "
                    f"{json.dumps(diagnostic, sort_keys=True)}"
                )
            result = {
                "target": str(INSTALLED),
                "source": str(source),
                "version": installed_info.get("CFBundleShortVersionString"),
                "build": installed_info.get("CFBundleVersion"),
                "executableSHA256": installed_executable_hash,
                "previousBackup": backup,
                "before": before,
                "after": after,
                "registrationReady": registration_ready,
                "otherCopiesPreserved": True,
            }
            write_evidence(result, support)
            return result
        except BaseException as error:
            rollback_errors = []
            if swapped:
                try:
                    unregister_embedded_open_in_extension(INSTALLED)
                except Exception as rollback_error:
                    rollback_errors.append(f"unregistering the candidate Open In extension failed: {rollback_error}")
                try:
                    run(LSREGISTER, "-u", str(INSTALLED))
                except Exception as rollback_error:
                    rollback_errors.append(f"unregistering the candidate app failed: {rollback_error}")
                try:
                    atomic_swap_paths(stage, INSTALLED)
                    swapped = False
                    fsync_directory(INSTALLED.parent)
                except Exception as rollback_error:
                    rollback_errors.append(f"atomically restoring the previous app failed: {rollback_error}")
                if not swapped:
                    try:
                        run(LSREGISTER, "-f", "-R", "-trusted", str(INSTALLED))
                    except Exception as rollback_error:
                        rollback_errors.append(f"re-registering the restored app failed: {rollback_error}")
                    try:
                        register_embedded_open_in_extension(INSTALLED)
                    except Exception as rollback_error:
                        rollback_errors.append(f"re-registering the restored Open In extension failed: {rollback_error}")
            elif new_created and INSTALLED.exists():
                try:
                    unregister_embedded_open_in_extension(INSTALLED)
                except Exception as rollback_error:
                    rollback_errors.append(f"unregistering the initial Open In extension failed: {rollback_error}")
                try:
                    run(LSREGISTER, "-u", str(INSTALLED))
                except Exception as rollback_error:
                    rollback_errors.append(f"unregistering the initial app failed: {rollback_error}")
                try:
                    shutil.rmtree(INSTALLED)
                    fsync_directory(INSTALLED.parent)
                except Exception as rollback_error:
                    rollback_errors.append(f"removing the initial app failed: {rollback_error}")
            if rollback_errors:
                backup_path = backup.get("archive") if backup else "no backup was created"
                if swapped and stage.exists():
                    recovery = INSTALLED.parent / f".Reel.app.recovery-{uuid.uuid4().hex[:12]}"
                    try:
                        stage.rename(recovery)
                        fsync_directory(INSTALLED.parent)
                        rollback_errors.append(f"previous bundle retained at {recovery}")
                    except Exception as preserve_error:
                        rollback_errors.append(f"could not preserve staged previous bundle: {preserve_error}")
                raise RuntimeError(
                    f"Install failed ({error}); rollback was incomplete: {'; '.join(rollback_errors)}. "
                    f"Previous-app recovery evidence: {backup_path}."
                ) from error
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["check", "repair", "install"])
    parser.add_argument("app", nargs="?", type=Path, help="local Reel.app build product to install; the source is kept")
    parser.add_argument("--support-folder", type=Path, default=Path.home() / "Documents/IINA")
    args = parser.parse_args()
    if (args.action == "install") != (args.app is not None):
        parser.error("Only install requires an app path.")
    if args.action == "check":
        identity(INSTALLED)
        result = audit()
        result["registered"] = [str(p) for p in registrations()]
        result["registeredPlugins"] = sorted(str(p) for p in registered_plugins())
        result["defaultDiscoveredPlugins"] = sorted(str(p) for p in default_discovered_plugins())
        result["discoverable"] = [str(p) for p in discoverable_copies()]
        print(json.dumps(result, indent=2))
        ready = canonical_selection_ready(result)
        expected_open_plugin = INSTALLED / "Contents/PlugIns/OpenInIINA.appex"
        default_plugin_matches = result["defaultDiscoveredPlugins"]
        extension_present = expected_open_plugin.exists()
        extension_registered = extension_present and any(
            same_path(path, expected_open_plugin) for path in result["registeredPlugins"]
        )
        extension_default_discovered = extension_present and any(
            same_path(path, expected_open_plugin) for path in default_plugin_matches
        )
        plugins_ready = (
            not extension_present or (extension_registered and extension_default_discovered)
        ) and all(Path(path).exists() for path in result["registeredPlugins"])
        if ready and (len(result["copies"]) > 1 or len(result["registered"]) > 1
                      or len(result["discoverable"]) > 1):
            print("Dormant Reel build copies are preserved; the canonical app is preferred. "
                  "The Desktop launcher rejects a conflicting running copy.", file=sys.stderr)
        return 0 if ready and plugins_ready else 1
    support = args.support_folder.expanduser().resolve()
    if args.action == "install":
        result = install(args.app, support)
        evidence = Path(result["evidence"])
    else:
        result = repair(support)
        evidence = Path(result["evidence"])
    if args.action == "install":
        print(f"Installed Reel at {INSTALLED}; other app copies and build products were preserved. Evidence: {evidence}")
        after = result["after"]
        if not canonical_selection_ready(after):
            print("Canonical Reel is installed, but Launch Services selection or running-app state is ambiguous.",
                  file=sys.stderr)
        elif (len(after["copies"]) > 1 or len(after["registered"]) > 1
              or len(after["discoverable"]) > 1):
            print("Dormant Reel build copies remain registered; /Applications/Reel.app is preferred, "
                  "and the Desktop launcher checks active processes before routing.", file=sys.stderr)
    else:
        if result["registrationClean"]:
            if result["openExtensionPresent"]:
                print(f"Canonical Reel and its embedded Open In extension pass PlugInKit's normal reduced match at "
                      f"{INSTALLED}. Evidence: {evidence}")
            else:
                print(f"Canonical Reel is preferred at {INSTALLED}. Evidence: {evidence}")
        else:
            if result["preservedLiveCopies"]:
                detail = "Live copies were preserved for review: " + ", ".join(result["preservedLiveCopies"])
            else:
                detail = "Registration checks still report an ambiguity after stale paths were pruned."
            print(f"Reel was re-registered. {detail} Evidence: {evidence}", file=sys.stderr)
    return 0 if args.action == "install" or result["registrationClean"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error))
