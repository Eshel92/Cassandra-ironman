# Airgapped Bill of Materials - Submariner + Cassandra Multi-DC

Everything you need to download on an internet-connected machine and transfer to your
airgapped network. This assumes you already have Kubernetes clusters running.

---

## CLI Tools

| Tool | Version | What It Does |
|------|---------|-------------|
| subctl | v0.18.1 | Submariner CLI - deploys broker, joins clusters |
| helm | v4.1.3 | K8s package manager - installs charts from local tarballs |
| cqlsh | 6.2.2 | Cassandra CQL client for querying |

```bash
# subctl
curl -Lo subctl "https://github.com/submariner-io/releases/releases/download/v0.18.1/subctl-v0.18.1-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
chmod +x subctl

# helm (skip if you already have it)
curl -L "https://get.helm.sh/helm-v4.1.3-$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/').tar.gz" | tar -xz --strip-components=1

# cqlsh
pip3 download cqlsh -d cqlsh-wheels/
```

---

## Helm Charts

| Chart | Version | What It Does |
|-------|---------|-------------|
| k8ssandra-operator | 1.32.3 | Manages Cassandra lifecycle, multi-DC coordination |

```bash
helm repo add k8ssandra https://helm.k8ssandra.io/stable
helm repo update

helm pull k8ssandra/k8ssandra-operator --version 1.32.3
```

Produces: `k8ssandra-operator-1.32.3.tgz`

---

## Container Images

### Submariner

| Image | What It Does |
|-------|-------------|
| submariner-operator:0.18.1 | Manages Submariner component lifecycle |
| submariner-gateway:0.18.1 | Creates tunnels between clusters (all cross-cluster traffic goes through here) |
| submariner-route-agent:0.18.1 | Runs on every node, injects routes for remote pod CIDRs |
| lighthouse-agent:0.18.1 | Cross-cluster service discovery |
| lighthouse-coredns:0.18.1 | DNS for cross-cluster service resolution |
| nettest:0.18.1 | Network diagnostic tool |

```bash
SUBMARINER_IMAGES=(
  quay.io/submariner/submariner-operator:0.18.1
  quay.io/submariner/submariner-gateway:0.18.1
  quay.io/submariner/submariner-route-agent:0.18.1
  quay.io/submariner/lighthouse-agent:0.18.1
  quay.io/submariner/lighthouse-coredns:0.18.1
  quay.io/submariner/nettest:0.18.1
)
for img in "${SUBMARINER_IMAGES[@]}"; do docker pull "$img"; done
docker save "${SUBMARINER_IMAGES[@]}" -o submariner-images.tar
```

### k8ssandra / Cassandra

| Image | What It Does |
|-------|-------------|
| k8ssandra-operator:v1.32.3 | Multi-cluster Cassandra operator (watches K8ssandraCluster CRDs) |
| cass-operator:v1.30.2 | Single-cluster Cassandra operator (manages StatefulSets) |
| cass-management-api:4.1.8-ubi | Cassandra 4.1.8 with management sidecar |
| k8ssandra-client:v0.8.13 | Init container for client config |
| system-logger:v1.30.2 | Log collection sidecar |

```bash
K8SSANDRA_IMAGES=(
  docker.io/k8ssandra/k8ssandra-operator:v1.32.3
  docker.io/k8ssandra/cass-operator:v1.30.2
  docker.io/k8ssandra/cass-management-api:4.1.8-ubi
  docker.io/k8ssandra/k8ssandra-client:v0.8.13
  docker.io/k8ssandra/system-logger:v1.30.2
)
for img in "${K8SSANDRA_IMAGES[@]}"; do docker pull "$img"; done
docker save "${K8SSANDRA_IMAGES[@]}" -o k8ssandra-images.tar
```

---

## Summary - What to Transfer

```
subctl                              # CLI binary (~60 MB)
helm                                # CLI binary (~50 MB) - skip if already have it
cqlsh-wheels/                       # Python wheels (~5 MB)
k8ssandra-operator-1.32.3.tgz      # Helm chart (~2 MB)
submariner-images.tar               # Container images (~400 MB)
k8ssandra-images.tar                # Container images (~1.2 GB)
cassandra-multidc-submariner.yaml   # K8ssandraCluster manifest
```

**Total: ~1.7 GB**
