#!/bin/bash
###############################################################################
# Chapter 10.6-10.7  Three-node Kubernetes cluster + WordPress -- verification script
# Book: Hands-On Ubuntu Server 26.04 LTS (Henry Hans)
#
# Usage: sudo ./k8s_verify.sh master   (on k8s-master: environment + cluster + app checks)
#        sudo ./k8s_verify.sh node     (on k8s-node1 / k8s-node2: environment checks only)
#
# BEFORE YOU RUN -- adjust these to your environment:
#   No NIC name is needed, but on multi-NIC VMs make sure each node's InternalIP
#          (kubectl get nodes -o wide) is the lab network address, not a NAT one.
#   Expects exactly 3 nodes (1 master + 2 workers). Change 'TOTAL -eq 3' in
#          step 10 if your cluster is a different size.
#   Expects Docker + cri-dockerd (as in the book) and Flannel in the kube-flannel
#          namespace. With containerd only or another CNI, steps 5, 6, 8 and 11
#          will report FAIL by design.
#   Cloned VMs: hostname and /etc/machine-id must differ on every node (step 1).
#   Step 13 expects a Service named 'wordpress' of type NodePort (10.7.1).
###############################################################################

ROLE="$1"
PASS=0; FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
bad()  { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL+1)); }
info() { echo -e "  ${YELLOW}[INFO]${NC} $1"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
step() { echo -e "\n== $1 =="; }

summary() {
    echo ""
    echo "############################################################"
    echo -e "  Summary: ${GREEN}PASS=$PASS${NC}  ${RED}FAIL=$FAIL${NC}"
    echo "############################################################"
}

if [[ "$ROLE" != "master" && "$ROLE" != "node" ]]; then
    echo "Usage: sudo $0 master|node"
    exit 1
fi

# kubectl needs a kubeconfig; under sudo, use the invoking user's or admin.conf
if [ -z "$KUBECONFIG" ]; then
    USER_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
    if [ -f "$USER_HOME/.kube/config" ]; then
        export KUBECONFIG="$USER_HOME/.kube/config"
    elif [ -f /etc/kubernetes/admin.conf ]; then
        export KUBECONFIG=/etc/kubernetes/admin.conf
    fi
fi

echo "############################################################"
echo "  Kubernetes environment + application verification -- role: $ROLE"
echo "############################################################"

step "1. Hostname and machine-id are unique (cloned VMs are a common trap)"
info "hostname=$(hostname)  machine-id=$(cut -c1-12 /etc/machine-id)..."
info "Compare these values across all three nodes -- they must all differ"

step "2. Swap disabled (required by Kubernetes)"
if [ -z "$(swapon --show)" ]; then
    ok "Swap is off"
else
    bad "Swap is on -- kubelet will not run properly: sudo swapoff -a"
fi

step "3. Kernel modules (br_netfilter / overlay)"
for m in br_netfilter overlay; do
    if lsmod | grep -q "^$m"; then
        ok "Kernel module $m loaded"
    else
        bad "Kernel module $m not loaded: sudo modprobe $m"
    fi
done

step "4. Kernel network parameters"
for p in net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward; do
    VAL=$(sysctl -n "$p" 2>/dev/null)
    if [ "$VAL" == "1" ]; then
        ok "$p = 1"
    else
        bad "$p = ${VAL:-unset} (expected 1)"
    fi
done

step "5. Docker cgroup driver (Kubernetes expects systemd)"
DRIVER=$(docker info 2>/dev/null | grep -i "Cgroup Driver" | awk '{print $NF}')
if [ "$DRIVER" == "systemd" ]; then
    ok "Docker Cgroup Driver = systemd"
else
    bad "Docker Cgroup Driver = ${DRIVER:-unknown} (expected systemd -- check /etc/docker/daemon.json)"
fi

step "6. cri-dockerd"
systemctl is-active --quiet cri-docker.socket && ok "cri-docker.socket is running" || bad "cri-docker.socket is not running"
if systemctl is-active --quiet cri-docker.service; then
    ok "cri-docker.service is running"
else
    info "cri-docker.service not running is normal (socket-activated; kubelet starts it on demand)"
fi
[ -S /var/run/cri-dockerd.sock ] && ok "CRI socket exists: /var/run/cri-dockerd.sock" || bad "CRI socket missing"
if [ -S /run/containerd/containerd.sock ] && [ -S /var/run/cri-dockerd.sock ]; then
    info "Both containerd.sock and cri-dockerd.sock exist -- always pass --cri-socket unix:///var/run/cri-dockerd.sock to kubeadm"
fi

step "7. kubelet / kubeadm / kubectl installed and held"
for bin in kubelet kubeadm kubectl; do
    if command -v $bin >/dev/null 2>&1; then
        case $bin in
            kubectl) VER=$(kubectl version --client 2>/dev/null | head -1) ;;
            kubeadm) VER=$(kubeadm version -o short 2>/dev/null) ;;
            kubelet) VER=$(kubelet --version 2>/dev/null) ;;
        esac
        ok "$bin installed: ${VER:-version unavailable}"
    else
        bad "$bin not installed"
    fi
