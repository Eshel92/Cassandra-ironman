# Airgapped Deployment Guide - Submariner + Cassandra Multi-DC

Step-by-step instructions for deploying after you've transferred all files from the
bill of materials into your airgapped network.

**Prerequisites:**
- Two Kubernetes clusters already running with non-overlapping pod CIDRs
- cert-manager already installed on both clusters (required by k8ssandra-operator for webhook TLS)
- All files from the bill of materials transferred to a management workstation that has
  kubectl access to both clusters

**Notation:**
- `<CTX1>` — kubectl context for cluster 1 (will host dc1)
- `<CTX2>` — kubectl context for cluster 2 (will host dc2)

---

## Step 1: Install CLI Tools

```bash
sudo cp subctl /usr/local/bin/
sudo cp helm /usr/local/bin/     # skip if you already have helm

# Install cqlsh
pip3 install --no-index --find-links=cqlsh-wheels/ cqlsh
```

Verify:
```bash
subctl version
helm version
cqlsh --version
```

---

## Step 2: Load Container Images

Since there's no internet, all container images must be pre-loaded into both clusters
before installing anything. Choose the method that matches your environment.

### Option A: Private Registry

If your airgapped environment has a container registry (Harbor, Nexus, etc.):

```bash
# Load the tarballs into local Docker
docker load -i submariner-images.tar
docker load -i k8ssandra-images.tar

# Retag and push each image to your registry
# Example for one image (repeat for all):
docker tag quay.io/submariner/submariner-gateway:0.18.1 \
  <your-registry>/submariner/submariner-gateway:0.18.1
docker push <your-registry>/submariner/submariner-gateway:0.18.1

# Do this for ALL images listed in the bill of materials
```

When using a private registry, you'll need to configure image overrides during
Helm installs (shown in later steps).

### Option B: Direct Node Import (containerd)

If your nodes use containerd and you can copy files to them:

```bash
# Copy tarballs to each node, then on EACH node run:
ctr -n k8s.io images import submariner-images.tar
ctr -n k8s.io images import k8ssandra-images.tar
```

This must be done on **every node** in **both clusters**.

### Option C: Direct Node Import (CRI-O)

```bash
# On each node:
podman load -i submariner-images.tar
podman load -i k8ssandra-images.tar
```

**Do this BEFORE proceeding.** If images aren't available, pods will fail with
`ImagePullBackOff` or `ErrImagePull`.

---

## Step 3: Deploy Submariner

Submariner creates encrypted tunnels between clusters so pods in cluster 1 can
talk directly to pods in cluster 2 using their pod IPs. This is what makes
Cassandra cross-DC gossip work without any application-level networking changes.

### 3a: Deploy the Broker

The broker is a lightweight coordination point. Both clusters register with it
to discover each other's endpoints, CIDRs, and tunnel keys. It stores metadata
only — no data traffic flows through the broker.

```bash
subctl deploy-broker --context <CTX1>
```

This creates a `broker-info.subm` file in your current directory. Keep this file —
both clusters need it to join the mesh.

### 3b: Choose a Tunnel Mode

Submariner supports three tunnel (cable driver) modes. Choose based on your
network trust level:

| Mode | Encryption | Performance | When to Use |
|------|-----------|-------------|-------------|
| **IPsec** (default) | Yes (AES-GCM) | Good, moderate CPU overhead | Clusters on untrusted/shared networks |
| **VXLAN** | No | Best — no crypto overhead | Clusters on same trusted network (same DC, private links) |
| **WireGuard** | Yes (ChaCha20) | Better than IPsec, lower CPU | Want encryption with less overhead than IPsec. Requires kernel 5.6+ or WireGuard module |

For airgapped environments, check with your security team whether encryption is
required by policy. If both clusters are in the same secured datacenter, VXLAN
gives the best Cassandra replication performance.

### 3c: Join Cluster 1 to the Broker

This installs on cluster 1:
- **Gateway** — creates tunnels to other clusters. All cross-cluster traffic
  flows through the gateway pod.
- **Route Agent** — DaemonSet on every node. Injects iptables rules and ip-routes
  so packets destined to remote pod CIDRs get forwarded to the gateway.
- **Lighthouse Agent** — cross-cluster service discovery.
- **Lighthouse CoreDNS** — DNS server for resolving services across clusters.

