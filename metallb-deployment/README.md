# Cassandra Multi-DC with MetalLB (No CNI Mesh Required)

## Overview

This deploys a multi-datacenter Cassandra cluster across two kind clusters using
**MetalLB** for cross-cluster networking. Unlike the Cilium or Submariner approaches,
this doesn't require a CNI mesh or VPN — each Cassandra pod gets its own externally
routable IP via MetalLB LoadBalancer services.

## Architecture

```
┌─────────────────────────────────┐     ┌─────────────────────────────────┐
│  kind cluster: sub-dc1          │     │  kind cluster: sub-dc2          │
│                                 │     │                                 │
│  ┌───────────────────────────┐  │     │  ┌───────────────────────────┐  │
│  │ Cassandra pod (dc1-sts-0) │  │     │  │ Cassandra pod (dc2-sts-0) │  │
│  │  pod IP: 10.30.0.x        │  │     │  │  pod IP: 10.40.0.x        │  │
│  │  broadcast: 172.19.255.1  │──┼─────┼──│  broadcast: 172.19.255.11 │  │
│  └───────────────────────────┘  │     │  └───────────────────────────┘  │
│              │                  │     │              │                  │
│  ┌───────────────────────────┐  │     │  ┌───────────────────────────┐  │
│  │ LoadBalancer Service      │  │     │  │ LoadBalancer Service      │  │
│  │  MetalLB: 172.19.255.1   │  │     │  │  MetalLB: 172.19.255.11  │  │
│  │  Ports: 9042, 7000, 8080 │  │     │  │  Ports: 9042, 7000, 8080 │  │
│  └───────────────────────────┘  │     │  └───────────────────────────┘  │
│                                 │     │                                 │
│  MetalLB pool: 172.19.255.1-10 │     │  MetalLB pool: 172.19.255.11-20│
└─────────────────────────────────┘     └─────────────────────────────────┘
                  │                                       │
                  └───────── Docker "kind" network ───────┘
                              172.19.0.0/16
```

## Why MetalLB IPs Are Routable Between Clusters

Both kind clusters run on the same Docker network (`kind`, subnet `172.19.0.0/16`).
MetalLB IP pools are chosen within this range:
- dc1: `172.19.255.1-10`
- dc2: `172.19.255.11-20`

MetalLB uses L2 advertisement (ARP), so any node on the Docker network can reach
these IPs. Since both kind cluster nodes are on the same Docker network, they can
route to each other's MetalLB IPs.

## The Problem This Solves

Cassandra nodes need to talk to each other for gossip (port 7000) and client queries
(port 9042). By default, each node broadcasts its **pod IP** (e.g., `10.30.0.16`).
But pod IPs are internal to each kind cluster — `10.30.x.x` is unreachable from the
dc2 cluster and vice versa.

We solve this by:
1. Giving each pod a MetalLB IP that IS reachable from both clusters
2. Telling Cassandra to broadcast that MetalLB IP instead of its pod IP

## How perNodeConfigMapRef Works

This is the core mechanism that makes it work. It's a built-in feature of
cass-operator (the Cassandra operator used by k8ssandra).

### The Config-Builder Init Container

When a Cassandra pod starts, cass-operator adds an init container called
`server-config-init`. This init container:

1. Takes the global Cassandra config from the K8ssandraCluster CR
2. Checks if `perNodeConfigMapRef` is set
3. If yes, looks for a ConfigMap key matching `<pod-name>_cassandra.yaml`
4. Deep-merges that YAML fragment into the global cassandra.yaml
5. Writes the final config to a shared volume
6. The Cassandra main container reads from that volume

### ConfigMap Key Format

```
<statefulset-pod-name>_<config-file-name>
```

Example:
```yaml
data:
  cassandra-cluster-dc1-default-sts-0_cassandra.yaml: |
    broadcast_address: 172.19.255.1
    broadcast_rpc_address: 172.19.255.1
```

