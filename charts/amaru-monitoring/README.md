# Amaru Monitoring

A Helm chart for monitoring Amaru Cardano nodes with Grafana dashboards and Prometheus metrics.

## Depends on the `amaru` chart's `job` relabel

Every alert rule here, and the dashboard's `namespace`/`node` variables, query
**`job="amaru"`**. That label does not arise naturally: Prometheus would otherwise
set `job` to the scraped Service's name (`amaru-relay-1-int`, and different again
for each relay). It exists because the `amaru` chart's ServiceMonitor explicitly
relabels it.

**That makes this a contract between two charts that neither enforces.** If the
relabel is removed or changed in the `amaru` chart, every rule here silently stops
matching — no error, no failed rule, just alerts that never fire and empty
dropdowns. Change the two together, or change neither.


## Overview

This chart deploys monitoring resources for Amaru nodes, including:
- Grafana dashboard with namespace and node filtering
- Support for multi-namespace deployments
- Automatic discovery of Amaru instances via label selectors

## Prerequisites

- Kubernetes cluster
- kube-prometheus-stack installed with Grafana
- Amaru nodes deployed with OTel Collector sidecars (for metrics)
- Prometheus configured to scrape Amaru ServiceMonitors

## Installation

```bash
# Install with default settings (scans all namespaces)
helm install amaru-monitoring ./charts/amaru-monitoring

# Install with custom release name
helm install my-monitoring ./charts/amaru-monitoring

# Install in specific namespace
helm install amaru-monitoring ./charts/amaru-monitoring -n monitoring
```

## Configuration

### Key Values

```yaml
# Enable/disable dashboard
dashboard:
  enabled: true

  # Grafana sidecar configuration
  grafanaLabel: grafana_dashboard
  grafanaLabelValue: "1"

  # Dashboard settings
  refreshInterval: "10s"
  timeRange:
    from: "now-1h"
    to: "now"
```

### Multi-Namespace Support

The dashboard automatically discovers Amaru nodes across all namespaces by default. Filter by namespace and node using the dropdown selectors in Grafana.

### Multiple Monitoring Deployments

You can deploy multiple instances of this chart with different configurations:

```bash
# Production monitoring
helm install prod-monitoring ./charts/amaru-monitoring -n monitoring

# Development monitoring
helm install dev-monitoring ./charts/amaru-monitoring -n monitoring
```

Each deployment creates uniquely named resources using the release name prefix.

## Dashboard Features

The "Amaru Node Dashboard" is one page, modelled on a Haskell stake pool overview:
relays and block producers side by side, one series (or one stat value) per node.
Six rows, all expanded:

- **General**: uptime, version (from `cardano_build_info`), epoch, time to epoch
  end, tip age, chain density, block height, slot in epoch, and sync speed in
  blocks per minute.
- **Network**: inbound, outbound and unidirectional connections, and blocks
  served per minute.
- **Consensus**: headers per minute by outcome, the p95 delay from slot start to
  header arrival, p95 block fetch time, and chain switches per hour.
- **Mempool**: mempool size in bytes, transactions in the mempool, and
  transaction insertions per minute by result.
- **Block producer**: `Current KES period`, `Opcert start KES period`,
  `Opcert expiry KES period`, `KES periods remaining`, `KES expiry` (remaining
  periods times 129600 slots per KES period), and `Our blocks seen at tip`.
- **Resources**: container CPU (cores) and working-set memory from cAdvisor,
  free bytes on the node's volume, and the node's open files. These read the
  kubelet's series by pod (`amaru-<node>-0`) and claim
  (`amaru-<node>-amaru-<node>-0`).

**Variables:**
- `datasource`: the Prometheus datasource.
- `namespace`: populated from the Amaru series in the datasource.
- `node`: multi-select, All by default, populated from the selected namespace.
- `pool_id`: a text box labelled "Pool id (hex)", the pool the
  `Our blocks seen at tip` panel looks for. Its default is the chart value
  `dashboard.poolId`, empty by default, which leaves that one panel empty. Set it
  in your own deployment values; this repository ships no pool id.

**There are no blocks panels, deliberately.** Amaru exports no forge counters: at
v10.11.20261112 there is no metric for slots led, blocks forged, blocks adopted
or slots missed. Forging shows up only as log events such as `FORGED` and
`MISSED_SLOT`. The absence is the design, not an omission: do not add panels for
Haskell forge counter names, because Amaru will never fill them.

**What `Our blocks seen at tip` counts.** It counts distinct blocks issued by
`pool_id` that the node reported as its tip during the dashboard's time range,
read from the `issuer_verification_key_hash` label of the tip gauge. It is
"seen at tip", not "forged": Amaru pushes metrics every 30 s, so a block that is
the tip for less than one push is never seen and is not counted, and the
collector keeps a replaced tip's series for 5 minutes, so a past tip lingers that
long. Use it as a sign of life, not as a forge tally.

**Block producer panels on a relay.** The three operational certificate panels
(`Opcert start KES period`, `Opcert expiry KES period`, `KES periods remaining`)
and `KES expiry` show data only on a block producer running with its keys,
because the forge stage records them. On a relay they are empty, which is
expected. `Current KES period` comes from the ledger, so it shows on relays too.

**Per-network values.** `Tip age` and `Time to epoch end` are derived per node
from its `network` label: an epoch is 86400 slots on preview and 432000 on
preprod and mainnet, and tip age uses each network's slot-zero time. A node
whose `network` label is none of preview, preprod or mainnet shows no tip age.

