# Risk Orchestrator (CRE Workflow)

This workflow is the project orchestration layer for Chainlink CRE.

It combines:
- On-chain risk state from `AssetRegistry` and `MultiAssetRiskRouter`
- Off-chain market volatility from CoinGecko
- Alert routing context from `LendingProtocolCircuitBreaker` and `CrossChainRiskBroadcaster`

## What It Produces

Every 5 minutes, the workflow returns:
- Enabled assets discovered on-chain
- Per-asset risk snapshot (score, tier, LTV, realized vol, manipulation cost)
- Per-asset off-chain volatility (24h)
- Global severity and recommended action
- Estimated CCIP fee when alert severity is high

## Prerequisites

1. Install Bun: https://bun.com/docs/installation
2. Install CRE CLI: https://docs.chain.link/cre/getting-started/cli-installation

## Commands

```bash
cd workflows/risk-orchestrator
npm install
npm run setup
npm run compile
```

Run local simulation with CRE CLI:

```bash
PATH="$HOME/.bun/bin:$PATH" \
cre workflow simulate ./workflows/risk-orchestrator -T staging-settings --non-interactive --trigger-index 0
```

If you later add write-path actions, use:

```bash
PATH="$HOME/.bun/bin:$PATH" \
cre workflow simulate ./workflows/risk-orchestrator -T staging-settings --non-interactive --trigger-index 0 --broadcast
```

## Config

Update `config.json` with current deployed addresses before simulation/deployment:
- `assetRegistryAddress`
- `multiAssetRouterAddress`
- `circuitBreakerAddress`
- `ccrbAddress`
- `ccipDestinationSelector`

The `assets[]` section maps on-chain token addresses to CoinGecko IDs.
