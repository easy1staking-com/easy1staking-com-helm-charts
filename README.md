# Cardano & Midnight Helm Charts

A comprehensive collection of production-ready Helm charts for deploying Cardano blockchain infrastructure and related ecosystem services on Kubernetes.

## About

These Helm charts have been developed and are maintained by **EASY1 Stake Pool** operators, who bring real-world experience running Cardano infrastructure to these deployments.

### Support the Project

If you find these charts useful and want to support their continued development, consider delegating to the **EASY1 Stake Pool** on Cardano.

**Learn more at: [easy1staking.com](https://easy1staking.com)**

## Available Charts

### Core Cardano Infrastructure

#### 🔵 Cardano Node
**Chart Version:** `0.0.1-beta.2` | **App Version:** `10.1.4`

Deploy a full Cardano blockchain node for network participation, block production, and chain synchronization.

- Supports mainnet, preprod, preview, and sanchonet networks
- Configurable for relay or block producer nodes
- Built-in health checks and monitoring support
- StatefulSet deployment for persistent blockchain data

#### 🔵 Ogmios
**Chart Version:** `0.0.1-alpha3` | **App Version:** `v6.8.0`

WebSocket JSON/RPC interface for Cardano, providing lightweight access to the Cardano blockchain.

- High-performance WebSocket API
- Multiple network support (mainnet, preprod, preview, sanchonet)
- Runs on port 1337
- Ideal for dApp backends and blockchain querying

#### 🔵 Kupo
**Chart Version:** `0.0.1-alpha6` | **App Version:** `v2.9.0`

Fast, lightweight chain-index for Cardano that provides efficient querying of on-chain data.

- Supports mainnet and preview networks
- Runs on port 1442
- Optimized for pattern matching and UTxO lookups
- Multiple chart versions available (v1/v2 in backup folder)

#### 🔵 Cardano DB Sync
**Chart Version:** `0.0.1-alpha6` | **App Version:** `13.6.0.4`

PostgreSQL-based chain indexer that synchronizes the Cardano blockchain to a relational database.

- Full blockchain data synchronization
- PostgreSQL backend for SQL queries
- Supports mainnet and preview networks
- Essential for block explorers and analytics platforms

### Additional Ecosystem Services

#### 🌙 Midnight Node
**Chart Version:** `0.0.1-beta.2` | **App Version:** `0.12.0`

Deploy a Midnight protocol node - Cardano's privacy-focused sidechain for protecting sensitive data.

**About Midnight:** Midnight is a data protection blockchain that operates as a sidechain to Cardano. It uses zero-knowledge proofs (zkSNARKs) to safeguard sensitive commercial and personal data while maintaining blockchain transparency. Built with TypeScript, Midnight enables developers to create privacy-preserving smart contracts that protect fundamental freedoms of association, commerce, and expression.

**Key Features:**
- Privacy-focused blockchain with ZK-proof technology
- Testnet support with boot node connectivity
- PostgreSQL integration for chain data
- Built-in monitoring with Prometheus metrics
- Configurable keystore and network settings
- Support for both testnet and mainnet configurations

**Ports:**
- Health check: 9933
- RPC: 9944
- P2P: 30333
- Metrics: 9615

#### 💾 Iagon
**Chart Version:** `0.0.1-alpha1` | **App Version:** `1.1.0`

Decentralized storage network node built on Cardano.

- Custom Docker image: `easy1staking/iagon`
- Development and production configurations
- Decentralized cloud storage infrastructure

## Repository Structure

```
easy1staking-com-helm-charts/
├── charts/
│   ├── cardano-node/        # Cardano blockchain node
│   ├── ogmios/             # WebSocket API for Cardano
│   ├── kupo/               # Chain-index service
│   ├── cardano-db-sync/    # PostgreSQL chain indexer
│   ├── midnight-node/      # Midnight privacy sidechain
│   ├── iagon/              # Decentralized storage node
│   └── backup/             # Alternative versions and PostgreSQL
├── docker/                 # Custom Docker builds
│   └── iagon/             # Iagon node build scripts
└── CLAUDE.md              # Development guidelines
```

## Quick Start

### Prerequisites

- Kubernetes cluster (1.19+)
- Helm 3.x
- kubectl configured for your cluster
- Persistent storage provisioner (for blockchain data)

### Basic Installation

```bash
# Install Ogmios on mainnet
helm install ogmios-mainnet ./charts/ogmios -f ./charts/ogmios/values-mainnet.yaml

# Install Kupo for mainnet
helm install kupo-mainnet ./charts/kupo -f ./charts/kupo/values-mainnet.yaml

# Install Midnight node on testnet
helm install midnight ./charts/midnight-node -f ./charts/midnight-node/values.yaml
```

### Installing with Custom Values

```bash
# Create a custom values file
cat > my-values.yaml <<EOF
resources:
  limits:
    cpu: 4
    memory: 8Gi
  requests:
    cpu: 2
    memory: 4Gi
volumeSize: 100Gi
EOF

# Install with custom values
helm install my-release ./charts/cardano-node -f my-values.yaml
```

## Network Configurations

Most charts support multiple Cardano networks through dedicated values files:

- `values-mainnet.yaml` - Production Cardano mainnet
- `values-preprod.yaml` - Pre-production testnet
- `values-preview.yaml` - Preview testnet
- `values-sanchonet.yaml` - Sanchonet governance testnet (where available)
- `values-dev.yaml` - Development environment

### Example: Multiple Network Deployments

```bash
# Deploy Ogmios for both mainnet and preview
helm install ogmios-main ./charts/ogmios -f ./charts/ogmios/values-mainnet.yaml
helm install ogmios-preview ./charts/ogmios -f ./charts/ogmios/values-preview.yaml
```

## Common Helm Operations

### Upgrade a Release

```bash
helm upgrade <release-name> ./charts/<chart-name> -f <values-file>
```

### Check Status

```bash
helm status <release-name>
kubectl get pods -l app.kubernetes.io/instance=<release-name>
```

### View Logs

```bash
kubectl logs -f <pod-name>
```

### Uninstall

```bash
helm uninstall <release-name>
```

### Dry Run (Test Before Deploy)

```bash
helm install <release-name> ./charts/<chart-name> --dry-run --debug
```

## Configuration

Each chart includes a `values.yaml` file with configurable options including:

- **Resources**: CPU and memory limits/requests
- **Storage**: Persistent volume sizes
- **Networking**: Service types, ports, ingress
- **Monitoring**: Prometheus integration
- **Security**: Pod security contexts, secrets management
- **Node Selection**: Node affinity, tolerations

Refer to individual chart `values.yaml` files for detailed configuration options.

## Monitoring

Many charts include built-in support for Prometheus monitoring via ServiceMonitor resources. Enable monitoring in your values:

```yaml
monitoring:
  enabled: true
  releaseName: kube-prometheus-stack
```

The Midnight Node chart includes custom Grafana dashboards in the `custom-dashboards/` directory.

## Storage Considerations

Blockchain data requires significant storage. Recommended minimum volumes:

- **Cardano Node (mainnet)**: 150GB+
- **Cardano DB Sync (mainnet)**: 200GB+ (PostgreSQL)
- **Ogmios**: Minimal (proxies to Cardano node)
- **Kupo**: 50GB+ depending on filters
- **Midnight Node**: 20GB+ (testnet, will grow)

Configure storage in values:

```yaml
volumeSize: 150Gi
```

## Development

### Testing Charts Locally

```bash
# Validate chart syntax
helm lint ./charts/<chart-name>

# Render templates locally
helm template test ./charts/<chart-name> --debug

# Test with specific values
helm template test ./charts/<chart-name> -f ./charts/<chart-name>/values-mainnet.yaml
```

### Packaging Charts

```bash
helm package ./charts/<chart-name>
```

## Docker Images

Custom Docker images are maintained in the `docker/` directory:

### Iagon

```bash
cd docker/iagon/
./build.sh  # Builds and pushes easy1staking/iagon:1.1.0
```

## Version Management

Charts follow semantic versioning:

- **Major version** (X.0.0): Breaking changes
- **Minor version** (0.X.0): New features, backward compatible
- **Patch version** (0.0.X): Bug fixes, backward compatible
- **Pre-release tags**: `-alpha`, `-beta`, `-rc`

The `appVersion` field tracks the version of the deployed application.

## Dependencies

Some charts may require external dependencies:

```bash
# Update chart dependencies
helm dependency update ./charts/<chart-name>
```

The PostgreSQL chart in `charts/backup/postgresql/` can be used as a dependency for charts requiring database backends.

## Troubleshooting

### Pod Not Starting

```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```

### Storage Issues

```bash
kubectl get pvc
kubectl describe pvc <pvc-name>
```

### Network Connectivity

```bash
kubectl exec -it <pod-name> -- sh
# Test connectivity inside the pod
```

### Chart Validation

```bash
helm lint ./charts/<chart-name>
helm template <release-name> ./charts/<chart-name> --debug
```

## Contributing

These charts are actively maintained by the EASY1 Stake Pool team. If you encounter issues or have suggestions:

1. Test your changes thoroughly
2. Follow semantic versioning
3. Update chart version in `Chart.yaml`
4. Maintain backward compatibility where possible

## Resources

### Cardano Resources
- [Cardano Official Documentation](https://docs.cardano.org/)
- [Cardano Node Documentation](https://github.com/IntersectMBO/cardano-node)
- [Ogmios Documentation](https://ogmios.dev/)
- [Kupo Documentation](https://cardanosolutions.github.io/kupo/)

### Midnight Resources
- [Midnight Network](https://midnight.network/)
- Midnight Testnet: `testnet-02.midnight.network`

### Kubernetes & Helm
- [Helm Documentation](https://helm.sh/docs/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)

## License

Please refer to individual chart licenses for specific terms.

---

## Support EASY1 Stake Pool

These charts are developed and maintained by professional stake pool operators who understand the importance of reliable infrastructure.

**Support ongoing development by delegating to EASY1:**

- Visit [easy1staking.com](https://easy1staking.com) to learn more
- Delegate to ticker: **EASY1**
- Help maintain decentralized, community-driven Cardano infrastructure

Your delegation helps fund the development of tools like these that benefit the entire Cardano ecosystem.

---

**Built with care by EASY1 Stake Pool operators**
