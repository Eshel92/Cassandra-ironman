# Cassandra Commands

## 1. Port-forward to Cassandra (run in a separate terminal)

Connect via dc1:
```bash
kubectl port-forward cassandra-cluster-dc1-default-sts-0 9042:9042 -n k8ssandra-operator --context kind-dc1
```

Or connect via dc2:
```bash
kubectl port-forward cassandra-cluster-dc2-default-sts-0 9042:9042 -n k8ssandra-operator --context kind-dc2
```

## 2. Connect with cqlsh

```bash
cqlsh 127.0.0.1 9042 -u cassandra-cluster-superuser -p 'vS83PTow5Br6LnY9pj2a'
```

## 3. Query peers_v2 (shows all nodes the connected node knows about)

```sql
SELECT peer, data_center, rack, host_id, preferred_ip, native_transport_address
FROM system.peers_v2;
```

Also check the local node:
```sql
SELECT listen_address, data_center, rack, host_id
FROM system.local;
```

## 4. Create a multi-DC keyspace

```sql
CREATE KEYSPACE my_app
WITH replication = {
  'class': 'NetworkTopologyStrategy',
  'dc1': 1,
  'dc2': 1
};
```

Verify:
```sql
DESCRIBE KEYSPACE my_app;
```

Use it:
```sql
USE my_app;

CREATE TABLE users (
  id UUID PRIMARY KEY,
  name text,
  email text
);

INSERT INTO users (id, name, email) VALUES (uuid(), 'test', 'test@example.com');

-- This data is replicated to both dc1 and dc2
SELECT * FROM users;
```

## 5. Check replication is working

Query with different consistency levels:
```sql
CONSISTENCY LOCAL_ONE;
SELECT * FROM my_app.users;

CONSISTENCY EACH_QUORUM;
SELECT * FROM my_app.users;
```
