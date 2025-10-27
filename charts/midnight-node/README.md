# Midnight Node Helm Chart

A production-ready Helm chart for deploying [Midnight Network](https://midnight.network/) nodes on Kubernetes.

**Chart Version:** `0.0.1-beta.2` | **App Version:** `0.12.0`

## What is Midnight?

**Midnight** is a data protection blockchain that operates as a privacy-focused sidechain to Cardano. It uses advanced zero-knowledge proof technology (zkSNARKs) to safeguard sensitive commercial and personal data while maintaining blockchain transparency and auditability.

### Key Features of Midnight

- **Privacy-First Design**: Protects user, commercial, and transaction metadata
- **Zero-Knowledge Proofs**: Uses zkSNARKs for privacy-preserving smart contracts
- **Developer-Friendly**: Built with TypeScript framework for easy development
- **Cardano Integration**: Operates as a sidechain to leverage Cardano's security
- **Data Protection**: Safeguards fundamental freedoms of association, commerce, and expression

Midnight enables developers to build applications that require strong privacy guarantees without sacrificing the benefits of blockchain technology.

## Prerequisites

Before installing this chart, ensure you have:

- Kubernetes cluster (1.19+)
- Helm 3.x installed
- kubectl configured for your cluster
- Persistent storage provisioner (for blockchain data)
- PostgreSQL database (for chain indexing)
- Kubernetes secrets configured (for node keys and credentials)

### Optional Prerequisites

- Prometheus Operator (for monitoring with ServiceMonitor)
- Grafana with sidecar (for automatic dashboard provisioning)

## Installation

### Basic Installation

```bash
# Install with default values (testnet)
helm install midnight-node ./charts/midnight-node

# Install with custom release name
helm install my-midnight-node ./charts/midnight-node
```

### Installation with Custom Values

```bash
# Create a custom values file
cat > my-values.yaml <<EOF
volumeSize: 50Gi
resources:
  limits:
    cpu: 4
    memory: 8Gi
  requests:
    cpu: 2
    memory: 4Gi
monitoring:
  enabled: true
EOF

# Install with custom values
helm install midnight-node ./charts/midnight-node -f my-values.yaml
```

## Configuration

### Essential Configuration Options

#### Node Configuration

```yaml
node:
  config:
    preset: testnet  # Network preset: testnet or mainnet
  appendArgs: ""     # Additional CLI arguments

  # Node identity (optional)
  keys:
    secretName: ""        # Secret containing node key
    nodeKeyKey: ""        # Key in secret for node key

  # Keystore for consensus (optional)
  keystore:
    secretName: ""           # Secret containing keystore keys
    sidechainSecretKey: ""   # Sidechain key filename
    auraSecretKey: ""        # AURA consensus key filename
    grandpaSecretKey: ""     # GRANDPA finality key filename

  # Network configuration (optional)
  network:
    secretName: ""  # Secret containing network configuration
```

#### PostgreSQL Configuration

```yaml
postgres:
  host: "postgresql.default.svc.cluster.local"
  port: 5432
  dbName: cexplorer

  # Using Kubernetes secret (recommended)
  secret:
    name: "postgres-credentials"
    usernameKey: "username"
    passwordKey: "password"

  # OR direct credentials (not recommended for production)
  username: ""
  password: ""
```

#### Storage Configuration

```yaml
volumeSize: 20Gi  # Persistent volume size for blockchain data
```

#### Resource Configuration

```yaml
resources:
  limits:
    cpu: 2
    memory: 4Gi
  requests:
    cpu: 1
    memory: 2Gi
```

#### Monitoring Configuration

```yaml
monitoring:
  enabled: true
  releaseName: kube-prometheus-stack  # Must match your Prometheus Operator release
  service:
    port: 9615  # Metrics endpoint port
```

### Complete Values File Example

```yaml
replicaCount: 1

image:
  repository: midnightnetwork/midnight-node
  pullPolicy: IfNotPresent
  tag: ""  # Defaults to chart appVersion

# Node configuration
node:
  config:
    preset: testnet
  appendArgs: ""

# PostgreSQL connection
postgres:
  host: "postgresql.default.svc.cluster.local"
  port: 5432
  dbName: cexplorer
  secret:
    name: "midnight-postgres-secret"
    usernameKey: "username"
    passwordKey: "password"

# Storage
volumeSize: 50Gi

# Resources
resources:
  limits:
    cpu: 4
    memory: 8Gi
  requests:
    cpu: 2
    memory: 4Gi

# Monitoring
monitoring:
  enabled: true
  releaseName: kube-prometheus-stack

# Debug mode
debug:
  enabled: false  # Set to true to enable RUST_LOG=debug
```

## Network Configuration

### Testnet (Default)

The chart is configured by default for Midnight testnet-02:

```yaml
node:
  config:
    preset: testnet
```

Boot nodes are automatically configured:
- `boot-node-01.testnet-02.midnight.network:30333`
- `boot-node-02.testnet-02.midnight.network:30333`
- `boot-node-03.testnet-02.midnight.network:30333`

### Mainnet

For mainnet deployment (when available):

```yaml
node:
  config:
    preset: mainnet
```

## PostgreSQL Setup

Midnight Node requires PostgreSQL for chain indexing. You can:

### Option 1: Use Existing PostgreSQL

```yaml
postgres:
  host: "my-postgres.example.com"
  port: 5432
  dbName: midnight
  secret:
    name: "my-postgres-secret"
    usernameKey: "username"
    passwordKey: "password"
```

### Option 2: Deploy PostgreSQL with Helm

```bash
# Add Bitnami repo
helm repo add bitnami https://charts.bitnami.com/bitnami

# Install PostgreSQL
helm install postgresql bitnami/postgresql \
  --set auth.database=cexplorer \
  --set primary.persistence.size=100Gi

# Get the password
export POSTGRES_PASSWORD=$(kubectl get secret postgresql -o jsonpath="{.data.postgres-password}" | base64 -d)

# Create secret for Midnight Node
kubectl create secret generic midnight-postgres-secret \
  --from-literal=username=postgres \
  --from-literal=password=$POSTGRES_PASSWORD
```

## Secrets Management

### Creating Node Keys Secret

If you want to specify a persistent node identity:

```bash
kubectl create secret generic midnight-node-keys \
  --from-literal=node-key="your-node-key-here"
```

Then configure in values:

```yaml
node:
  keys:
    secretName: "midnight-node-keys"
    nodeKeyKey: "node-key"
```

### Creating Keystore Secret

For validator nodes with consensus keys:

```bash
kubectl create secret generic midnight-keystore \
  --from-file=sidechain=/path/to/sidechain-key \
  --from-file=aura=/path/to/aura-key \
  --from-file=grandpa=/path/to/grandpa-key
```

Configure in values:

```yaml
node:
  keystore:
    secretName: "midnight-keystore"
    sidechainSecretKey: "sidechain"
    auraSecretKey: "aura"
    grandpaSecretKey: "grandpa"
```

## Service Ports

The chart creates two services:

### Internal Service (ClusterIP)

- **RPC**: 9944 - JSON-RPC endpoint
- **P2P**: 30333 - Peer-to-peer networking
- **Metrics**: 9615 - Prometheus metrics (if monitoring enabled)

### External Service (NodePort)

- **P2P**: 30333 - Exposed for external peer connections

### Health Check

- **Health**: 9933 - Health check endpoint at `/health`

## Monitoring

This chart includes comprehensive monitoring support with Prometheus and Grafana.

### Enabling Monitoring

```yaml
monitoring:
  enabled: true
  releaseName: kube-prometheus-stack  # Must match your Prometheus Operator release
```

### What's Included

- **ServiceMonitor**: Automatic Prometheus scraping configuration
- **Grafana Dashboard**: Pre-built dashboard with key metrics
- **Metrics**: Substrate and Midnight-specific metrics

### Key Metrics

The dashboard includes:

- **Block Heights**: Best, finalized, and sync target heights
- **Finality**: GRANDPA round numbers and voting rates
- **Performance**: Block verification, import, and processing times
- **Storage**: Database cache size and operation latencies
- **Network**: RPC call rates and peer connections
- **Consensus**: Block production rates and AURA activity

See [DASHBOARD.md](./DASHBOARD.md) for complete monitoring documentation.

## Upgrading

### Upgrade the Chart

```bash
# Upgrade to new version
helm upgrade midnight-node ./charts/midnight-node

# Upgrade with new values
helm upgrade midnight-node ./charts/midnight-node -f my-values.yaml
```

### Upgrade the Node Version

To upgrade the Midnight Node application version:

```yaml
image:
  tag: "0.13.0"  # Specify new version
```

Then upgrade:

```bash
helm upgrade midnight-node ./charts/midnight-node -f values.yaml
```

## Maintenance Mode

For maintenance operations, you can start the pod without running the node:

```yaml
maintenanceMode: true
```

This will start an Ubuntu container with `sleep infinity`, allowing you to exec into it for troubleshooting or data recovery.

```bash
kubectl exec -it midnight-node-0 -- bash
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -l app.kubernetes.io/name=midnight-node
kubectl describe pod midnight-node-0
```

### View Logs

```bash
# View logs
kubectl logs midnight-node-0

# Follow logs
kubectl logs -f midnight-node-0

# Enable debug logging
helm upgrade midnight-node ./charts/midnight-node --set debug.enabled=true
```

### Check Persistent Volume

```bash
kubectl get pvc
kubectl describe pvc midnight-node-db-midnight-node-0
```

### Test PostgreSQL Connection

```bash
kubectl exec -it midnight-node-0 -- bash
psql -h $POSTGRES_HOST -U $POSTGRES_USER -d $POSTGRES_DB
```

### Check Service Endpoints

```bash
kubectl get svc -l app.kubernetes.io/name=midnight-node
kubectl get endpoints midnight-node
```

### Health Check

```bash
kubectl port-forward midnight-node-0 9933:9933
curl http://localhost:9933/health
```

### Common Issues

#### Pod Pending

- Check if persistent volume can be provisioned
- Verify storage class exists: `kubectl get storageclass`

#### Database Connection Failed

- Verify PostgreSQL is running and accessible
- Check credentials in secret
- Test connection from pod

#### Node Not Syncing

- Check logs for peer connection issues
- Verify P2P port (30333) is accessible
- Check boot node connectivity

#### Metrics Not Appearing

- Verify monitoring is enabled in values
- Check ServiceMonitor: `kubectl get servicemonitor`
- Verify Prometheus is scraping targets

## Uninstalling

```bash
# Uninstall the release
helm uninstall midnight-node

# Note: This will NOT delete the PersistentVolumeClaim
# To also delete the data:
kubectl delete pvc midnight-node-db-midnight-node-0
```

## Advanced Configuration

### Custom Boot Nodes

While the chart configures default boot nodes, you can override them:

```yaml
node:
  appendArgs: "--bootnodes /dns/my-boot-node.example.com/tcp/30333/p2p/12D3KooWxxx"
```

### Node Selection and Affinity

```yaml
nodeSelector:
  disktype: ssd

affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: node-role
          operator: In
          values:
          - blockchain

tolerations:
  - key: "blockchain"
    operator: "Equal"
    value: "true"
    effect: "NoSchedule"
```

### Security Context

```yaml
podSecurityContext:
  fsGroup: 1000

securityContext:
  capabilities:
    drop:
    - ALL
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1000
```

## Production Recommendations

For production deployments:

1. **Resources**: Allocate sufficient CPU and memory
   ```yaml
   resources:
     limits:
       cpu: 4
       memory: 8Gi
     requests:
       cpu: 2
       memory: 4Gi
   ```

2. **Storage**: Use fast SSD storage with adequate space
   ```yaml
   volumeSize: 100Gi  # Adjust based on network growth
   ```

3. **Monitoring**: Enable monitoring for observability
   ```yaml
   monitoring:
     enabled: true
   ```

4. **Secrets**: Use proper secret management (Vault, Sealed Secrets, etc.)

5. **High Availability**: Consider database replication for PostgreSQL

6. **Backup**: Regularly backup the database and consider PVC snapshots

7. **Resource Limits**: Set appropriate limits to prevent resource exhaustion

## Resources

### Midnight Network
- [Midnight Website](https://midnight.network/)
- [Midnight Documentation](https://docs.midnight.network/) (when available)
- Midnight Testnet: `testnet-02.midnight.network`

### Kubernetes Resources
- [StatefulSets](https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/)
- [Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)

## Contributing

Issues and improvements are welcome! This chart is maintained by the EASY1 Stake Pool team.

## About

This Helm chart was developed by the **Cardano EASY1 Stake Pool** operators, bringing enterprise-grade infrastructure expertise to the Midnight ecosystem.

### Support EASY1 Stake Pool

If you find this chart useful and want to support continued development:

- **Delegate to EASY1** on Cardano
- Visit **[easy1staking.com](https://easy1staking.com)** to learn more
- Help maintain community-driven blockchain infrastructure

Your support helps fund the development of tools like these that benefit the entire ecosystem.

---

**Maintained with care by EASY1 Stake Pool**
