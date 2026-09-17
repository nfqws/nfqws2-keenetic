#!/bin/sh

PIDFILE="/opt/var/run/nfqws2.pid"
if [ ! -f "$PIDFILE" ] || ! kill -0 $(cat "$PIDFILE") 2>/dev/null; then
  exit 0
fi
if [ "$table" != "mangle" ] && [ "$table" != "nat" ]; then
  exit 0
fi

# $type is `iptables` or `ip6tables`
/opt/etc/init.d/S51nfqws2 firewall_"$type"
exit 0
