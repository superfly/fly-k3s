# K8s on Fly.io

This repository contains the code to create a Kubernetes cluster on Fly.io.
The cluster created will be a dual-stack cluster created using k3s.
The cluster prioritizes IPv6.

The cluster is created using the `k3s.sh` tool. The script can be used to
create the control-plane node and add worker nodes to the cluster.

## Configuration

`k3s.sh` depends on a configuration that is stored as follows: `clusters/<cluster-name>/config`.
For example, the configuration of the cluster `fly-k3s-poc` can be found at `clusters/fly-k3s-poc/config`.

The configuration of the cluster `fly-k3s-poc` looks as follows:

```bash
CLUSTER_NAME=fly-k3s-poc
CLUSTER_CIDR="dead:beef:1:0::/56,10.1.0.0/16"
SERVICE_CIDR="dead:beef:1:1::/112,10.2.0.0/16"
CLUSTER_DNS="dead:beef:1:1::10"
REGION=sjc
NODE_GROUP_SIZE=6
VOLUME_SIZE=250
VOLUME_NAME=fly_k3s_poc_data
WORKER_VM_SIZE=performance-2x
WORKER_VM_MEMORY=16384
CP_VM_SIZE=performance-4x
CP_VM_MEMORY=16384
K3S_VERSION="v1.24.15+k3s1"
ORG_NAME="fly-org-slug-goes-here"
```

## 1. Creating the control-plane nodes

Once the configuration is set, the control-plane nodes can be created as follows:

```bash
./k3s.sh -c clusters/<cluster-name>/
```

Here `clusters/<cluster-name>/` is the path to the directory containing the configuration of the cluster.

This will setup a 3-node control plane using the node with index of 0 to bootstrap the remaining nodes.

You can use the BOOTSTRAP_NODE_ID variable to override the default index for emergency maintenance scenarios:

```
❯ BOOTSTRAP_NODE_ID=1 ./k3s.sh -c clusters/fly-k3s-poc
[INFO]  Importing cluster config ./fly/clusters/fly-k3s-poc/config
[INFO]  Setting cluster name to fly-k3s-poc
[INFO]  Creating cluster fly-k3s-poc
[INFO]  Checking if node exists... (name: ctrl-0, vm-size: shared-cpu-4x)
[INFO]  Creating volume... (name: fly_k3s_poc_data, region: iad, size: 250)
[INFO]  Creating control plane node... (name: ctrl-0, vm-size: shared-cpu-4x, zone: da22)
Remote builder fly-builder-billowing-shape-893 ready
==> Building image with Docker
--> docker host: 20.10.12 linux x86_64
...
```

## 2. Add worker nodes

Once the control-plane nodes are created, worker nodes can be added to the cluster in the form of node groups.
A node group consists of N nodes where N is the number of unique zones in the region.

```bash
./k3s.sh -a 0 clusters/<cluster-name>/
```

You can keep adding as many worker nodes as needed.

## 3. Setup kubeconfig on your local machine

Once the cluster is created, you can setup the kubeconfig file as follows:

```bash
./k3s.sh -k clusters/<cluster-name>/
```

Then you can run `kubectl` commands as follows:

```bash
KUBECONFIG=$HOME/.kube/<cluster-name> kubectl get nodes
```

This assumes that you have the wireguard tunnel setup on your local machine.

## Accessing the cluster via SSH

You can login to the control-plane node as follows:

```bash
./k3s.sh -s cp clusters/<cluster-name>/
```

Once logged in, you can use `kubectl` or `k` to access the cluster.

```bash
k get nodes
```

## Notes

### Kernel modules

Fly machines run with kernel modules disabled. This means that the networking related modules
needed by Kubernetes are not available. The host kernel needs to be built with the modules
bundled inside the kernel. The following kernel config options need to be enabled:

```bash
# required by k3s for iptables management
CONFIG_NETFILTER_XT_MATCH_MULTIPORT=y
CONFIG_NETFILTER_XT_MATCH_IPVS=y
CONFIG_INET_ESP=y
CONFIG_VXLAN=y
CONFIG_IP_VS_RR=y
CONFIG_IP_VS=y
CONFIG_NET_CLS_CGROUP=y
CONFIG_INET_XFRM_MODE_TRANSPORT=y
CONFIG_NETFILTER_XT_TARGET_NOTRACK=y
CONFIG_NETFILTER_XT_TARGET_NFLOG=y
CONFIG_NETFILTER_XT_MATCH_LIMIT=y
CONFIG_IP6_NF_TARGET_REJECT=y
CONFIG_NETFILTER_XT_MATCH_PHYSDEV=y
CONFIG_NETFILTER_XT_TARGET_TPROXY=y
CONFIG_NF_TPROXY_IPV4=y
CONFIG_NF_TPROXY_IPV6=y

# required by systemd
CONFIG_AUTOFS4_FS=y

# required by longhorn
CONFIG_NFS_V4=y
CONFIG_NFS_FS=y
```

### Networking

The cluster is created by default with flannel as the CNI. We use the
Fly machine's private 6PN address as the node IP.

For a given fly app, all the machines within that app are part of the same subnet.
For example the machines below all have the same /64 prefix (the fly org v6 prefix):

- <fly_org_v6_prefix>:a7b:16f:9018:7aee:2
- <fly_org_v6_prefix>:a7b:181:3292:c3ab:2
- <fly_org_v6_prefix>:a7b:138:fdc5:30aa:2
- <fly_org_v6_prefix>:a7b:16b:c967:5e63:2

### Logging into the systemd namespace

From one of the nodes login to the systemd namespace as follows:

```bash
nsenter --all -t $(pgrep -xo systemd) runuser -P -l root -c "exec $SHELL"
```

## Benchmarking

### Network benchmark

Start the iperf3 server pod as follows:

```bash
kubectl apply -f /etc/kubernetes/manifests/tools/iperf-server.yaml
```

Start the sender pod as follows:

```bash
kubectl apply -f /etc/kubernetes/manifests/tools/pod-worker.yaml
```

Run tcp test with 4 parallel streams:

```bash
IPERF3_IP=$(kubectl get pods iperf-server -o jsonpath='{.status.podIP}')
kubectl exec -it pod-worker -- iperf3 -c $IPERF3_IP -i 1 -t 10 -P 4
```

Run udp test with 4 parallel streams:

```bash
IPERF3_IP=$(kubectl get pods iperf-server -o jsonpath='{.status.podIP}')
kubectl exec -it pod-worker -- iperf3 -c $IPERF3_IP -i 1 -t 10 -P 4 -u -b 1G
```

Max throughput seen pod to pod: 1.2Gbps

### Disk benchmark

Start the benchmark job as follows:

```bash
kubectl create -f /etc/kubernetes/manifests/tools/fio-benchmarks/fio-deploy.yaml
```

Check the benchmarks logs:

```bash
kubectl logs -f dbench-l5fss-gtfhz
```