```bash
# IPsec (default — encrypted)
subctl join broker-info.subm --context <CTX1> --clusterid cluster1 \
  --natt=false

# VXLAN (no encryption — best performance on trusted networks)
subctl join broker-info.subm --context <CTX1> --clusterid cluster1 \
  --natt=false --cable-driver vxlan

# WireGuard (encrypted — faster than IPsec)
subctl join broker-info.subm --context <CTX1> --clusterid cluster1 \
  --natt=false --cable-driver wireguard
```

Flags:
- `--clusterid cluster1` — unique identifier for this cluster in the mesh
- `--natt=false` — disable NAT traversal. Use this if clusters can reach each other
  directly on their node IPs. If there's a firewall/NAT between clusters, omit this flag.
- `--cable-driver` — tunnel mode (default: IPsec if omitted)

### 3d: Join Cluster 2 to the Broker

Use the same `--cable-driver` as cluster 1 — both gateways must speak the same
tunnel protocol to establish a connection.

```bash
subctl join broker-info.subm --context <CTX2> --clusterid cluster2 \
  --natt=false

# If you used --cable-driver vxlan for cluster 1:
subctl join broker-info.subm --context <CTX2> --clusterid cluster2 \
  --natt=false --cable-driver vxlan
```

### 3e: Wait for Submariner Components

```bash
# Wait for gateways
kubectl rollout status daemonset/submariner-gateway \
  -n submariner-operator --context <CTX1> --timeout=180s
kubectl rollout status daemonset/submariner-gateway \
  -n submariner-operator --context <CTX2> --timeout=180s

# Wait for route agents
kubectl rollout status daemonset/submariner-routeagent \
  -n submariner-operator --context <CTX1> --timeout=120s
kubectl rollout status daemonset/submariner-routeagent \
  -n submariner-operator --context <CTX2> --timeout=120s
```

### 3f: Verify Connectivity

```bash
# Check connections — should show status "connected"
subctl show connections --context <CTX1>

# Check endpoints
subctl show endpoints --context <CTX1>

# Full diagnostics (optional)
subctl diagnose all --context <CTX1>
```

You should see a connection with status `connected` and both clusters' pod/service
CIDRs listed. Cross-cluster pod networking is now active.

**Troubleshooting:** If connections don't establish:
- Verify that UDP port 4500 (IPsec) is open between cluster nodes
- If using `--natt=false`, verify nodes can reach each other directly on their IPs
- Check gateway pod logs: `kubectl logs -l app=submariner-gateway -n submariner-operator --context <CTX1>`

---

## Step 4: Install k8ssandra-operator

The k8ssandra-operator watches for `K8ssandraCluster` CRDs and creates Cassandra
StatefulSets, Services, and configuration. It must run on both clusters.

```bash
helm install k8ssandra-operator ./k8ssandra-operator-1.32.3.tgz \
  --kube-context <CTX1> \
  --namespace k8ssandra-operator \
  --create-namespace

helm install k8ssandra-operator ./k8ssandra-operator-1.32.3.tgz \
  --kube-context <CTX2> \
  --namespace k8ssandra-operator \
  --create-namespace
```

If using a private registry, add image overrides:
```bash
helm install k8ssandra-operator ./k8ssandra-operator-1.32.3.tgz \
  --kube-context <CTX1> \
  --namespace k8ssandra-operator \
  --create-namespace \
  --set global.imageRegistry=<your-registry>
```

Wait for ready:
```bash
kubectl rollout status deployment/k8ssandra-operator \
  -n k8ssandra-operator --context <CTX1> --timeout=180s
kubectl rollout status deployment/k8ssandra-operator \
  -n k8ssandra-operator --context <CTX2> --timeout=180s
```

---

## Step 5: Create Cross-Cluster Access (ClientConfig)

The k8ssandra-operator on cluster 1 is the control plane — it manages Cassandra on
both clusters. It needs kubeconfig credentials to access cluster 2's API server.

### 5a: Create the Kubeconfig Secret

