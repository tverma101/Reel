#!/usr/bin/env bash

# Assemble Reel's bundled AirPlay plugin from the pinned upstream release plus
# Reel's small helper hardening patch. The large FFmpeg binary remains the
# verified, unmodified upstream artifact.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_PATH="$ROOT/deps/plugins"
PATCH_FILE="$SCRIPT_DIR/iina-airplay-reel.patch"
ARCHIVE_HELPERS="$SCRIPT_DIR/check_airplay_package_integrity_archive.sh"
PACKAGE_URL="https://github.com/ozykhan/iina-airplay/releases/download/v0.4.0/iina-airplay.iinaplgz"
PACKAGE_SHA256="6bad39d1d05f7c0c6f335248e557092e2a5a0fe1f99662b53c9f3f6cd6ef71fe"
SOURCE_COMMIT="7c2bfe839b1370bcbb322e9b0662a4f06857fb2d"
SOURCE_URL="https://codeload.github.com/ozykhan/iina-airplay/tar.gz/$SOURCE_COMMIT"
SOURCE_SHA256="a81ad8188c15fa895c8e606b0658388c43257c0d129fae2587ee7e5c4982dd8d"
FFMPEG_SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz"
FFMPEG_SOURCE_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"

for tool in curl go node lipo codesign unzip zip patch python3 shasum cmp install; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "AirPlay packaging requires '$tool'." >&2
    exit 1
  }
done
[ -f "$PATCH_FILE" ] || { echo "Missing Reel helper patch: $PATCH_FILE" >&2; exit 1; }
[ -f "$ARCHIVE_HELPERS" ] || { echo "Missing deterministic archive helpers: $ARCHIVE_HELPERS" >&2; exit 1; }
source "$ARCHIVE_HELPERS"
bash "$SCRIPT_DIR/check_airplay_package_integrity_determinism.sh"

# Patch timestamps are intentionally omitted from unified headers so the same
# exact-source diff has the same hash on every checkout and regeneration.
if ! awk '/^(---|\+\+\+) / && index($0, "\t") { bad = 1 } END { exit bad }' "$PATCH_FILE"; then
  echo "AirPlay patch contains timestamped file headers; normalize them before packaging." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PLUGIN_PATH" "$WORK/source" "$WORK/package"

# The sink enforces a hard byte ceiling even when the server omits or lies
# about Content-Length. curl's deadline bounds slow/stalled transfers; the
# pipefail setting makes either curl or the bounded sink failure fatal.
cat > "$WORK/bounded_download.py" <<'PY'
import pathlib
import sys

limit = int(sys.argv[1])
path = pathlib.Path(sys.argv[2])
total = 0
with path.open("wb") as output:
    while True:
        remaining = limit - total
        # Read at most one byte beyond the destination cap so we can
        # distinguish an exactly-sized stream from an oversized one.
        chunk = sys.stdin.buffer.read(min(64 * 1024, remaining + 1))
        if not chunk:
            break
        if total + len(chunk) > limit:
            raise SystemExit(f"download exceeded the {limit} byte limit")
        output.write(chunk)
        total += len(chunk)
PY

printf '12345' | python3 "$WORK/bounded_download.py" 5 "$WORK/bounded-exact"
if printf '123456' | python3 "$WORK/bounded_download.py" 5 "$WORK/bounded-over" 2>/dev/null; then
  echo "Bounded AirPlay downloader accepted a payload above its byte limit." >&2
  exit 1
fi
python3 - "$WORK/bounded-exact" "$WORK/bounded-over" <<'PY'
import pathlib
import sys

exact, over = map(pathlib.Path, sys.argv[1:])
if exact.read_bytes() != b"12345" or over.read_bytes() != b"":
    raise SystemExit("bounded downloader size smoke test failed")
PY

download_limited() {
  local url="$1" limit="$2" destination="$3"
  curl -q -fsSL --connect-timeout 20 --max-time 300 "$url" |
    python3 "$WORK/bounded_download.py" "$limit" "$destination"
}

