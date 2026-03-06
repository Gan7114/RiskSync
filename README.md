# RiskSync

**Chainlink Convergence 2026 Hackathon Submission — Risk & Compliance Track**

RiskSync is a multi-asset, on-chain risk orchestration layer for DeFi protocols.  
It continuously measures four live risk vectors and turns them into actionable protocol defense:
- Oracle manipulation cost (MCO)
- Realized volatility stress (TDRV)
- Cross-protocol liquidation cascade pressure (CPLCS)
- Tick concentration entropy anomalies (TCO)

From a single deployment, RiskSync monitors assets like ETH, BTC, LINK, and AAVE through config-only onboarding (`AssetRegistry` + `MultiAssetRiskRouter`), computes a composite score, recommends dynamic LTV, and can trigger automated protective actions through Chainlink services.

## 🎖 Hackathon Submission (March 2026)

This project is built for the **Chainlink Convergence 2026 Hackathon**. It leverages the latest **Chainlink Runtime Environment (CRE)** and on-chain risk primitives to solve the $10B "Risk Visibility Gap" in DeFi.

### ⛓️ Key Chainlink Integrations
- **Automation**: 5-minute decentralized heartbeat for risk updates (`AutomatedRiskUpdater.sol`).
- **CCIP**: Cross-chain risk alert propagation to Base, Arbitrum, and Optimism.
- **Price Feeds**: Real-time volatility verification (`ChainlinkVolatilityOracle.sol`).

### ☁️ Cloud Is Required
This project is intentionally cloud-connected and depends on Chainlink network services:
- Chainlink Automation (scheduled upkeep execution)
- Chainlink CCIP (cross-chain risk broadcast)
- Chainlink CRE workflow execution (`workflows/risk-orchestrator`)
- RPC access for live Sepolia/Mainnet verification

## Live Demo (Dashboard)

> Dashboard connects directly to deployed Sepolia contracts — real on-chain risk data, live Chainlink ETH/USD price feed.

**Deploy to Vercel:** `cd dashboard && vercel --prod` (requires Vercel account)

### Sepolia Testnet Contracts (chainId 11155111)

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

`AssetRegistry` and `MultiAssetRiskRouter` are included in the upgraded deployment scripts and should be exported to dashboard env vars:
`NEXT_PUBLIC_ASSET_REGISTRY_ADDRESS`, `NEXT_PUBLIC_MULTI_ASSET_ROUTER_ADDRESS`.

**External integrations on Sepolia:**
- Chainlink ETH/USD feed: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- Uniswap V3 ETH/USDC pool: `0x6Ce0896eAE6D4BD668fDe41BB784548fb8F59b50`
- CCIP Router: `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59`
- Aave V3 PoolDataProvider: `0x3e9708d80f7B3e43118013075F7e95CE3AB31F31`

---

## Architecture

```
src/
├── AssetRegistry.sol                  — Owner-managed per-asset config + enabled/disabled state
├── MultiAssetRiskRouter.sol           — Per-asset risk cache/router (MCO+TDRV+CPLCS+TCO)
├── ManipulationCostOracle.sol          — Pillar 1: TWAP attack cost via tick-bitmap walk
├── TickDerivedRealizedVolatility.sol   — Pillar 2: 24-h realized vol + EWMA + regime
├── CrossProtocolCascadeScore.sol       — Pillar 3: Aave/Compound/Morpho/Euler cascade
├── TickConcentrationOracle.sol         — Pillar 4: HHI + Renyi entropy + directional bias
├── UnifiedRiskCompositor.sol           — Weighted aggregator (4-pillar) + score history
├── RiskCircuitBreaker.sol              — Abstract base + LendingProtocolCircuitBreaker
├── StressScenarioRegistry.sol          — 5 historical crisis scenarios + custom support
├── ChainlinkVolatilityOracle.sol       — Chainlink Price Feeds: historical realized vol
├── AutomatedRiskUpdater.sol            — Chainlink Automation: 5-min keeper heartbeat
├── CrossChainRiskBroadcaster.sol       — Chainlink CCIP: cross-chain risk alert relay
├── interfaces/
│   └── IRiskConsumer.sol               — IRiskConsumer + IRiskScoreProvider
└── libraries/
    └── TickMathLib.sol                 — Shared Uniswap V3 tick <-> sqrtPrice math

test/foundry/
├── NovelSystem.t.sol             — Core system unit tests
├── MultiAssetArchitecture.t.sol  — Mandatory multi-asset registry/router/upkeep tests
└── ForkTests.t.sol    — 21 mainnet fork tests (auto-skip when MAINNET_RPC_URL unset)

script/
├── Deploy.s.sol         — Mainnet deployment + multi-asset registry seed (enable/disable aware)
└── DeploySepolia.s.sol  — Sepolia deployment + multi-asset registry seed (enable/disable aware)
```

