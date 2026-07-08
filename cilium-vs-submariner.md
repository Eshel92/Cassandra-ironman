# Cilium ClusterMesh vs Submariner for Multi-Cluster Pod Connectivity

## The Problem Both Solve

Kubernetes clusters are network islands. A pod in cluster A cannot reach a pod in cluster B by IP. For Cassandra multi-DC, this is a dealbreaker - Cassandra nodes must gossip (TCP 7000) and replicate data (TCP 9042) directly between pod IPs across DCs.

Both Cilium ClusterMesh and Submariner create cross-cluster pod-to-pod connectivity, but their architectures are fundamentally different.

---

## Architecture Comparison

### Cilium ClusterMesh

```
Cilium IS the CNI. It handles local pod networking AND cross-cluster routing
in a single unified system using eBPF.

dc1                                         dc2
┌─────────────────────────────┐            ┌─────────────────────────────┐
│                              │            │                              │
│  Pod A (10.10.0.95)          │            │  Pod B (10.20.0.37)          │
│       │                      │            │       ▲                      │
│       ▼                      │            │       │                      │
│  ┌─────────────────────┐    │            │  ┌─────────────────────┐    │
│  │ Cilium eBPF datapath │    │            │  │ Cilium eBPF datapath │    │
│  │                      │    │            │  │                      │    │
│  │ 1. Lookup 10.20.0.37 │    │            │  │ 4. Decapsulate VXLAN │    │
│  │ 2. "Remote cluster   │    │            │  │ 5. Route to Pod B    │    │
│  │     dc2, node .0.3"  │    │            │  │                      │    │
│  │ 3. VXLAN encapsulate │    │            │  └──────────────────────┘   │
│  └──────────┬───────────┘    │            │                              │
│             │                │            │                              │
│  ClusterMesh API (etcd) ◄────┼── sync ───┼─► ClusterMesh API (etcd)    │
│                              │            │                              │
└──────────────┬───────────────┘            └──────────────────────────────┘
               │          VXLAN tunnel                    ▲
               └──────────────────────────────────────────┘
               (direct: node-to-node, no gateway)

Hops: Pod → eBPF → VXLAN → remote eBPF → Pod  (1 network hop)
```

### Submariner

```
Submariner is NOT a CNI. It sits on top of an existing CNI (Calico, Flannel, etc.)
and adds cross-cluster routing via a dedicated gateway node.

dc1                                         dc2
┌─────────────────────────────┐            ┌─────────────────────────────┐
│                              │            │                              │
│  Pod A (10.10.0.95)          │            │  Pod B (10.20.0.37)          │
│       │                      │            │       ▲                      │
│       ▼                      │            │       │                      │
│  ┌──────────┐                │            │  ┌──────────┐                │
│  │ Calico   │ (local CNI)    │            │  │ Calico   │ (local CNI)    │
│  └────┬─────┘                │            │  └────▲─────┘                │
│       │                      │            │       │                      │
│       ▼                      │            │       │                      │
│  ┌──────────────────┐        │            │  ┌──────────────────┐        │
│  │ Route Agent       │        │            │  │ Route Agent       │        │
│  │ (iptables rules)  │        │            │  │ (iptables rules)  │        │
│  │                   │        │            │  │                   │        │
│  │ "10.20.0.0/16 →   │        │            │  │ "10.10.0.0/16 →   │        │
│  │  send to gateway" │        │            │  │  send to gateway" │        │
│  └────┬──────────────┘        │            │  └────▲──────────────┘        │
│       │                      │            │       │                      │
│       ▼                      │            │       │                      │
│  ┌──────────────────┐        │            │  ┌──────────────────┐        │
│  │ ★ Gateway Node ★  │        │            │  │ ★ Gateway Node ★  │        │
│  │                   │        │            │  │                   │        │
│  │ Cable Driver:     │        │            │  │ Cable Driver:     │        │
│  │ IPsec / VXLAN /   │────────┼── tunnel ──┼──│ IPsec / VXLAN /   │        │
│  │ WireGuard         │        │            │  │ WireGuard         │        │
│  └───────────────────┘        │            │  └───────────────────┘        │
│                              │            │                              │
│  Broker (CRD-based           │            │                              │
│   cluster registry)          │            │                              │
└──────────────────────────────┘            └──────────────────────────────┘

Hops: Pod → CNI → iptables → Gateway → tunnel → Gateway → iptables → CNI → Pod  (3 network hops)
```