download_limited "$PACKAGE_URL" "$((64 * 1024 * 1024))" "$WORK/upstream.iinaplgz"
printf '%s  %s\n' "$PACKAGE_SHA256" "$WORK/upstream.iinaplgz" | shasum -a 256 -c -
download_limited "$SOURCE_URL" "$((16 * 1024 * 1024))" "$WORK/upstream-source.tar.gz"
printf '%s  %s\n' "$SOURCE_SHA256" "$WORK/upstream-source.tar.gz" | shasum -a 256 -c -
download_limited "$FFMPEG_SOURCE_URL" "$((32 * 1024 * 1024))" "$WORK/ffmpeg-9.0.1.tar.xz"
printf '%s  %s\n' "$FFMPEG_SOURCE_SHA256" "$WORK/ffmpeg-9.0.1.tar.xz" | shasum -a 256 -c -
tar -xzf "$WORK/upstream-source.tar.gz" --strip-components=1 -C "$WORK/source"
unzip -q "$WORK/upstream.iinaplgz" -d "$WORK/package"
airplay_require_regular_file "$WORK/package/bin/ffmpeg-LICENSE.md" "upstream FFmpeg license notice"
airplay_require_regular_file "$WORK/package/bin/COPYING.LGPLv2.1" "upstream LGPL license text"
cp "$WORK/package/bin/ffmpeg-LICENSE.md" "$WORK/upstream-ffmpeg-LICENSE.md"
cp "$WORK/package/bin/COPYING.LGPLv2.1" "$WORK/upstream-COPYING.LGPLv2.1"
# The release bundle and source archive are both pinned. Require their raw
# plugin inputs to match before applying Reel's source patch; the patched files
# are then copied into the package as intentional Reel-specific changes.
for file in Info.json main.js sidebar.html preferences.html; do
  source_file="$WORK/source/$file"
  if [ "$file" = "preferences.html" ]; then
    source_file="$WORK/source/plugin/$file"
  elif [ "$file" != "Info.json" ]; then
    source_file="$WORK/source/plugin/$file"
  fi
  if ! cmp -s "$source_file" "$WORK/package/$file"; then
    echo "Pinned release package and source disagree at $file." >&2
    exit 1
  fi
done

# Zero fuzz plus a dry run makes upstream drift or a stale patch fail before
# any helper is built or package artifact is written. A shifted hunk is also a
# mismatch: this patch is for the exact source archive hash above.
if ! PATCH_CHECK_OUTPUT="$(patch --dry-run --batch --forward -F 0 -p1 -d "$WORK/source" < "$PATCH_FILE" 2>&1)"; then
  printf '%s\n' "$PATCH_CHECK_OUTPUT" >&2
  echo "Reel AirPlay patch does not apply cleanly to the pinned source." >&2
  exit 1
fi
case "$PATCH_CHECK_OUTPUT" in
  *offset*|*fuzz*)
    printf '%s\n' "$PATCH_CHECK_OUTPUT" >&2
    echo "Reel AirPlay patch used shifted or fuzzy context." >&2
    exit 1
    ;;
esac
printf '%s\n' "$PATCH_CHECK_OUTPUT"
patch --silent --batch --forward -F 0 -p1 -d "$WORK/source" < "$PATCH_FILE"

# The pinned release plugin is the patched source plus these intentional Reel
# labels. Apply them to the source before comparing and installing it so the
# package cannot silently drift from either input or lose its Reel branding on
# a future rebuild.
python3 - "$WORK/source/plugin/main.js" "$WORK/source/plugin/tests/runtime.test.mjs" <<'PY'
import pathlib
import sys

updates = (
    (
        pathlib.Path(sys.argv[1]),
        {
            "reinstall the plugin through IINA (Settings → Plugins → Install)":
                ("reinstall the plugin through Reel (Settings → Plugins → Install)", 1),
            "cannot determine IINA process id": ("cannot determine Reel process id", 2),
        },
    ),
    (
        pathlib.Path(sys.argv[2]),
        {"assert.match(s.msg, /IINA/);": ("assert.match(s.msg, /Reel/);", 1)},
    ),
)
for path, replacements in updates:
    source = path.read_text(encoding="utf-8")
    for old, (new, expected) in replacements.items():
        count = source.count(old)
        if count != expected:
            raise SystemExit(f"Expected {expected} occurrence(s) of {old!r} in {path}, found {count}")
        source = source.replace(old, new)
    path.write_text(source, encoding="utf-8")
PY

