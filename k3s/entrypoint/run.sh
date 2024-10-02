#!/usr/bin/env bash

set -euo pipefail

info()
{
  echo '[INFO] ' "$@"
}
warn()
{
  echo '[WARN] ' "$@" >&2
}
fatal()
{
  echo '[ERROR] ' "$@" >&2
  exit 1
}

BIN_DIR=/usr/local/bin

if [ "${ROLE}" = "server" ]; then
  SYSTEM_NAME=k3s
else
  SYSTEM_NAME=k3s-${ROLE}
fi

SERVICE_K3S=${SYSTEM_NAME}.service
SYSTEMD_DIR=/etc/systemd/system
FILE_K3S_SERVICE=${SYSTEMD_DIR}/${SERVICE_K3S}
SERVICE_K3S_SYSTEMD_LINK=${SYSTEMD_DIR}/multi-user.target.wants/${SERVICE_K3S}
DATA_DIR_K3S=/data/k3s
CONFIG_DIR_K3S=/etc/rancher/k3s
CONFIG_FILE_K3S=${DATA_DIR_K3S}/config.yaml
CONFIG_FILE_K3S_LINK=${CONFIG_DIR_K3S}/config.yaml
NODE_DIR_K3S=${DATA_DIR_K3S}/node
NODE_DIR_K3S_LINK=/etc/rancher/node
ISCSI_SYSTEM_NAME=iscsid
SERVICE_ISCSI=${ISCSI_SYSTEM_NAME}.service
DATA_DIR_OPENEBS=/data/openebs

# --- set machine-id ---
set_machine_id() {
  echo "$FLY_MACHINE_ID" > /etc/machine-id
}

# --- load sysctl settings ---
setup_sysctls() {
  info "setting sysctl settings"

  sysctl -w net.bridge.bridge-nf-call-iptables=1
  sysctl -w net.bridge.bridge-nf-call-ip6tables=1
  sysctl -w net.ipv4.ip_forward=1
  sysctl -w net.ipv4.conf.all.src_valid_mark=1
  sysctl -w net.ipv6.conf.all.forwarding=1
  sysctl -w net.ipv6.conf.all.disable_ipv6=0
  sysctl -w net.ipv4.tcp_congestion_control=bbr
  sysctl -w vm.overcommit_memory=1
  sysctl -w kernel.panic=10
  sysctl -w net.ipv4.conf.all.rp_filter=1
  sysctl -w kernel.panic_on_oops=1
}

setup_limits() {
  info "setting limits"

  ulimit -n 1048576    # open files
  ulimit -u unlimited  # num processes
}

# --- setup shared mount. Kubernetes mount propagation requires shared mounts ---
setup_shared_mount() {
  info "setting shared mount"

  mount --make-rshared /
}

# --- move /var/log/pods to the data volume
setup_pod_logs() {
  info "mounting pod log directory"
  logdir="/data/logs"
  podlogdir="/var/log/pods"

  [ ! -d "${logdir}" ] && mkdir "${logdir}"
  [ ! -d "${podlogdir}" ] && mkdir "${podlogdir}"
  mount --bind "${logdir}" "${podlogdir}"
}

# --- move /var/lib/kubelet/pods to data volume
setup_pod_temp() {
  info "mounting pod temp directory"
  tmpdir="/data/podtemp"
  podtmpdir="/var/lib/kubelet/pods"

  [ ! -d "${tmpdir}" ] && mkdir "${tmpdir}"
  [ ! -d "${podtmpdir}" ] && mkdir -p "${podtmpdir}"
  mount --bind "${tmpdir}" "${podtmpdir}"
}

# --- install k3s if this is the first time machine is booted ---
install_k3s() {
  if [ ! -L "$SERVICE_K3S_SYSTEMD_LINK" ]; then
    info "installing k3s"
    INSTALL_K3S_SKIP_ENABLE=true INSTALL_K3S_EXEC=$ROLE INSTALL_K3S_VERSION=$K3S_VERSION /install_k3s.sh

    # systemd is not available yet, so we need to create the symlink manually
    ln -s "$FILE_K3S_SERVICE" "$SERVICE_K3S_SYSTEMD_LINK"
  else
    info "k3s already installed"
  fi
}