## Multi-Asset Architecture (No Per-Token Redeploy)

The protocol is now split into:

1. **Primitive oracles** (`MCO`, `TDRV`, `CPLCS`, `TCO`) deployed once.
2. **`AssetRegistry`** with per-asset config:
   - `asset`, `pool`, `feed`, `token1Decimals`, `shockBps`
   - `mcoThresholdLow`, `mcoThresholdHigh`, `enabled`
3. **`MultiAssetRiskRouter`** that computes and caches `RiskState` per asset:
   - `score`, `tier`, `recommendedLtv`, `updatedAt`
   - component inputs (`mcoInput`, `tdrvInput`, `cpInput`, `tcoInput`)
4. **`AutomatedRiskUpdater`** batch cursor for gas-safe N-asset updates per upkeep call.

This means one protocol deployment can cover multiple collateral assets. Adding a token is now a config update, not a full contract redeploy.

### Configured Asset Reality (Current Script Defaults)

| Network | ETH | BTC | LINK | AAVE |
|---|---|---|---|---|
| Mainnet script default | Enabled | Disabled unless `BTC_UNI_POOL` env is set | Disabled unless `LINK_UNI_POOL` env is set | Disabled unless `AAVE_UNI_POOL` env is set |
| Sepolia script default | Enabled | Disabled unless env pool+feed are set | Disabled unless env pool+feed are set | Disabled unless env pool+feed are set |

Disabled assets are explicitly marked disabled in registry and dashboard (not shown as fake live).

## Composite Score Formula

```
riskScore = (MCO x 30 + TDRV x 35 + CPLCS x 20 + TCO x 15) / 100
```

| Pillar | Weight | What it measures |
|--------|--------|------------------|
| MCO   | 30% | Economic cost to manipulate the TWAP oracle |
| TDRV  | 35% | Realized volatility of the underlying asset |
| CPLCS | 20% | Liquidation cascade amplification across protocols |
| TCO   | 15% | Entropy of the tick observation sequence (manipulation fingerprint) |

Score maps to a dynamic LTV recommendation (50%-80%) and a 5-rung alert ladder
(NOMINAL / WATCH / WARNING / DANGER / EMERGENCY).

---

## Contracts

### ManipulationCostOracle (MCO) — Pillar 1

Estimates the USD cost to manipulate a Uniswap V3 TWAP by a given number of basis
points. Uses a tick-bitmap liquidity walk (up to 20 initialized ticks, 10 bitmap words)
to account for real on-chain liquidity distribution. Pulls the live WETH borrow rate
from Aave V3 via `variableBorrowRate` (falls back to a static rate when unavailable).
Supports multi-window analysis.

```solidity
(uint256 costUsd, uint256 score) = mco.getManipulationCost(devBps);
uint256 rateBps = mco.getEffectiveBorrowRateBps();

// Multi-window (300s, 900s, 1800s, 3600s)
ManipulationCostOracle.MultiWindowCost memory mw = mco.getManipulationCostMultiWindow(devBps);

// Single custom window (min 300 s)
(uint256 cost, uint256 s) = mco.getManipulationCostAtWindow(devBps, windowSeconds);
```

