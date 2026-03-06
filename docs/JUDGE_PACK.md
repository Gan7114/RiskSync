# RiskSync — Judge Verification Pack

## TL;DR: Verify in 5 Minutes

```shell
# 1. Clone & Install
git clone <REPO_URL> && cd RiskSync
forge install                         # Foundry dependencies
npm --prefix dashboard install        # Dashboard dependencies

# 2. Run all unit tests (no RPC needed)
forge test --no-match-path "test/foundry/ForkTests.t.sol"
# ✅ Expected: 192 tests, 0 failures across 18 suites

# 3. Build dashboard
npm --prefix dashboard run build
# ✅ Expected: clean build, no type errors

# 4. Verify live on Sepolia dashboard
# Point browser at the live Vercel URL or run:
cd dashboard && npm run dev   # opens http://localhost:3000
```

---

## Deployed Contract Addresses (Sepolia, chainId 11155111)

| Contract | Address | Etherscan |
|---|---|---|
| ManipulationCostOracle (MCO) | `0xf410d4450A98cB1304e7F5B529EBcd30801b771C` | [view](https://sepolia.etherscan.io/address/0xf410d4450A98cB1304e7F5B529EBcd30801b771C) |
| TickDerivedRealizedVolatility (TDRV) | `0x25Ec7B78DaaB44137121ceD05FAcc07A2dFB0570` | [view](https://sepolia.etherscan.io/address/0x25Ec7B78DaaB44137121ceD05FAcc07A2dFB0570) |
| CrossProtocolCascadeScore (CPLCS) | `0x075D2961682F72C4fbf6d43FBF6a34bf7BBc0B72` | [view](https://sepolia.etherscan.io/address/0x075D2961682F72C4fbf6d43FBF6a34bf7BBc0B72) |
| TickConcentrationOracle (TCO) | `0x54F4050Dc6e61611F99FC8F4C85b081f7aa6749C` | [view](https://sepolia.etherscan.io/address/0x54F4050Dc6e61611F99FC8F4C85b081f7aa6749C) |
| UnifiedRiskCompositor (URC) | `0x153D2bc4bdDdB1b6b54f127e718bdE004d75AB44` | [view](https://sepolia.etherscan.io/address/0x153D2bc4bdDdB1b6b54f127e718bdE004d75AB44) |
| LendingProtocolCircuitBreaker | `0x297A1BccC9F1578B4c3fA2701fCf6Ad8a41E1fEa` | [view](https://sepolia.etherscan.io/address/0x297A1BccC9F1578B4c3fA2701fCf6Ad8a41E1fEa) |
| StressScenarioRegistry | `0xb7Ac84503e02a95ae06494FF44594139dAAE51dC` | [view](https://sepolia.etherscan.io/address/0xb7Ac84503e02a95ae06494FF44594139dAAE51dC) |
| ChainlinkVolatilityOracle (CVO) | `0x2DD8064f972168d3eEadedb90BbBd4B49DaC046c` | [view](https://sepolia.etherscan.io/address/0x2DD8064f972168d3eEadedb90BbBd4B49DaC046c) |
| AssetRegistry | `0xAc8509a209eF27BD92A43C31F33705e1c30376d8` | [view](https://sepolia.etherscan.io/address/0xAc8509a209eF27BD92A43C31F33705e1c30376d8) |
| MultiAssetRiskRouter | `0x6BF3B6DfB0884A45a54140D38513F991Cf633721` | [view](https://sepolia.etherscan.io/address/0x6BF3B6DfB0884A45a54140D38513F991Cf633721) |
| AutomatedRiskUpdater | `0x473779900D540F0098D4EDf40bD3b94a36f8731C` | [view](https://sepolia.etherscan.io/address/0x473779900D540F0098D4EDf40bD3b94a36f8731C) |
| CrossChainRiskBroadcaster | `0xFd51A5E98355dC874Bf75EA6ED36Ae159810bFBE` | [view](https://sepolia.etherscan.io/address/0xFd51A5E98355dC874Bf75EA6ED36Ae159810bFBE) |

### Multi-Asset Upgrade Contracts

`AssetRegistry` and `MultiAssetRiskRouter` are now part of the deployment scripts (`Deploy.s.sol`, `DeploySepolia.s.sol`).
After running the upgraded scripts, set:

- `ASSET_REGISTRY=<deployed registry address>`
- `MULTI_ASSET_ROUTER=<deployed router address>`

and run the verification commands below.

### Configured Asset Reality (Script Defaults)

| Network | ETH | BTC | LINK | AAVE |
|---|---|---|---|---|
| Mainnet deploy script | Enabled by default | Disabled unless `BTC_UNI_POOL` is provided | Disabled unless `LINK_UNI_POOL` is provided | Disabled unless `AAVE_UNI_POOL` is provided |
| Sepolia deploy script | Enabled by default | Disabled unless env pool+feed exist | Disabled unless env pool+feed exist | Disabled unless env pool+feed exist |

Disabled assets are explicitly marked disabled in registry and dashboard (never shown as fake live).

---

## Chainlink Product Proof Checklist

### ✅ 1. Chainlink Price Feeds
- **Contract**: [`ChainlinkVolatilityOracle.sol`](../src/ChainlinkVolatilityOracle.sol)
- **Feed used**: ETH/USD Sepolia `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- **Verification**: Call `getPriceFeedDetails()` on CVO — returns live ETH/USD price, round ID, and description.
- **Test files**: `CVO*` tests in [`NovelSystem.t.sol`](../test/foundry/NovelSystem.t.sol)

```shell
cast call 0x2DD8064f972168d3eEadedb90BbBd4B49DaC046c \
  "getPriceFeedDetails()(string,uint8,uint256,uint80)" \
  --rpc-url $SEPOLIA_RPC_URL
```

### ✅ 2. Chainlink Automation
- **Contract**: [`AutomatedRiskUpdater.sol`](../src/AutomatedRiskUpdater.sol)
- **Implements**: `AutomationCompatibleInterface` (`checkUpkeep` + `performUpkeep`)
- **Verification**: Call `checkUpkeep("")` — returns `(bool upkeepNeeded, bytes)`.
- **Live Proof**: Actively registered on Chainlink Automation with **Upkeep ID**: `55979398141976704248916940835648987232607128922315091009692569738181087735824`

```shell
cast call 0x473779900D540F0098D4EDf40bD3b94a36f8731C \
  "checkUpkeep(bytes)(bool,bytes)" \
  0x \
  --rpc-url $SEPOLIA_RPC_URL
```

### ✅ 3. Chainlink CCIP
- **Contract**: [`CrossChainRiskBroadcaster.sol`](../src/CrossChainRiskBroadcaster.sol)
- **Inherits**: `CCIPReceiver`, calls `IRouterClient.ccipSend()`
- **Router**: `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` (Sepolia)
- **Verification**: Call `estimateFee(chainSelector)` to confirm router integration.
- **Live Proof**: A successful cross-chain message was executed from the upgraded broadcaster: **[0x214808a8a6990228fb270ccb83ab45d37ddf3b58f3044a6d250889a61528209e](https://ccip.chain.link/msg/0x214808a8a6990228fb270ccb83ab45d37ddf3b58f3044a6d250889a61528209e)**.

```shell
cast call 0xFd51A5E98355dC874Bf75EA6ED36Ae159810bFBE \
  "estimateFee(uint64)(uint256)" \
  10344971235874465080 \
  --rpc-url $SEPOLIA_RPC_URL
```

### ✅ 4. Chainlink CRE Workflow
- **Location**: [`workflows/risk-orchestrator/index.ts`](../workflows/risk-orchestrator/index.ts)
- **Config**: [`workflows/risk-orchestrator/config.json`](../workflows/risk-orchestrator/config.json)
- **What it does**: Reads enabled assets from `AssetRegistry`, reads per-asset risk from `MultiAssetRiskRouter`, fetches per-asset 24h volatility from CoinGecko, computes severity/action, and estimates CCIP fee for alert routing.
- **Build + simulate**:
```shell
cd workflows/risk-orchestrator
npm install
npm run setup
npm run compile
PATH="$HOME/.bun/bin:$PATH" \
cre workflow simulate ./workflows/risk-orchestrator -T staging-settings --non-interactive --trigger-index 0
```

---

## Exact Verification Commands

### Verify multi-asset registry + router

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

### Read current composite risk score
```shell
cast call 0x153D2bc4bdDdB1b6b54f127e718bdE004d75AB44 \
  "getRiskScore()(uint256)" \
  --rpc-url $SEPOLIA_RPC_URL
```

### Read full risk breakdown
```shell
cast call 0x153D2bc4bdDdB1b6b54f127e718bdE004d75AB44 \
  "getRiskBreakdown()(uint256,uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256)" \
  --rpc-url $SEPOLIA_RPC_URL
```
Returns: `compositeScore, mcoInput, tdrvInput, cpInput, tier, recommendedLtv, realizedVolBps, manipCostUsd, updatedAt`

### Read manipulation attack cost (ETH/USDC, 2% deviation)
```shell
cast call 0xf410d4450A98cB1304e7F5B529EBcd30801b771C \
  "getManipulationCost(uint256)(uint256,uint256)" \
  200 \
  --rpc-url $SEPOLIA_RPC_URL
```
Returns: `costUsd (8-decimal, divide by 1e8 for USD), securityScore (0-100)`

---

## LTV Impact Table: Static vs Dynamic Under Stress

| Scenario | Static LTV (Industry Avg) | RiskSync Dynamic LTV | Risk Reduction |
|----------|--------------------------|------------------------------|---------------|
| Normal market (score 0–25) | 80% | **80%** — full capacity | None (no unnecessary restriction) |
| Moderate volatility spike (score 26–50) | 80% (unchanged) | **75%** — 500 BPS tighter | Prevents ~$500M undercollateral at $10B TVL |
| Sustained high vol / cascade (score 51–75) | 80% (unchanged) | **65%** — 1500 BPS tighter | Prevents ~$1.5B undercollateral |
| Emergency (score 76–100) | 80% (unchanged) | **50%** + borrowing paused | Full liquidation cascade prevention |

**Key point**: Static LTV protocols (Aave, Compound, most others) use the same LTV in normal markets AND during Black Thursday–style crashes. RiskSync tightens LTV *before* positions go underwater, not after.

---

## Expected Test Output

```
Ran 21 tests for test/foundry/ForkTests.t.sol:ForkTests
[PASS] testFuzz_fork_mco_scoreBounded(uint256) (runs: 256, μ: 426833, ~: 461168)
[PASS] test_fork_cb_initialState() (gas: 593602)
[PASS] test_fork_cplcs_largerShockNotLowerScore() (gas: 266949)
[PASS] test_fork_cplcs_nonzeroCollateral() (gas: 209409)
[PASS] test_fork_mco_atWindowArbitrary() (gas: 454067)
[PASS] test_fork_mco_largerDeviationCostsMore() (gas: 629408)
[PASS] test_fork_mco_liveBorrowRateInRange() (gas: 94424)
[PASS] test_fork_mco_multiWindowCostProportional() (gas: 457800)
[PASS] test_fork_mco_returnsPositiveCost() (gas: 454093)
[PASS] test_fork_mco_twapVsSpotDeviation() (gas: 74295)
[PASS] test_fork_ssr_runBlackThursday() (gas: 3226717)
[PASS] test_fork_ssr_scenarioCountFive() (gas: 2638103)
[PASS] test_fork_tdrv_ewmaInRange() (gas: 958084)
[PASS] test_fork_tdrv_rawDimensions() (gas: 589281)
[PASS] test_fork_tdrv_regimeIsValid() (gas: 585973)
[PASS] test_fork_tdrv_scoreInRange() (gas: 585715)
[PASS] test_fork_tdrv_volInRange() (gas: 585578)
[PASS] test_fork_urc_breakdownConsistency() (gas: 1686272)
[PASS] test_fork_urc_ewmaInitializedAfterUpdate() (gas: 1685029)
[PASS] test_fork_urc_scoreHistoryAfterOneUpdate() (gas: 1690019)
[PASS] test_fork_urc_updateRiskScore() (gas: 1689437)
Suite result: ok. 21 passed; 0 failed; 0 skipped; finished in 31.65s (198.24s CPU time)

Ran 1 test suite in 31.66s (31.65s CPU time): 21 tests passed, 0 failed, 0 skipped (21 total tests)
```
