#!/bin/sh

PIDFILE="/opt/var/run/nfqws2.pid"
if [ ! -f "$PIDFILE" ] || ! kill -0 $(cat "$PIDFILE") 2>/dev/null; then
  exit
fi
[ "$table" != "mangle" ] && [ "$table" != "nat" ] && exit

# $type is `iptables` or `ip6tables`
# $table is `mangle` or `nat`
/opt/etc/init.d/S51nfqws2 firewall_reload "$type" "$table"