Constructor (9 params):
```solidity
new ManipulationCostOracle(
    address pool,
    address token1UsdFeed,
    uint32  twapWindow,           // min 300 s
    uint256 borrowRatePerYearBps, // 1-10000
    uint256 costThresholdLow,     // 8-decimal USD, e.g. 1_000_000 * 1e8
    uint256 costThresholdHigh,    // 8-decimal USD, e.g. 100_000_000 * 1e8
    address aaveDataProvider,     // address(0) = disabled
    address token1Address,        // address(0) = disabled
    uint8   token1Decimals        // 18 for WETH, 6 for USDC
)
```

Normalized/breakdown helpers (useful for UIs — caps display cost without affecting score):
```solidity
(uint256 normalizedCostUsd, uint256 score, bool capped) =
    mco.getManipulationCostNormalized(devBps);

(uint256 rawCostUsd, uint256 normalizedCostUsd, uint256 score, bool capped) =
    mco.getManipulationCostBreakdown(devBps);
```

---

### TickDerivedRealizedVolatility (TDRV) — Pillar 2

Computes 24-hour annualized realized volatility from Uniswap V3 pool observations.
Samples 24 hourly TWAP ticks, converts to log-returns, and applies a 252-day
annualization factor. Entirely on-chain, no off-chain feeds. Supports EWMA smoothing
and automatic volatility regime classification.

```solidity
uint256 volBps = tdrv.getRealizedVolatility();           // annualized, in BPS
uint256 score  = tdrv.getVolatilityScore(2_000, 20_000); // 0-100

// EWMA-smoothed vol (lambdaBps: 9000 = slow decay, 5000 = fast)
uint256 ewmaVol = tdrv.getVolatilityEWMA(lambdaBps);

// Over a custom window
uint256 windowVol = tdrv.getVolatilityOverWindow(windowSeconds, nSamples);

// Regime: LOW_VOL / NORMAL / ELEVATED / HIGH_VOL / EXTREME
TickDerivedRealizedVolatility.VolatilityRegime regime = tdrv.getVolatilityRegime();
```

---

### CrossProtocolCascadeScore (CPLCS) — Pillar 3

Aggregates collateral exposure across Aave V3, Compound V3, Morpho Blue, and
Euler V2 vaults (ERC-4626), then models liquidation cascade amplification via
iterative convergence (8 rounds). Larger price shocks produce proportionally
higher cascade scores.

```solidity
CrossProtocolCascadeScore.CascadeResult memory r = cplcs.getCascadeScore(weth, shockBps);
// r.totalCollateralUsd, r.cascadeScore, r.amplificationBps

uint256 eulerVaultCount = cplcs.eulerV2ConfigCount();
```

---

### TickConcentrationOracle (TCO) — Pillar 4

Detects manipulation fingerprints using information theory on the Uniswap V3 tick
observation sequence. A legitimate price moves randomly (high Shannon entropy); a
TWAP attack requires holding the price artificially (low entropy, highly structured).

**Entropy proxy:** Herfindahl-Hirschman Index (HHI), the same measure used in
antitrust economics to quantify market concentration — here applied to tick-bucket
concentration.

- **HHI** = sum(count_i^2) / N^2 — 1/K for K uniform buckets, 1 for single bucket
- **Renyi H_2** = floor(log2(BPS / hhiBps)) integer bits
- **Directional Bias** = fraction of consecutive same-direction tick pairs
  (5000 BPS = random walk, 10000 = monotone push)

```solidity
uint256 score = tco.getConcentrationScore();  // 0 = organic, 100 = attack

TickConcentrationOracle.ConcentrationResult memory r = tco.getConcentrationBreakdown();
// r.hhiBps, r.directionalBiasBps, r.entropyBits, r.compositeScore

uint256 hhi     = tco.getHHI();
uint256 entropy = tco.getApproximateEntropyBits();
uint256 bias    = tco.getDirectionalBias();
```

