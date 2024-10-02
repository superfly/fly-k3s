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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Organization name (stored in config)
ORG_NAME=

# The name prefixes of the nodes
CONTROLLER_NODE_PREFIX="ctrl-"
WORKER_NODE_PREFIX="worker-ng-"

# The directory containing the cluster config
CLUSTER_CONFIG_DIR=

# The name of the cluster
CLUSTER_NAME=

# The bootstrap node id, defaults to 0
BOOTSTRAP_NODE_ID=${BOOTSTRAP_NODE_ID:-0}
info "Bootstrap node id is ${BOOTSTRAP_NODE_ID}"

# We create two different fly apps for the cluster 
# One for the controller nodes and one for the worker nodes
FLY_APP_NAME_CP=
FLY_APP_NAME_WORKERS_PREFIX=

# Fly commands
FLY_CMD=fly

# The fly command with the app name set to the cluster name suffixed with "-cp"
FLY_CMD_CP=

# check for required binaries
for prog in $FLY_CMD jq openssl; do
  command -v "$prog" >/dev/null 2>&1 || { echo >&2 "I require $prog but it's not installed.  Aborting."; exit 1; }
done

# --- usage info --- 
usage() {
  cat <<EOF
A utility to create a k3s cluster on fly.io

Usage: $(basename "$0") [-a|-c|-l|-s|-h] cluster_dir
a             - add a node to the k3s cluster (requires an argument [node_group_id])
c             - create the k3s cluster
l             - list nodes in the k3s cluster (requires an argument [cp|workers])
s             - ssh into a node in the k3s cluster (requires an argument [cp|workers])
k             - fetch kubeconfig for the k3s cluster
h             - help
cluster_dir   -  the directory containing the cluster config
EOF
}