(
  cd "$WORK/source/helper"
  go test ./...
)
(
  cd "$WORK/source"
  node --test plugin/tests/*.test.mjs
)

for goarch in arm64 amd64; do
  (
    cd "$WORK/source/helper"
    CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" \
      go build -trimpath -ldflags='-s -w' -o "$WORK/airplay-helper-$goarch" .
  )
done
lipo -create "$WORK/airplay-helper-arm64" "$WORK/airplay-helper-amd64" \
  -output "$WORK/airplay-helper-unsigned"
codesign --force --sign - "$WORK/airplay-helper-unsigned"
codesign --verify --strict "$WORK/airplay-helper-unsigned"
ARCHS="$(lipo -archs "$WORK/airplay-helper-unsigned")"
case " $ARCHS " in *' arm64 '*) ;; *) echo "AirPlay helper is missing arm64." >&2; exit 1 ;; esac
case " $ARCHS " in *' x86_64 '*) ;; *) echo "AirPlay helper is missing x86_64." >&2; exit 1 ;; esac

cp "$WORK/source/LICENSE" "$WORK/package/LICENSE"
install -m 644 "$WORK/source/plugin/main.js" "$WORK/package/main.js"
install -m 644 "$WORK/source/plugin/sidebar.html" "$WORK/package/sidebar.html"
install -m 644 "$WORK/source/plugin/preferences.html" "$WORK/package/preferences.html"
install -m 755 "$WORK/airplay-helper-unsigned" "$WORK/package/bin/airplay-helper"
install -m 644 "$WORK/ffmpeg-9.0.1.tar.xz" "$WORK/package/bin/ffmpeg-9.0.1.tar.xz"
airplay_assert_files_equal "$WORK/source/LICENSE" "$WORK/package/LICENSE" "packaged MIT license"
airplay_assert_files_equal "$WORK/upstream-COPYING.LGPLv2.1" \
  "$WORK/package/bin/COPYING.LGPLv2.1" "packaged FFmpeg LGPL license text"
airplay_assert_sha256 "$WORK/package/bin/ffmpeg-9.0.1.tar.xz" "$FFMPEG_SOURCE_SHA256" \
  "packaged FFmpeg source tarball"

PATCH_SHA256="$(shasum -a 256 "$PATCH_FILE" | cut -d ' ' -f 1)"
HELPER_SHA256="$(shasum -a 256 "$WORK/package/bin/airplay-helper" | cut -d ' ' -f 1)"
python3 - "$WORK/package/Info.json" "$WORK/package/main.js" \
  "$WORK/package/bin/VERSIONS" "$WORK/package/bin/ffmpeg-LICENSE.md" \
  "$HELPER_SHA256" "$SOURCE_COMMIT" "$SOURCE_SHA256" "$PATCH_SHA256" "$FFMPEG_SOURCE_SHA256" <<'PY'
import json
import pathlib
import sys

manifest_path, plugin_path, versions_path, ffmpeg_license_path, helper_hash, commit, source_hash, patch_hash, ffmpeg_source_hash = sys.argv[1:]
manifest_file = pathlib.Path(manifest_path)
manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
if manifest.get("identifier") != "dev.faruk.iina-airplay":
    raise SystemExit("Unexpected upstream AirPlay plugin identifier")
if manifest.get("version") != "0.4.0":
    raise SystemExit("Unexpected upstream AirPlay plugin version")
if manifest.get("ghRepo") != "ozykhan/iina-airplay" or manifest.get("ghVersion") != 6:
    raise SystemExit("Unexpected upstream AirPlay update source")
upstream_description = ("Cast the current file to an AirPlay device: remuxes to HLS, "
                        "serves on the LAN, and hands the stream to the TV. "
                        "IINA stays your remote.")
if manifest.get("description") != upstream_description:
    raise SystemExit("Unexpected upstream AirPlay plugin description")
# Keep repository provenance so Reel can allow only this maintained package to
# run its helper-only callback after mpv shutdown. Omitting ghVersion keeps the
# generic plugin auto-updater disabled; Reel ships reviewed package updates.
manifest.pop("ghVersion", None)
manifest["version"] = "0.4.0-reel.1"
manifest["description"] = ("Cast local video files to an AirPlay device: remuxes to HLS, "
                            "serves on the LAN, and hands the stream to the TV. "
                            "Reel stays your remote.")
manifest_file.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

versions_file = pathlib.Path(versions_path)
values = {}
for line_number, line in enumerate(versions_file.read_text(encoding="utf-8").splitlines(), start=1):
    if not line or "=" not in line:
        raise SystemExit(f"Malformed upstream VERSIONS line {line_number}")
    key, value = line.split("=", 1)
    if not key or not value or key in values:
        raise SystemExit(f"Malformed or duplicate upstream VERSIONS key on line {line_number}")
    values[key] = value
values["helper_version"] = "0.4.0-reel.1"
values["helper_sha256"] = helper_hash
values["airplay_source_commit"] = commit
values["airplay_source_archive_sha256"] = source_hash
values["reel_helper_patch_sha256"] = patch_hash
versions_file.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")

ffmpeg_license_file = pathlib.Path(ffmpeg_license_path)
ffmpeg_license = ffmpeg_license_file.read_text(encoding="utf-8")
marker = "- Upstream source: "
source_notice = ("- Complete matching source tarball included as "
                 f"`bin/ffmpeg-9.0.1.tar.xz`; SHA-256: `{ffmpeg_source_hash}`.\n")
if ffmpeg_license.count(marker) != 1:
    raise SystemExit("Could not add the matching FFmpeg source notice")
ffmpeg_license_file.write_text(ffmpeg_license.replace(marker, source_notice + marker), encoding="utf-8")
PY

python3 - "$WORK/upstream-ffmpeg-LICENSE.md" "$WORK/package/bin/ffmpeg-LICENSE.md" \
  "$FFMPEG_SOURCE_SHA256" "$SOURCE_COMMIT" <<'PY'
import pathlib
import sys

upstream_path, packaged_path, source_hash, source_commit = sys.argv[1:]
upstream = pathlib.Path(upstream_path).read_text(encoding="utf-8")
packaged = pathlib.Path(packaged_path).read_text(encoding="utf-8")
marker = "- Upstream source: "
notice = ("- Complete matching source tarball included as "
          f"`bin/ffmpeg-9.0.1.tar.xz`; SHA-256: `{source_hash}`.\n")
if upstream.count(marker) != 1 or upstream.count(notice) != 0:
    raise SystemExit("Unexpected upstream FFmpeg source-notice template")
expected = upstream.replace(marker, notice + marker, 1)
if packaged != expected:
    raise SystemExit("Packaged FFmpeg license/source notice differs from the exact expected text")
required_text = (
    "under the GNU Lesser General Public License version 2.1 or later.",
    "configured with LGPL-licensed components only: no GPL components are enabled",
    notice.rstrip("\n"),
    f"- Upstream source: https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz",
    f"- Source SHA-256: {source_hash}",
    f"packaging/build-ffmpeg.sh` in https://github.com/ozykhan/iina-airplay at commit `{source_commit}`",
    "A copy of the license text is included alongside this file as",
)
for text in required_text:
    if packaged.count(text) != 1:
        raise SystemExit(f"Missing or duplicate expected FFmpeg license/provenance text: {text}")
PY

cat > "$WORK/package/REEL-AIRPLAY-SOURCE.md" <<EOF
# Reel AirPlay component sources

Reel bundles [ozykhan/iina-airplay](https://github.com/ozykhan/iina-airplay) v0.4.0.
The plugin and helper source is pinned to commit \`$SOURCE_COMMIT\`;
the source archive SHA-256 is \`$SOURCE_SHA256\`. Reel's helper changes are
published in \`other/iina-airplay-reel.patch\` in the Reel source repository
(SHA-256 \`$PATCH_SHA256\`). The plugin's MIT license is included as \`LICENSE\`.

The FFmpeg 9.0.1 binary is unmodified from the upstream release package. Its
complete matching source tarball is included as \`bin/ffmpeg-9.0.1.tar.xz\`
(SHA-256 \`$FFMPEG_SOURCE_SHA256\`). Its LGPL 2.1-or-later notice, license
text, exact source URL and build-recipe link are included in
\`bin/ffmpeg-LICENSE.md\` and \`bin/COPYING.LGPLv2.1\`.
EOF

python3 - "$WORK/package/bin/VERSIONS" "$WORK/package/bin/airplay-helper" \
  "$WORK/package/bin/ffmpeg" "$HELPER_SHA256" "$FFMPEG_SOURCE_SHA256" \
  "$SOURCE_COMMIT" "$SOURCE_SHA256" "$PATCH_SHA256" <<'PY'
import hashlib
import pathlib
import re
import sys

versions_path, helper_path, ffmpeg_path, helper_hash, ffmpeg_source_hash, commit, source_hash, patch_hash = sys.argv[1:]
versions_file = pathlib.Path(versions_path)
values = {}
for line_number, line in enumerate(versions_file.read_text(encoding="utf-8").splitlines(), start=1):
    if not line or "=" not in line:
        raise SystemExit(f"Malformed packaged VERSIONS line {line_number}")
    key, value = line.split("=", 1)
    if not key or not value or key in values:
        raise SystemExit(f"Malformed or duplicate packaged VERSIONS key on line {line_number}")
    values[key] = value

def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()

expected = {
    "helper_version": "0.4.0-reel.1",
    "helper_sha256": helper_hash,
    "ffmpeg_version": "9.0.1",
    "ffmpeg_source_sha256": ffmpeg_source_hash,
    "airplay_source_commit": commit,
    "airplay_source_archive_sha256": source_hash,
    "reel_helper_patch_sha256": patch_hash,
}
for key, value in expected.items():
    if values.get(key) != value:
        raise SystemExit(f"Packaged VERSIONS provenance mismatch for {key}")

for key in ("helper_sha256", "ffmpeg_sha256"):
    if not re.fullmatch(r"[0-9a-f]{64}", values.get(key, "")):
        raise SystemExit(f"Packaged VERSIONS contains a malformed {key}")
actual_hashes = {
    "helper_sha256": sha256_file(helper_path),
    "ffmpeg_sha256": sha256_file(ffmpeg_path),
}
for key, actual in actual_hashes.items():
    if values[key] != actual:
        raise SystemExit(f"Packaged {key} does not match the executable bytes")
if actual_hashes["helper_sha256"] != helper_hash:
    raise SystemExit("Built helper hash changed before final packaging")
PY

python3 - "$WORK/package/REEL-AIRPLAY-SOURCE.md" "$SOURCE_COMMIT" "$SOURCE_SHA256" \
  "$PATCH_SHA256" "$FFMPEG_SOURCE_SHA256" <<'PY'
import pathlib
import sys

path, commit, source_hash, patch_hash, ffmpeg_source_hash = sys.argv[1:]
provenance = pathlib.Path(path).read_text(encoding="utf-8")
expected_fragments = (
    "Reel bundles [ozykhan/iina-airplay](https://github.com/ozykhan/iina-airplay) v0.4.0.",
    f"The plugin and helper source is pinned to commit `{commit}`;",
    f"the source archive SHA-256 is `{source_hash}`.",
    f"(SHA-256 `{patch_hash}`). The plugin's MIT license is included as `LICENSE`.",
    "The FFmpeg 9.0.1 binary is unmodified from the upstream release package.",
    f"(SHA-256 `{ffmpeg_source_hash}`). Its LGPL 2.1-or-later notice, license",
    "text, exact source URL and build-recipe link are included in",
    "`bin/ffmpeg-LICENSE.md` and `bin/COPYING.LGPLv2.1`.",
)
for fragment in expected_fragments:
    if provenance.count(fragment) != 1:
        raise SystemExit(f"Missing or duplicate expected AirPlay provenance text: {fragment}")
PY

chmod 755 "$WORK/package/bin/ffmpeg" "$WORK/package/bin/airplay-helper"
airplay_create_deterministic_archive "$WORK/package" "$WORK/iina-airplay.iinaplgz" \
  "$WORK/package-entries.txt"
unzip -tq "$WORK/iina-airplay.iinaplgz"
unzip -Z1 "$WORK/iina-airplay.iinaplgz" | cmp - "$WORK/package-entries.txt"
while IFS= read -r file; do
  airplay_assert_archive_entry_matches_file "$WORK/iina-airplay.iinaplgz" "$file" \
    "$WORK/package/$file" "packaged $file"
done < "$WORK/package-entries.txt"
unzip -p "$WORK/iina-airplay.iinaplgz" Info.json | python3 -c '
import json, sys
manifest = json.load(sys.stdin)
assert manifest["identifier"] == "dev.faruk.iina-airplay"
assert manifest.get("ghRepo") == "ozykhan/iina-airplay"
assert "ghVersion" not in manifest
assert manifest["version"] == "0.4.0-reel.1"
assert manifest["description"].startswith("Cast local video files to an AirPlay device:")
assert manifest["preferencesPage"] == "preferences.html"
'
mv -f "$WORK/iina-airplay.iinaplgz" "$PLUGIN_PATH/iina-airplay.iinaplgz"
echo "Prepared Reel AirPlay package: $PLUGIN_PATH/iina-airplay.iinaplgz"
shasum -a 256 "$PLUGIN_PATH/iina-airplay.iinaplgz"