Constructor (3 params):
```solidity
new TickConcentrationOracle(
    address pool,
    uint32  windowSeconds,  // >= 60 * numSamples
    uint8   numSamples      // 3-48
)
```

---

### UnifiedRiskCompositor (URC)

Combines the four sub-scores with configurable weights into a single 0-100 risk score,
maps it to a dynamic LTV recommendation, and maintains an 8-slot ring-buffer score
history with EWMA smoothing and momentum tracking.

```solidity
(uint256 score, UnifiedRiskCompositor.RiskTier tier, uint256 ltvBps) = urc.updateRiskScore();

uint256 ewma           = urc.getEWMAScore();
uint256[] memory hist  = urc.getScoreHistory(); // up to 8 entries
bool tcoEnabled        = urc.isTcoEnabled();

// Momentum enum: PLUNGING / FALLING / STABLE / RISING / SPIKING
(UnifiedRiskCompositor.ScoreMomentum momentum, int256 delta) = urc.getScoreMomentum();

// Multi-asset query (does NOT update cached state)
(uint256 comp, uint256 mcoIn, uint256 tdrvIn, uint256 cpIn,
 RiskTier t, uint256 ltv, uint256 volBps, uint256 costUsd, uint256 tcoIn)
    = urc.getScoreForAsset(pool, feed);           // cascade uses trackedAsset
    = urc.getScoreForAsset(pool, feed, asset);    // explicit cascade asset override
```

Weights are mutable via `setWeights(uint8 w1, uint8 w2, uint8 w3, uint8 w4)`
(w4 = 0 when TCO is disabled for 3-pillar mode).

---

### RiskCircuitBreaker

Abstract base contract for on-chain autonomous risk response. Inherit in any lending
protocol, vault, or AMM that wants risk-score-driven parameter adjustment in the
**same block** a threshold is crossed — zero governance delay.

```
AlertLevel ladder:
  NOMINAL    score  0-24
  WATCH      score 25-49
  WARNING    score 50-64
  DANGER     score 65-79
  EMERGENCY  score 80-100
```

```solidity
// Permissionless trigger (callable by any bot after cooldown)
circuitBreaker.checkAndRespond();
bool cooling = circuitBreaker.isInCooldown();
RiskCircuitBreaker.AlertLevel level = circuitBreaker.currentLevel();
```

Override `_onLevelChange(AlertLevel prev, AlertLevel next)` to implement custom
responses (tighten LTV, pause borrows, halt deposits, etc.).

`LendingProtocolCircuitBreaker` is the ready-to-use concrete implementation included
in `RiskCircuitBreaker.sol`.

---

### StressScenarioRegistry

On-chain library of historical DeFi stress scenarios — permanently verifiable and
replayable against current market conditions. Makes protocol stress-testing auditable
rather than proprietary.

| ID | Scenario | Event |
|----|----------|-------|
| 0 | BLACK_THURSDAY_2020   | ETH -60% in 24 h, MakerDAO liquidation crisis |
| 1 | LUNA_COLLAPSE_2022    | LUNA hyperinflation, $40 B wiped in 72 h |
| 2 | FTX_COLLAPSE_2022     | FTX insolvency, ETH -40% contagion |
| 3 | STABLECOIN_DEPEG_2023 | SVB bank-run, USDC temporarily at $0.87 |
| 4 | SYNTHETIC_WORST_CASE  | Synthetic -90% shock, maximum cascade |

```solidity
registry.runScenario(scenarioId, token);
registry.runAllScenarios(token);
registry.worstCaseScenario(token);
registry.addCustomScenario(name, shockBps, volBps, devBps, description);
```

---

## Chainlink Integration

