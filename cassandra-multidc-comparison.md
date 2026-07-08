# Cassandra Multi-DC on Kubernetes: Networking Approaches Comparison

Three networking strategies for deploying Cassandra multi-DC across separate
Kubernetes clusters. All three use k8ssandra-operator and K8ssandraCluster CR.
The difference is how pods in different clusters reach each other.

The target environment is an **airgapped network**, so all images, charts, and
binaries must be pre-loaded. This affects the choice significantly.

---

## 1. Cilium ClusterMesh

### How It Works

Cilium replaces the default CNI and provides full pod-to-pod connectivity between
clusters using eBPF. It creates VXLAN/Geneve tunnels so that pod IPs are directly
routable across clusters without any application-level changes.

```
Cluster DC1                          Cluster DC2
+-----------------------+            +-----------------------+
| Pod: 10.10.0.x        |<---------->| Pod: 10.20.0.x        |
|                       |   eBPF     |                       |
| Cilium Agent          |   tunnel   | Cilium Agent          |
| ClusterMesh API       |            | ClusterMesh API       |
+-----------------------+            +-----------------------+
```

- Pod IPs are directly routable across clusters -- no NAT, no broadcast override
- ClusterMesh syncs service and endpoint information between clusters
- Cassandra uses its default pod IPs for everything -- no special config needed
- The K8ssandraCluster CR is completely vanilla

### Pros

- **Zero Cassandra config changes** -- vanilla K8ssandraCluster CR, no perNodeConfigMapRef, no additionalSeeds
- **Full pod-to-pod mesh** -- benefits all services, not just Cassandra
- **Scaling is trivial** -- just change `size` in the CR, no extra services or ConfigMaps
- **Rich observability** -- Hubble UI for network flow visualization and debugging
- **Network policies** -- L3/L4/L7 policies across clusters with eBPF enforcement
- **Helm templating is simple** -- vanilla CR, nothing per-pod to generate
- **Mature and widely adopted** -- used in production by Google, AWS, Azure

### Cons

- **Replaces the CNI entirely** -- cannot use alongside an existing CNI (Calico, Flannel, etc.)
- **Airgapped complexity** -- many container images to pre-load (cilium-agent, cilium-operator, clustermesh-apiserver, hubble-relay, hubble-ui, etc.)
- **Kernel requirements** -- needs Linux 4.19+ (5.10+ recommended for full features)
- **Complex initial setup** -- CNI replacement, ClusterMesh enable, cluster connect
- **Cluster limit** -- ClusterMesh supports max 255 connected clusters (unlikely to hit)
- **If Cilium breaks, the entire cluster network breaks** -- it IS the CNI

---

## 2. Submariner

### How It Works

Submariner creates encrypted IPsec or VXLAN tunnels between clusters at the node
level. It runs alongside the existing CNI. A gateway node in each cluster handles
all cross-cluster traffic, and route agents on every node set up routing rules to
forward inter-cluster packets through the gateway.

```
Cluster DC1                          Cluster DC2
+-----------------------+            +-----------------------+
| Pod: 10.30.0.x        |            | Pod: 10.40.0.x        |
|         |             |            |         |             |
|  Route Agent          |            |  Route Agent          |
|         |             |            |         |             |
|  Gateway Node --------+--IPsec----+-- Gateway Node        |
+-----------------------+  tunnel    +-----------------------+
```

- Runs alongside any existing CNI -- does not replace it
- Gateway pods handle cross-cluster traffic with IPsec encryption by default
- Pod IPs are directly routable across clusters via the tunnel
- Cassandra uses default pod IPs -- no special config needed
- The K8ssandraCluster CR is completely vanilla

### Pros

- **Zero Cassandra config changes** -- vanilla K8ssandraCluster CR, same as Cilium
- **Works with any CNI** -- Calico, Flannel, Cilium, whatever is already deployed
- **Encrypted by default** -- IPsec tunnel between clusters, no extra TLS config needed
- **Scaling is trivial** -- just change `size` in the CR
- **Helm templating is simple** -- vanilla CR
- **Works across networks** -- tunnels over L3, clusters don't need shared L2 segment

