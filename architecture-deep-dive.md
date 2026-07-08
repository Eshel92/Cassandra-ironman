# Multi-DC Cassandra on Kind - Architecture Deep Dive

## Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MacBook (Docker Desktop)                     │
│                                                                     │
│  ┌──────────────────────────┐    ┌──────────────────────────────┐   │
│  │   Kind Cluster: dc1      │    │   Kind Cluster: dc2          │   │
│  │   (Docker container)     │    │   (Docker container)         │   │
│  │                          │    │                              │   │
│  │  Pod CIDR: 10.10.0.0/16  │    │  Pod CIDR: 10.20.0.0/16     │   │
│  │  Svc CIDR: 10.11.0.0/16  │    │  Svc CIDR: 10.21.0.0/16     │   │
│  │                          │    │                              │   │
│  │  ┌────────────────────┐  │    │  ┌────────────────────────┐  │   │
│  │  │ Cilium CNI         │  │    │  │ Cilium CNI             │  │   │
│  │  │ cluster.id=1       │◄─┼────┼─►│ cluster.id=2           │  │   │
│  │  │ cluster.name=dc1   │  │    │  │ cluster.name=dc2       │  │   │
│  │  └────────────────────┘  │    │  └────────────────────────┘  │   │
│  │           │               │    │           │                  │   │
│  │  ┌────────┴───────────┐  │    │  ┌────────┴───────────────┐  │   │
│  │  │ ClusterMesh Agent  │  │    │  │ ClusterMesh Agent      │  │   │
│  │  │ + API Server       │◄─┼────┼─►│ + API Server           │  │   │
│  │  └────────────────────┘  │    │  └────────────────────────┘  │   │
│  │                          │    │                              │   │
│  │  ┌────────────────────┐  │    │  ┌────────────────────────┐  │   │
│  │  │ Cassandra (dc1)    │  │    │  │ Cassandra (dc2)        │  │   │
│  │  │ 10.10.0.95         │◄─┼────┼─►│ 10.20.0.37             │  │   │
│  │  │ Gossip port: 7000  │  │    │  │ Gossip port: 7000      │  │   │
│  │  └────────────────────┘  │    │  └────────────────────────┘  │   │
│  │                          │    │                              │   │
│  │  cert-manager            │    │  cert-manager                │   │
│  │  k8ssandra-operator      │    │  k8ssandra-operator          │   │
│  └──────────────────────────┘    └──────────────────────────────┘   │
│                                                                     │
│            Docker network: "kind" (bridge: 172.19.0.0/16)           │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 1. Kind (Kubernetes in Docker)

### What it is
Kind runs entire Kubernetes clusters inside Docker containers. Each "node" in the cluster is actually a Docker container running systemd, kubelet, containerd, and all the Kubernetes control plane components (API server, etcd, scheduler, controller-manager).

### What we did
We created two separate clusters, dc1 and dc2. Each is a single-node cluster (one Docker container acting as both control-plane and worker).

### Key config choices

```yaml
networking:
  disableDefaultCNI: true      # Critical - explained below
  podSubnet: "10.10.0.0/16"    # Non-overlapping with dc2
  serviceSubnet: "10.11.0.0/16"
```

**disableDefaultCNI: true** - By default, Kind installs "kindnet", a simple CNI that just does basic networking. We disable it because:
- We need Cilium as the CNI instead
- Running two CNIs would cause conflicts (double IP assignment, broken routing)
- Without this flag, nodes appear "Ready" immediately but Cilium installation would fail

**Non-overlapping CIDRs** - This is critical for ClusterMesh:
- dc1 pods get IPs from 10.10.0.0/16
- dc2 pods get IPs from 10.20.0.0/16
- If both used the same range (e.g., 10.244.0.0/16, the default), a pod at 10.244.0.5 could exist in BOTH clusters. The mesh wouldn't know which one to route to. Non-overlapping ranges make every pod IP globally unique across both clusters.

### Docker networking
Both Kind containers land on the same Docker bridge network called "kind" (172.19.0.0/16). This means:
- dc1-control-plane (172.19.0.2) can reach dc2-control-plane (172.19.0.3) directly
- This is what makes ClusterMesh possible - the nodes can talk to each other

---

## 2. CNI (Container Network Interface) - Deep Dive

### What is a CNI?

CNI is a **specification** that defines how network plugins integrate with container runtimes. When Kubernetes needs to create a pod, this is what happens:

