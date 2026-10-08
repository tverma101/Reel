#!/usr/bin/env bash

# Assemble Reel's bundled AirPlay plugin from the pinned upstream release plus
# Reel's small helper hardening patch. The large FFmpeg binary remains the
# verified, unmodified upstream artifact.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
PLUGIN_PATH="$ROOT/deps/plugins"
PATCH_FILE="$SCRIPT_DIR/iina-airplay-reel.patch"
PACKAGE_URL="https://github.com/ozykhan/iina-airplay/releases/download/v0.3.2/iina-airplay.iinaplgz"
PACKAGE_SHA256="277ae8235ebe911d22814022eaf7ab10074a83e58016a2e25d717ae2523e2b6e"
SOURCE_COMMIT="123245a5e9921794caf63fb67ffb04ea9bd8711f"
SOURCE_URL="https://codeload.github.com/ozykhan/iina-airplay/tar.gz/$SOURCE_COMMIT"
SOURCE_SHA256="1a9e63c5679c75f9e76c363aa514703ea4f6b7bc4c709c4cff166c4c4f485900"
FFMPEG_SOURCE_URL="https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz"
FFMPEG_SOURCE_SHA256="cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635"

for tool in curl go node lipo codesign unzip zip patch python3 shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "AirPlay packaging requires '$tool'." >&2
    exit 1
  }
done
[ -f "$PATCH_FILE" ] || { echo "Missing Reel helper patch: $PATCH_FILE" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PLUGIN_PATH" "$WORK/source" "$WORK/package"

curl -fsSL "$PACKAGE_URL" -o "$WORK/upstream.iinaplgz"
printf '%s  %s\n' "$PACKAGE_SHA256" "$WORK/upstream.iinaplgz" | shasum -a 256 -c -
curl -fsSL "$SOURCE_URL" -o "$WORK/upstream-source.tar.gz"
printf '%s  %s\n' "$SOURCE_SHA256" "$WORK/upstream-source.tar.gz" | shasum -a 256 -c -
curl -fsSL "$FFMPEG_SOURCE_URL" -o "$WORK/ffmpeg-9.0.1.tar.xz"
printf '%s  %s\n' "$FFMPEG_SOURCE_SHA256" "$WORK/ffmpeg-9.0.1.tar.xz" | shasum -a 256 -c -
tar -xzf "$WORK/upstream-source.tar.gz" --strip-components=1 -C "$WORK/source"
patch --silent --forward -p1 -d "$WORK/source" < "$PATCH_FILE"

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

unzip -q "$WORK/upstream.iinaplgz" -d "$WORK/package"
cp "$WORK/source/LICENSE" "$WORK/package/LICENSE"
install -m 755 "$WORK/airplay-helper-unsigned" "$WORK/package/bin/airplay-helper"
install -m 644 "$WORK/ffmpeg-9.0.1.tar.xz" "$WORK/package/bin/ffmpeg-9.0.1.tar.xz"

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
manifest.pop("ghRepo", None)
manifest.pop("ghVersion", None)
manifest["version"] = "0.3.2-reel.1"
manifest["description"] = (manifest.get("description", "")
                            .replace("IINA stays your remote.", "Reel stays your remote."))
manifest_file.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

plugin_file = pathlib.Path(plugin_path)
plugin = plugin_file.read_text(encoding="utf-8")
replacements = {
    "reinstall the plugin through IINA (Settings → Plugins → Install)":
        "reinstall the plugin through Reel (Settings → Plugins → Install)",
    "cannot determine IINA process id": "cannot determine Reel process id",
}
for old, new in replacements.items():
    count = plugin.count(old)
    expected = 2 if old.startswith("cannot determine") else 1
    if count != expected:
        raise SystemExit(f"Expected {expected} occurrence(s) of {old!r}, found {count}")
    plugin = plugin.replace(old, new)
plugin_file.write_text(plugin, encoding="utf-8")

versions_file = pathlib.Path(versions_path)
values = {}
for line in versions_file.read_text(encoding="utf-8").splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        values[key] = value
values["helper_version"] = "0.3.2-reel.1"
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

cat > "$WORK/package/REEL-AIRPLAY-SOURCE.md" <<EOF
# Reel AirPlay component sources

Reel bundles [ozykhan/iina-airplay](https://github.com/ozykhan/iina-airplay) v0.3.2.
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

chmod 755 "$WORK/package/bin/ffmpeg" "$WORK/package/bin/airplay-helper"
(
  cd "$WORK/package"
  zip -q -X -r "$WORK/iina-airplay.iinaplgz" .
)
unzip -tq "$WORK/iina-airplay.iinaplgz"
unzip -p "$WORK/iina-airplay.iinaplgz" Info.json | python3 -c '
import json, sys
manifest = json.load(sys.stdin)
assert manifest["identifier"] == "dev.faruk.iina-airplay"
assert "ghRepo" not in manifest and "ghVersion" not in manifest
assert manifest["version"] == "0.3.2-reel.1"
'
mv -f "$WORK/iina-airplay.iinaplgz" "$PLUGIN_PATH/iina-airplay.iinaplgz"
echo "Prepared Reel AirPlay package: $PLUGIN_PATH/iina-airplay.iinaplgz"
shasum -a 256 "$PLUGIN_PATH/iina-airplay.iinaplgz"
