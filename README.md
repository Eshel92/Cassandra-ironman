# Cassandra Multi-DC on Local Kubernetes (kind + Cilium + k8ssandra)

## Overview

This guide sets up two local Kubernetes clusters on a MacBook using `kind`, installs Cilium CNI with ClusterMesh for cross-cluster pod networking, and deploys Apache Cassandra in a multi-datacenter configuration using the k8ssandra operator.

### Architecture

```
MacBook (Docker - 8 CPUs, ~10 GB RAM)
├── cluster: dc1  (kind)
│   ├── Pod CIDR:     10.10.0.0/16
│   ├── Service CIDR: 10.11.0.0/16
│   ├── Cilium CNI    cluster-id=1, cluster-name=dc1
│   ├── cert-manager
│   ├── k8ssandra-operator
│   └── CassandraDatacenter: dc1  (JVM heap: 512MB)
│
└── cluster: dc2  (kind)
    ├── Pod CIDR:     10.20.0.0/16
    ├── Service CIDR: 10.21.0.0/16
    ├── Cilium CNI    cluster-id=2, cluster-name=dc2
    ├── cert-manager
    ├── k8ssandra-operator
    └── CassandraDatacenter: dc2  (JVM heap: 512MB)

Cilium ClusterMesh (NodePort-based tunnel)
→ Pods in dc1 can reach pods in dc2 by IP
→ Cassandra gossip and seed sharing across DCs
```

### Tool Versions Used

| Tool    | Version  | Status |
|---------|----------|--------|
| Docker  | 29.0.1   | ✅     |
| kind    | v0.31.0  | ✅     |
| kubectl | v1.34.1  | ✅     |
| helm    | v4.1.3   | ✅     |
| cilium  | TBD      | install|
| cmctl   | TBD      | install|

---

## Phase 1 — Install Missing CLI Tools

### What & Why

Two tools are missing from the environment:

- **cilium CLI** — official CLI for Cilium CNI. Used to install Cilium into clusters,
  enable ClusterMesh, connect clusters, and verify mesh health.
- **cmctl** — cert-manager CLI. Used to verify cert-manager installation, which is a
  hard dependency of the k8ssandra operator (it uses cert-manager to manage TLS certificates
  for Cassandra inter-node encryption).

### Commands

```bash
brew install cilium-cli
brew install cmctl
```

### Verification

```bash
cilium version
cmctl version
```

---

## Phase 2 — Create kind Cluster Config Files

### What & Why

kind (Kubernetes in Docker) spins up full Kubernetes clusters as Docker containers.
We need two clusters with:

- `disableDefaultCNI: true` — prevents kind from installing its default CNI (kindnet).
  Cilium will be installed instead. Without this flag, kindnet and Cilium would conflict.
- Non-overlapping Pod and Service CIDRs — required for ClusterMesh. If both clusters
  used the same IP ranges, pods in dc1 and dc2 would have conflicting addresses, making
  cross-cluster routing impossible.
- Single-node (control-plane only) — conserves the ~9.7 GB RAM. The control-plane node
  will also run workloads (taints are removed automatically by kind in single-node mode).

### Files Created

- `kind-dc1.yaml` — config for cluster-dc1
- `kind-dc2.yaml` — config for cluster-dc2

#### kind-dc1.yaml

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: dc1
networking:
  disableDefaultCNI: true
  podSubnet: "10.10.0.0/16"
  serviceSubnet: "10.11.0.0/16"
nodes:
- role: control-plane
```

#### kind-dc2.yaml

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: dc2
networking:
  disableDefaultCNI: true
  podSubnet: "10.20.0.0/16"
  serviceSubnet: "10.21.0.0/16"
nodes:
- role: control-plane
```

---

## Phase 3 — Create the kind Clusters

### What & Why

Spins up the two Kubernetes clusters using the config files above.
Each cluster runs as a Docker container (the control-plane node).
kind automatically:
- Generates kubeconfig entries (contexts: `kind-dc1`, `kind-dc2`)
- Sets up the Kubernetes API server, etcd, scheduler, controller-manager
- Does NOT install a CNI (we disabled it) — nodes will be in `NotReady` state until Cilium is installed

### Commands

```bash
kind create cluster --name dc1 --config kind-dc1.yaml
kind create cluster --name dc2 --config kind-dc2.yaml
```

### Verification

```bash
kubectl get nodes --context kind-dc1
kubectl get nodes --context kind-dc2
# Expected: nodes in NotReady (no CNI yet)
```

---

## Phase 4 — Install Cilium CNI on Both Clusters

### What & Why

Cilium is a CNI plugin that uses eBPF for networking and security.
We install it on both clusters with different `cluster.id` and `cluster.name` values —
these are required for ClusterMesh to distinguish traffic between the two clusters.

Key Helm values:
- `cluster.id` / `cluster.name` — unique per cluster, used for ClusterMesh routing
- `ipam.mode=kubernetes` — Cilium uses the pod CIDR assigned by Kubernetes (from kind config)
- `operator.replicas=1` — single-node cluster, only need 1 operator replica
- `hubble.relay.enabled=true` — enables Hubble (Cilium observability platform)
- `hubble.ui.enabled=true` — Hubble UI for visual network flow inspection

### Commands

