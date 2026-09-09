#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Experimental v2 tooling — not part of the published npm package.
#
# Fetches (via fetch-dxc.sh, cached) and runs dxc against the fixtures in
# experimental/hlsl, to see what dxc itself can tell us about a work graph's
# structure — as a candidate replacement for this tool's current
# regex/paren-balance scan, especially around #define/#ifdef resolution and
# dead-code elimination that the regex scanner can't do at all.
#
# dxc.exe is a native Windows PE binary — nuget.org's Microsoft.Direct3D.DXC
# package ships no Linux build, at any version checked so far. On Linux this
# script runs it through `wine64`; on native Windows it runs it directly.
#
# Usage:
#   run-dxc.sh [options] [sourceFile]
#
# Options:
#   --entry NAME       For a lib_* profile: restrict the compiled library to
#                       this export only (dxc `-exports NAME`). For a
#                       non-lib profile: the single entry point (`-E NAME`).
#                       Repeatable. Default: none (lib profile: export every
#                       [Shader("node")] function found, i.e. the whole
#                       graph; non-lib profile: dxc's own default of "main").
#   --profile PROFILE  Target profile passed as `-T`. Default: lib_6_8
#                       (required for work graphs).
#   --define KEY=VAL   Preprocessor define, passed as `-D KEY=VAL`.
#                       Repeatable. Pass `--define ENABLE_MESH_PATH=1` to
#                       pull the mesh-launch fixture node into the compile.
#   --mode MODE        preprocess | compile | both. Default: both.
#                         preprocess: `dxc -P` — dumps the fully macro- and
#                           #if-resolved source, no compilation. Directly
#                           shows what dxc's preprocessor did with
#                           --define/#ifdef, nothing a regex scanner sees.
#                         compile: full `-T <profile>` compile, emitting the
#                           compiled container (-Fo) and its disassembly
#                           (-Fc) — the disassembly's metadata blocks
#                           (!dx.entryPoints etc.) describe every compiled
#                           node's launch mode/records/dispatch grid as dxc
#                           actually resolved them, which is the main thing
#                           worth comparing against the regex scanner.
#   --out-dir DIR       Where to write outputs. Default: experimental/out.
#
# sourceFile defaults to experimental/hlsl/WorkGraph.hlsl.
#
# Anything after a bare `--` is passed through to dxc verbatim.
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPERIMENTAL_DIR="$(dirname "$SCRIPT_DIR")"

profile="lib_6_8"
mode="both"
out_dir="$EXPERIMENTAL_DIR/out"
source_file=""
entries=()
defines=()
extra_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --entry) entries+=("$2"); shift 2 ;;
        --profile) profile="$2"; shift 2 ;;
        --define) defines+=("$2"); shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        --out-dir) out_dir="$2"; shift 2 ;;
        --) shift; extra_args+=("$@"); break ;;
        -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            if [ -n "$source_file" ]; then
                echo "unexpected extra argument: $1 (source file already set to $source_file)" >&2
                exit 1
            fi
            source_file="$1"
            shift
            ;;
    esac
done

source_file="${source_file:-$EXPERIMENTAL_DIR/hlsl/WorkGraph.hlsl}"
source_file="$(cd "$(dirname "$source_file")" && pwd)/$(basename "$source_file")"

case "$mode" in
    preprocess|compile|both) ;;
    *) echo "--mode must be one of: preprocess, compile, both (got: $mode)" >&2; exit 1 ;;
esac

dxc_dir="$("$SCRIPT_DIR/fetch-dxc.sh" "$(dirname "$source_file")")"
dxc_exe="$dxc_dir/dxc.exe"
[ -f "$dxc_exe" ] || { echo "expected dxc.exe at $dxc_exe after fetch-dxc.sh — see its output above" >&2; exit 1; }

mkdir -p "$out_dir"
stem="$(basename "$source_file" .hlsl)"

runner=()
case "$(uname -s)" in
    Linux|Darwin)
        command -v wine64 >/dev/null 2>&1 || command -v wine >/dev/null 2>&1 || {
            echo "dxc.exe is a native Windows binary and no 'wine'/'wine64' was found on PATH." >&2
            echo "Install wine64 (e.g. 'apt-get install wine64' on Debian/Ubuntu) or run this" >&2
            echo "script on Windows / a machine with WSL Windows-interop enabled." >&2
            exit 1
        }
        export WINEDEBUG="${WINEDEBUG:--all}"
        # dxc.exe needs neither .NET (mono) nor an embedded browser (mshtml);
        # disabling both up front skips wine's first-run installer prompts.
        export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
        runner=("$(command -v wine64 || command -v wine)")
        ;;
    *)
        runner=()
        ;;
esac

to_win_path() {
    # wine accepts POSIX paths for arguments directly (Z: maps to /), so no
    # translation is needed beyond making the path absolute — kept as a
    # named step in case a future platform needs real translation here.
    printf '%s' "$1"
}

define_args=()
if [ ${#defines[@]} -gt 0 ]; then
    for d in "${defines[@]}"; do
        define_args+=("-D" "$d")
    done
fi

entry_args=()
is_lib_profile=0
case "$profile" in lib_*) is_lib_profile=1 ;; esac
if [ ${#entries[@]} -gt 0 ]; then
    if [ "$is_lib_profile" -eq 1 ]; then
        joined="$(IFS=,; echo "${entries[*]}")"
        entry_args=("-exports" "$joined")
    else
        entry_args=("-E" "${entries[0]}")
    fi
fi

validator_args=()
[ -f "$dxc_dir/dxil.dll" ] || validator_args=("-Vd")

run_dxc() {
    echo "+ dxc $*" >&2
    if [ ${#runner[@]} -gt 0 ]; then
        "${runner[@]}" "$(to_win_path "$dxc_exe")" "$@"
    else
        "$(to_win_path "$dxc_exe")" "$@"
    fi
}

if [ "$mode" = "preprocess" ] || [ "$mode" = "both" ]; then
    pre_out="$out_dir/$stem.i.hlsl"
    run_dxc -P -Fi "$(to_win_path "$pre_out")" "${define_args[@]}" "$(to_win_path "$source_file")" "${extra_args[@]}"
    echo "preprocessed source: $pre_out" >&2
fi

if [ "$mode" = "compile" ] || [ "$mode" = "both" ]; then
    dxil_out="$out_dir/$stem.dxil"
    asm_out="$out_dir/$stem.dis.ll"
    run_dxc -T "$profile" \
        "${entry_args[@]}" \
        "${define_args[@]}" \
        "${validator_args[@]}" \
        -Fo "$(to_win_path "$dxil_out")" \
        -Fc "$(to_win_path "$asm_out")" \
        "$(to_win_path "$source_file")" \
        "${extra_args[@]}"
    echo "compiled container: $dxil_out" >&2
    echo "disassembly:        $asm_out" >&2
fi