```bash
# Extract cluster 2 credentials from your kubeconfig
DC2_CA=$(kubectl config view --raw -o jsonpath='{.clusters[?(@.name=="<CTX2>")].cluster.certificate-authority-data}')
DC2_CERT=$(kubectl config view --raw -o jsonpath='{.users[?(@.name=="<CTX2>")].user.client-certificate-data}')
DC2_KEY=$(kubectl config view --raw -o jsonpath='{.users[?(@.name=="<CTX2>")].user.client-key-data}')

# Get cluster 2's API server address
# This must be reachable FROM INSIDE cluster 1 pods (not just your workstation)
DC2_SERVER="https://<cluster2-api-server>:6443"

# Create the kubeconfig file
cat > /tmp/dc2-kubeconfig.yaml <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${DC2_CA}
    server: ${DC2_SERVER}
  name: <CTX2>
contexts:
- context:
    cluster: <CTX2>
    user: <CTX2>
  name: <CTX2>
current-context: <CTX2>
users:
- name: <CTX2>
  user:
    client-certificate-data: ${DC2_CERT}
    client-key-data: ${DC2_KEY}
EOF

# Create the secret on cluster 1
kubectl create secret generic dc2-kubeconfig \
  --from-file=kubeconfig=/tmp/dc2-kubeconfig.yaml \
  -n k8ssandra-operator \
  --context <CTX1>

rm -f /tmp/dc2-kubeconfig.yaml
```

**Important:** The `DC2_SERVER` address must be reachable from inside cluster 1's
pods. If the clusters are on different networks, this must be a routable address,
not a localhost or VPN-only address.

### 5b: Apply the ClientConfig

Create a file `clientconfig.yaml`:
```yaml
apiVersion: config.k8ssandra.io/v1beta1
kind: ClientConfig
metadata:
  name: cluster2
  namespace: k8ssandra-operator
spec:
  contextName: <CTX2>
  kubeConfigSecret:
    name: dc2-kubeconfig
```

```bash
kubectl apply -f clientconfig.yaml --context <CTX1>
```

---

## Step 6: Deploy Cassandra Multi-DC

Create a file `cassandra-cluster.yaml` (or use `cassandra-multidc-submariner.yaml`
from the bill of materials, edited to match your context names):

```yaml
apiVersion: k8ssandra.io/v1alpha1
kind: K8ssandraCluster
metadata:
  name: cassandra-cluster
  namespace: k8ssandra-operator
spec:
  cassandra:
    serverVersion: "4.1.8"
    storageConfig:
      cassandraDataVolumeClaimSpec:
        storageClassName: <your-storage-class>
        accessModes:
          - ReadWriteOnce
        resources:
          requests:
            storage: 50Gi
    config:
      jvmOptions:
        heapSize: 4G
    networking:
      hostNetwork: false
    datacenters:
      - metadata:
          name: dc1
        k8sContext: ""          # empty = local cluster (cluster 1)
        size: 3                 # number of Cassandra nodes in dc1
        resources:
          requests:
            cpu: "2"
            memory: 8Gi
          limits:
            cpu: "4"
            memory: 8Gi
      - metadata:
          name: dc2
        k8sContext: <CTX2>      # must match ClientConfig contextName
        size: 3
        resources:
          requests:
            cpu: "2"
            memory: 8Gi
          limits:
            cpu: "4"
            memory: 8Gi
```

Deploy:
```bash
kubectl apply -f cassandra-cluster.yaml --context <CTX1>
```

The operator will:
1. Create a Cassandra StatefulSet on cluster 1 (dc1) — wait for it to be fully ready
2. Connect to cluster 2 via the ClientConfig
3. Create a Cassandra StatefulSet on cluster 2 (dc2)
4. Cassandra nodes discover each other over port 7000 (gossip) via the Submariner tunnel
5. They form a single logical cluster spanning both DCs

Watch the deployment (takes 5-10 minutes):
```bash
kubectl get pods -n k8ssandra-operator -w --context <CTX1>
kubectl get pods -n k8ssandra-operator -w --context <CTX2>
```

Wait until all pods show `Running` with all containers ready (2/2).

---

## Step 7: Post-Deployment — Rebuild DC2

When dc2 first joins, system keyspaces (including `system_auth`) may not be
replicated yet. This means you can't authenticate to dc2 nodes directly.
Run a rebuild to stream all data from dc1 to dc2:

```bash
kubectl exec cassandra-cluster-dc2-default-sts-0 -c cassandra \
  -n k8ssandra-operator --context <CTX2> -- nodetool rebuild dc1
```