done
HELD=$(apt-mark showhold 2>/dev/null | grep -cE "^(kubelet|kubeadm|kubectl)$")
if [ "$HELD" -eq 3 ]; then
    ok "kubelet/kubeadm/kubectl are held (apt-mark hold)"
else
    bad "Only $HELD/3 packages held. Run: sudo apt-mark hold kubelet kubeadm kubectl"
fi

step "8. kubelet runtime endpoint"
if grep -q "cri-dockerd.sock" /etc/default/kubelet 2>/dev/null || grep -rqs "cri-dockerd.sock" /var/lib/kubelet/kubeadm-flags.env; then
    ok "kubelet points to cri-dockerd.sock"
else
    bad "kubelet is not configured to use cri-dockerd.sock (/etc/default/kubelet)"
fi

step "9. System clock synchronized (clock drift breaks TLS certificates)"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    ok "System clock is NTP-synchronized"
else
    bad "System clock not synchronized -- certificates may appear 'not yet valid'"
fi

if [ "$ROLE" == "node" ]; then
    step "10. kubelet status (worker; should be active after kubeadm join)"
    systemctl is-active --quiet kubelet && ok "kubelet is running" || info "kubelet not running -- normal if kubeadm join has not been run yet"
    summary
    exit 0
fi

# ------------------ master node only ------------------

step "10. Cluster nodes (kubectl get nodes -- all should be Ready)"
if command -v kubectl >/dev/null 2>&1; then
    NODES=$(kubectl get nodes --no-headers 2>/dev/null)
    echo "$NODES" | sed 's/^/    /'
    TOTAL=$(echo "$NODES" | grep -c .)
    READY=$(echo "$NODES" | grep -c " Ready ")
    if [ "$READY" -eq "$TOTAL" ] && [ "$TOTAL" -eq 3 ]; then
        ok "All 3 nodes Ready"
    else
        bad "$READY/$TOTAL nodes Ready (expected 3/3). Check Flannel and kubeadm join"
    fi
else
    bad "kubectl not available, cannot check the cluster"
fi

step "11. Flannel pods"
FLANNEL=$(kubectl get pods -n kube-flannel --no-headers 2>/dev/null)
if [ -n "$FLANNEL" ]; then
    echo "$FLANNEL" | sed 's/^/    /'
    NOTRUNNING=$(echo "$FLANNEL" | grep -vc "Running")
    if [ "$NOTRUNNING" -eq 0 ]; then
        ok "All Flannel pods Running"
    else
        bad "Some Flannel pods are not Running"
    fi
else
    bad "No pods in kube-flannel namespace -- was the Flannel manifest applied?"
fi

step "12. kube-system core pods"
SYS=$(kubectl get pods -n kube-system --no-headers 2>/dev/null)
NOTRUNNING=$(echo "$SYS" | grep -vc "Running")
if [ "$NOTRUNNING" -eq 0 ] && [ -n "$SYS" ]; then
    ok "All kube-system pods Running"
else
    bad "Problem pods in kube-system:"
    echo "$SYS" | grep -v "Running" | sed 's/^/    /'
fi

step "13. WordPress on Kubernetes (10.7.1)"
WP_PODS=$(kubectl get pods --no-headers 2>/dev/null | grep -E "wordpress|mysql")
if [ -n "$WP_PODS" ]; then
    echo "$WP_PODS" | sed 's/^/    /'
    NOTRUNNING=$(echo "$WP_PODS" | grep -vc "Running")
    if [ "$NOTRUNNING" -eq 0 ]; then
        ok "WordPress/MySQL pods Running"
    else
        bad "Some WordPress/MySQL pods not Running -- use: kubectl describe pod <name>"
    fi

    SVC=$(kubectl get svc wordpress -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [ -n "$SVC" ]; then
        ok "WordPress Service NodePort=$SVC"
        NODEIP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${NODEIP}:${SVC}/" 2>/dev/null)
        if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
            ok "http://${NODEIP}:${SVC}/ returned $HTTP_CODE (WordPress reachable)"
        else
            bad "http://${NODEIP}:${SVC}/ returned $HTTP_CODE -- check the Service and pods"
        fi
    else
        bad "Could not read the NodePort of the wordpress Service"
    fi
else
    skip "No WordPress/MySQL pods found -- skipping (ignore if you skipped 10.7.1)"
fi

step "14. Deployment management spot check (10.7.2)"
kubectl get deployments 2>/dev/null | sed 's/^/    /'
info "Try scaling:        kubectl scale deployment wordpress --replicas=3"
info "Try a rollout:      kubectl rollout status deployment wordpress"

summary
