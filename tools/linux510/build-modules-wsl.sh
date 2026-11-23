#!/bin/bash
# Run the out-of-tree module builds (modules/*/build-module.sh) on an x86-64 WSL2 host without Docker.
# Those scripts hard-code the Mac container layout (/work/kernel, /work/out, /work/prebuilts, /m); this runs each
# one with the paths rewritten. Output: $O/ext-<name>/<name>.ko, as in the container.
#
#   K=~/e850/kernel O=~/e850/out PREBUILTS=~/e850/a13-build/prebuilts tools/linux510/build-modules-wsl.sh [name ...]
#   (PREBUILTS/clang/host/linux-x86/clang-r450784e must exist; default: all modules with a build-module.sh)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
K=${K:?K=kernel source}
O=${O:?O=kernel build output}
PREBUILTS=${PREBUILTS:?PREBUILTS=directory that holds clang/host/linux-x86/clang-r450784e}
SHIM=$(mktemp -d)
trap 'rm -rf "$SHIM"' EXIT
command -v python >/dev/null || ln -s "$(command -v python3)" "$SHIM/python"
export PATH=$SHIM:$PATH
if [ $# -gt 0 ]; then names="$*"; else names=$(cd "$R/modules" && ls -d */build-module.sh | sed 's|/.*||'); fi
fail=0
for d in $names; do
    sed -e "s#/work/prebuilts#$PREBUILTS#g" -e "s#/work/kernel#$K#g" -e "s#/work/out#$O#g" -e "s#/m/#$R/modules/$d/#g" \
        "$R/modules/$d/build-module.sh" > "$SHIM/$d.sh"
    if bash "$SHIM/$d.sh" > "$SHIM/$d.log" 2>&1; then
        echo "ok   $d: $(tail -n 1 "$SHIM/$d.log")"
    else
        echo "FAIL $d"; tail -n 15 "$SHIM/$d.log"; fail=1
    fi
done
exit $fail
