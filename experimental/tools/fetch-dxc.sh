#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Experimental v2 tooling — not part of the published npm package.
#
# Downloads the right Microsoft.Direct3D.DXC build from nuget.org and
# extracts the win-x64 dxc.exe + dxcompiler.dll (+ dxil.dll, when the package
# ships one) into experimental/tools/dxc/<version>/x64/.
#
# Version selection: this repo/tool has no host machine anywhere with a real
# DXC install to fall back on, and the mesh-nodes-preview DXC build is the
# only one able to compile a `NodeLaunch("mesh")` node at all (mesh nodes
# were still preview-only as of the DXC versions published so far) — so:
#
#   - if any *.hlsl/*.hlsli file under the given path(s) contains the raw
#     text `NodeLaunch("mesh")`, pin to 1.8.2404.55-mesh-nodes-preview
#   - otherwise fetch whatever nuget.org currently reports as the latest
#     stable (non-prerelease) release
#
# This is a plain text scan, deliberately not preprocessor-aware — the same
# question ("could this tree need the mesh-capable compiler at all") the
# current regex-based tool would face, before any dxc invocation exists to
# resolve #ifdefs for us.
#
# Usage: fetch-dxc.sh [hlslPath...]
#   hlslPath defaults to experimental/hlsl (this repo's fixtures).
#
# On stdout: the resulting DXC directory (experimental/tools/dxc/<version>/x64),
# so this composes as e.g. DXC_DIR="$(fetch-dxc.sh)".
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTAL_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_ROOT="$EXPERIMENTAL_DIR/tools/dxc"

PACKAGE_ID="Microsoft.Direct3D.DXC"
PACKAGE_ID_LOWER="microsoft.direct3d.dxc"
MESH_PREVIEW_VERSION="1.8.2404.55-mesh-nodes-preview"

hlsl_paths=("$@")
if [ ${#hlsl_paths[@]} -eq 0 ]; then
    hlsl_paths=("$EXPERIMENTAL_DIR/hlsl")
fi

echo "Scanning for mesh-launch nodes under: ${hlsl_paths[*]}" >&2
if grep -rlIiE 'NodeLaunch[[:space:]]*\([[:space:]]*"mesh"' \
        --include='*.hlsl' --include='*.hlsli' \
        "${hlsl_paths[@]}" >&2; then
    echo "-> found a mesh-launch node, pinning to $MESH_PREVIEW_VERSION" >&2
    version="$MESH_PREVIEW_VERSION"
else
    echo "-> no mesh-launch node found, resolving latest stable release from nuget.org" >&2
    version="$(curl -fsSL "https://azuresearch-usnc.nuget.org/query?q=packageid:${PACKAGE_ID}&prerelease=false" \
        | node -e 'const d=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(d.data[0].version)')"
    echo "-> latest stable release is $version" >&2
fi

out_dir="$CACHE_ROOT/$version/x64"
dxc_exe="$out_dir/dxc.exe"

if [ -f "$dxc_exe" ]; then
    echo "already fetched: $out_dir" >&2
    echo "$out_dir"
    exit 0
fi

nupkg_url="https://api.nuget.org/v3-flatcontainer/${PACKAGE_ID_LOWER}/${version}/${PACKAGE_ID_LOWER}.${version}.nupkg"
nupkg_path="$CACHE_ROOT/$version/$(basename "$nupkg_url")"
mkdir -p "$(dirname "$nupkg_path")"

echo "downloading $nupkg_url" >&2
curl -fL --progress-bar -o "$nupkg_path" "$nupkg_url"

echo "extracting win-x64 binaries" >&2
node "$SCRIPT_DIR/extract-nupkg-entries.js" "$nupkg_path" "$out_dir" \
    build/native/bin/x64/dxc.exe \
    build/native/bin/x64/dxcompiler.dll

# dxil.dll (the DXIL validator/signer) isn't shipped by every version — e.g.
# the mesh-nodes-preview package has none at all. It's only needed to run
# the container validator; run-dxc.sh passes -Vd (skip validation) when it's
# absent, so treat this extraction as best-effort.
node "$SCRIPT_DIR/extract-nupkg-entries.js" "$nupkg_path" "$out_dir" \
    build/native/bin/x64/dxil.dll 2>/dev/null \
    && echo "extracted dxil.dll (validator available)" >&2 \
    || echo "no dxil.dll in this package (fine — run-dxc.sh will pass -Vd)" >&2

rm -f "$nupkg_path"

echo "fetched: $out_dir" >&2
echo "$out_dir"
