#!/bin/bash
###############################################################################
# Chapter 9.2.2  HAProxy Layer 4 / Layer 7 load balancing -- verification script
# Book: Hands-On Ubuntu Server 26.04 LTS (Henry Hans)
#
# Usage: sudo ./haproxy_verify.sh lb    (run on the HAProxy node)
#        sudo ./haproxy_verify.sh web   (run on each backend, web01 / web02)
#
# Lab plan used in the book (replace with your own environment):
#   LB 10.0.0.180   web01 10.0.0.181   web02 10.0.0.182
#
# BEFORE YOU RUN -- adjust these to your environment:
#   No NIC name is needed. The script tests HAProxy on 127.0.0.1 from the LB node.
#   CFG    Default Ubuntu path; change it only if you keep haproxy.cfg elsewhere.
#   The Layer 7 test needs web01 and web02 to serve DIFFERENT index pages.
#   The Layer 4 test expects 'listen mysql_lb' on port 6688 as in the book; if
#          you used another port, change 6688 in step 5. Install netcat-openbsd
#          for the port test.
#   If HAProxy binds only to a specific IP (not *:80), replace 127.0.0.1 in step 4
#          with that IP.
###############################################################################

CFG="/etc/haproxy/haproxy.cfg"
ROLE="$1"
PASS=0; FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${YELLOW}[INFO]${NC} $1"; }
step() { echo -e "\n== $1 =="; }

if [[ "$ROLE" != "lb" && "$ROLE" != "web" ]]; then
    echo "Usage: sudo $0 lb|web"
    exit 1
fi

echo "############################################################"
echo "  HAProxy load balancing verification -- role: $ROLE"
echo "############################################################"

if [ "$ROLE" == "lb" ]; then
    step "1. HAProxy installed / version"
    command -v haproxy >/dev/null 2>&1 && ok "haproxy installed: $(haproxy -v | head -1)" || bad "haproxy not installed"

    step "2. Config syntax check"
    if [ -f "$CFG" ]; then
        if haproxy -c -f "$CFG" >/tmp/hatest.log 2>&1; then
            ok "Config syntax valid (haproxy -c -f)"
        else
            bad "Config syntax error:"
            sed 's/^/         /' /tmp/hatest.log
        fi
    else
        bad "Config file not found: $CFG"
    fi

    step "3. Service status"
    systemctl is-active --quiet haproxy && ok "haproxy is running" || bad "haproxy is not running"

    step "4. Layer 7 (HTTP) round-robin test -- 6 requests"
    if command -v curl >/dev/null 2>&1; then
        declare -A COUNTS
        for i in $(seq 1 6); do
            RESP=$(curl -s --max-time 2 "http://127.0.0.1/" 2>/dev/null)
            COUNTS["$RESP"]=$(( ${COUNTS["$RESP"]:-0} + 1 ))
        done
        for k in "${!COUNTS[@]}"; do
            info "Response [$k] seen ${COUNTS[$k]} times"
        done
        UNIQ=${#COUNTS[@]}
        if [ "$UNIQ" -ge 2 ]; then
            ok "$UNIQ different backend responses -- Layer 7 round-robin works"
        else
            bad "Only $UNIQ distinct response(s). Give web01/web02 different index pages"
        fi
    else
        bad "curl not installed, cannot test distribution"
    fi

    step "5. Layer 4 (TCP/MySQL) proxy test (if 'listen mysql_lb' on port 6688 is configured)"
    if grep -q "6688" "$CFG" 2>/dev/null; then
        if command -v nc >/dev/null 2>&1; then
            if nc -z -w2 127.0.0.1 6688; then
                ok "Port 6688 reachable -- Layer 4 MySQL proxy is listening"
            else
                bad "Port 6688 unreachable. Check 'listen mysql_lb' and that the backend MySQL servers are running"
            fi
        else
            info "nc not installed. Test manually: mysql -h 127.0.0.1 -P 6688 -u<user> -p"
        fi
    else
        info "No Layer 4 MySQL proxy (6688) configured -- ignore if you are only testing Layer 7"
    fi

    step "6. Backend health status"
    if [ -S /run/haproxy/admin.sock ]; then
        info "Check backend health with:"
        info "  echo 'show stat' | sudo socat stdio /run/haproxy/admin.sock"
    fi

elif [ "$ROLE" == "web" ]; then
    step "1. Nginx service and index page"
    systemctl is-active --quiet nginx && ok "nginx is running" || bad "nginx is not running"
    CONTENT=$(curl -s --max-time 2 http://127.0.0.1 2>/dev/null)
    info "Local index page: $CONTENT"
    if [ -n "$CONTENT" ]; then
        ok "This node answers HTTP requests"
    else
        bad "No HTTP response"
    fi
    info "Make sure /var/www/html/index.html differs on web01 and web02 (e.g. 'web01' / 'web02') so round-robin is visible from the LB"
fi

echo ""
echo "############################################################"
echo -e "  Summary: ${GREEN}PASS=$PASS${NC}  ${RED}FAIL=$FAIL${NC}"
echo "############################################################"
