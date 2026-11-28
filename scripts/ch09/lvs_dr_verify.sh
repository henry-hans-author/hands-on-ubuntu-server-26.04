#!/bin/bash
###############################################################################
# Chapter 9.2.1  LVS Direct Routing (DR), three nodes -- verification script
# Book: Hands-On Ubuntu Server 26.04 LTS (Henry Hans)
#
# Usage: sudo ./lvs_dr_verify.sh lvs   (run on the LVS director)
#        sudo ./lvs_dr_verify.sh web   (run on each real server, web01 / web02)
#
# Lab plan used in the book (replace with your own environment):
#   LVS 10.0.0.180   web01 10.0.0.181   web02 10.0.0.182   VIP 10.0.0.168
#
# BEFORE YOU RUN -- adjust these to your environment:
#   IFACE  The real NIC on BOTH the director and the real servers. The book uses
#          ens33 (VMware default). Find yours with: ip -br link
#          On real servers this script also checks ARP suppression on this NIC and
#          expects net.ipv4.conf.<IFACE>.arp_ignore / arp_announce in the persistent
#          sysctl file (belt and braces; see the note in the 'web' section).
#   VIP    Must be the same on the director (bound to IFACE) and on every real
#          server (bound to lo).
#   The director and real servers must be on the same Layer 2 network (DR mode).
#   The distribution test needs web01 and web02 to serve DIFFERENT index pages.
###############################################################################

VIP="10.0.0.168"
IFACE="ens33"                 # change to your NIC name (book default: ens33)
ROLE="$1"
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${YELLOW}[INFO]${NC} $1"; }
step() { echo -e "\n== $1 =="; }

if [[ "$ROLE" != "lvs" && "$ROLE" != "web" ]]; then
    echo "Usage: sudo $0 lvs|web"
    exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "NIC '$IFACE' not found. Available NICs:"
    ip -br link | awk '{print "  " $1}'
    echo "Edit IFACE at the top of this script and run it again."
    exit 1
fi

echo "############################################################"
echo "  LVS DR verification -- role: $ROLE"
echo "############################################################"

if [ "$ROLE" == "lvs" ]; then
    step "1. ipvsadm"
    command -v ipvsadm >/dev/null 2>&1 && ok "ipvsadm installed" || bad "ipvsadm not installed (sudo aptitude install -y ipvsadm)"

    step "2. VIP bound to the director NIC"
    if ip addr show "$IFACE" | grep -q "$VIP"; then
        ok "VIP $VIP is bound to $IFACE"
    else
        bad "VIP not bound. Run: sudo ip addr add $VIP/32 dev $IFACE"
    fi

    step "3. LVS rules (expected: wrr scheduler + 2 real servers forwarded by Route)"
    RULES=$(ipvsadm -Ln)
    echo "$RULES" | sed 's/^/  /'
    if echo "$RULES" | grep -q "$VIP:80"; then
        ok "Virtual service $VIP:80 configured"
    else
        bad "Virtual service not found. Check: sudo ipvsadm -A -t $VIP:80 -s wrr"
    fi
    RSCOUNT=$(echo "$RULES" | grep -c "Route")
    if [ "$RSCOUNT" -eq 2 ]; then
        ok "2 real servers in DR mode (Route) found"
    else
        bad "DR-mode real servers = $RSCOUNT (expected 2). Check your 'ipvsadm -a ... -g' commands"
    fi

    step "4. Distribution test (10 requests, count responses per backend)"
    if command -v curl >/dev/null 2>&1; then
        declare -A COUNTS
        for i in $(seq 1 10); do
            RESP=$(curl -s --max-time 2 "http://$VIP" 2>/dev/null)
            KEY=$(echo "$RESP" | head -c 60)
            COUNTS["$KEY"]=$(( ${COUNTS["$KEY"]:-0} + 1 ))
        done
        for k in "${!COUNTS[@]}"; do
            info "Response [$k...] seen ${COUNTS[$k]} times"
        done
        UNIQ=${#COUNTS[@]}
        if [ "$UNIQ" -ge 2 ]; then
            ok "$UNIQ different backend responses -- load balancing works"
        else
            bad "Only $UNIQ distinct response(s). Make sure web01/web02 serve different index pages and that ARP suppression is in effect"
        fi
        info "Note: test from a separate client machine as well -- requests sent from the director itself may not follow the DR path"
    else
        bad "curl not installed, cannot test distribution"
    fi

    step "5. Connection statistics (optional, watch manually)"
    info "To watch distribution live: watch -n 2 ipvsadm -Ln --stats"

elif [ "$ROLE" == "web" ]; then
    step "1. ARP suppression kernel parameters (lo, all, AND the real NIC $IFACE)"
    # Per the kernel docs, the max of conf/all and conf/<iface> is used, so the
    # 'all' values should already cover the NIC. We still check the NIC explicitly:
    # in our lab a backend answered ARP for the VIP until the NIC values were set,
    # most likely because the 'all' values were not actually in effect. Always
    # confirm the live values with sysctl and arping, not just the config file.
    for dev in lo all "$IFACE"; do
        for key in arp_ignore arp_announce; do
            p="net.ipv4.conf.${dev}.${key}"
            VAL=$(sysctl -n "$p" 2>/dev/null)
            if [[ "$key" == "arp_ignore" && "$VAL" == "1" ]] || [[ "$key" == "arp_announce" && "$VAL" == "2" ]]; then
                ok "$p = $VAL"
            else
                bad "$p = ${VAL:-unset} (expected arp_ignore=1 / arp_announce=2)"
            fi
        done
    done

    step "2. Persistent sysctl file"
    if [ -f /etc/sysctl.d/99-lvs-dr.conf ]; then
        ok "Persistent file exists: /etc/sysctl.d/99-lvs-dr.conf"
        if grep -q "conf.${IFACE}.arp_ignore" /etc/sysctl.d/99-lvs-dr.conf; then
            ok "Persistent file includes the $IFACE entries"
        else
            bad "Persistent file has no net.ipv4.conf.${IFACE}.* entries -- the fix will be lost after reboot"
        fi
    else
        bad "Persistent file missing -- ARP suppression will be lost after reboot"
    fi

    step "3. VIP bound to lo"
    if ip addr show lo | grep -q "$VIP"; then
        ok "VIP $VIP is bound to lo"
    else
        bad "VIP not bound to lo. Run: sudo ip addr add $VIP/32 dev lo"
    fi

    step "4. Routing table"
    if ip route show table local | grep -q "$VIP.*dev lo" || ip route show | grep -q "$VIP.*dev lo"; then
        ok "Route $VIP -> lo exists"
    else
        bad "Route missing. Run: sudo ip route add $VIP/32 dev lo"
    fi

    step "5. Nginx service and index page"
    systemctl is-active --quiet nginx && ok "nginx is running" || bad "nginx is not running"
    CONTENT=$(curl -s --max-time 2 http://127.0.0.1 2>/dev/null)
    info "Local index page: $CONTENT"
    if [ -n "$CONTENT" ]; then
        ok "This node answers HTTP requests"
        info "Make sure web01 and web02 serve different content so distribution is visible from the director"
    else
        bad "No HTTP response. Check nginx and the index file"
    fi
fi

echo ""
echo "############################################################"
echo -e "  Summary: ${GREEN}PASS=$PASS${NC}  ${RED}FAIL=$FAIL${NC}"
echo "############################################################"
