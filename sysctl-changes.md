# Temporary sysctl changes

These changes revert automatically on reboot.

## Changes made

| Setting | Original Value | New Value | Why |
|---------|---------------|-----------|-----|
| net.inet.ip.portrange.first | 49152 | 10000 | Expand ephemeral port range from ~16K to ~55K ports to avoid TIME_WAIT exhaustion |
| net.inet.tcp.msl | 15000 | 5000 | Reduce TIME_WAIT duration from 30s to 10s so stale connections clear faster |

## Revert commands

```bash
sudo sysctl -w net.inet.ip.portrange.first=49152
sudo sysctl -w net.inet.tcp.msl=15000
```

## Verify current values

```bash
sysctl net.inet.ip.portrange.first net.inet.tcp.msl
```
