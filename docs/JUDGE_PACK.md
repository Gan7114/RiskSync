# DeFiStressOracle — Judge Verification Pack

## TL;DR: Verify in 5 Minutes

```shell
# 1. Clone & Install
git clone <REPO_URL> && cd DeFiStressOracle
forge install                         # Foundry dependencies
npm --prefix dashboard install        # Dashboard dependencies

# 2. Run all unit tests (no RPC needed)
forge test --no-match-path "test/foundry/ForkTests.t.sol"
# ✅ Expected: 184 tests, 0 failures across 15 suites

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
| ManipulationCostOracle (MCO) | `0xB3C34601FA06E78afe459C0c16D49449d575669B` | [view](https://sepolia.etherscan.io/address/0xB3C34601FA06E78afe459C0c16D49449d575669B) |
| TickDerivedRealizedVolatility (TDRV) | `0x2DFc934b215C2D1ceCA838e7b53CFCae08877Ccf` | [view](https://sepolia.etherscan.io/address/0x2DFc934b215C2D1ceCA838e7b53CFCae08877Ccf) |
| CrossProtocolCascadeScore (CPLCS) | `0xD34314722A972925F4A2D5fFf0752aBbD8F39675` | [view](https://sepolia.etherscan.io/address/0xD34314722A972925F4A2D5fFf0752aBbD8F39675) |
| TickConcentrationOracle (TCO) | `0xeCF62d406025b06b9FC44198235C30EFde62a3e9` | [view](https://sepolia.etherscan.io/address/0xeCF62d406025b06b9FC44198235C30EFde62a3e9) |
| UnifiedRiskCompositor (URC) | `0x191A27Eae07712410A0f37FFd4477B82412AA31e` | [view](https://sepolia.etherscan.io/address/0x191A27Eae07712410A0f37FFd4477B82412AA31e) |
| LendingProtocolCircuitBreaker | `0x3b2859D5c62F78146836Bb47a76e1556cfdEfC3c` | [view](https://sepolia.etherscan.io/address/0x3b2859D5c62F78146836Bb47a76e1556cfdEfC3c) |
| StressScenarioRegistry | `0xA1C034E51Db8d80A50dB9e096638950ceABCE666` | [view](https://sepolia.etherscan.io/address/0xA1C034E51Db8d80A50dB9e096638950ceABCE666) |
| ChainlinkVolatilityOracle (CVO) | `0x9b27152bE4ddc75C1ad7614BD18858D5966B9E8F` | [view](https://sepolia.etherscan.io/address/0x9b27152bE4ddc75C1ad7614BD18858D5966B9E8F) |
| AutomatedRiskUpdater | `0xd3DD2704AE928e130825b4db9C0e862419e7aB40` | [view](https://sepolia.etherscan.io/address/0xd3DD2704AE928e130825b4db9C0e862419e7aB40) |
| CrossChainRiskBroadcaster | `0x7639A986bC26012216A57Ea1E53aF14B26E70077` | [view](https://sepolia.etherscan.io/address/0x7639A986bC26012216A57Ea1E53aF14B26E70077) |

---

## Chainlink Product Proof Checklist

### ✅ 1. Chainlink Price Feeds
- **Contract**: [`ChainlinkVolatilityOracle.sol`](../src/ChainlinkVolatilityOracle.sol)
- **Feed used**: ETH/USD Sepolia `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- **Verification**: Call `getPriceFeedDetails()` on CVO — returns live ETH/USD price, round ID, and description.
- **Test files**: `CVO*` tests in [`NovelSystem.t.sol`](../test/foundry/NovelSystem.t.sol)

```shell
cast call 0x9b27152bE4ddc75C1ad7614BD18858D5966B9E8F \
  "getPriceFeedDetails()(string,uint8,uint256,uint80)" \
  --rpc-url $SEPOLIA_RPC_URL
```

### ✅ 2. Chainlink Automation
- **Contract**: [`AutomatedRiskUpdater.sol`](../src/AutomatedRiskUpdater.sol)
- **Implements**: `AutomationCompatibleInterface` (`checkUpkeep` + `performUpkeep`)
- **Verification**: Call `checkUpkeep("")` — returns `(bool upkeepNeeded, bytes)`.
- **Live Proof**: Actively registered on Chainlink Automation with **Upkeep ID**: `43299524312024280719987296485661783062184338223244119633145042715674688313470`