```
1. Scheduler assigns pod to a node
2. Kubelet on that node tells containerd to create the pod
3. Containerd creates a network namespace for the pod (an isolated network stack)
4. Containerd calls the CNI plugin via a standardized API:
   "Here's a network namespace, please give it networking"
5. CNI plugin:
   a. Creates a virtual ethernet pair (veth)
   b. Places one end in the pod's namespace
   c. Places the other end on the host
   d. Assigns an IP address from the pod CIDR
   e. Sets up routes so the pod can reach other pods
   f. Returns the IP and config to containerd
6. Pod now has networking
```

Without a CNI, pods get created but have NO network interface (besides loopback). They can't communicate with anything. That's why nodes show "NotReady" until a CNI is installed - the node knows it can't run workloads without networking.

### Why Cilium specifically?

There are many CNIs (Calico, Flannel, Weave, etc.). We chose Cilium because:

1. **ClusterMesh** - Cilium's built-in multi-cluster networking. Other CNIs require third-party tools (like Submariner) to connect clusters, and those are more complex and less reliable.

2. **eBPF-based** - Cilium uses eBPF (extended Berkeley Packet Filter), which operates at the Linux kernel level. Traditional CNIs use iptables for routing, which:
   - Creates chains of rules that are evaluated sequentially (O(n))
   - Gets slower as you add more services/pods
   - Is hard to debug

   eBPF instead:
   - Loads small programs directly into the kernel
   - Processes packets in-kernel without bouncing to userspace
   - Operates at O(1) complexity regardless of rule count
   - Provides deep visibility via Hubble

### How Cilium networking works

```
Pod A (10.10.0.95) wants to talk to Pod B (10.20.0.37)

┌─────────────────────────────────────────────────────┐
│ Pod A's network namespace                            │
│  eth0 (10.10.0.95) ──► veth pair ──► host-side veth │
└─────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────┐
│ Cilium eBPF datapath (in kernel)                     │
│                                                      │
│  1. Packet arrives from Pod A                        │
│  2. eBPF program looks up destination 10.20.0.37     │
│  3. Checks identity map: "10.20.0.37 is in dc2"     │
│  4. Encapsulates in VXLAN tunnel to dc2 node         │
│  5. Sends to 172.19.0.3 (dc2-control-plane)         │
└─────────────────────────────────────────────────────┘
                              │
                              ▼ (VXLAN tunnel over Docker bridge)
                              │
┌─────────────────────────────────────────────────────┐
│ Cilium eBPF on dc2 node                              │
│                                                      │
│  1. Receives VXLAN packet                            │
│  2. Decapsulates, finds dest 10.20.0.37              │
│  3. Routes to Pod B's veth                           │
└─────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────┐
│ Pod B's network namespace                            │
│  eth0 (10.20.0.37) receives the packet               │
└─────────────────────────────────────────────────────┘
```

### Cilium Helm values explained

| Value | Purpose |
|-------|---------|
| `cluster.name=dc1` | Unique identifier for this cluster in the mesh. Cilium tags every packet with the source cluster identity. |
| `cluster.id=1` | Numeric ID (must be unique per cluster). Used internally for identity encoding - Cilium packs cluster ID + endpoint ID into a 32-bit identity. |
| `ipam.mode=kubernetes` | Tells Cilium to use the pod CIDR that Kubernetes allocated (from Kind config). Alternative is Cilium managing its own IPAM, but for Kind the Kubernetes mode is simpler. |
| `operator.replicas=1` | The Cilium operator manages cluster-wide tasks (CRD cleanup, node management). We only have 1 node so 1 replica is enough. |
| `hubble.relay.enabled=true` | Hubble is Cilium's observability layer. Relay aggregates flow data from all nodes. Useful for debugging traffic. |
| `hubble.ui.enabled=true` | Web UI for visualizing network flows between pods. |

---

## 3. ClusterMesh

### What it is
ClusterMesh is Cilium's multi-cluster feature. It allows pods in different Kubernetes clusters to communicate directly by pod IP, as if they were in the same cluster.

### How it works internally