---

## Component Comparison

### What each system deploys

| Component | Cilium ClusterMesh | Submariner |
|-----------|-------------------|------------|
| CNI | Cilium (IS the CNI) | Needs existing CNI (Calico, Flannel, etc.) |
| State sync | ClusterMesh API server (etcd per cluster) | Broker cluster (Kubernetes CRDs) |
| Routing | eBPF programs in kernel | Route Agent DaemonSet (iptables + ip rules) |
| Tunnel | VXLAN (built into eBPF datapath) | Cable Driver: IPsec (libreswan) / VXLAN / WireGuard |
| Gateway | None - every node routes directly | Dedicated gateway node (single point of transit) |
| Service discovery | Shared services via etcd sync | Lighthouse DNS for cross-cluster service discovery |
| Total DaemonSets | 1 (cilium) | 2 (route agent + existing CNI) |
| Total Deployments | 2 (operator + clustermesh-apiserver) | 3+ (operator + gateway + broker + lighthouse) |

### How state synchronization works

**Cilium ClusterMesh:**
```
dc1 etcd ◄──── watches ────► dc2 etcd

- Each cluster's Cilium agent writes local pod IPs and identities to its etcd
- KVStoreMesh caches the remote etcd state locally
- Cilium agent reads both local and cached remote state
- Programs eBPF maps with full cross-cluster routing table
- Updates propagate in real-time (etcd watch streams)
```

**Submariner:**
```
dc1 ──► Broker Cluster ◄── dc2

- Each cluster runs a "submariner-gateway" that registers with the broker
- Broker stores Cluster, Endpoint, and ServiceImport CRDs
- Clusters discover each other via the broker
- Route agents watch local Submariner CRDs for remote cluster CIDRs
- Updates propagate via Kubernetes watch (slower than etcd native)
- Lighthouse controller syncs ServiceImport/ServiceExport CRDs for DNS
```

---

## Performance Comparison

### Packet path latency

| Step | Cilium ClusterMesh | Submariner (IPsec) |
|------|-------------------|-------------------|
| Pod to routing decision | eBPF in-kernel (~microseconds) | iptables chain traversal (~tens of microseconds) |
| Routing decision | eBPF map lookup O(1) | iptables rule matching O(n) |
| Encapsulation | VXLAN in eBPF | IPsec in kernel (encryption adds ~50-100μs) |
| Network hops | 1 (node-to-node direct) | 3 (node → gateway → gateway → node) |
| Decapsulation | VXLAN in eBPF | IPsec decrypt + iptables |
| Estimated added latency | ~0.1-0.5ms | ~1-5ms |

### Why this matters for Cassandra

Cassandra is latency-sensitive in several ways:

1. **Gossip (every 1 second)**: Each node sends heartbeats to 1-3 peers. Added latency here delays failure detection. With Submariner's extra hops, a node failure in dc2 takes longer to be detected by dc1.

2. **Read/Write at EACH_QUORUM**: The coordinator must wait for acknowledgment from both DCs. The slower path (Submariner) directly increases client-visible latency for every consistent operation.

3. **Streaming (bootstrap/repair)**: When a new node joins or repair runs, gigabytes of data stream between DCs. All of this funnels through Submariner's single gateway node.

### The gateway bottleneck

This is Submariner's fundamental limitation for Cassandra:

```
Cilium - N nodes can all route cross-cluster simultaneously:

  dc1-node1 ──VXLAN──► dc2-node1
  dc1-node2 ──VXLAN──► dc2-node2
  dc1-node3 ──VXLAN──► dc2-node3
  (parallel, each node handles its own traffic)

Submariner - ALL traffic funnels through 1 gateway:

  dc1-node1 ─┐
  dc1-node2 ─┼──► dc1-gateway ──tunnel──► dc2-gateway ──┬──► dc2-node1
  dc1-node3 ─┘                                          ├──► dc2-node2
                                                          └──► dc2-node3
  (serialized through gateway, single point of failure)
```

