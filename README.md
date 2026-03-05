# DeFiStressOracle

On-chain risk middleware for DeFi protocols — ten composable contracts that measure
oracle manipulation cost, realized volatility, cross-protocol liquidation cascades, and
tick-sequence entropy, then unify them into a single risk score with autonomous circuit
breakers, Chainlink-powered keepers, cross-chain alert propagation, and historical
stress-scenario replay.

## Live Demo

> Dashboard connects directly to deployed Sepolia contracts — real on-chain risk data, live Chainlink ETH/USD price feed.

**Deploy to Vercel:** `cd dashboard && vercel --prod` (requires Vercel account)

### Sepolia Testnet Contracts (chainId 11155111)

| Contract | Address | Etherscan |
|---|---|---|
| ManipulationCostOracle | `0xB3C34601FA06E78afe459C0c16D49449d575669B` | [view](https://sepolia.etherscan.io/address/0xB3C34601FA06E78afe459C0c16D49449d575669B) |
| TickDerivedRealizedVolatility | `0x2DFc934b215C2D1ceCA838e7b53CFCae08877Ccf` | [view](https://sepolia.etherscan.io/address/0x2DFc934b215C2D1ceCA838e7b53CFCae08877Ccf) |
| CrossProtocolCascadeScore | `0xD34314722A972925F4A2D5fFf0752aBbD8F39675` | [view](https://sepolia.etherscan.io/address/0xD34314722A972925F4A2D5fFf0752aBbD8F39675) |
| TickConcentrationOracle | `0xeCF62d406025b06b9FC44198235C30EFde62a3e9` | [view](https://sepolia.etherscan.io/address/0xeCF62d406025b06b9FC44198235C30EFde62a3e9) |
| UnifiedRiskCompositor | `0x191A27Eae07712410A0f37FFd4477B82412AA31e` | [view](https://sepolia.etherscan.io/address/0x191A27Eae07712410A0f37FFd4477B82412AA31e) |
| LendingProtocolCircuitBreaker | `0x3b2859D5c62F78146836Bb47a76e1556cfdEfC3c` | [view](https://sepolia.etherscan.io/address/0x3b2859D5c62F78146836Bb47a76e1556cfdEfC3c) |
| StressScenarioRegistry | `0xA1C034E51Db8d80A50dB9e096638950ceABCE666` | [view](https://sepolia.etherscan.io/address/0xA1C034E51Db8d80A50dB9e096638950ceABCE666) |
| ChainlinkVolatilityOracle | `0x9b27152bE4ddc75C1ad7614BD18858D5966B9E8F` | [view](https://sepolia.etherscan.io/address/0x9b27152bE4ddc75C1ad7614BD18858D5966B9E8F) |
| AutomatedRiskUpdater | `0xd3DD2704AE928e130825b4db9C0e862419e7aB40` | [view](https://sepolia.etherscan.io/address/0xd3DD2704AE928e130825b4db9C0e862419e7aB40) |
| CrossChainRiskBroadcaster | `0x7639A986bC26012216A57Ea1E53aF14B26E70077` | [view](https://sepolia.etherscan.io/address/0x7639A986bC26012216A57Ea1E53aF14B26E70077) |

**External integrations on Sepolia:**
- Chainlink ETH/USD feed: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- Uniswap V3 ETH/USDC pool: `0x6Ce0896eAE6D4BD668fDe41BB784548fb8F59b50`
- CCIP Router: `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59`
- Aave V3 PoolDataProvider: `0x3e9708d80f7B3e43118013075F7e95CE3AB31F31`

---

## Architecture

```
src/
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
├── NovelSystem.t.sol  — 179 unit tests (mock-based, no RPC needed)
└── ForkTests.t.sol    — Mainnet fork tests (auto-skip when MAINNET_RPC_URL unset)

script/
├── Deploy.s.sol         — One-shot mainnet deployment (all 10 contracts)
└── DeploySepolia.s.sol  — Sepolia testnet deployment (testnet-friendly windows)
```

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

Constructor (8 params):
```solidity
new ManipulationCostOracle(
    address pool,
    address token1UsdFeed,
    uint32  twapWindow,           // min 300 s
    uint256 borrowRatePerYearBps, // 1-10000
    uint256 costThresholdLow,
    uint256 costThresholdHigh,
    address aaveDataProvider,     // address(0) = disabled
    address token1Address         // address(0) = disabled
)
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

uint256 ewma            = urc.getEWMAScore();
uint256[8] memory hist  = urc.getScoreHistory();
bool tcoEnabled         = urc.isTcoEnabled();

// Momentum: ACCELERATING / STABLE / DECELERATING / REVERSING
UnifiedRiskCompositor.ScoreMomentum momentum = urc.getScoreMomentum();
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
`updateRiskScore()` and `checkAndRespond()` every 5 minutes — no off-chain bot required,
no single point of failure, Sybil-resistant via the Chainlink DON.

```solidity
(bool upkeepNeeded, bytes memory) = aru.checkUpkeep("");
aru.performUpkeep(""); // called by Automation Node

uint256 count    = aru.upkeepCount();
uint256 nextIn   = aru.secondsUntilNextUpkeep();
uint256 score    = aru.currentRiskScore();
```

`checkUpkeep` returns `true` when:
- Contract is not paused
- `block.timestamp >= lastUpkeep + interval`
- Circuit breaker is not in cooldown

### CrossChainRiskBroadcaster — Chainlink CCIP

Sends a `RiskPayload{compositeScore, alertLevel, ltvBps, timestamp, sourceContract}`
to any registered L2 destination via **Chainlink CCIP** whenever the alert level is
at or above the configured threshold (default: WARNING).

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

# Build
forge build

# Unit tests (no RPC needed — 179 tests, 15 suites)
forge test --match-path test/foundry/NovelSystem.t.sol -vvv

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

Both scripts deploy all 10 contracts in dependency order and log each address.

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
| TCO samples | 24, window 1440 s | Tick entropy observation count |
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
