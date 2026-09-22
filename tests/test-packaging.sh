#!/bin/bash
# Run on Linux: bash tests/test-packaging.sh
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$repo/Makefile" "$repo/packages.mk" "$repo/repository.mk" "$repo/VERSION" "$work/"
cp -R "$repo/common" "$repo/etc" "$work/"
cd "$work"
mkdir -p out/nfqws2
if make _prepare_bins >missing.log 2>&1; then
    echo 'Missing artifacts must fail' >&2
    exit 1
fi
grep -q 'Missing patched binaries' missing.log
for arch in arm64 arm mips64 mipselsf mipssf x86 x86_64; do
    case "$arch" in
        mipselsf) bin=mipsel ;;
        mipssf) bin=mips ;;
        *) bin=$arch ;;
    esac
    mkdir -p "fixture/$arch/binaries/linux-$bin"
    printf 'patched-%s\n' "$arch" > "fixture/$arch/binaries/linux-$bin/nfqws2"
    chmod +x "fixture/$arch/binaries/linux-$bin/nfqws2"
    if [[ "$arch" == arm64 ]]; then
        mkdir -p "fixture/$arch/lua"
        printf 'lua-from-pinned-source\n' | gzip > "fixture/$arch/lua/zapret-lib.lua.gz"
    fi
    tar -C "fixture/$arch" -czf "out/nfqws2/nfqws2-$arch.tar.gz" .
done
make entware openwrt >build.log 2>&1 || { cat build.log; exit 1; }
version=$(cat VERSION)
for entry in 'mipsel:mipsel-3.4:mipselsf' 'mips:mips-3.4:mipssf' 'aarch64:aarch64-3.10:arm64'; do
    IFS=: read -r dir package arch <<< "$entry"
    mkdir unpack
    tar -xzf "out/nfqws2-keenetic_${version}_${package}.ipk" -C unpack
    tar -xzf unpack/control.tar.gz -C unpack
    grep -qx "Version: $version" unpack/control
    tar -xzf unpack/data.tar.gz -C unpack
    cmp "fixture/$arch/binaries/linux-${dir/aarch64/arm64}/nfqws2" unpack/opt/usr/bin/nfqws2
    test -x unpack/opt/usr/bin/nfqws2
    cmp fixture/arm64/lua/zapret-lib.lua.gz unpack/opt/etc/nfqws2/lua/zapret-lib.lua.gz
    rm -rf unpack
done
for dir in out/all/data/opt out/openwrt/data; do
    test "$(find "$dir/tmp/nfqws2_binary" -type f | wc -l)" -eq 7
    for entry in 'mipsel:mipselsf' 'mips:mipssf' 'mips64:mips64' 'aarch64:arm64' 'armv7:arm' 'x86:x86' 'x86_64:x86_64'; do
        IFS=: read -r bin arch <<< "$entry"
        printf 'patched-%s\n' "$arch" | cmp - "$dir/tmp/nfqws2_binary/nfqws2-$bin"
        test -x "$dir/tmp/nfqws2_binary/nfqws2-$bin"
    done
    cmp fixture/arm64/lua/zapret-lib.lua.gz "$dir/etc/nfqws2/lua/zapret-lib.lua.gz"
done
printf 'corrupt archive\n' > out/nfqws2/nfqws2-arm64.tar.gz
if make _prepare_bins >corrupt.log 2>&1; then
    echo 'Corrupt artifacts must fail' >&2
    exit 1
fi
echo 'PASS: package version, all architectures, executable modes, Lua, missing/corrupt artifacts'
