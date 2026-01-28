#!/bin/sh

./setup.sh

echo "src-link nfqws2 /builder/src/openwrt" > feeds.conf

./scripts/feeds update nfqws2
./scripts/feeds install -a -p nfqws2

make defconfig
make CONFIG_USE_APK=y package/nfqws2-keenetic/compile V=s
make CONFIG_USE_APK=y package/index V=s
make CONFIG_USE_APK= package/nfqws2-keenetic/compile V=s
make CONFIG_USE_APK= package/index V=s