```shell
cast call 0xd3DD2704AE928e130825b4db9C0e862419e7aB40 \
  "checkUpkeep(bytes)(bool,bytes)" \
  0x00 \
  --rpc-url $SEPOLIA_RPC_URL
```

### ✅ 3. Chainlink CCIP
- **Contract**: [`CrossChainRiskBroadcaster.sol`](../src/CrossChainRiskBroadcaster.sol)
- **Inherits**: `CCIPReceiver`, calls `IRouterClient.ccipSend()`
- **Router**: `0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59` (Sepolia)
- **Verification**: Call `estimateFee(chainSelector)` to confirm router integration.
- **Live Proof**: A successful cross-chain `broadcastToAll` call to Base Sepolia was executed in Tx **[0xe2ab53e3cfd9ed10c6d0b4db3b6a2a984259677e9e956a9d97074f2fb4031724](https://ccip.chain.link/msg/0xe2ab53e3cfd9ed10c6d0b4db3b6a2a984259677e9e956a9d97074f2fb4031724)**.

```shell
cast call 0x7639A986bC26012216A57Ea1E53aF14B26E70077 \
  "estimateFee(uint64)(uint256)" \
  10344971235874465080 \
  --rpc-url $SEPOLIA_RPC_URL
```

### ✅ 4. Chainlink CRE Workflow
- **Location**: [`workflows/risk-orchestrator/index.ts`](../workflows/risk-orchestrator/index.ts)
- **Config**: [`workflows/risk-orchestrator/config.json`](../workflows/risk-orchestrator/config.json)
- **What it does**: Reads composite risk score from URC on-chain, fetches ETH 24h volatility from CoinGecko API, emits alerts when combined risk exceeds thresholds.
- **Compile**:
```shell
cd workflows/risk-orchestrator
npm install
npm run compile
```

---

## Exact Verification Commands

### Read current composite risk score
```shell
cast call 0x191A27Eae07712410A0f37FFd4477B82412AA31e \
  "getRiskScore()(uint256)" \
  --rpc-url $SEPOLIA_RPC_URL
```

### Read full risk breakdown
```shell
cast call 0x191A27Eae07712410A0f37FFd4477B82412AA31e \
  "getRiskBreakdown()(uint256,uint256,uint256,uint256,uint8,uint256,uint256,uint256,uint256)" \
  --rpc-url $SEPOLIA_RPC_URL
```
Returns: `compositeScore, mcoInput, tdrvInput, cpInput, tier, recommendedLtv, realizedVolBps, manipCostUsd, updatedAt`

### Read manipulation attack cost (ETH/USDC, 2% deviation)
```shell
cast call 0xB3C34601FA06E78afe459C0c16D49449d575669B \
  "getManipulationCost(uint256)(uint256,uint256)" \
  200 \
  --rpc-url $SEPOLIA_RPC_URL
```
Returns: `costUsd (8-decimal, divide by 1e8 for USD), securityScore (0-100)`

---

## LTV Impact Table: Static vs Dynamic Under Stress

| Scenario | Static LTV (Industry Avg) | DeFiStressOracle Dynamic LTV | Risk Reduction |
|----------|--------------------------|------------------------------|---------------|
| Normal market (score 0–25) | 80% | **80%** — full capacity | None (no unnecessary restriction) |
| Moderate volatility spike (score 26–50) | 80% (unchanged) | **75%** — 500 BPS tighter | Prevents ~$500M undercollateral at $10B TVL |
| Sustained high vol / cascade (score 51–75) | 80% (unchanged) | **65%** — 1500 BPS tighter | Prevents ~$1.5B undercollateral |
| Emergency (score 76–100) | 80% (unchanged) | **50%** + borrowing paused | Full liquidation cascade prevention |

**Key point**: Static LTV protocols (Aave, Compound, most others) use the same LTV in normal markets AND during Black Thursday–style crashes. DeFiStressOracle tightens LTV *before* positions go underwater, not after.

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