## How It Works

1. **Label-Based Discovery**: The dashboard uses Prometheus queries with label selectors to find Amaru instances:
   ```promql
   amaru_cardano_node_metrics_blockNum_int{job="amaru",namespace="$namespace"}
   ```

2. **Grafana Sidecar**: The ConfigMap is labeled with `grafana_dashboard: "1"`, which the kube-prometheus-stack Grafana sidecar automatically detects and imports.

3. **Dynamic Variables**: Namespace and node lists are dynamically populated from Prometheus label values; `node` is multi-select and defaults to All. `pool_id` is a free-text box whose default comes from `dashboard.poolId`.

## Integration with Amaru Chart

This chart is designed to work with the Amaru Helm chart (v0.0.1-alpha.19+). The Amaru chart must have:
- OTel Collector sidecar enabled
- ServiceMonitor configured
- Proper Kubernetes labels applied

Example Amaru configuration:
```yaml
nodes:
  - name: my-node
    enabled: true
    otelCollector:
      enabled: true  # Required for metrics
```

## Troubleshooting

### Dashboard Not Appearing

1. Check Grafana sidecar is running:
   ```bash
   kubectl get pods -n monitoring -l app.kubernetes.io/name=grafana
   ```

2. Verify ConfigMap has correct label:
   ```bash
   kubectl get cm -l grafana_dashboard=1
   ```

3. Check Grafana sidecar logs:
   ```bash
   kubectl logs -n monitoring <grafana-pod> -c grafana-sc-dashboard
   ```

### No Data in Dashboard

1. Verify Prometheus is scraping Amaru metrics:
   ```bash
   # Check for amaru job
   curl http://prometheus:9090/api/v1/label/job/values | grep amaru
   ```

2. Verify ServiceMonitor exists:
   ```bash
   kubectl get servicemonitor -l app.kubernetes.io/name=amaru
   ```

3. Check OTel Collector is running in Amaru pods:
   ```bash
   kubectl get pods -l app.kubernetes.io/name=amaru -o jsonpath='{.items[*].spec.containers[*].name}'
   ```

## Alerting

The chart includes comprehensive PrometheusRule alerts for monitoring Amaru node health.

### Alert Categories

**Node Availability (Critical)**
- `AmaruNodeDown` - Node unreachable by Prometheus (2m)
- `AmaruNodeRestarted` - Node recently restarted, potential instability (5m)

**Performance (Warning)**
- `AmaruHighCPUUsage` - CPU usage above 90% (5m)
- `AmaruHighMemoryUsage` - Resident memory above 90% of available virtual memory (dynamic, self-adjusting) (5m)
- `AmaruHighDiskIOWait` - Sustained high disk I/O (10m)

**Blockchain Sync (Critical/Warning)**
- `AmaruSyncStalled` - Block number not increasing (15m) - **Critical**
- `AmaruLowBlockDensityWarning` - Block density below 4% (ideal is 5%) (30m)
- `AmaruLowBlockDensityCritical` - Block density below 3% (30m) - **Critical**
- `AmaruEpochTransitionDelay` - Stuck near epoch boundary (10m)

**Observability (Warning)**
- `AmaruMetricsMissing` - No metrics in Prometheus (5m)
- `AmaruHighFileDescriptors` - Too many open files (5m)

### Configuring Alerts

```yaml
alerts:
  enabled: true
  evaluationInterval: 30s

  # Add labels for alert routing
  additionalLabels:
    team: cardano
    environment: production

  rules:
    # Customize thresholds
    highCPU:
      threshold: 85  # Lower threshold
      for: 10m       # Wait longer before firing

    syncStalled:
      for: 20m       # Custom duration

    # Per-network block density thresholds
    # Different Cardano networks have different ideal densities
    lowDensity:
      networks:
        mainnet:
          warningThreshold: 0.04   # 4%
          criticalThreshold: 0.03  # 3%
        preprod:
          warningThreshold: 0.03   # Adjust for preprod's d parameter
          criticalThreshold: 0.02
        preview:
          warningThreshold: 0.035
          criticalThreshold: 0.025
      defaultWarningThreshold: 0.04   # For unknown networks
      defaultCriticalThreshold: 0.03

    # Add runbook links
    nodeDown:
      annotations:
        runbook_url: https://wiki.example.com/runbooks/amaru-node-down
```

### Alert Routing

Add labels to route alerts to specific receivers in Alertmanager:

```yaml
alerts:
  additionalLabels:
    team: sre
    severity_override: page  # For paging integration
    slack_channel: cardano-alerts
```

### Disabling Alerts

```yaml
alerts:
  enabled: false  # Disable all alerts
```

Or deploy without alerts:
```bash
helm install amaru-mon ./charts/amaru-monitoring --set alerts.enabled=false
```

### Testing Alerts

```bash
# Check PrometheusRule is created
kubectl get prometheusrule -l app.kubernetes.io/name=amaru-monitoring

# View alert rules
kubectl get prometheusrule <name> -o yaml

# Check alert status in Prometheus UI
# Navigate to: Alerts → Filter by "amaru"
```

## Future Enhancements

- Additional dashboards for specific metrics
- Support for custom dashboard templates
- Pre-configured Alertmanager routes

## License

Same as Amaru project
