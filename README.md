# RiskSync

**Chainlink Convergence 2026 Hackathon Submission - Risk & Compliance Track**

RiskSync is a multi-asset, on-chain risk orchestration layer for DeFi protocols. It measures four live risk vectors, turns them into a composite score, recommends dynamic LTV, and can trigger automated defensive actions through Chainlink services.

At a high level, RiskSync answers one question:

> How unsafe is this asset market right now, and what should the protocol do about it?

Instead of relying on static parameters, manual governance, or off-chain dashboards, RiskSync computes risk directly from on-chain liquidity, volatility, cascade exposure, and manipulation fingerprints.

## Table of Contents

- [Why RiskSync Exists](#why-risksync-exists)
- [What RiskSync Does](#what-risksync-does)
- [What Is Live Today](#what-is-live-today)
- [Chainlink Footprint](#chainlink-footprint)
- [Architecture](#architecture)
- [Risk Engine](#risk-engine)
- [Multi-Asset Architecture](#multi-asset-architecture)
- [Core Contracts](#core-contracts)
- [Live Sepolia Deployment](#live-sepolia-deployment)
- [Quickstart](#quickstart)
- [Verification](#verification)
- [Deployment](#deployment)
- [Configuration Reference](#configuration-reference)
- [Repository Layout](#repository-layout)
- [Limitations](#limitations)
- [Additional Docs](#additional-docs)

## Why RiskSync Exists

Most DeFi protocols still operate with static risk parameters:

- Static collateral factors
- Slow governance-based emergency response
- Weak visibility into oracle manipulation cost
- No native view of cross-protocol liquidation contagion
- No unified score that can be consumed on-chain

That breaks down during stress events. A market can move from "fine" to "liquidation spiral" long before governance can react. RiskSync closes that gap by computing a live, on-chain risk score and exposing it to contracts, dashboards, automation, and cross-chain alerting.

## What RiskSync Does

RiskSync combines four risk primitives into one operational layer:

| Layer | What it measures | Why it matters |
|---|---|---|
| MCO | Cost to manipulate a Uniswap V3 TWAP | Detects whether oracle security is economically strong or weak |
| TDRV | Realized volatility from pool observations | Detects fast-moving market stress |
| CPLCS | Cross-protocol liquidation cascade amplification | Detects systemic contagion risk |
| TCO | Tick concentration entropy anomalies | Detects manipulation fingerprints before full exploit completion |

Outputs produced by the system:

- Composite risk score from `0` to `100`
- Risk tier from `NOMINAL` to `EMERGENCY`
- Recommended LTV band from `80%` down to `50%`
- On-chain cached risk state per asset
- Permissionless circuit-breaker triggers
- Automation-compatible update flow
- CCIP alert broadcasting

## What Is Live Today

The repo contains both live and simulation-ready components. They are not the same thing, and the README should be explicit about that.

| Component | Status | Notes |
|---|---|---|
| Core risk contracts | Live on Sepolia | Core contracts are deployed and readable on-chain |
| `AssetRegistry` + `MultiAssetRiskRouter` | Live on Sepolia | Multi-asset config and cached risk routing are deployed |
| Chainlink Automation | Live on Sepolia | `AutomatedRiskUpdater` has a registered upkeep |
| Chainlink CCIP | Live on Sepolia | Broadcaster integration is deployed and a message was sent |
| Dashboard | Local and deployable | Reads live contracts when `NEXT_PUBLIC_*` addresses are configured |
| Chainlink CRE workflow | Compile + simulate ready | Workflow is implemented and verifiable via simulation |

Important boundary:

- The README treats CRE accurately as a workflow integrated into the project and ready for compile/simulate.
- The current README does **not** claim CRE is part of the currently live on-chain Sepolia execution path unless separately deployed on CRE infrastructure.

## Chainlink Footprint

RiskSync uses multiple Chainlink products as distinct parts of the system:

| Product | Role in RiskSync | File |
|---|---|---|
| Chainlink Price Feeds | External price-verification and volatility cross-checking | [`src/ChainlinkVolatilityOracle.sol`](src/ChainlinkVolatilityOracle.sol) |
| Chainlink Automation | Scheduled risk updates and circuit-breaker execution | [`src/AutomatedRiskUpdater.sol`](src/AutomatedRiskUpdater.sol) |
| Chainlink CCIP | Cross-chain risk alert routing | [`src/CrossChainRiskBroadcaster.sol`](src/CrossChainRiskBroadcaster.sol) |
| Chainlink CRE | Risk orchestration workflow over registry/router state | [`workflows/risk-orchestrator/index.ts`](workflows/risk-orchestrator/index.ts) |

## Architecture

```text
Uniswap V3 pool data + Chainlink feeds + lending protocol exposure
                |
                v
  +-------------------------------------------------------------+
  | Core Risk Primitives                                        |
  | - ManipulationCostOracle (MCO)                              |
  | - TickDerivedRealizedVolatility (TDRV)                      |
  | - CrossProtocolCascadeScore (CPLCS)                         |
  | - TickConcentrationOracle (TCO)                             |
  +-------------------------------------------------------------+
                |
                v
  +-------------------------------------------------------------+
  | Risk Composition Layer                                      |
  | - UnifiedRiskCompositor (legacy single-asset path)          |
  | - AssetRegistry + MultiAssetRiskRouter (current path)       |
  +-------------------------------------------------------------+
                |
        +-------+--------+------------------+
        |                |                  |
        v                v                  v
  Dashboard UI     Automation Upkeep   CCIP Broadcaster
        |                |                  |
        +----------------+------------------+
                         |
                         v
                 Protocol Safeguards
                 - Dynamic LTV
                 - Borrow pause
                 - Alert propagation

Off to the side:
CRE workflow reads registry/router state, enriches with off-chain context,
computes severity/action, and estimates routing cost for alert workflows.
```

## Risk Engine

### Composite score

```text
riskScore = (MCO x 30 + TDRV x 35 + CPLCS x 20 + TCO x 15) / 100
```

| Pillar | Weight | Purpose |
|---|---|---|
| MCO | 30% | Economic security of the oracle path |
| TDRV | 35% | Market volatility and trend stress |
| CPLCS | 20% | Systemic liquidation amplification |
| TCO | 15% | Information-theoretic manipulation detection |

### Score ladder

| Score | Level | Recommended LTV | Typical response |
|---|---|---|---|
| 0-24 | `NOMINAL` | 8000 BPS | No intervention |
| 25-49 | `WATCH` | 7500 BPS | Monitor closely |
| 50-64 | `WARNING` | 7000 BPS | Tighten collateral parameters |
| 65-79 | `DANGER` | 6000 BPS | Aggressive protection |
| 80-100 | `EMERGENCY` | 5000 BPS | Pause sensitive actions such as borrows |

## Multi-Asset Architecture

RiskSync was upgraded from a mostly single-asset design into a true multi-asset system without redeploying the full protocol per token.

### How it works

1. Deploy the four core risk primitives once.
2. Store per-asset metadata in `AssetRegistry`.
3. Compute and cache per-asset risk state in `MultiAssetRiskRouter`.
4. Let Automation update assets in gas-safe batches.
5. Render only enabled assets in the dashboard.

### `AssetRegistry` fields

Each asset config includes:

- `asset`
- `pool`
- `feed`
- `token1Decimals`
- `shockBps`
- `mcoThresholdLow`
- `mcoThresholdHigh`
- `enabled`

### Why this matters

- ETH, BTC, LINK, AAVE and future assets share the same deployment.
- New asset support is a config operation, not a protocol rewrite.
- Disabled assets are explicit and never shown as fake live in the dashboard.
- Per-asset decimal handling is preserved in manipulation-cost calculations.

### Current script defaults

| Network | ETH | BTC | LINK | AAVE |
|---|---|---|---|---|
| Mainnet deploy script | Enabled | Disabled unless `BTC_UNI_POOL` is set | Disabled unless `LINK_UNI_POOL` is set | Disabled unless `AAVE_UNI_POOL` is set |
| Sepolia deploy script | Enabled | Disabled unless pool + feed env vars exist | Disabled unless pool + feed env vars exist | Disabled unless pool + feed env vars exist |

## Core Contracts

| Contract | Responsibility | Selected methods |
|---|---|---|
| `ManipulationCostOracle` | Computes TWAP manipulation cost from real pool liquidity | `getManipulationCost`, `getManipulationCostMultiWindow` |
| `TickDerivedRealizedVolatility` | Computes realized vol from pool observations | `getRealizedVolatility`, `getVolatilityRegime` |
| `CrossProtocolCascadeScore` | Models liquidation contagion across lending systems | `getCascadeScore` |
| `TickConcentrationOracle` | Measures structured tick concentration and entropy loss | `getConcentrationScore`, `getConcentrationBreakdown` |
| `UnifiedRiskCompositor` | Legacy single-asset weighted composition path | `updateRiskScore`, `getRiskBreakdown` |
| `AssetRegistry` | Stores supported-asset config and enabled/disabled state | `getSupportedAssets`, `getConfig`, `getEnabledAssets` |
| `MultiAssetRiskRouter` | Caches composite risk state per asset | `updateRiskForAsset`, `updateRiskForAssets`, `assetRiskState` |
| `RiskCircuitBreaker` | Base layer for autonomous on-chain protection | `checkAndRespond`, `currentLevel` |
| `LendingProtocolCircuitBreaker` | Concrete LTV/pause implementation | `currentMaxLtvBps`, `borrowingPaused` |
| `StressScenarioRegistry` | Replays historical crisis scenarios | `runScenario`, `runAllScenarios` |
| `ChainlinkVolatilityOracle` | Verifies volatility using Chainlink price feed history | `getVolatilityWithConfidence`, `getPriceFeedDetails` |
| `AutomatedRiskUpdater` | Automation-compatible batched updater | `checkUpkeep`, `performUpkeep` |
| `CrossChainRiskBroadcaster` | Sends and receives CCIP risk payloads | `broadcastToAll`, `estimateFee` |

## Live Sepolia Deployment

### Core contracts

| Contract | Address | Etherscan |
|---|---|---|
| ManipulationCostOracle | `0xf410d4450A98cB1304e7F5B529EBcd30801b771C` | [view](https://sepolia.etherscan.io/address/0xf410d4450A98cB1304e7F5B529EBcd30801b771C) |
| TickDerivedRealizedVolatility | `0x25Ec7B78DaaB44137121ceD05FAcc07A2dFB0570` | [view](https://sepolia.etherscan.io/address/0x25Ec7B78DaaB44137121ceD05FAcc07A2dFB0570) |
| CrossProtocolCascadeScore | `0x075D2961682F72C4fbf6d43FBF6a34bf7BBc0B72` | [view](https://sepolia.etherscan.io/address/0x075D2961682F72C4fbf6d43FBF6a34bf7BBc0B72) |
| TickConcentrationOracle | `0x54F4050Dc6e61611F99FC8F4C85b081f7aa6749C` | [view](https://sepolia.etherscan.io/address/0x54F4050Dc6e61611F99FC8F4C85b081f7aa6749C) |
| UnifiedRiskCompositor | `0x153D2bc4bdDdB1b6b54f127e718bdE004d75AB44` | [view](https://sepolia.etherscan.io/address/0x153D2bc4bdDdB1b6b54f127e718bdE004d75AB44) |
| LendingProtocolCircuitBreaker | `0x297A1BccC9F1578B4c3fA2701fCf6Ad8a41E1fEa` | [view](https://sepolia.etherscan.io/address/0x297A1BccC9F1578B4c3fA2701fCf6Ad8a41E1fEa) |
| StressScenarioRegistry | `0xb7Ac84503e02a95ae06494FF44594139dAAE51dC` | [view](https://sepolia.etherscan.io/address/0xb7Ac84503e02a95ae06494FF44594139dAAE51dC) |
| ChainlinkVolatilityOracle | `0x2DD8064f972168d3eEadedb90BbBd4B49DaC046c` | [view](https://sepolia.etherscan.io/address/0x2DD8064f972168d3eEadedb90BbBd4B49DaC046c) |
| AssetRegistry | `0xAc8509a209eF27BD92A43C31F33705e1c30376d8` | [view](https://sepolia.etherscan.io/address/0xAc8509a209eF27BD92A43C31F33705e1c30376d8) |
| MultiAssetRiskRouter | `0x6BF3B6DfB0884A45a54140D38513F991Cf633721` | [view](https://sepolia.etherscan.io/address/0x6BF3B6DfB0884A45a54140D38513F991Cf633721) |
| AutomatedRiskUpdater | `0x473779900D540F0098D4EDf40bD3b94a36f8731C` | [view](https://sepolia.etherscan.io/address/0x473779900D540F0098D4EDf40bD3b94a36f8731C) |
| CrossChainRiskBroadcaster | `0xFd51A5E98355dC874Bf75EA6ED36Ae159810bFBE` | [view](https://sepolia.etherscan.io/address/0xFd51A5E98355dC874Bf75EA6ED36Ae159810bFBE) |

### External Sepolia dependencies

| Dependency | Address |
|---|---|
| Chainlink ETH/USD feed | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Uniswap V3 ETH/USDC pool | `0x6Ce0896eAE6D4BD668fDe41BB784548fb8F59b50` |
| Chainlink CCIP Router | `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` |
| Aave V3 PoolDataProvider | `0x3e9708d80f7B3e43118013075F7e95CE3AB31F31` |

### Live operational proof

- Automation Upkeep ID: `55979398141976704248916940835648987232607128922315091009692569738181087735824`
- CCIP message proof: [CCIP Explorer](https://ccip.chain.link/msg/0x214808a8a6990228fb270ccb83ab45d37ddf3b58f3044a6d250889a61528209e)

## Quickstart

### Prerequisites

- Foundry
- Node.js / npm
- Optional RPC URLs for Sepolia or Mainnet fork tests
- Optional Bun + CRE CLI if you want to compile/simulate the workflow

### Install

```shell
curl -L https://foundry.paradigm.xyz | bash
foundryup
npm install
npm --prefix dashboard install
```

### Build

```shell
forge build
npm --prefix dashboard run build
```

### Tests

Offline / unit path:

```shell
FOUNDRY_OFFLINE=true forge test --no-match-path test/foundry/ForkTests.t.sol
```

Mainnet fork path:

```shell
MAINNET_RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY \
  forge test --match-path test/foundry/ForkTests.t.sol -vvv
```

### Run the dashboard locally

```shell
npm --prefix dashboard run dev
```

The dashboard reads live contracts when `NEXT_PUBLIC_*` addresses are configured. Unsupported or disabled assets are not rendered as fake live markets.

### Compile and simulate the CRE workflow

```shell
cd workflows/risk-orchestrator
npm install
npm run setup
npm run compile
PATH="$HOME/.bun/bin:$PATH" \
cre workflow simulate ./workflows/risk-orchestrator -T staging-settings --non-interactive --trigger-index 0
```

## Verification

For the full judge-oriented verification pack, see [`docs/JUDGE_PACK.md`](docs/JUDGE_PACK.md).

### Multi-asset verification

```shell
cast call $ASSET_REGISTRY \
  "getSupportedAssets()(address[])" \
  --rpc-url $SEPOLIA_RPC_URL

cast call $ASSET_REGISTRY \
  "getEnabledAssets()(address[])" \
  --rpc-url $SEPOLIA_RPC_URL

cast call $ASSET_REGISTRY \
  "getConfig(address)((address,address,address,uint8,uint256,uint256,uint256,bool))" \
  $ASSET_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL

cast call $MULTI_ASSET_ROUTER \
  "assetRiskState(address)(uint256,uint256,uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256,uint256)" \
  $ASSET_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL
```

### Chainlink Price Feeds verification

```shell
cast call 0x2DD8064f972168d3eEadedb90BbBd4B49DaC046c \
  "getPriceFeedDetails()(string,uint8,uint256,uint80)" \
  --rpc-url $SEPOLIA_RPC_URL
```

### Chainlink Automation verification

```shell
cast call 0x473779900D540F0098D4EDf40bD3b94a36f8731C \
  "checkUpkeep(bytes)(bool,bytes)" \
  0x \
  --rpc-url $SEPOLIA_RPC_URL
```

### Chainlink CCIP verification

```shell
cast call 0xFd51A5E98355dC874Bf75EA6ED36Ae159810bFBE \
  "estimateFee(uint64)(uint256)" \
  10344971235874465080 \
  --rpc-url $SEPOLIA_RPC_URL
```

### Composite score verification

```shell
cast call 0x153D2bc4bdDdB1b6b54f127e718bdE004d75AB44 \
  "getRiskScore()(uint256)" \
  --rpc-url $SEPOLIA_RPC_URL
```

## Deployment

### Sepolia

```shell
source .env
forge script script/DeploySepolia.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --verify
```

### Mainnet

```shell
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL \
  --private-key $DEPLOYER_KEY \
  --broadcast --verify
```

### Dashboard wiring

After deploying the multi-asset upgrade, export:

- `NEXT_PUBLIC_ASSET_REGISTRY_ADDRESS`
- `NEXT_PUBLIC_MULTI_ASSET_ROUTER_ADDRESS`

The dashboard should be pointed only at deployed contracts. If an asset is not configured or not enabled in `AssetRegistry`, it should stay absent or disabled in the UI.

## Configuration Reference

| Parameter | Default | Meaning |
|---|---|---|
| TWAP window (MCO) | `1800` seconds | Manipulation resistance vs freshness |
| Fallback borrow rate | `500` BPS | Used if Aave live borrow rate is unavailable |
| Cost threshold low | `$1M` | MCO score floor |
| Cost threshold high | `$100M` | MCO score ceiling |
| Vol sample window | `24 x 1h` | TDRV realized volatility span |
| TCO samples | `24`, window `86400` seconds | Entropy observation range |
| Composite weights | `30 / 35 / 20 / 15` | MCO / TDRV / CPLCS / TCO |
| URC EWMA alpha | `3000` BPS | Score smoothing factor |
| Circuit breaker cooldown | `300` seconds | Minimum interval between state changes |

### Mainnet reference infrastructure

| Component | Address |
|---|---|
| WETH/USDC pool (0.05%) | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` |
| ETH/USD Chainlink feed | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Chainlink CCIP Router | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` |
| Aave V3 PoolDataProvider | `0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| Compound V3 USDC Comet | `0xc3d688B66703497DAA19211EEdff47f25384cdc3` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |

## Repository Layout

| Path | Purpose |
|---|---|
| [`src/`](src) | Solidity contracts |
| [`script/`](script) | Forge deployment and upkeep scripts |
| [`test/foundry/`](test/foundry) | Unit and fork tests |
| [`dashboard/`](dashboard) | Next.js dashboard |
| [`workflows/risk-orchestrator/`](workflows/risk-orchestrator) | Chainlink CRE workflow |
| [`docs/JUDGE_PACK.md`](docs/JUDGE_PACK.md) | Verification pack |
| [`docs/COMPETITIVE_EDGE.md`](docs/COMPETITIVE_EDGE.md) | Novelty and positioning |

## Limitations

RiskSync is explicit about its current boundaries:

- It is a hackathon system, not a production-audited protocol.
- Sepolia is useful for proving integration, but not all mainnet lending venues exist there with equal fidelity.
- Additional assets require valid pool and feed infrastructure; they are not auto-magically live.
- The CRE workflow is implemented and simulation-ready, but should only be described as live if separately deployed on CRE infrastructure.
- The single-asset `UnifiedRiskCompositor` path still exists for backward compatibility, while the multi-asset router is the current architecture.

## Additional Docs

- [`docs/JUDGE_PACK.md`](docs/JUDGE_PACK.md) - exact verification commands and expected outputs
- [`docs/COMPETITIVE_EDGE.md`](docs/COMPETITIVE_EDGE.md) - novelty framing and competitive differentiation
- [`workflows/risk-orchestrator/README.md`](workflows/risk-orchestrator/README.md) - workflow-specific notes

## Summary

RiskSync turns DeFi risk from a passive analytics problem into an on-chain execution layer. It does that with:

- Real liquidity-aware oracle security measurement
- On-chain realized volatility
- Cross-protocol liquidation contagion modeling
- Information-theoretic manipulation detection
- Multi-asset routing without per-token redeploys
- Chainlink-native automation, cross-chain alerting, and workflow orchestration

If a lending protocol wants risk-aware collateral management instead of static assumptions, RiskSync is the integration layer.
