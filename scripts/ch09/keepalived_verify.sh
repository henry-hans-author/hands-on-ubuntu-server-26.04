#!/bin/bash
###############################################################################
# Chapter 9.1  Keepalived Master/Backup High Availability -- verification script
# Book: Hands-On Ubuntu Server 26.04 LTS (Henry Hans)
#
# Usage: sudo ./keepalived_verify.sh master   (run on the master node)
#        sudo ./keepalived_verify.sh backup   (run on the backup node)
#
# Lab plan used in the book (replace with your own environment):
#   Master 10.0.0.180   Backup 10.0.0.181   VIP 10.0.0.168
#
# BEFORE YOU RUN -- adjust these to your environment:
#   IFACE  The NIC that carries the VIP. The book uses ens33 (VMware default).
#          Find yours with: ip -br link   (common names: ens33, ens160, enp0s3, eth0)
#          A wrong IFACE makes the VIP checks report FAIL even when HA works.
#   VIP    Must match virtual_ipaddress in keepalived.conf on BOTH nodes.
#   CONF / CHECK_SCRIPT  Paths used in the book; change them if you installed
#          keepalived from source under /usr/local/keepalived.
#   The script assumes Nginx is the service being protected (as in the book).
#   Step 8 can stop nginx on the master -- run it in a lab, not in production.
###############################################################################

VIP="10.0.0.168"
IFACE="ens33"                 # change to your NIC name (book default: ens33)
CONF="/etc/keepalived/keepalived.conf"
CHECK_SCRIPT="/etc/keepalived/nginx_check.sh"

ROLE="$1"
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${YELLOW}[INFO]${NC} $1"; }
step() { echo -e "\n== $1 =="; }

if [[ "$ROLE" != "master" && "$ROLE" != "backup" ]]; then
    echo "Usage: sudo $0 master|backup"
    exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "NIC '$IFACE' not found. Available NICs:"
    ip -br link | awk '{print "  " $1}'
    echo "Edit IFACE at the top of this script and run it again."
    exit 1
fi

echo "############################################################"
echo "  Keepalived HA verification -- role: $ROLE"
echo "############################################################"

step "1. Package and version"
if command -v keepalived >/dev/null 2>&1 || [ -x /usr/local/keepalived/sbin/keepalived ]; then
    ok "keepalived installed: $(keepalived --version 2>&1 | head -1 || /usr/local/keepalived/sbin/keepalived --version 2>&1 | head -1)"
else
    bad "keepalived not found. Install it first: sudo aptitude install -y keepalived"
fi

step "2. Config file and syntax check (a syntax error does NOT stop keepalived from starting -- always test it)"
if [ -f "$CONF" ]; then
    ok "Config file exists: $CONF"
    if keepalived -t -f "$CONF" >/tmp/katest.log 2>&1; then
        ok "Config syntax test passed (keepalived -t -f)"
    else
        bad "Config syntax test failed. Details:"
        sed 's/^/         /' /tmp/katest.log
    fi
else
    bad "Config file not found: $CONF"
fi

step "3. state / priority / virtual_router_id vs. role"
if [ -f "$CONF" ]; then
    STATE=$(grep -m1 -oP '(?<=state )\w+' "$CONF")
    PRIO=$(grep -m1 -oP '(?<=priority )\d+' "$CONF")
    VRID=$(grep -m1 -oP '(?<=virtual_router_id )\d+' "$CONF")
    info "state=$STATE priority=$PRIO virtual_router_id=$VRID"
    if [[ "$ROLE" == "master" && "$STATE" == "MASTER" ]]; then
        ok "state matches role (MASTER)"
    elif [[ "$ROLE" == "backup" && "$STATE" == "BACKUP" ]]; then
        ok "state matches role (BACKUP)"
    else
        bad "state=$STATE does not match role '$ROLE'. Check the config."
    fi
    if [[ "$ROLE" == "master" && "$PRIO" -ge 100 ]]; then
        ok "priority=$PRIO (master should have the higher priority)"
    elif [[ "$ROLE" == "backup" ]]; then
        ok "priority=$PRIO (backup -- for reference; keep it at least 50 below the master)"
    fi
fi

step "4. Health-check script"
if [ -x "$CHECK_SCRIPT" ]; then
    ok "Check script exists and is executable: $CHECK_SCRIPT"
else
    bad "Check script missing or not executable: $CHECK_SCRIPT (sudo chmod u+x $CHECK_SCRIPT)"
fi

step "5. Nginx and Keepalived service status"
systemctl is-active --quiet nginx && ok "nginx is running" || bad "nginx is not running"
systemctl is-active --quiet keepalived && ok "keepalived is running" || bad "keepalived is not running"

NPROC=$(pgrep -c keepalived)
if [ "$NPROC" -eq 3 ]; then
    ok "keepalived process count = 3 (normal: core / checker / VRRP)"
else
    bad "keepalived process count = $NPROC (expected 3 -- just started, or crashed?)"
fi

step "6. VIP binding"
if ip addr show "$IFACE" 2>/dev/null | grep -q "$VIP"; then
    if [ "$ROLE" == "master" ]; then
        ok "VIP $VIP is bound to $IFACE on this node (master holds the VIP)"
    else
        info "VIP is on the backup node -- the master may be down, or this is the post-failover state"
    fi
else
    if [ "$ROLE" == "master" ]; then
        bad "Master does not hold the VIP. Check priority / virtual_router_id / auth_pass on both nodes"
    else
        ok "Backup does not hold the VIP (normal while the master is healthy)"
    fi
fi

step "7. VRRP state transitions (last 10 minutes)"
journalctl -u keepalived --since "-10 min" 2>/dev/null | grep -iE "state transition|entering|VRRP_Instance" | tail -5 | sed 's/^/  /'
info "For older entries, drop the --since option"

step "8. Manual failover test"
if [ "$ROLE" == "master" ]; then
    echo -e "  ${YELLOW}Stop nginx on this node now to simulate a master failure and move the VIP? [y/N]${NC}"
    read -r ANSWER
    if [[ "$ANSWER" == "y" || "$ANSWER" == "Y" ]]; then
        systemctl stop nginx
        info "nginx stopped. After ~10 seconds, run this on the backup node:"
        info "  ip addr show $IFACE | grep $VIP"
        info "Expected: $VIP appears on the backup node -- failover works."
        info "Restore afterwards: sudo systemctl start nginx keepalived"
    else
        info "Failover test skipped. Run 'sudo systemctl stop nginx' later to test it."
    fi
else
    info "Stop nginx on the master, then run this here (backup) to confirm the VIP moved:"
    info "  ip addr show $IFACE | grep $VIP"
fi

echo ""
echo "############################################################"
echo -e "  Summary: ${GREEN}PASS=$PASS${NC}  ${RED}FAIL=$FAIL${NC}"
echo "############################################################"