With 10 Cassandra nodes per DC, all gossip, replication, and streaming traffic between DCs must pass through the gateway. The gateway's NIC bandwidth and CPU (for IPsec encryption) become the ceiling.

Submariner does support gateway HA (active/passive failover), but NOT active/active load balancing. If the gateway fails, there's a brief outage (~10-30s) while the standby takes over.

---

## Feature Comparison

| Feature | Cilium ClusterMesh | Submariner |
|---------|-------------------|------------|
| Overlapping pod CIDRs | Not supported - CIDRs must be unique | Supported via Globalnet (NAT) |
| Encryption | Optional (WireGuard transparent encryption) | Default (IPsec), optional VXLAN (no encryption) |
| Network policies across clusters | Yes - Cilium NetworkPolicy works cross-cluster | No - policies are cluster-local |
| Service discovery | Shared Services (annotate to expose) | Lighthouse DNS (ServiceExport/ServiceImport) |
| Observability | Hubble (eBPF-based flow visibility) | Basic metrics, no deep packet visibility |
| CNI lock-in | Must use Cilium as CNI | Works with any CNI |
| Managed K8s support | Varies (some managed K8s use fixed CNIs) | Better (works alongside any CNI) |
| Complexity | Lower (one system) | Higher (CNI + Submariner + broker) |
| Maturity | Graduated CNCF project | Sandbox CNCF project |

---

## When to use which

### Use Cilium ClusterMesh when:

- You can choose your CNI (new clusters, Kind, self-managed K8s)
- You need low-latency cross-cluster communication (Cassandra, databases)
- You want a single unified networking stack
- You need cross-cluster network policies
- You want eBPF observability (Hubble)
- Your clusters have non-overlapping CIDRs

### Use Submariner when:

- You can't change the CNI (EKS with AWS VPC CNI, AKS with Azure CNI)
- Your clusters have overlapping CIDRs that can't be changed (Globalnet)
- You need encrypted tunnels by default (IPsec)
- You're connecting clusters across different cloud providers with existing CNIs
- You only need basic service-level connectivity (not pod-to-pod performance)

### For Cassandra multi-DC specifically:

**Cilium ClusterMesh is the better choice** because:
1. No gateway bottleneck for gossip and replication traffic
2. Lower latency improves consistency-level performance (EACH_QUORUM)
3. Direct pod-to-pod routing matches Cassandra's peer-to-peer architecture
4. Simpler to operate (one system vs three)

Submariner **would work** but adds unnecessary latency and complexity. The gateway node becomes a bottleneck as the cluster scales, and IPsec encryption overhead is wasted for local-network traffic between Kind containers.

---

## Setup comparison (what it takes to deploy each)

### Cilium ClusterMesh setup
```bash
# 1. Install Cilium as CNI on both clusters (replaces default CNI)
helm install cilium cilium/cilium --set cluster.name=dc1 --set cluster.id=1 ...
helm install cilium cilium/cilium --set cluster.name=dc2 --set cluster.id=2 ...

# 2. Enable ClusterMesh
cilium clustermesh enable --context kind-dc1 --service-type NodePort
cilium clustermesh enable --context kind-dc2 --service-type NodePort

# 3. Connect
cilium clustermesh connect --context kind-dc1 --destination-context kind-dc2

# Done. 3 commands after CNI install.
```

### Submariner setup
```bash
# 0. You already have a CNI installed (Calico, Flannel, etc.)

# 1. Deploy the broker on one cluster
subctl deploy-broker --context kind-dc1

# 2. Join each cluster to the broker
subctl join broker-info.subm --context kind-dc1 --clusterid dc1 --natt=false
subctl join broker-info.subm --context kind-dc2 --clusterid dc2 --natt=false

# 3. Verify
subctl show connections
subctl show endpoints

# 4. If overlapping CIDRs, also configure Globalnet
subctl deploy-broker --globalnet --context kind-dc1
# (changes the join commands as well)

# More steps, but also straightforward for basic setup.
```