# --- creates the fly apps corresponding to the cluster ---
create_fly_app() {
  if [[ $# != 1 ]]; then
    fatal "create_fly_app requires 1 argument"
  fi

  local fly_app_name="$1"

  if [[ $($FLY_CMD apps list -o $ORG_NAME -j | jq '.[] | select(.ID=="'"$fly_app_name"'") | .ID' -r 2>/dev/null) != "$fly_app_name" ]]; then
    info "Creating fly app... (name: $fly_app_name)"
    $FLY_CMD apps create "$fly_app_name" -o $ORG_NAME
  fi
}

# --- fetches the instance id of a node ---
fetch_instance_id() {
  local node_name="$1"
  local node_id=

  node_id=$($FLY_CMD_CP machine list -j | jq '.[] | select(.name=="'"$node_name"'") | .id' -r)
  if [[ -z "$node_id" ]]; then
    fatal "Node not found"
  fi

  # return the token
  echo "$node_id"
}

fetch_bootstrap_instance_id() {
  fetch_instance_id "${CONTROLLER_NODE_PREFIX}${BOOTSTRAP_NODE_ID}"
}

# --- creates the volume without snapshots ---
create_volume_without_snapshot() {
  if [[ $# != 1 ]]; then
    fatal "create_volume requires 1 argument"
  fi

  local fly_cmd="$1"
  local volume_info=
  local volume_id=

  volume_info=$(create_volume "${fly_cmd}")
  volume_id=$(echo "$volume_info" | jq '.id' -r)

  # Disable automatic volume snapshots
  $fly_cmd volume update "${volume_id}" --scheduled-snapshots=false > /dev/null

  echo "${volume_info}"
}

# --- creates the volume ---
create_volume() {
  if [[ $# != 1 ]]; then
    fatal "create_volume requires 1 argument"
  fi

  local fly_cmd="$1"
  local volume_info=

  volume_info=$($fly_cmd volumes create "$VOLUME_NAME" --region "$REGION" --size "$VOLUME_SIZE" --require-unique-zone --yes -j)

  if [[ $(echo "$volume_info" | jq .id -r) != "vol_"* ]]; then
    fatal "Failed to create volume"
  fi

  if [[ $(echo "$volume_info" | jq .zone -r) == "null" ]]; then
    fatal "Failed to fetch zone info for volume"
  fi

  # return the volume id and zone
  echo "$volume_info"
}

node_exists() {
  [ $# -ne 1 ] && fatal "incorrect number of arguments"
  node_name="$1"
  if [[ $($FLY_CMD_CP machine list -j | jq '.[] | select(.name=="'"$node_name"'") | .name' -r 2>/dev/null) == "$node_name" ]]; then
    return 0
  else
    return 1
  fi
}

# --- creates the control plane node ---
create_controlplane_node() {
  if [[ $# != 1 ]]; then
    fatal "create_controlplane_node requires 1 argument"
  fi

  local node_id="$1"

  # node_id: 0 is always the bootstrap node
  local node_name="${CONTROLLER_NODE_PREFIX}${node_id}"

  info "Checking if node exists... (name: $node_name, vm-size: $CP_VM_SIZE)"
  # check if controller already exists
  if [[ $($FLY_CMD_CP machine list -j | jq '.[] | select(.name=="'"$node_name"'") | .name' -r 2>/dev/null) == "$node_name" ]]; then
    return 0
  fi

  # create volume
  info "Creating volume... (name: $VOLUME_NAME, region: $REGION, size: $VOLUME_SIZE)"
  local volume_info='' volume_id='' volume_zone=''

  volume_info=$(create_volume_without_snapshot "$FLY_CMD_CP")
  volume_id=$(echo "$volume_info" | jq .id -r)
  volume_zone=$(echo "$volume_info" | jq .zone -r)

  # create controller node
  if [[ "$node_id" == "${BOOTSTRAP_NODE_ID}" ]]; then
    info "Creating bootstrap node... (name: $node_name, vm-size: $CP_VM_SIZE, zone: $volume_zone)"
    $FLY_CMD_CP machine run . \
      --name "$node_name" \
      --vm-size "$CP_VM_SIZE" \
      --vm-memory "$CP_VM_MEMORY" \
      --region "$REGION" \
      --env REGION="$REGION" \
      --env ZONE="$volume_zone" \
      --env BOOTSTRAP=true \
      --env K3S_VERSION="$K3S_VERSION" \
      --env ROLE=server \
      --env CLUSTER_CIDR="$CLUSTER_CIDR" \
      --env SERVICE_CIDR="$SERVICE_CIDR" \
      --env CLUSTER_DNS="$CLUSTER_DNS" \
      --volume "$volume_id:/data"

      # we need to wait for the bootstrap node to be ready before we can create the other nodes
      info "Waiting for bootstrap node to be ready..."
      local bootstrap_instance_id=
      local node_status=

      bootstrap_instance_id=$(fetch_bootstrap_instance_id)
      while true; do
        node_status=$($FLY_CMD_CP machine exec "$bootstrap_instance_id" "k3s kubectl get nodes -o jsonpath='{.items..status.conditions[-1:].status}'")
        if [[ "$node_status" == "True" ]]; then
          break
        fi
        sleep 5
      done

      info "Installing openebs..."
      $FLY_CMD_CP machine exec "$bootstrap_instance_id" "k3s kubectl apply -f /etc/kubernetes/manifests/openebs/"

      info "Bootstrap node ready"
  else
    info "Creating control plane node... (name: $node_name, vm-size: $CP_VM_SIZE, zone: $volume_zone)"

    # fetch the token from the bootstrap node
    local bootstrap_instance_id=
    local token=

    bootstrap_instance_id=$(fetch_bootstrap_instance_id)
    token=$($FLY_CMD_CP machine exec "$bootstrap_instance_id" "cat /data/k3s/server/token")
    if [[ -z "$token" ]]; then
      fatal "Failed to get token from bootstrap node"
    fi

    $FLY_CMD_CP machine run . \
      --name "$node_name" \
      --vm-size "$CP_VM_SIZE" \
      --vm-memory "$CP_VM_MEMORY" \
      --region "$REGION" \
      --env REGION="$REGION" \
      --env ZONE="$volume_zone" \
      --env BOOTSTRAP=false \
      --env K3S_VERSION="$K3S_VERSION" \
      --env TOKEN="$token" \
      --env SERVER="$bootstrap_instance_id.vm.$FLY_APP_NAME_CP.internal" \
      --env ROLE=server \
      --env CLUSTER_CIDR="$CLUSTER_CIDR" \
      --env SERVICE_CIDR="$SERVICE_CIDR" \
      --env CLUSTER_DNS="$CLUSTER_DNS" \
      --volume "$volume_id:/data"
  fi
}

# --- creates the fly app corresponding to the cluster and the controller node ---
create_cluster() {
  # create the fly app for the control plane nodes if it doesn't exist
  create_fly_app "$FLY_APP_NAME_CP"

  # create the control plane nodes
  for i in {0..2}; do
    create_controlplane_node "$i"
  done

  taint_controlplane
}

# --- blocks control nodes from running generic workload ---
taint_controlplane() {
  for i in {0..2}; do
    taint_controlplane_node "$i"
  done
}

# --- blocks a single control node from running generic workload ---
taint_controlplane_node() {
  local node_id="$1"
  local node_name="${CONTROLLER_NODE_PREFIX}${node_id}"
  instance_id=$(fetch_instance_id "$node_name")
  instance_name="${instance_id}.vm.${FLY_APP_NAME_CP}.internal"

  $FLY_CMD_CP machine exec "${instance_id}" "k3s kubectl taint node ${instance_name} CriticalAddonsOnly=true:NoExecute"
}

# --- add worker node ---
add_worker_nodegroup() {
  if [[ $# != 1 ]]; then
    fatal "add_worker_nodegroup requires 1 argument"
  fi

  local nodegroup_id="$1"
  local fly_app_name="${FLY_APP_NAME_WORKERS_PREFIX}-${nodegroup_id}"
  local fly_cmd_worker="${FLY_CMD} -a $fly_app_name"

  # create the fly app for the worker nodes if it doesn't exist
  create_fly_app "$fly_app_name"

  # fetch the token from the bootstrap node
  local bootstrap_instance_id='' token=''

  bootstrap_instance_id=$(fetch_bootstrap_instance_id)
  token=$($FLY_CMD_CP machine exec "$bootstrap_instance_id" "cat /data/k3s/server/token")
  if [[ -z "$token" ]]; then
    fatal "Failed to get token from bootstrap node"
  fi

  # for the worker nodes we use the DNS name of the control plane fly app as the server address
  # this is to avoid dependency on a static control plane node
  local server="$FLY_APP_NAME_CP.internal"

  # create the worker nodes
  for ((i=0; i<NODE_GROUP_SIZE; i++)); do
    local node_name="${WORKER_NODE_PREFIX}${nodegroup_id}-${i}"

    info "Checking if node exists... (name: $node_name, vm-size: $WORKER_VM_SIZE)"
    # check if worker node already exists
    if [[ $($fly_cmd_worker machine list -j | jq '.[] | select(.name=="'"$node_name"'") | .name' -r 2>/dev/null) == "$node_name" ]]; then
      continue
    fi

    info "Creating volume... (name: $VOLUME_NAME, region: $REGION, size: $VOLUME_SIZE)"
    local volume_info='' volume_id='' volume_zone=''

    volume_info=$(create_volume_without_snapshot "$fly_cmd_worker")
    volume_id=$(echo "$volume_info" | jq '.id' -r)
    volume_zone=$(echo "$volume_info" | jq '.zone' -r)

    info "Creating worker node... (name: $node_name, vm-size: $WORKER_VM_SIZE, zone: $volume_zone)"
    $fly_cmd_worker machine run . \
      --name "$node_name" \
      --vm-size "$WORKER_VM_SIZE" \
      --vm-memory "$WORKER_VM_MEMORY" \
      --region "$REGION" \
      --env K3S_VERSION="$K3S_VERSION" \
      --env REGION="$REGION" \
      --env ZONE="$volume_zone" \
      --env ROLE=agent \
      --env SERVER="$server" \
      --env TOKEN="$token" \
      --volume "$volume_id:/data"
  done
}

# --- list nodes ---
list_nodes() {
  if [[ $# != 1 ]]; then
    fatal "list_nodes requires 1 argument [cp|node_group_id]"
  fi

  local node_group="$1"

  if [[ "$node_group" == "cp" ]]; then
    $FLY_CMD_CP machine list
  else
    fly -a "${FLY_APP_NAME_WORKERS_PREFIX}-${node_group}" machine list
  fi
}

# --- ssh into node ---
ssh_node() {
  if [[ $# != 1 ]]; then
    fatal "ssh_node requires 1 argument [cp|node_group_id]"
  fi

  local node_group="$1"

  if [[ "$node_group" == "cp" ]]; then
    $FLY_CMD_CP ssh console --select
  else
    fly -a "${FLY_APP_NAME_WORKERS_PREFIX}-${node_group}" ssh console --select
  fi
}

# --- fetch kubeconfig ---
fetch_kubeconfig() {
  # fetch the token from the bootstrap node
  local bootstrap_instance_id='' kubeconfig=''

  bootstrap_instance_id=$(fetch_bootstrap_instance_id)
  kubeconfig=$($FLY_CMD_CP machine exec "$bootstrap_instance_id" "cat /etc/rancher/k3s/k3s.yaml")
  if [[ -z "$kubeconfig" ]]; then
    fatal "Failed to get kubeconfig from bootstrap node"
  fi

  # replace the server address with the DNS name of the control plane fly app
  kubeconfig=$(echo "$kubeconfig" | sed "s/server: https:\/\/127.0.0.1:6443/server: https:\/\/$FLY_APP_NAME_CP.internal:6443/g" | sed "s/default/${CLUSTER_NAME}/")

  # write the kubeconfig to a file
  local kubeconfig_dir="$HOME/.kube"
  info "Writing kubeconfig to $kubeconfig_dir/$CLUSTER_NAME"
  
  mkdir -p "$HOME/.kube"
  echo "$kubeconfig" > "$kubeconfig_dir/$CLUSTER_NAME"
}

# --- validate config ---
validate_config() {
  if [[ -z "$CLUSTER_NAME" ]]; then
    fatal "CLUSTER_NAME not specified in config"
  fi

  if [[ -z "$CLUSTER_CIDR" ]]; then
    fatal "CLUSTER_CIDR not specified in config"
  fi

  if [[ -z "$SERVICE_CIDR" ]]; then
    fatal "SERVICE_CIDR not specified in config"
  fi

  if [[ -z "$CLUSTER_DNS" ]]; then
    fatal "CLUSTER_DNS not specified in config"
  fi

  if [[ -z "$REGION" ]]; then
    fatal "REGION not specified in config"
  fi

  if [[ -z "$NODE_GROUP_SIZE" ]]; then
    fatal "NODE_GROUP_SIZE not specified in config"
  fi

  if [[ -z "$VOLUME_SIZE" ]]; then
    fatal "VOLUME_SIZE not specified in config"
  fi

  if [[ -z "$VOLUME_NAME" ]]; then
    fatal "VOLUME_NAME not specified in config"
  fi

  if [[ -z "$WORKER_VM_SIZE" ]]; then
    fatal "WORKER_VM_SIZE not specified in config"
  fi

  if [[ -z "$WORKER_VM_MEMORY" ]]; then
    fatal "WORKER_VM_MEMORY not specified in config"
  fi

  if [[ -z "$CP_VM_SIZE" ]]; then
    fatal "CP_VM_SIZE not specified in config"
  fi

  if [[ -z "$CP_VM_MEMORY" ]]; then
    fatal "CP_VM_MEMORY not specified in config"
  fi

  if [[ -z "$K3S_VERSION" ]]; then
    fatal "K3S_VERSION not specified in config"
  fi

  if [[ -z "$ORG_NAME" ]]; then
    fatal "ORG_NAME not specified in config"
  fi
}

# --- main ---
# The operation to perform
OPERATION=
OPERATION_ARG=

while getopts "a:ctl:s:kh" opt; do
  case "$opt" in
    a)
      OPERATION="add_worker_nodegroup"
      OPERATION_ARG="$OPTARG"
      break
      ;;
    c)
      OPERATION="create_cluster"
      break
      ;;
    t)
      OPERATION="taint_controlplane"
      break
      ;;
    l)
      OPERATION="list_nodes"
      OPERATION_ARG="$OPTARG"
      break
      ;;
    s)
      OPERATION="ssh_node"
      OPERATION_ARG="$OPTARG"
      break
      ;;
    k)
      OPERATION="fetch_kubeconfig"
      break
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

# Process the cluster config directory argument
shift $((OPTIND - 1))

if [[ $# != 1 ]]; then
  warn "Cluster config directory not specified"
  usage
  exit 1
fi

for arg in "$@"; do
  CLUSTER_CONFIG_DIR="$ROOT_DIR/${arg%/}"
done

if [[ ! -d "$CLUSTER_CONFIG_DIR" ]]; then
  fatal "Cluster directory $CLUSTER_CONFIG_DIR does not exist"
fi

if [[ ! -f "$CLUSTER_CONFIG_DIR/config" ]]; then
  fatal "Config $CLUSTER_CONFIG_DIR/config does not exist"
fi

# Import the cluster config
info "Importing cluster config $CLUSTER_CONFIG_DIR/config"

# shellcheck source=clusters/fly-k3s-poc/config
source "$CLUSTER_CONFIG_DIR/config"

# Validate the config
validate_config

info "Setting cluster name to $CLUSTER_NAME"

# Set the fly command to include the cluster name from the config
# For worker nodes the fly command will use $CLUSTER_NAME to select the app
# For controller nodes the fly command will use ${CLUSTER_NAME}-cp to select the app
FLY_APP_NAME_CP="${CLUSTER_NAME}-cp"
FLY_APP_NAME_WORKERS_PREFIX="${CLUSTER_NAME}-ng"
FLY_CMD_CP="fly -a $FLY_APP_NAME_CP"

# Run the operation
case "$OPERATION" in
  "add_worker_nodegroup")
    info "Adding node to cluster $CLUSTER_NAME"
    add_worker_nodegroup "$OPERATION_ARG"
    ;;
  "create_cluster")
    info "Creating cluster $CLUSTER_NAME"
    create_cluster
    ;;
  "taint_controlplane")
    info "Tainting control plane of $CLUSTER_NAME"
    taint_controlplane
    ;;
  "list_nodes")
    info "Listing $OPERATION_ARG nodes for cluster $CLUSTER_NAME"
    list_nodes "$OPERATION_ARG"
    ;;
  "ssh_node")
    info "SSH into $OPERATION_ARG nodes for cluster $CLUSTER_NAME"
    ssh_node "$OPERATION_ARG"
    ;;
  "fetch_kubeconfig")
    info "Fetching kubeconfig for cluster $CLUSTER_NAME"
    fetch_kubeconfig
    ;;
  *)
    usage
    exit 1
    ;;
esac