If you have multiple nodes in dc2, rebuild each one:
```bash
for i in 0 1 2; do
  kubectl exec cassandra-cluster-dc2-default-sts-$i -c cassandra \
    -n k8ssandra-operator --context <CTX2> -- nodetool rebuild dc1
done
```

---

## Step 8: Verify

### Check cluster health

```bash
kubectl exec cassandra-cluster-dc1-default-sts-0 -c cassandra \
  -n k8ssandra-operator --context <CTX1> -- nodetool status
```

Expected output — all nodes `UN` (Up/Normal) in both DCs:
```
Datacenter: dc1
  UN  10.x.x.x  ...
  UN  10.x.x.x  ...
  UN  10.x.x.x  ...
Datacenter: dc2
  UN  10.y.y.y  ...
  UN  10.y.y.y  ...
  UN  10.y.y.y  ...
```

### Check cross-DC peer visibility

```bash
# From dc1 — should show dc2 nodes
kubectl exec cassandra-cluster-dc1-default-sts-0 -c cassandra \
  -n k8ssandra-operator --context <CTX1> -- \
  cqlsh -u cassandra-cluster-superuser -p '<PASSWORD>' \
  -e "SELECT peer, data_center, rack FROM system.peers_v2;"
```

### Connect with cqlsh

```bash
# Get the superuser password
kubectl get secret cassandra-cluster-superuser -n k8ssandra-operator \
  --context <CTX1> -o jsonpath='{.data.password}' | base64 -d; echo

# Port-forward to a dc1 node
kubectl port-forward cassandra-cluster-dc1-default-sts-0 9042:9042 \
  -n k8ssandra-operator --context <CTX1> &

# Connect
cqlsh localhost 9042 -u cassandra-cluster-superuser -p '<PASSWORD>'
```

### Test multi-DC replication

```sql
-- Create a keyspace replicated to both DCs
CREATE KEYSPACE test_multidc WITH replication = {
  'class': 'NetworkTopologyStrategy', 'dc1': 1, 'dc2': 1
};

-- Write data on dc1
CREATE TABLE test_multidc.messages (id int PRIMARY KEY, msg text);
INSERT INTO test_multidc.messages (id, msg) VALUES (1, 'written on dc1');
```

Now port-forward to a dc2 node and verify the data is there:
```bash
kubectl port-forward cassandra-cluster-dc2-default-sts-0 9043:9042 \
  -n k8ssandra-operator --context <CTX2> &

cqlsh localhost 9043 -u cassandra-cluster-superuser -p '<PASSWORD>' \
  -e "SELECT * FROM test_multidc.messages;"
```

If you see the data on dc2, multi-DC replication is working.

---

## Troubleshooting

### Pods stuck in ImagePullBackOff
Images weren't loaded properly. Re-check Step 2. Run `crictl images` on the node
to verify the images are present.

### K8ssandraCluster stuck — dc2 not deploying
Check that the ClientConfig and kubeconfig secret are correct:
```bash
kubectl get clientconfig -n k8ssandra-operator --context <CTX1>
kubectl get secret dc2-kubeconfig -n k8ssandra-operator --context <CTX1>
```
Check operator logs:
```bash
kubectl logs deployment/k8ssandra-operator -n k8ssandra-operator --context <CTX1> --tail=50
```

### DC2 authentication fails (Bad credentials)
Run `nodetool rebuild dc1` on dc2 nodes (Step 7). The `system_auth` keyspace needs
to be streamed from dc1.

### Submariner connections not establishing
```bash
subctl diagnose all --context <CTX1>
```
Check that UDP port 4500 is open between cluster nodes. Check gateway logs:
```bash
kubectl logs -l app=submariner-gateway -n submariner-operator --context <CTX1>
```

### Cassandra nodes see each other but show DN (Down/Normal)
Cross-cluster pod networking may not be working. Test from a pod in cluster 1:
```bash
kubectl exec -it cassandra-cluster-dc1-default-sts-0 -c cassandra \
  -n k8ssandra-operator --context <CTX1> -- \
  bash -c "echo | nc -w 3 <dc2-pod-ip> 7000 && echo OK || echo FAIL"
```
If this fails, Submariner tunnels are not routing correctly.