```bash
# dc1
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
  --kube-context kind-dc1 \
  --namespace kube-system \
  --set cluster.name=dc1 \
  --set cluster.id=1 \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

# dc2
helm install cilium cilium/cilium \
  --kube-context kind-dc2 \
  --namespace kube-system \
  --set cluster.name=dc2 \
  --set cluster.id=2 \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

### Verification

```bash
cilium status --context kind-dc1
cilium status --context kind-dc2
kubectl get nodes --context kind-dc1   # should be Ready now
kubectl get nodes --context kind-dc2   # should be Ready now
```

---

## Phase 5 — Enable Cilium ClusterMesh

### What & Why

ClusterMesh is Cilium's multi-cluster networking feature.
It works by:
1. Exposing each cluster's Cilium etcd (key-value store) via a service
2. Connecting clusters so they share service and endpoint information
3. Enabling pods in dc1 to communicate directly with pod IPs in dc2 (and vice versa)

This is what allows Cassandra gossip protocol to work across clusters —
each Cassandra node needs to reach seed nodes in the other DC by pod IP.

`--service-type NodePort` is used because LoadBalancer is not available in kind
without additional tooling (like MetalLB). NodePort exposes the ClusterMesh API
on a host port accessible within the Docker network.

### Commands

```bash
# Enable ClusterMesh on both clusters
cilium clustermesh enable --context kind-dc1 --service-type NodePort
cilium clustermesh enable --context kind-dc2 --service-type NodePort

# Wait for ClusterMesh to be ready
cilium clustermesh status --context kind-dc1 --wait
cilium clustermesh status --context kind-dc2 --wait

# Connect the two clusters
cilium clustermesh connect \
  --context kind-dc1 \
  --destination-context kind-dc2

# Verify the connection
cilium clustermesh status --context kind-dc1
```

---

## Phase 6 — Install cert-manager

### What & Why

cert-manager is a Kubernetes add-on that automates TLS certificate management.
The k8ssandra operator requires cert-manager because:
- It issues TLS certificates for Cassandra inter-node encryption (server-to-server)
- It issues certs for the Cassandra JMX interface
- It manages certificate rotation automatically

We install it on both clusters since each cluster runs its own k8ssandra operator
managing its local Cassandra datacenter.

### Commands

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

# dc1
helm install cert-manager jetstack/cert-manager \
  --kube-context kind-dc1 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true

# dc2
helm install cert-manager jetstack/cert-manager \
  --kube-context kind-dc2 \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

### Verification

```bash
cmctl check api --context kind-dc1
cmctl check api --context kind-dc2
```

---

## Phase 7 — Install k8ssandra Operator

### What & Why

The k8ssandra operator extends Kubernetes with CRDs (Custom Resource Definitions)
for managing Apache Cassandra. It handles:
- Cassandra node lifecycle (bootstrap, decommission, replace)
- Configuration management
- Backup/restore (via Medusa)
- Repair scheduling (via Reaper)
- TLS and superuser secret management

We install it on both clusters. Each operator manages only its local datacenter.
Cross-DC communication happens at the Cassandra level (gossip) over the ClusterMesh network.

The operator is installed in `watching all namespaces` mode.

### Commands

```bash
helm repo add k8ssandra https://helm.k8ssandra.io/stable
helm repo update

# dc1
helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
  --kube-context kind-dc1 \
  --namespace k8ssandra-operator \
  --create-namespace

# dc2
helm install k8ssandra-operator k8ssandra/k8ssandra-operator \
  --kube-context kind-dc2 \
  --namespace k8ssandra-operator \
  --create-namespace
```

### Verification

```bash
kubectl get pods -n k8ssandra-operator --context kind-dc1
kubectl get pods -n k8ssandra-operator --context kind-dc2
```

---

## Phase 8 — Deploy Cassandra Multi-DC

### What & Why

We create a `K8ssandraCluster` resource on the **primary cluster (dc1)**.
The k8ssandra operator uses this to deploy:
- A `CassandraDatacenter` (dc1) on cluster-dc1
- A `CassandraDatacenter` (dc2) on cluster-dc2

Key configuration choices:
- **JVM heap: 512MB** — conservative setting for limited RAM (9.7 GB total)
- **1 Cassandra node per DC** — minimal footprint for local dev/testing
- **Cassandra 4.1** — latest stable release supported by k8ssandra
- **storageConfig** — uses `standard` storage class (default in kind)
- **superuserSecretRef** — shared secret so both DCs can authenticate to each other

### File

`cassandra-multidc.yaml`

### Commands

```bash
kubectl apply -f cassandra-multidc.yaml --context kind-dc1
```

### Verification

```bash
# Watch Cassandra pods come up (takes 3-5 minutes)
kubectl get pods -n k8ssandra -w --context kind-dc1
kubectl get pods -n k8ssandra -w --context kind-dc2

# Check Cassandra cluster status
kubectl exec -it <cassandra-pod> -n k8ssandra --context kind-dc1 \
  -- nodetool status
# Expected: UN (Up/Normal) for both dc1 and dc2 nodes
```

---

## Troubleshooting

### Nodes stuck in NotReady
Cilium may still be initializing. Run `cilium status` and wait for all components green.

### ClusterMesh connect fails
Ensure both clusters' API servers are reachable. With kind, the nodes are Docker
containers on the same bridge network. Run `docker network inspect kind` to verify
both cluster nodes are on the same network.

### Cassandra pods in CrashLoopBackOff
Usually JVM heap or storage issues. Check logs:
```bash
kubectl logs <pod> -n k8ssandra --context kind-dc1
```

### OOMKilled
Reduce `heapSize` in `cassandra-multidc.yaml` or increase Docker Desktop memory allocation.

---

## Cleanup

```bash
kind delete cluster --name dc1
kind delete cluster --name dc2
```