- `cassandra-cluster-dc1-default-sts-0` = the pod name
- `cassandra.yaml` = the Cassandra config file to merge into

### What broadcast_address Does

In `cassandra.yaml`:
- `listen_address`: The IP Cassandra binds to (pod IP — set automatically by cass-operator)
- `broadcast_address`: The IP this node tells OTHER Cassandra nodes to use when
  connecting to it. This is what appears in `nodetool status`.
- `broadcast_rpc_address`: The IP this node tells CQL CLIENTS to connect to.

By setting `broadcast_address` to the MetalLB IP, gossip traffic between DCs flows
over the MetalLB network instead of the unreachable pod network.

## How additionalSeeds Works

Cassandra uses "seed nodes" for initial cluster discovery. A new node contacts seeds
to learn about the rest of the cluster.

Within a single DC, cass-operator manages seeds automatically via a headless
Kubernetes service (`cassandra-cluster-seed-service`). But this service only resolves
to pods **within the same cluster**.

For cross-DC discovery, we use `additionalSeeds` in the K8ssandraCluster CR:

```yaml
additionalSeeds:
  - "172.19.255.1"    # dc1 node's MetalLB IP
  - "172.19.255.11"   # dc2 node's MetalLB IP
```

This adds these IPs to the `additional-seed-service` in each cluster, so when dc2
starts, it can reach dc1 via `172.19.255.1:7000` for gossip.

## Prerequisites

Before deploying, you need:
- Two kind clusters (`sub-dc1`, `sub-dc2`) on the same Docker network
- MetalLB installed on both clusters
- cert-manager installed on both clusters
- k8ssandra-operator installed on both clusters

## Deployment Steps

All commands assume you're in this directory.

### Step 1: Configure MetalLB IP Pools

```bash
# DC1 pool
kubectl apply -f 01-metallb-pools.yaml --context kind-sub-dc1

# DC2 pool
kubectl apply -f 02-metallb-pools-dc2.yaml --context kind-sub-dc2
```

### Step 2: Create RBAC

```bash
kubectl apply -f 03-rbac.yaml --context kind-sub-dc1
kubectl apply -f 03-rbac.yaml --context kind-sub-dc2
```

### Step 3: Create Per-Pod LoadBalancer Services

These must be created BEFORE the Cassandra pods start, so MetalLB assigns the IPs
that we reference in the per-node config.

```bash
# DC1 LoadBalancer service
kubectl apply -f 04-loadbalancer-services.yaml --context kind-sub-dc1

# DC2 LoadBalancer service
kubectl apply -f 05-loadbalancer-services-dc2.yaml --context kind-sub-dc2
```

Verify IPs were assigned:
```bash
kubectl get svc cassandra-dc1-node-0-lb -n k8ssandra-operator \
  --context kind-sub-dc1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Expected: 172.19.255.1

kubectl get svc cassandra-dc2-node-0-lb -n k8ssandra-operator \
  --context kind-sub-dc2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
# Expected: 172.19.255.11
```

### Step 4: Create Per-Node Config

```bash
# DC1 per-node config (applied to dc1 cluster)
kubectl apply -f 06-per-node-config-dc1.yaml --context kind-sub-dc1

# DC2 per-node config (applied to dc2 cluster — NOT dc1!)
kubectl apply -f 07-per-node-config-dc2.yaml --context kind-sub-dc2
```

**Important:** The DC2 ConfigMap must be applied to the **dc2 cluster** directly.
The k8ssandra-operator creates the CassandraDatacenter on dc2, but it doesn't copy
ConfigMaps across clusters.

### Step 5: Create Cross-Cluster Kubeconfig Secret

The k8ssandra-operator on dc1 needs API access to dc2:

