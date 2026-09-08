#!/bin/sh
# dns-check.sh - rules DNS out before you start tuning strategies.
#
# A filtering or dead DNS upstream looks exactly like a broken bypass from the
# user side: some sites stop opening while everything else works. Checking it
# first costs seconds and saves hours, because no strategy fixes a resolver.
#
# Two checks, both chosen because they cannot produce a false alarm:
#
#   1. Does the system resolver answer at all, for names that resolve
#      everywhere. No answer means the configured upstream is dead.
#   2. Does it invent an answer for a name that does not exist. A resolver
#      that returns an address for random garbage is intercepting NXDOMAIN,
#      which is what filtering DNS services do - and their answers for real
#      names cannot be trusted either.
#
# What this script deliberately does NOT do:
#
#   - compare addresses against a public resolver. Any CDN legitimately hands
#     out different addresses to different resolvers, so a mismatch says
#     nothing. Tried it, every CDN-hosted name reported a false alarm.
#   - check that the addresses accept connections. On stock busybox there is
#     no portable way to do it: nc is built without -z and -w, and timeout is
#     not in the image, so every "unreachable" verdict would be the tool
#     failing rather than the address.
#   - probe each upstream separately. On Keenetic every DoT/DoH upstream is a
#     local stub on its own port, and busybox nslookup cannot query a port
#     other than 53. They are listed for context instead.
#
# Usage:
#   dns-check.sh                    check the default names
#   dns-check.sh example.com ...    check the given names instead

if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "usage: dns-check.sh [name ...]" >&2
  exit 2
fi

if [ $# -gt 0 ]; then
  NAMES="$*"
else
  # Deliberately boring names: they resolve everywhere, so no answer here
  # means the resolver, not the site.
  NAMES="example.com wikipedia.org github.com"
fi

# Addresses come after the "Name:" line; what is above it describes the server
# being queried. Take the first IPv4-looking field of the line rather than the
# last one - busybox appends the reverse name after the address, so $NF is the
# hostname on most answers.
resolve() {
  nslookup "$1" 2>/dev/null | awk '
    /^Name:/ { seen = 1; next }
    seen && /^Address/ {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; break }
    }
  ' | sort -u
}

echo "resolver(s) in use:"
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/  /' \
  || echo "  (no /etc/resolv.conf)"

# On Keenetic the system resolver is a local proxy and the real upstreams are
# only visible in its running config. ndmc reads stdin, so it gets /dev/null -
# otherwise it eats the rest of this script when the script is piped in.
if command -v ndmc >/dev/null 2>&1; then
  upstreams=$(LD_LIBRARY_PATH="/lib:/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    ndmc -c "show dns-proxy" </dev/null 2>/dev/null | grep -E '^dns_server' | sed 's/^/  /')
  if [ -n "$upstreams" ]; then
    echo "configured upstreams:"
    echo "$upstreams"
  fi
fi

echo

failed=0
for name in $NAMES; do
  addrs=$(resolve "$name")
  if [ -z "$addrs" ]; then
    echo "NO-ANSWER  $name"
    failed=$((failed + 1))
  else
    echo "OK         $name - $(echo "$addrs" | tr '\n' ' ')"
  fi
done

# A name that cannot exist: the label is not a registered TLD, so a correct
# resolver must answer NXDOMAIN and nothing else.
BOGUS="nxdomain-probe-$$.invalid"
bogus_addrs=$(resolve "$BOGUS")
echo
if [ -n "$bogus_addrs" ]; then
  echo "HIJACKED   $BOGUS resolved to $(echo "$bogus_addrs" | tr '\n' ' ')"
  echo "           A name that does not exist must not resolve. This resolver"
  echo "           intercepts NXDOMAIN, so it is filtering, and its answers"
  echo "           for real names cannot be trusted either."
  failed=$((failed + 1))
else
  echo "OK         non-existent name correctly returns no address"
fi

echo
if [ "$failed" -gt 0 ]; then
  echo "DNS is a likely cause here, not the bypass. Switch the upstream,"
  echo "re-check, and only then go back to tuning strategies."
  exit 1
fi

echo "DNS looks fine. If sites are still broken, the cause is elsewhere."
exit 0