### Cons

- **Gateway is a bottleneck** -- all cross-cluster traffic flows through a single gateway node per cluster
- **Gateway HA requires extra config** -- multiple gateway nodes needed for redundancy
- **IPsec CPU overhead** -- encryption/decryption adds latency and CPU usage on gateway nodes
- **Broker dependency** -- the broker (on dc1) is needed for initial cluster discovery; if it's down, new clusters can't join (existing traffic is unaffected)
- **Airgapped complexity** -- submariner-gateway, submariner-routeagent, submariner-operator, broker images all need pre-loading, plus the `subctl` binary
- **`subctl` CLI required** -- imperative commands for broker deploy and cluster join (not purely declarative)
- **Added latency** -- extra hop through gateway node for every cross-cluster packet

---

## 3. MetalLB / AKO / Per-Pod External IPs

### How It Works

No network mesh or tunnel. Each Cassandra pod gets its own external IP from a
LoadBalancer provider (MetalLB on bare-metal, AKO on VMware NSX, or a cloud LB).
Cassandra is configured to broadcast this external IP instead of its pod IP, so
nodes in other clusters can reach it directly over the physical/underlay network.

```
Cluster DC1                          Cluster DC2
+-----------------------+            +-----------------------+
| Pod: 10.30.0.x        |            | Pod: 10.40.0.x        |
|  broadcast:           |            |  broadcast:           |
|  192.168.1.101        |            |  192.168.2.101        |
|         |             |            |         |             |
|  LB Svc (MetalLB/AKO) |            |  LB Svc (MetalLB/AKO) |
|  192.168.1.101        |            |  192.168.2.101        |
+-----------------------+            +-----------------------+
         |                                    |
         +---- Physical / Underlay Network ---+
```

- No tunnel, no mesh -- traffic goes directly over the existing network
- A LoadBalancer service per pod exposes it with an external IP
- `perNodeConfigMapRef` injects the external IP as `broadcast_address` into
  `cassandra.yaml` via cass-operator's built-in config-builder init container
- `additionalSeeds` lists external IPs of nodes in other DCs for cross-DC discovery
- Pod IPs are NOT routable cross-cluster -- only the external LB IPs are

### Pros

- **No CNI changes** -- works with any CNI, no replacement, no overlay
- **No tunnel overhead** -- traffic goes directly over the physical network, lowest latency
- **Minimal infrastructure** -- only needs a LoadBalancer provider (MetalLB, AKO), no mesh or gateway components
- **Fewest container images for airgapped** -- MetalLB is just controller + speaker (2 images); AKO is a single image. Far fewer than Cilium or Submariner
- **Mirrors traditional Cassandra deployments** -- each node has a routable IP, same as VM-based Cassandra
- **No extra DaemonSets on every node** -- MetalLB speaker is lightweight; AKO is a single deployment
- **Network-agnostic LB** -- in production, swap MetalLB for AKO (VMware), AWS NLB, GCP ILB, etc. without changing the Cassandra config pattern

### Cons

- **Requires Cassandra config changes** -- `perNodeConfigMapRef` for broadcast addresses, `additionalSeeds` for cross-DC discovery
- **Per-pod manual resources** -- each Cassandra pod needs its own LoadBalancer service and ConfigMap entry
- **Scaling is complex** -- adding a node requires: new LB service + ConfigMap entry + CR size change (coordinated multi-resource update)
- **IP discovery chicken-and-egg** -- the ConfigMap needs the LB IP, but the IP is assigned only when the service is created. With MetalLB (sequential pools) you can pre-compute; with AKO/cloud LBs you cannot -- requires an init container or controller for dynamic discovery
- **Shared L2 required for MetalLB** -- MetalLB L2 mode needs clusters on the same network segment (BGP mode works cross-subnet but adds complexity). AKO/cloud LBs handle routing automatically
- **No encryption** -- traffic is plain on the network; must configure Cassandra internode TLS separately if needed
- **Helm templating is harder** -- need two releases (one per cluster), per-pod resource generation, and IP computation or dynamic discovery
- **ConfigMap changes require pod restart** -- `perNodeConfigMapRef` is read at startup only