### File Links (for Judges)
| Product | Contract File | Key function |
|---------|--------------|-------------|
| **Price Feeds** | [`ChainlinkVolatilityOracle.sol`](src/ChainlinkVolatilityOracle.sol) | `getVolatilityWithConfidence()`, `getPriceFeedDetails()` |
| **Automation** | [`AutomatedRiskUpdater.sol`](src/AutomatedRiskUpdater.sol) | `checkUpkeep()`, `performUpkeep()` |
| **CCIP** | [`CrossChainRiskBroadcaster.sol`](src/CrossChainRiskBroadcaster.sol) | `broadcastToAll()`, `_ccipReceive()` |
| **CRE Workflow** | [`workflows/risk-orchestrator/index.ts`](workflows/risk-orchestrator/index.ts) | `onTrigger()` |

### How Judges Can Verify in 5 Minutes
See **[docs/JUDGE_PACK.md](docs/JUDGE_PACK.md)** for:
- Exact `cast call` commands to read live Sepolia data
- Expected outputs for each Chainlink product
- Complete `forge test` + `npm build` commands
- Registry/router verification commands for multi-asset mode (`getSupportedAssets`, `getConfig`, `assetRiskState`)

### Multi-Asset Verification Commands

```shell
# AssetRegistry: all configured assets
cast call $ASSET_REGISTRY \
  "getSupportedAssets()(address[])" \
  --rpc-url $SEPOLIA_RPC_URL

# AssetRegistry: enabled-only assets
cast call $ASSET_REGISTRY \
  "getEnabledAssets()(address[])" \
  --rpc-url $SEPOLIA_RPC_URL

# AssetRegistry: config for one asset
cast call $ASSET_REGISTRY \
  "getConfig(address)((address,address,address,uint8,uint256,uint256,uint256,bool))" \
  $ASSET_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL

# MultiAssetRiskRouter: cached risk state for one asset
cast call $MULTI_ASSET_ROUTER \
  "assetRiskState(address)(uint256,uint256,uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256,uint256)" \
  $ASSET_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL
```

Three contracts add deep Chainlink product coverage on top of the four-pillar core.

### ChainlinkVolatilityOracle — Price Feeds

Independently verifies TDRV's Uniswap-derived volatility using **Chainlink Price Feeds**.
Walks backwards through `getRoundData(roundId--)` over N historical rounds, computes
simple returns, calculates variance, and annualizes with a √8760 factor (hourly rounds).
Provides a second, off-chain-verified volatility signal that cross-checks the on-chain
Uniswap observation ring-buffer — any divergence is a manipulation signal.

```solidity
uint256 volBps = cvo.getRealizedVolatility();             // annualised, BPS
uint256 score  = cvo.getVolatilityScore(lowBps, highBps); // 0-100
ChainlinkVolatilityOracle.VolatilityRegime regime = cvo.getVolatilityRegime();

ChainlinkVolatilityOracle.VolatilityWithConfidence memory vc = cvo.getVolatilityWithConfidence();
// vc.volBps, vc.numRoundsUsed, vc.latestPrice, vc.oldestRoundAge

(string memory desc, uint8 dec, uint256 price, uint80 roundId) = cvo.getPriceFeedDetails();
```

Constructor:
```solidity
new ChainlinkVolatilityOracle(
    address priceFeed,       // AggregatorV3Interface (e.g. ETH/USD)
    uint8   numSamples,      // 4-48 historical rounds
    uint32  maxStaleness     // min 3600 s
)
```

### AutomatedRiskUpdater — Chainlink Automation

Implements `AutomationCompatibleInterface` so a **Chainlink Automation** keeper calls
batched `updateRiskForAssets()` and `checkAndRespond()` every 5 minutes — no off-chain
bot required, no single point of failure, Sybil-resistant via the Chainlink DON.

```solidity
(bool upkeepNeeded, bytes memory) = aru.checkUpkeep("");
aru.performUpkeep(""); // called by Automation Node

uint256 count    = aru.upkeepCount();
uint256 nextIn   = aru.secondsUntilNextUpkeep();
```

> **Live Sepolia Automation Proof:**
> `AutomatedRiskUpdater` is actively registered on the Chainlink Automation Network.
> **Upkeep ID**: `55979398141976704248916940835648987232607128922315091009692569738181087735824`