```bash
DC2_CA=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="kind-sub-dc2")].cluster.certificate-authority-data}')
DC2_CERT=$(kubectl config view --raw -o jsonpath='{.users[?(@.name=="kind-sub-dc2")].user.client-certificate-data}')
DC2_KEY=$(kubectl config view --raw -o jsonpath='{.users[?(@.name=="kind-sub-dc2")].user.client-key-data}')
DC2_IP=$(docker inspect sub-dc2-control-plane --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

cat > /tmp/dc2-kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${DC2_CA}
    server: https://${DC2_IP}:6443
  name: kind-sub-dc2
contexts:
- context:
    cluster: kind-sub-dc2
    user: kind-sub-dc2
  name: kind-sub-dc2
current-context: kind-sub-dc2
users:
- name: kind-sub-dc2
  user:
    client-certificate-data: ${DC2_CERT}
    client-key-data: ${DC2_KEY}
EOF

kubectl create secret generic sub-dc2-kubeconfig \
  --from-file=kubeconfig=/tmp/dc2-kubeconfig.yaml \
  -n k8ssandra-operator --context kind-sub-dc1

rm /tmp/dc2-kubeconfig.yaml
```

### Step 6: Deploy ClientConfig and K8ssandraCluster

```bash
# ClientConfig (tells operator how to reach dc2)
kubectl apply -f 08-clientconfig.yaml --context kind-sub-dc1

# K8ssandraCluster (deploys Cassandra on both DCs)
kubectl apply -f 09-k8ssandra-cluster.yaml --context kind-sub-dc1
```

### Step 7: Wait and Verify

Watch pods come up (dc1 deploys first, then dc2):
```bash
kubectl get pods -n k8ssandra-operator -w --context kind-sub-dc1
kubectl get pods -n k8ssandra-operator -w --context kind-sub-dc2
```

Once both pods are 2/2 Running, verify the cluster:
```bash
# Check nodetool status — should show both DCs with MetalLB IPs
kubectl exec cassandra-cluster-dc1-default-sts-0 -c cassandra \
  -n k8ssandra-operator --context kind-sub-dc1 -- nodetool status
```

Expected output:
```
Datacenter: dc1
  UN  172.19.255.1   ...
Datacenter: dc2
  UN  172.19.255.11  ...
```

Verify broadcast_address was injected:
```bash
kubectl exec cassandra-cluster-dc1-default-sts-0 -c cassandra \
  -n k8ssandra-operator --context kind-sub-dc1 -- \
  grep broadcast_address /etc/cassandra/cassandra.yaml
# broadcast_address: 172.19.255.1
```

### Step 8: Connect with cqlsh

Get credentials:
```bash
kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator \
  --context kind-sub-dc1 -o jsonpath='{.data.username}' | base64 -d && echo
kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator \
  --context kind-sub-dc1 -o jsonpath='{.data.password}' | base64 -d && echo
```

Connect (requires port-forward or NodePort — see kind config with extraPortMappings):
```bash
# Port forward dc1
kubectl port-forward pod/cassandra-cluster-dc1-default-sts-0 9042:9042 \
  -n k8ssandra-operator --context kind-sub-dc1

# Then connect
cqlsh localhost 9042 -u <username> -p <password>
```

## Scaling

To add more nodes, for each new pod:

1. Create a new LoadBalancer service targeting the pod
   (change `statefulset.kubernetes.io/pod-name` selector)
2. Add a new entry to the per-node ConfigMap with the new MetalLB IP
3. Update `size` in the K8ssandraCluster CR

## Comparison with Other Approaches

| Aspect | MetalLB | Cilium ClusterMesh | Submariner |
|--------|---------|-------------------|------------|
| Network setup | Simple (L2 only) | Complex (eBPF, mesh) | Moderate (IPsec/VXLAN) |
| Pod-to-pod routing | No (MetalLB IPs only) | Yes (full mesh) | Yes (tunnel) |
| Extra components | MetalLB only | Cilium CNI | Submariner gateway |
| Overhead per node | 1 LoadBalancer svc | None | None |
| Scaling complexity | Manual (svc + configmap per pod) | Automatic | Automatic |
| Production readiness | Needs automation | Production-ready | Production-ready |