---

## Summary Table

| Aspect | Cilium ClusterMesh | Submariner | MetalLB / AKO |
|--------|-------------------|------------|---------------|
| **How pods connect cross-cluster** | eBPF tunnel (VXLAN/Geneve) | IPsec/VXLAN gateway tunnel | External LB IPs on underlay network |
| **CNI impact** | Replaces CNI | No change | No change |
| **Pod IPs routable cross-cluster** | Yes | Yes | No (LB IPs only) |
| **Cassandra config changes needed** | None | None | broadcast_address + seeds |
| **K8ssandraCluster CR complexity** | Vanilla | Vanilla | perNodeConfigMapRef + additionalSeeds |
| **Extra resources per Cassandra pod** | None | None | 1 LB Service + 1 ConfigMap entry |
| **Encryption** | Optional (WireGuard) | Yes (IPsec default) | No (add Cassandra TLS) |
| **Network requirement** | Any (tunnels over L3) | Any (tunnels over L3) | Shared L2 (MetalLB) or routable VIPs (AKO) |
| **Scaling a DC** | Change `size`, done | Change `size`, done | Change `size` + add LB svc + update ConfigMap |
| **Latency overhead** | Tunnel encap/decap | Tunnel + gateway hop | None (direct underlay) |
| **Images to pre-load (airgapped)** | ~8-10 (agent, operator, mesh API, hubble, etc.) | ~5-6 (gateway, routeagent, operator, broker, globalnet) | ~2-3 (controller, speaker) or 1 (AKO) |
| **External CLI tools needed** | `cilium` CLI | `subctl` CLI | None |
| **Helm templating** | Simple | Simple | Medium (MetalLB) / Hard (AKO) |
| **Failure blast radius** | CNI failure = cluster network down | Gateway failure = cross-cluster down | LB failure = single pod unreachable |
| **Debugging tools** | Hubble UI, `cilium` CLI | `subctl diagnose` | Standard `kubectl`, `nodetool` |

## Airgapped Deployment Considerations

All three approaches require pre-loading container images and charts into an internal
registry. Here's how they compare for airgapped environments:

### Image Count and Complexity

| Approach | Images to Mirror                                                                                                          | Binaries to Pre-load | Charts |
|----------|---------------------------------------------------------------------------------------------------------------------------|---------------------|--------|
| Cilium | cilium-agent, cilium-operator, clustermesh-apiserver, hubble-relay, hubble-ui, hubble-ui-backend, certgen                 | `cilium` CLI | cilium/cilium |
| Submariner | submariner-gateway, submariner-routeagent, submariner-operator, submariner-globalnet, lighthouse-agent, lighthouse-coredns | `subctl` binary | submariner-operator |
| MetalLB/AKO | None                                                                                                                      | None | metallb (or ako) |

### Operational Considerations for Airgapped

- **Cilium**: Most images to mirror, but once Cilium is the CNI, Cassandra deployment
  is completely standard. Upgrades require careful CNI rolling updates.
- **Submariner**: Moderate image count. The `subctl` binary must be available on the
  management workstation. Broker setup is a one-time imperative step.
- **MetalLB/AKO**: Fewest images, no special CLI tools. But Cassandra deployment is
  more complex (per-pod services and ConfigMaps). If using AKO with dynamic IPs, you
  also need to build and mirror the init container image that discovers LB IPs.

### Recommendation for Airgapped

- If the airgapped environment already has or plans to adopt **Cilium as CNI**: use
  Cilium ClusterMesh. Simplest Cassandra deployment, and you already pay the CNI cost.
- If the environment has an **existing CNI you can't change** and needs cross-cluster
  connectivity for multiple services: use Submariner.
- If the environment is **on-prem with routable VLANs/VIPs** (e.g., VMware with NSX)
  and you only need cross-cluster connectivity for Cassandra: use MetalLB/AKO. Fewest
  moving parts, lowest image footprint, and matches how traditional Cassandra clusters
  are deployed on VMs.
