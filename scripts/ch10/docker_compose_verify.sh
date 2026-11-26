#!/bin/bash
###############################################################################
# Chapter 10.1-10.5  Docker / Compose / Harbor / Dockerfile -- verification script
# Book: Hands-On Ubuntu Server 26.04 LTS (Henry Hans)
#
# Usage: sudo ./docker_compose_verify.sh
# Single-host script; checks each hands-on section in book order.
#
# BEFORE YOU RUN -- adjust these to your environment:
#   No NIC name is needed.
#   Lab directories are looked up in the home of the user who ran sudo:
#          ~/docker/ubuntu-ssh/Dockerfile      (10.4.1)
#          ~/compose/wordpress/docker-compose.yml (10.5.1)
#          If you used other paths, edit steps 5 and 7.
#   Container names wp-db / wp-php / wp-nginx follow the book (10.3.2).
#   The Compose WordPress test calls http://127.0.0.1/ -- if you mapped another
#          host port, add it to the URL in step 7 (e.g. 127.0.0.1:8080).
#   Step 3 pulls hello-world and step 5 builds an image: both need Internet
#          access or a working registry mirror.
###############################################################################

PASS=0; FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${YELLOW}[INFO]${NC} $1"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
step() { echo -e "\n== $1 =="; }

# Paths are relative to the user who ran sudo, not /root
USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)

echo "############################################################"
echo "  Docker / Compose end-to-end verification"
echo "############################################################"

step "1. Docker package source (use Docker's official repo, not the distro's docker.io)"
if ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi docker; then
    ok "Docker official APT source found in /etc/apt/sources.list.d/"
else
    bad "No Docker official APT source found -- was docker.io installed instead?"
fi
if dpkg -l | grep -q "^ii  docker-ce "; then
    ok "docker-ce is installed (not docker.io)"
else
    bad "docker-ce package not found"
fi

step "2. Docker / Compose version and status"
if command -v docker >/dev/null 2>&1; then
    ok "docker version: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
    systemctl is-active --quiet docker && ok "docker service is running" || bad "docker service is not running"
    docker compose version >/dev/null 2>&1 && ok "docker compose plugin OK: $(docker compose version --short 2>/dev/null)" || bad "docker compose plugin not available"
else
    bad "docker command not found -- finish the installation first"
fi

step "3. hello-world smoke test"
if docker run --rm hello-world >/tmp/hello.log 2>&1; then
    ok "hello-world ran successfully -- Docker Engine basics work"
else
    bad "hello-world failed, see /tmp/hello.log"
fi

step "4. daemon.json key settings (registry mirror / data root / address pools)"
if [ -f /etc/docker/daemon.json ]; then
    info "Current daemon.json:"
    sed 's/^/    /' /etc/docker/daemon.json
    grep -q "registry-mirrors" /etc/docker/daemon.json && ok "Registry mirror configured" || info "No registry mirror (optional)"
else
    info "No daemon.json -- default settings in use"
fi

step "5. Dockerfile build test (10.4.1, needs ~/docker/ubuntu-ssh/Dockerfile)"
if [ -f "$USER_HOME/docker/ubuntu-ssh/Dockerfile" ]; then
    if docker build -t ubuntu/sshd:test "$USER_HOME/docker/ubuntu-ssh" >/tmp/build.log 2>&1; then
        ok "Dockerfile built: ubuntu/sshd:test"
        docker rmi ubuntu/sshd:test >/dev/null 2>&1
    else
        bad "Dockerfile build failed, see /tmp/build.log"
    fi
else
    skip "~/docker/ubuntu-ssh/Dockerfile not found -- skipping (create it as in 10.4.1)"
fi

step "6. LEMP + WordPress with docker run (10.3.2)"
for c in wp-db wp-php wp-nginx; do
    if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        ok "Container $c is running"
    else
        skip "Container $c not running (ignore if you skipped this lab)"
    fi
done

step "7. LEMP + WordPress with Compose (10.5.1, needs ~/compose/wordpress/docker-compose.yml)"
COMPOSE_DIR="$USER_HOME/compose/wordpress"
if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    ok "docker-compose.yml found"
    cd "$COMPOSE_DIR" || exit 1
    STATUS=$(docker compose ps --format '{{.Name}} {{.State}}' 2>/dev/null)
    echo "$STATUS" | sed 's/^/    /'
    if echo "$STATUS" | grep -qi "running"; then
        ok "Compose services are running"
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/ 2>/dev/null)
        if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
            ok "WordPress returned HTTP $HTTP_CODE (normal -- may be the setup wizard)"
        else
            bad "WordPress returned HTTP $HTTP_CODE. Check that nginx, php-fpm and mysql are all up"
        fi
    else
        bad "Compose services are not running"
    fi
else
    skip "$COMPOSE_DIR/docker-compose.yml not found -- skipping Compose test"
fi

step "8. Harbor private registry (10.4.2, optional)"
if docker ps --format '{{.Names}}' | grep -q "harbor"; then
    ok "Harbor containers are running"
    if grep -q "insecure-registries" /etc/docker/daemon.json 2>/dev/null; then
        ok "insecure-registries configured (required for Harbor without HTTPS)"
    else
        info "insecure-registries not set -- pushes will fail if Harbor runs without HTTPS"
    fi
else
    skip "No Harbor containers -- skipping (ignore if you are not testing a private registry)"
fi

echo ""
echo "############################################################"
echo -e "  Summary: ${GREEN}PASS=$PASS${NC}  ${RED}FAIL=$FAIL${NC}"
echo "############################################################"
