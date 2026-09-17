#!/bin/sh
# netfilter hook for nfqws2 - restores iptables rules only when needed

PIDFILE="/opt/var/run/nfqws2.pid"
CONFFILE="/opt/etc/nfqws2/nfqws2.conf"
LOGFILE="/opt/var/log/nfqws2-netfilter.log"
MAXLOGSIZE=104857600   # 100 MB

# Default log level (0 = off, 1 = on)
NF_LOG_LEVEL=${NF_LOG_LEVEL:-0}

# Load configuration (will override NF_LOG_LEVEL if set there)
if [ -f "$CONFFILE" ]; then
    . "$CONFFILE"
fi

# Simple log rotation (only if logging is enabled)
if [ "$NF_LOG_LEVEL" -eq 1 ] && [ -f "$LOGFILE" ]; then
    size=$(ls -l "$LOGFILE" | awk '{print $5}')
    if [ -n "$size" ] && [ "$size" -gt $MAXLOGSIZE ]; then
        mv "$LOGFILE" "${LOGFILE}.old" 2>/dev/null
    fi
fi

# Log function: either write to file or do nothing
if [ "$NF_LOG_LEVEL" -eq 1 ]; then
    log() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOGFILE"
    }
else
    log() {
        # No-op
        :
    }
fi

log "=== Hook called ==="
log "table=$table type=$type"

# 1. Check if the service is running
if [ ! -f "$PIDFILE" ] || ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    log "nfqws2 not running, exit"
    exit 0
fi

# 2. Load configuration again (variables already loaded, but ensure they are available)
if [ -f "$CONFFILE" ]; then
    . "$CONFFILE"
fi

# 3. If no interfaces are configured, exit
if [ -z "$ISP_INTERFACE" ]; then
    log "ISP_INTERFACE empty, exit"
    exit 0
fi

# 4. Only handle mangle and nat tables
[ "$table" != "mangle" ] && [ "$table" != "nat" ] && {
    log "table=$table not mangle/nat, exit"
    exit 0
}

# 5. Helper functions to check if rules exist for a given interface
check_post() {
    iptables -t mangle -S nfqws_post 2>/dev/null | grep -qF -- "-o $1 "
}
check_pre() {
    iptables -t mangle -S nfqws_pre 2>/dev/null | grep -qF -- "-i $1 "
}

# 6. Check all interfaces from config
need_reload=0
for iface in $ISP_INTERFACE; do
    log "Checking iface $iface: post rule? $(check_post "$iface" && echo yes || echo no); pre rule? $(check_pre "$iface" && echo yes || echo no)"
    if ! check_post "$iface" || ! check_pre "$iface"; then
        log "First check failed for $iface, waiting 0.2 sec"
        if command -v usleep >/dev/null 2>&1; then
            usleep 200000
        else
            sleep 1
        fi
        if ! check_post "$iface" || ! check_pre "$iface"; then
            log "Second check also failed for $iface, need reload"
            need_reload=1
            break
        else
            log "Second check succeeded, rules present"
        fi
    else
        log "Rules present for $iface"
    fi
done

if [ $need_reload -eq 0 ]; then
    log "All rules present, exit"
    exit 0
fi

# 7. Regenerate rules by calling the main script
log "Calling /opt/etc/init.d/S51nfqws2 firewall_$type"
/opt/etc/init.d/S51nfqws2 firewall_"$type" >/dev/null 2>&1
log "Done"
exit 0