```
┌─────────────────────────────────────────────────────────────────┐
│                      ClusterMesh Architecture                    │
│                                                                  │
│  dc1                                    dc2                      │
│  ┌──────────────────────┐              ┌──────────────────────┐  │
│  │ ClusterMesh API      │              │ ClusterMesh API      │  │
│  │ Server (etcd)        │◄────────────►│ Server (etcd)        │  │
│  │                      │   Sync       │                      │  │
│  │ Stores:              │   state      │ Stores:              │  │
│  │ - pod IPs & identities│             │ - pod IPs & identities│  │
│  │ - service endpoints  │              │ - service endpoints  │  │
│  │ - network policies   │              │ - network policies   │  │
│  └──────────┬───────────┘              └──────────┬───────────┘  │
│             │                                     │              │
│  ┌──────────▼───────────┐              ┌──────────▼───────────┐  │
│  │ KVStoreMesh          │              │ KVStoreMesh          │  │
│  │ (local cache)        │              │ (local cache)        │  │
│  │                      │              │                      │  │
│  │ Caches remote        │              │ Caches remote        │  │
│  │ cluster state locally│              │ cluster state locally│  │
│  └──────────┬───────────┘              └──────────┬───────────┘  │
│             │                                     │              │
│  ┌──────────▼───────────┐              ┌──────────▼───────────┐  │
│  │ Cilium Agent         │              │ Cilium Agent         │  │
│  │ (DaemonSet)          │              │ (DaemonSet)          │  │
│  │                      │              │                      │  │
│  │ Programs eBPF with   │              │ Programs eBPF with   │  │
│  │ routes to remote pods│              │ routes to remote pods│  │
│  └──────────────────────┘              └──────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

Step by step:
1. **`cilium clustermesh enable`** deploys a ClusterMesh API server (a dedicated etcd) on each cluster, exposed via NodePort
2. **`cilium clustermesh connect`** exchanges connection credentials between clusters. Each cluster gets a secret containing the other cluster's etcd CA cert, client cert, and endpoint address
3. Each Cilium agent watches both its local etcd AND the remote cluster's etcd
4. When a pod is created in dc2, dc2's Cilium agent writes its IP and identity to dc2's etcd
5. dc1's Cilium agent sees this update and programs an eBPF route: "to reach 10.20.0.37, send VXLAN packet to 172.19.0.3"
6. Now Pod A in dc1 can send traffic directly to Pod B in dc2

**--service-type NodePort**: The ClusterMesh API server needs to be reachable from the other cluster. In cloud environments you'd use a LoadBalancer. In Kind (no cloud LB), NodePort exposes it on the node's IP (the Docker container's IP on the bridge network).

**--allow-mismatching-ca**: Each Kind cluster generates its own Cilium CA certificate. Since they were created independently, the CAs don't match. This flag tells Cilium to trust both CAs by bundling them together, rather than requiring a shared CA.

---

## 4. cert-manager

### What it is
cert-manager is a Kubernetes controller that automates TLS certificate lifecycle:
- Creates certificates from various issuers (self-signed, Let's Encrypt, Vault, etc.)
- Stores them as Kubernetes Secrets
- Automatically renews before expiry

### Why k8ssandra needs it
The k8ssandra operator uses cert-manager for:
- **Webhook certificates**: The operator runs admission webhooks (the `vk8ssandracluster.kb.io` webhook we saw). These need TLS certs to serve HTTPS
- **Internode encryption**: Cassandra nodes can encrypt gossip traffic between them using TLS. cert-manager issues and rotates these certs
- **Client encryption**: TLS for CQL client connections

Without cert-manager, the k8ssandra operator pods fail to start because they can't obtain the webhook serving certificate.

---

## 5. k8ssandra Operator

### What it is
A Kubernetes operator that manages Apache Cassandra clusters using Custom Resource Definitions (CRDs). Instead of manually deploying StatefulSets, ConfigMaps, and managing Cassandra lifecycle, you declare a `K8ssandraCluster` resource and the operator handles everything.

### Architecture on our setup

```
dc1 cluster:
  k8ssandra-operator (watches K8ssandraCluster CR)
    └── creates CassandraDatacenter "dc1" locally
    └── creates CassandraDatacenter "dc2" on dc2 (via ClientConfig)

  cass-operator (watches CassandraDatacenter CR)
    └── creates StatefulSet for Cassandra pods
    └── manages pod lifecycle, readiness, configuration
