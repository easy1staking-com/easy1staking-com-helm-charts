# Amaru Monitoring

A Helm chart for monitoring Amaru Cardano nodes with Grafana dashboards and Prometheus metrics.

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

  # Namespace scanning configuration
  namespaceSelector:
    any: true  # Scan all namespaces

  # Label selector for finding Amaru instances
  labelSelector:
    app.kubernetes.io/name: amaru
    app.kubernetes.io/component: node

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

The Grafana dashboard includes:

**Overview Stats:**
- Current Block Number
- Current Epoch
- Slot in Epoch (gauge)
- Block Density
- Uptime
- Open Files

**Time Series Charts:**
- Block Sync Progress
- Transaction Processing Rate
- CPU Usage
- Memory Usage (Resident & Virtual)
- Disk I/O Rate
- Total Disk I/O
- Total Transactions Processed

**Filtering:**
- Namespace selector (dropdown)
- Node selector (dropdown, filtered by namespace)
- Datasource selector

## How It Works

1. **Label-Based Discovery**: The dashboard uses Prometheus queries with label selectors to find Amaru instances:
   ```promql
   amaru_cardano_node_metrics_blockNum_int{job="amaru",namespace="$namespace"}
   ```

2. **Grafana Sidecar**: The ConfigMap is labeled with `grafana_dashboard: "1"`, which the kube-prometheus-stack Grafana sidecar automatically detects and imports.

3. **Dynamic Variables**: Namespace and node lists are dynamically populated from Prometheus label values.

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