# --- set up k3s configuration ---
configure_k3s() {
  info "configuring k3s"

  # Setup directories for k3s
  mkdir -p $DATA_DIR_K3S

  # Setup k3s configuration
  mkdir -p $CONFIG_DIR_K3S

  # Setup openebs directory
  mkdir -p $DATA_DIR_OPENEBS

  # NOTE: IP addresses might change during fly machine migrations
  # Thus, we need to update configuration on each machine start
  
  # Obtain primary IPv4 address
  FLY_PRIVATE_IPV4=$(ip -4 -j addr show eth0 | jq '.[].addr_info[] | select(.secondary != true) | .local' -r)

  # We will use the 6PN IP address for all communication between the machines
  FLY_PRIVATE_IPV6=$(awk '/fly-local-6pn/ { print $1 }' /etc/hosts)

  # This is the DNS name of the application
  FLY_APP_DNS_NAME="${FLY_APP_NAME}.internal"

  # Work in progress config file
  CONFIG_FILE_K3S_WIP="${CONFIG_FILE_K3S}.wip"

  # Setup the k3s configuration that is common to the control plane and worker nodes
  cat <<EOF > $CONFIG_FILE_K3S_WIP
node-name: "${FLY_ALLOC_ID}.vm.${FLY_APP_DNS_NAME}"
kubelet-arg:
  - "node-ip=::"
data-dir: "/data/k3s"
node-ip: "${FLY_PRIVATE_IPV6},${FLY_PRIVATE_IPV4}"
node-external-ip: "$FLY_PRIVATE_IPV6"
node-label:
  - "topology.kubernetes.io/region=$REGION"
  - "topology.kubernetes.io/zone=$ZONE"
EOF

  # Add additional configuration if this is a server (control-plane) node
  if [ "$ROLE" = "server" ]; then
    # This configuration is only needed on the server nodes and will be
    # pushed to the agent nodes by the server nodes.
    cat <<EOF >> $CONFIG_FILE_K3S_WIP
cluster-cidr: "$CLUSTER_CIDR"
service-cidr: "$SERVICE_CIDR"
cluster-dns: "$CLUSTER_DNS"
flannel-backend: wireguard-native
flannel-external-ip: true
flannel-ipv6-masq: true
etcd-expose-metrics: true
EOF
    # If this is the bootstrap node, we additionally need to set cluster-init
    if [ "$BOOTSTRAP" = "true" ]; then
      cat <<EOF >> $CONFIG_FILE_K3S_WIP
cluster-init: true
EOF
    else
      # if this is not the bootstrap node then we need to point this node to
      # the bootstrap node
      cat <<EOF >> $CONFIG_FILE_K3S_WIP
server: "https://${SERVER}:6443"
token: "${TOKEN}"
EOF
    fi

    # Additional for server (control-plane) nodes we want to set the 
    # Subject Alternative Name in the TLS certificate to the DNS name of the
    # application. This allows us to provide a fixed DNS name as the server
    # address to the agent nodes.
    cat <<EOF >> $CONFIG_FILE_K3S_WIP
tls-san: 
  - "${FLY_APP_DNS_NAME}"
EOF
  fi

  # Add additional configuration if this is an agent node
  if [ "$ROLE" = "agent" ]; then
    cat <<EOF >> $CONFIG_FILE_K3S_WIP
server: "https://${SERVER}:6443"
token: "${TOKEN}"
EOF
  fi

  # Update configuration file, if there are applicable changes
  if [ -f "${CONFIG_FILE_K3S}" ] && ! diff "${CONFIG_FILE_K3S}" "${CONFIG_FILE_K3S_WIP}" >/dev/null 2>&1; then
    info "Backing up and updating configuration ${CONFIG_FILE_K3S}"
    mv "${CONFIG_FILE_K3S}" "${CONFIG_FILE_K3S}.backup.$(date +%s)"
    mv "${CONFIG_FILE_K3S}.wip" "${CONFIG_FILE_K3S}"
  elif [ ! -f "${CONFIG_FILE_K3S}" ]; then
    info "Creating new configuration ${CONFIG_FILE_K3S}"
    mv "${CONFIG_FILE_K3S}.wip" "${CONFIG_FILE_K3S}"
  else
    info "No changes to configuration ${CONFIG_FILE_K3S}"
  fi

  # Ensure a symlink to the config exists
  if [ ! -e "${CONFIG_FILE_K3S_LINK}" ]; then
    ln -s "$CONFIG_FILE_K3S" "$CONFIG_FILE_K3S_LINK"
  fi
}

setup_k3s_node_dir() {
  info "setting up k3s node dir, linking $NODE_DIR_K3S to $NODE_DIR_K3S_LINK"

  mkdir -p $NODE_DIR_K3S
  ln -s "$NODE_DIR_K3S" "$NODE_DIR_K3S_LINK"
}

# --- enable iscid service required by longhorn ---
setup_iscsid_service() {
  if [ ! -L ${SYSTEMD_DIR}/sysinit.target.wants/${SERVICE_ISCSI} ]; then
    info "setting up iscsid service"

    ln -s /lib/systemd/system/${SERVICE_ISCSI} ${SYSTEMD_DIR}/sysinit.target.wants/${SERVICE_ISCSI}
  fi
}

# --- run the k3s config check --
run_k3s_config_check() {
  info "running k3s config check"

  ${BIN_DIR}/k3s check-config
}

# --- run the setup process --
{
  set_machine_id
  setup_sysctls
  setup_limits
  setup_shared_mount
  install_k3s
  configure_k3s
  setup_k3s_node_dir
  setup_pod_logs
  setup_pod_temp
  setup_iscsid_service
  run_k3s_config_check
}

# --- startup the init process now
info "starting systemd"
exec unshare --pid --fork --mount-proc /lib/systemd/systemd