```

### ClientConfig
The `ClientConfig` CRD tells the k8ssandra operator how to reach another Kubernetes cluster. We created:
- A Secret containing the dc2 kubeconfig (with the Docker-internal IP 172.19.0.3:6443 instead of localhost)
- A ClientConfig that references this secret with `contextName: kind-dc2`

This allows the operator running in dc1 to create and manage resources in dc2.

### Multi-DC bootstrap sequence
1. Operator creates CassandraDatacenter dc1 first
2. Waits for dc1 Cassandra to be fully ready (UN state)
3. Configures dc1's seed nodes
4. Creates CassandraDatacenter dc2 on the remote cluster (via ClientConfig)
5. dc2 Cassandra starts, uses dc1's seed node for gossip
6. dc2 joins the ring, streams data, becomes UN
7. Operator updates system keyspace replication to include both DCs

---

## 6. Cassandra Multi-DC

### How Cassandra multi-DC works

Cassandra uses a **gossip protocol** for cluster membership. Every node periodically (every second) sends gossip messages to 1-3 other nodes, sharing its view of the cluster state.

```
Gossip flow:
dc1 node (10.10.0.95:7000) ──gossip──► dc2 node (10.20.0.37:7000)
  "I am dc1/default, my status is UP, my load is 109KB, my schema is X"

dc2 node (10.20.0.37:7000) ──gossip──► dc1 node (10.10.0.95:7000)
  "I am dc2/default, my status is UP, my load is 75KB, my schema is X"
```

This gossip happens over **TCP port 7000** and requires **direct pod-to-pod IP connectivity**. This is exactly why we need ClusterMesh - without it, 10.10.0.95 cannot reach 10.20.0.37 because they're in different clusters with different network namespaces.

### NetworkTopologyStrategy

```sql
CREATE KEYSPACE my_app WITH replication = {
  'class': 'NetworkTopologyStrategy',
  'dc1': 1,
  'dc2': 1
};
```

This means:
- Every write is replicated to 1 node in dc1 AND 1 node in dc2
- Since we have 1 node per DC, every piece of data exists on both nodes
- If dc1 goes down entirely, dc2 has all the data

### Consistency levels

| Level | Meaning |
|-------|---------|
| LOCAL_ONE | Only 1 node in the LOCAL DC must respond. Fastest, but no cross-DC guarantee. |
| LOCAL_QUORUM | Majority of nodes in the LOCAL DC must respond. |
| EACH_QUORUM | Majority of nodes in EACH DC must respond. Proves cross-DC replication is working. Highest consistency. |
| ALL | Every replica everywhere must respond. Slowest, lowest availability. |

### What peers_v2 shows

```sql
SELECT peer, data_center, host_id FROM system.peers_v2;
```

This table contains every OTHER node the current node knows about via gossip. If you connect to dc1's node and see dc2's node in peers_v2, it proves:
1. Gossip is working across the ClusterMesh
2. The nodes have discovered each other
3. The network path (pod IP → Cilium eBPF → VXLAN tunnel → remote pod) is functional

---

## Full request flow: writing data from dc1, reading from dc2

```
1. cqlsh connects to 127.0.0.1:9042
2. kubectl port-forward tunnels this to Cassandra pod in dc1

3. INSERT INTO my_app.users (...) VALUES (...)
   │
   ▼
4. dc1 Cassandra coordinator receives the write
   - Checks replication strategy: NetworkTopologyStrategy dc1:1, dc2:1
   - Determines: "I need to write to myself AND to the dc2 replica"
   │
   ├──► Writes to local commitlog + memtable (dc1 done)
   │
   └──► Sends mutation to dc2 node at 10.20.0.37:9042
        │
        ▼
5.      Packet: src=10.10.0.95, dst=10.20.0.37
        │
        ▼
6.      Cilium eBPF (dc1):
        - Looks up 10.20.0.37 in identity map
        - "This is in cluster dc2, on node 172.19.0.3"
        - Encapsulates in VXLAN, sends to 172.19.0.3
        │
        ▼
7.      Docker bridge forwards to dc2-control-plane container
        │
        ▼
8.      Cilium eBPF (dc2):
        - Decapsulates VXLAN
        - Routes to pod 10.20.0.37
        │
        ▼
9.      dc2 Cassandra receives mutation
        - Writes to local commitlog + memtable
        - Sends ACK back (same path in reverse)
        │
        ▼
10. dc1 coordinator receives ACK
    - If CONSISTENCY LOCAL_ONE: already responded to client at step 4
    - If CONSISTENCY EACH_QUORUM: now responds to client (both DCs confirmed)

11. Later, cqlsh on dc2 (port 9043) runs SELECT
    - dc2 Cassandra reads from local memtable/sstable
    - Data is there because step 9 wrote it locally
    - Returns result - proof that multi-DC replication works
```