`checkUpkeep` returns `true` when:
- Contract is not paused
- `block.timestamp >= lastUpkeep + interval`
- Circuit breaker is not in cooldown

### CrossChainRiskBroadcaster — Chainlink CCIP

Sends a `RiskPayload{compositeScore, alertLevel, ltvBps, timestamp, sourceContract}`
to any registered L2 destination via **Chainlink CCIP** whenever the alert level is
at or above the configured threshold (default: WARNING).

> **Live Sepolia CCIP Integration Proof:**
> See **[CCIP Explorer Link](https://ccip.chain.link/msg/0x214808a8a6990228fb270ccb83ab45d37ddf3b58f3044a6d250889a61528209e)** for a live cross-chain message successfully sent from Sepolia to Base Sepolia using this implementation.

```solidity
// Register a destination chain
ccrb.addDestination(chainSelector, receiverAddress);

// Send to a single chain (with ETH for fee)
bytes32 messageId = ccrb.broadcastTo{value: fee}(chainSelector);

// Broadcast to all active destinations
uint256 totalFeeSpent = ccrb.broadcastToAll{value: estimatedFee}();

// Fee estimation
uint256 fee = ccrb.estimateFee(chainSelector);
```

The receiver on any destination chain inherits `CCIPReceiver` and decodes the
`RiskPayload`, enabling native on-chain risk-aware execution on Base, Arbitrum,
Optimism, or any CCIP-supported network.

---

## Quickstart

```shell
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Install JS dependencies (root + dashboard)
npm install
npm --prefix dashboard install

# Build
forge build

# Unit tests (no RPC needed — 192 tests total)
forge test --no-match-path test/foundry/ForkTests.t.sol -vvv

# Mainnet fork tests (requires RPC)
MAINNET_RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY \
  forge test --match-path test/foundry/ForkTests.t.sol -vvv
```

## Deployment

**Sepolia testnet** (live — contracts already deployed, see addresses above):
```shell
source .env
forge script script/DeploySepolia.s.sol \
  --rpc-url $SEPOLIA_RPC_URL    \
  --private-key $PRIVATE_KEY    \
  --broadcast --verify
```

**Mainnet**:
```shell
forge script script/Deploy.s.sol \
  --rpc-url $MAINNET_RPC_URL     \
  --private-key $DEPLOYER_KEY    \
  --broadcast --verify
```

Both scripts deploy all core + multi-asset contracts in dependency order and log each address.

**Dashboard** (live mode — point to deployed contracts):
```shell
cd dashboard
# Create .env.local with NEXT_PUBLIC_* addresses (see .env.example)
npm run dev          # local dev
vercel --prod        # deploy to Vercel
```

## Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| TWAP window (MCO) | 1800 s (30 min) | Manipulation resistance vs. freshness |
| Fallback borrow rate | 500 BPS (5%) | Used when Aave V3 is unavailable |
| Cost threshold low | $1M | MCO score = 0 below this |
| Cost threshold high | $100M | MCO score = 100 above this |
| Vol sample window | 24 x 1 h | TDRV realized vol span |
| TCO samples | 24, window 86400 s | Tick entropy observation window (24h) |
| Composite weights | 30 / 35 / 20 / 15 | MCO / TDRV / CPLCS / TCO |
| EWMA alpha (URC) | 3000 BPS (30%) | Score smoothing decay |
| Circuit breaker cooldown | 300 s | Min seconds between alert transitions |

## Mainnet Addresses (Ethereum)

| Contract / Feed | Address |
|-----------------|---------|
| WETH/USDC pool (0.05%) | `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` |
| ETH/USD Chainlink feed | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Chainlink CCIP Router | `0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D` |
| Aave V3 PoolDataProvider | `0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3` |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| Compound V3 USDC comet | `0xc3d688B66703497DAA19211EEdff47f25384cdc3` |
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
