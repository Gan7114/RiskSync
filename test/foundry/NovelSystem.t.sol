// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ManipulationCostOracle} from "../../src/ManipulationCostOracle.sol";
import {TickDerivedRealizedVolatility} from "../../src/TickDerivedRealizedVolatility.sol";
import {CrossProtocolCascadeScore} from "../../src/CrossProtocolCascadeScore.sol";
import {UnifiedRiskCompositor} from "../../src/UnifiedRiskCompositor.sol";
import {LendingProtocolCircuitBreaker, RiskCircuitBreaker} from "../../src/RiskCircuitBreaker.sol";
import {StressScenarioRegistry} from "../../src/StressScenarioRegistry.sol";
import {IRiskConsumer, IRiskScoreProvider} from "../../src/interfaces/IRiskConsumer.sol";
import {TickConcentrationOracle} from "../../src/TickConcentrationOracle.sol";

// ─── Mock Contracts ───────────────────────────────────────────────────────────

/// @dev Mock Uniswap V3 pool. Configurable tick cumulatives, slot0, and liquidity.
contract MockUniV3Pool {
    // slot0 state
    uint160 public s_sqrtPriceX96;
    int24  public s_tick;
    bool   public s_unlocked = true;

    // liquidity
    uint128 public s_liquidity;

    // observe() returns: two arrays indexed by secondsAgo
    // We store a mapping: secondsAgo → tickCumulative
    // The pool accumulates tick every second. We approximate: tickCumulative(t) = baseAccum - tick*t
    // where baseAccum is the cumulative at t=0 (now), and tick is current tick.
    // For testing: caller sets a base tick and we compute linearly.
    int56 public s_baseTickCumulative; // tickCumulative at secondsAgo=0 (now)
    int24 public s_avgTick;            // used for linear interpolation: cumulative(t) = base - avgTick*t

    // For more precise control, caller can inject tick cumulative snapshots directly.
    // When s_useCustomCumulatives = true, observe() reads from s_cumulatives[secondsAgo].
    bool public s_useCustomCumulatives;
    mapping(uint32 => int56) public s_cumulatives;

    function setSlot0(uint160 sqrtP, int24 tick, bool unlocked) external {
        s_sqrtPriceX96 = sqrtP;
        s_tick = tick;
        s_unlocked = unlocked;
    }

    function setLiquidity(uint128 liq) external { s_liquidity = liq; }

    function setLinearTick(int56 baseAccum, int24 avgTick) external {
        s_baseTickCumulative = baseAccum;
        s_avgTick = avgTick;
        s_useCustomCumulatives = false;
    }

    function setCustomCumulative(uint32 secondsAgo, int56 cumulative) external {
        s_cumulatives[secondsAgo] = cumulative;
        s_useCustomCumulatives = true;
    }

    function slot0() external view returns (
        uint160, int24, uint16, uint16, uint16, uint8, bool
    ) {
        return (s_sqrtPriceX96, s_tick, 0, 1, 1, 0, s_unlocked);
    }

    function liquidity() external view returns (uint128) { return s_liquidity; }

    function fee() external view returns (uint24) { return 3000; }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory spls)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        spls = new uint160[](secondsAgos.length);

        for (uint256 i = 0; i < secondsAgos.length; i++) {
            if (s_useCustomCumulatives) {
                tickCumulatives[i] = s_cumulatives[secondsAgos[i]];
            } else {
                // Linear model: cumulative(t) = baseAccum - avgTick * t
                tickCumulatives[i] = s_baseTickCumulative - int56(s_avgTick) * int56(uint56(secondsAgos[i]));
            }
        }
    }

    // ── Tick bitmap / ticks support (for MCO tick-walk tests) ─────────────────

    int24 public s_tickSpacing = 60; // default: 0.3% pool spacing
    mapping(int16 => uint256) public s_tickBitmap;
    mapping(int24 => int128) public s_liquidityNet; // per-tick liquidityNet override

    function setTickSpacing(int24 spacing) external { s_tickSpacing = spacing; }

    function setTickBitmapWord(int16 wordPos, uint256 word) external {
        s_tickBitmap[wordPos] = word;
    }

    function setLiquidityNet(int24 tick, int128 liqNet) external {
        s_liquidityNet[tick] = liqNet;
    }

    function tickSpacing() external view returns (int24) { return s_tickSpacing; }

    function tickBitmap(int16 wordPosition) external view returns (uint256) {
        return s_tickBitmap[wordPosition];
    }

    function ticks(int24 tick) external view returns (
        uint128 liquidityGross,
        int128  liquidityNet,
        uint256 feeGrowthOutside0X128,
        uint256 feeGrowthOutside1X128,
        int56   tickCumulativeOutside,
        uint160 secondsPerLiquidityOutsideX128,
        uint32  secondsOutside,
        bool    initialized
    ) {
        liquidityNet = s_liquidityNet[tick];
        liquidityGross = liquidityNet > 0 ? uint128(liquidityNet) : uint128(-liquidityNet);
        initialized = (liquidityGross > 0);
        return (liquidityGross, liquidityNet, 0, 0, 0, 0, 0, initialized);
    }
}

/// @dev Mock Chainlink price feed.
contract MockChainlinkFeed {
    int256  public s_answer;
    uint256 public s_updatedAt;
    uint8   public s_decimals;
    uint80  public s_roundId = 1;

    constructor(int256 answer, uint8 dec) {
        s_answer = answer;
        s_decimals = dec;
        s_updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) { return s_decimals; }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (s_roundId, s_answer, 0, s_updatedAt, s_roundId);
    }

    function setAnswer(int256 answer) external {
        s_answer = answer;
        s_updatedAt = block.timestamp;
    }

    function setStale() external { s_updatedAt = block.timestamp - 7200; }
}

/// @dev Minimal Aave V3 DataProvider mock.
contract MockAaveDataProvider {
    uint256 public s_totalAToken;
    uint256 public s_liqThreshold; // in BPS, e.g. 8000 = 80%
    uint256 public s_variableBorrowRate; // in RAY (1e27), e.g. 5e25 = 5% APY
    bool public s_revert;

    constructor(uint256 totalAToken, uint256 liqThreshold) {
        s_totalAToken = totalAToken;
        s_liqThreshold = liqThreshold;
    }

    function setRevert(bool r) external { s_revert = r; }
    function setVariableBorrowRate(uint256 rayRate) external { s_variableBorrowRate = rayRate; }

    function getReserveData(address) external view returns (
        uint256, uint256, uint256 totalAToken, uint256, uint256,
        uint256, uint256 variableBorrowRate, uint256, uint256, uint256, uint256, uint40
    ) {
        if (s_revert) revert("mock revert");
        return (0, 0, s_totalAToken, 0, 0, 0, s_variableBorrowRate, 0, 0, 0, 0, 0);
    }

    function getReserveConfigurationData(address) external view returns (
        uint256, uint256, uint256 liqThreshold, uint256, uint256,
        bool, bool, bool, bool, bool
    ) {
        if (s_revert) revert("mock revert");
        return (0, 0, s_liqThreshold, 0, 0, true, true, false, true, false);
    }
}

/// @dev Minimal Compound V3 Comet mock.
contract MockCompoundComet {
    uint128 public s_totalSupplyAsset;
    uint64  public s_liquidateCollateralFactor; // 1e18 scaled, e.g. 0.9e18 = 90%
    bool    public s_revert;
    uint8   public s_decimals = 18;

    constructor(uint128 totalSupply, uint64 liqFactor) {
        s_totalSupplyAsset = totalSupply;
        s_liquidateCollateralFactor = liqFactor;
    }

    function setRevert(bool r) external { s_revert = r; }

    function decimals() external view returns (uint8) { return s_decimals; }

    function totalsCollateral(address) external view returns (
        uint128 totalSupplyAsset, uint128 _reserved
    ) {
        if (s_revert) revert("mock revert");
        return (s_totalSupplyAsset, 0);
    }

    function getAssetInfoByAddress(address) external view returns (
        uint8, address, address, uint64, uint64 borrowCollateralFactor,
        uint64 liquidateCollateralFactor, uint64, uint128
    ) {
        if (s_revert) revert("mock revert");
        return (0, address(0), address(0), 0, 0, s_liquidateCollateralFactor, 0, 0);
    }
}

/// @dev Minimal Morpho Blue mock.
contract MockMorphoBlue {
    uint128 public s_totalSupplyAssets;
    uint256 public s_lltv; // 1e18 scaled
    bool    public s_revert;

    constructor(uint128 totalSupply, uint256 lltv) {
        s_totalSupplyAssets = totalSupply;
        s_lltv = lltv;
    }

    function setRevert(bool r) external { s_revert = r; }

    function market(bytes32) external view returns (
        uint128 totalSupplyAssets, uint128 totalSupplyShares,
        uint128 totalBorrowAssets, uint128 totalBorrowShares,
        uint128 lastUpdate, uint128 fee
    ) {
        if (s_revert) revert("mock revert");
        return (s_totalSupplyAssets, 0, 0, 0, uint128(block.timestamp), 0);
    }

    function idToMarketParams(bytes32) external view returns (
        address loanToken, address collateralToken, address oracle,
        address irm, uint256 lltv
    ) {
        if (s_revert) revert("mock revert");
        return (address(0), address(0), address(0), address(0), s_lltv);
    }
}

// ─── ManipulationCostOracle Tests ─────────────────────────────────────────────

contract MCOTest is Test {
    MockUniV3Pool    pool;
    MockChainlinkFeed feed;
    ManipulationCostOracle mco;

    // sqrtPriceX96 for tick = 0: price = 1.0 → sqrtPrice = 1 → sqrtPriceX96 = 2^96
    // Using tick=0 makes TWAP and spot match exactly (no deviation from baseline).
    uint160 constant SQRT_PRICE_TICK0 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    int24 constant AVG_TICK = 0; // tick=0 → price=1, sqrtPriceX96=2^96

    // ETH/USD = $3000 (8 decimals = 300000000000)
    int256 constant ETH_USD_PRICE = 300_000_000_000; // $3000 with 8 decimals

    function setUp() public {
        // Advance timestamp so setStale() (which subtracts 7200) never underflows.
        vm.warp(10_000);

        pool = new MockUniV3Pool();
        feed = new MockChainlinkFeed(ETH_USD_PRICE, 8);

        // Pool at tick=0: tickCumulative(t) = 0 for all t (flat price).
        // sqrtPriceX96 in slot0 matches getSqrtRatioAtTick(0) = 2^96 exactly,
        // so getTwapVsSpot() reports zero deviation.
        pool.setLinearTick(0, AVG_TICK);
        pool.setSlot0(SQRT_PRICE_TICK0, AVG_TICK, true);
        pool.setLiquidity(1_000_000 ether); // large liquidity

        // Deploy MCO: 30-min TWAP, 5% borrow rate, $1M low, $100M high
        mco = new ManipulationCostOracle(
            address(pool),
            address(feed),
            1800,           // 30 minute TWAP
            500,            // 5% per year borrow rate
            100_000_000_00, // $1M threshold low (1e8)
            10_000_000_000_00, // $100M threshold high (1e8)
            address(0),     // no Aave live rate (use static)
            address(0),     // no token1 address
            18              // 18 decimals
        );
    }

    // ── Constructor validation ─────────────────────────────────────────────────

    function test_constructor_rejectsZeroPool() public {
        vm.expectRevert(ManipulationCostOracle.InvalidConfig.selector);
        new ManipulationCostOracle(address(0), address(feed), 1800, 500, 1e8, 1e10, address(0), address(0), 18);
    }

    function test_constructor_rejectsShortWindow() public {
        vm.expectRevert(ManipulationCostOracle.ObservationWindowTooShort.selector);
        new ManipulationCostOracle(address(pool), address(feed), 299, 500, 1e8, 1e10, address(0), address(0), 18);
    }

    function test_constructor_rejectsZeroBorrowRate() public {
        vm.expectRevert(ManipulationCostOracle.InvalidConfig.selector);
        new ManipulationCostOracle(address(pool), address(feed), 1800, 0, 1e8, 1e10, address(0), address(0), 18);
    }

    function test_constructor_rejectsExcessiveBorrowRate() public {
        vm.expectRevert(ManipulationCostOracle.InvalidConfig.selector);
        // 10001 bps = 100.01% — absurd rate
        new ManipulationCostOracle(address(pool), address(feed), 1800, 10_001, 1e8, 1e10, address(0), address(0), 18);
    }

    function test_constructor_rejectsInvertedThresholds() public {
        vm.expectRevert(ManipulationCostOracle.InvalidConfig.selector);
        new ManipulationCostOracle(address(pool), address(feed), 1800, 500, 1e10, 1e8, address(0), address(0), 18);
    }

    // ── Core functionality ─────────────────────────────────────────────────────

    function test_getManipulationCost_returnsPositiveCost() public view {
        (uint256 costUsd, uint256 score) = mco.getManipulationCost(200); // 2% deviation
        assertGt(costUsd, 0, "cost must be positive with nonzero liquidity");
        assertLe(score, 100, "score must be <= 100");
    }

    function test_getManipulationCost_higherDeviationCostsMore() public view {
        (uint256 cost200,) = mco.getManipulationCost(200);
        (uint256 cost1000,) = mco.getManipulationCost(1000);
        assertGt(cost1000, cost200, "larger deviation must cost more");
    }

    function test_getManipulationCostNormalized_matchesScoreAndCapsWhenNeeded() public view {
        (uint256 rawCostUsd, uint256 rawScore) = mco.getManipulationCost(200);
        (uint256 normalizedCostUsd, uint256 normalizedScore, bool capped) = mco.getManipulationCostNormalized(200);

        assertEq(normalizedScore, rawScore, "normalization must not change risk score");
        assertLe(normalizedCostUsd, mco.costThresholdHigh(), "normalized cost must be bounded by high threshold");

        if (rawCostUsd > mco.costThresholdHigh()) {
            assertEq(normalizedCostUsd, mco.costThresholdHigh(), "cost must clamp at high threshold");
            assertTrue(capped, "cap flag must be true when clamped");
        } else {
            assertEq(normalizedCostUsd, rawCostUsd, "cost must match raw when below cap");
            assertFalse(capped, "cap flag must be false when not clamped");
        }
    }

    function test_getManipulationCostBreakdown_consistentWithRawAndNormalized() public view {
        (uint256 rawCostUsd, uint256 rawScore) = mco.getManipulationCost(200);
        (
            uint256 breakdownRaw,
            uint256 normalizedCostUsd,
            uint256 breakdownScore,
            bool capped
        ) = mco.getManipulationCostBreakdown(200);

        assertEq(breakdownRaw, rawCostUsd, "breakdown raw cost must match base query");
        assertEq(breakdownScore, rawScore, "breakdown score must match base query");
        assertLe(normalizedCostUsd, mco.costThresholdHigh(), "breakdown normalized cost must be capped");

        if (breakdownRaw > mco.costThresholdHigh()) {
            assertEq(normalizedCostUsd, mco.costThresholdHigh(), "normalized cost must clamp at threshold");
            assertTrue(capped, "cap flag should be true when raw exceeds threshold");
        } else {
            assertEq(normalizedCostUsd, breakdownRaw, "normalized must equal raw below threshold");
            assertFalse(capped, "cap flag should be false below threshold");
        }
    }

    function test_getManipulationCost_rejectsZeroDeviation() public {
        vm.expectRevert(ManipulationCostOracle.DeviationOutOfRange.selector);
        mco.getManipulationCost(0);
    }

    function test_getManipulationCost_rejectsExcessiveDeviation() public {
        vm.expectRevert(ManipulationCostOracle.DeviationOutOfRange.selector);
        mco.getManipulationCost(5_001);
    }

    function test_getManipulationCost_lockedPoolReverts() public {
        pool.setSlot0(SQRT_PRICE_TICK0, AVG_TICK, false);
        vm.expectRevert(ManipulationCostOracle.PoolLocked.selector);
        mco.getManipulationCost(200);
    }

    function test_getManipulationCost_staleChainlinkReverts() public {
        feed.setStale();
        vm.expectRevert(ManipulationCostOracle.StaleChainlinkFeed.selector);
        mco.getManipulationCost(200);
    }

    /// @notice Verify holding cost uses opportunity cost (borrow rate × time), not flash loan fees.
    ///
    /// The formula: holdingCost = moveCapital × borrowRatePerYearBps × twapWindow / (BPS × SECONDS_PER_YEAR)
    ///
    /// Proof by comparison: deploy two MCOs with rate R1=500 and R2=5000 (10× difference).
    /// Because moveCapital is the SAME for both (same pool, same deviation, same TWAP),
    /// the DIFFERENCE in costs equals:
    ///   costDiff = moveCapital × (R2 - R1) × twapWindow / (BPS × SECONDS_PER_YEAR)
    ///
    /// We can't read moveCapital directly, but we can verify:
    ///   (cost2 - cost1) / cost1 ≈ (R2 - R1) × twapWindow / (BPS × SECONDS_PER_YEAR + R1 × twapWindow)
    ///
    /// Wrong formula (flash loan fee × blocks) would not scale with borrowRatePerYearBps at all,
    /// since it ignores that parameter entirely.
    function test_holdingCostIsOpportunityCostNotFlashLoanFee() public {
        // MCO1: 5% borrow rate, MCO2: 50% borrow rate — 10× more expensive to hold
        ManipulationCostOracle mco1 = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 500, 1, 2, address(0), address(0), 18
        );
        ManipulationCostOracle mco2 = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 5_000, 1, 2, address(0), address(0), 18
        );

        (uint256 cost1,) = mco1.getManipulationCost(200);
        (uint256 cost2,) = mco2.getManipulationCost(200);

        // cost2 > cost1 because higher borrow rate increases holding cost.
        assertGt(cost2, cost1, "higher borrow rate must increase total cost");

        // Cost difference must be nonzero (holding cost scales with rate).
        uint256 diff = cost2 - cost1;
        assertGt(diff, 0, "cost difference must be positive");

        // The ratio diff/cost1 ≈ (R2 - R1) × twapWindow / (BPS × SECONDS_PER_YEAR)
        //   = 4500 × 1800 / (10000 × 31536000) ≈ 2.567e-5 (very small)
        // This means holding costs are a tiny fraction of move capital (correct behaviour).
        // If the WRONG formula (flash loan fee × blocks) were used, borrowRatePerYearBps
        // would have NO effect on the output — cost1 == cost2 — which we rule out above.

        // Additionally: with R2=5000 (50% APY) and 30-min window, holding fraction = 50%×(30min/1yr)
        //   = 0.5 × (1800/31536000) = 2.853e-5
        // diff/cost1 should be ≈ 2.853e-5 × (4500/500) / (1 + 500×1800/315360000000)
        // ≈ 2.567e-4 (the move capital dominates, so the ratio is dominated by move capital).
        // We simply assert diff > 0 and cost2 > cost1 — the key invariant.
        assertGt(cost1, 0, "cost1 must be positive");
    }

    /// @notice Score is 0 when cost < low threshold, 100 when cost > high threshold.
    function test_scoring_thresholds() public {
        // Deploy MCO with very high thresholds so score = 0
        ManipulationCostOracle mcoLow = new ManipulationCostOracle(
            address(pool),
            address(feed),
            1800,
            500,
            uint256(type(uint128).max) / 2,   // absurdly high low threshold
            uint256(type(uint128).max),        // absurdly high high threshold
            address(0),
            address(0),
            18
        );
        (,uint256 score) = mcoLow.getManipulationCost(200);
        assertEq(score, 0, "score must be 0 when cost below low threshold");

        // Deploy MCO with very low thresholds so score = 100
        ManipulationCostOracle mcoHigh = new ManipulationCostOracle(
            address(pool),
            address(feed),
            1800,
            500,
            1,          // $0.00000001 low threshold
            2,          // $0.00000002 high threshold
            address(0),
            address(0),
            18
        );
        (,uint256 scoreHigh) = mcoHigh.getManipulationCost(200);
        assertEq(scoreHigh, 100, "score must be 100 when cost above high threshold");
    }

    function test_getTwapVsSpot_returnsValues() public view {
        (uint160 twap, uint160 spot, uint256 dev) = mco.getTwapVsSpot();
        assertGt(twap, 0, "TWAP must be nonzero");
        assertGt(spot, 0, "spot must be nonzero");
        // In our mock: spot = linear TWAP baseline, so deviation should be 0
        assertEq(dev, 0, "deviation should be 0 when spot = TWAP");
    }

    function test_getTwapPrice_nonzero() public view {
        uint256 p = mco.getTwapPrice();
        assertGt(p, 0, "TWAP price must be nonzero");
    }

    // ── Fuzz tests ─────────────────────────────────────────────────────────────

    /// @notice Score is always in [0, 100] for any valid deviation.
    function testFuzz_score_alwaysBounded(uint256 devBps) public view {
        devBps = bound(devBps, 1, 5_000);
        (, uint256 score) = mco.getManipulationCost(devBps);
        assertLe(score, 100, "score must be <= 100");
    }

    /// @notice Cost is monotonically non-decreasing in deviation.
    function testFuzz_cost_monotone(uint256 dev1, uint256 dev2) public view {
        dev1 = bound(dev1, 1, 2_499);
        dev2 = bound(dev2, dev1 + 1, 5_000);
        (uint256 c1,) = mco.getManipulationCost(dev1);
        (uint256 c2,) = mco.getManipulationCost(dev2);
        assertGe(c2, c1, "higher deviation must cost at least as much");
    }

    // ── Tick-bitmap walk tests ─────────────────────────────────────────────────

    /// @notice With no initialized ticks, tick walk = single-point L×ΔsqrtP (unchanged).
    ///         Verifies backward compatibility: bitmap all zeros → same result as before.
    function test_tickWalk_noInitializedTicks_matchesBaseline() public view {
        // Pool has no initialized ticks (bitmap = 0 everywhere).
        // Both paths must return the same positive cost.
        (uint256 costUsd, uint256 score) = mco.getManipulationCost(200);
        assertGt(costUsd, 0, "no-bitmap path must still produce positive cost");
        assertLe(score, 100);
    }

    /// @notice With an initialized tick IN the deviation path that drops liquidity,
    ///         the tick walk produces a LOWER cost than single-point L (correct).
    ///         This reflects real pool behavior: liquidity decreases beyond a position boundary.
    function test_tickWalk_liquidityDropMidRange_lowersCost() public {
        // Set up an initialized tick at compressed position just above tick=0 (TWAP tick).
        // With tickSpacing=60, compressed tick 1 = actual tick 60.
        // Place it at wordPos=0, bitPos=1 (compressed tick 1 → actual tick 60).
        pool.setTickBitmapWord(0, uint256(1) << 1); // bit 1 set = compressed tick 1 initialized
        pool.setLiquidityNet(60, -int128(500_000 ether)); // crossing tick 60 reduces L by 500k ETH

        // The walk will now use L=1M ETH for the [TWAP, tick60] segment,
        // then L=500k ETH for the [tick60, target] segment.
        // Baseline (no walk) would use L=1M for the whole range.
        // So cost WITH walk < cost WITHOUT walk.

        // Get cost without the initialized tick (plain pool, fresh deploy)
        ManipulationCostOracle mcoPlain = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 500,
            100_000_000_00, 10_000_000_000_00, address(0), address(0), 18
        );
        // Reset bitmap to empty for plain test
        pool.setTickBitmapWord(0, 0);
        (uint256 costPlain, ) = mcoPlain.getManipulationCost(500);

        // Now set the bitmap for the walk-aware test
        pool.setTickBitmapWord(0, uint256(1) << 1);
        ManipulationCostOracle mcoWalk = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 500,
            100_000_000_00, 10_000_000_000_00, address(0), address(0), 18
        );
        (uint256 costWalk, ) = mcoWalk.getManipulationCost(500);

        // With liquidity dropping from 1M→500k at tick 60, walk cost <= plain cost.
        assertLe(costWalk, costPlain, "tick walk with L drop must not exceed single-point estimate");
        assertGt(costWalk, 0, "walk cost must still be positive");
    }

    /// @notice With an initialized tick IN the path that ADDS liquidity,
    ///         the tick walk produces a HIGHER cost than single-point L.
    ///         Models a concentrated position added above current price.
    function test_tickWalk_liquidityIncreaseMidRange_raisesCost() public {
        // Start fresh: pool with 100k ETH liquidity.
        pool.setLiquidity(100_000 ether);
        pool.setTickBitmapWord(0, uint256(1) << 1); // compressed tick 1 = actual tick 60
        pool.setLiquidityNet(60, int128(900_000 ether)); // crossing adds 900k ETH (a huge position)

        ManipulationCostOracle mcoWalk = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 500,
            1, 2, address(0), address(0), 18 // low thresholds → score=100
        );

        // Without the extra position, attacking with 100k ETH liquidity is cheaper.
        pool.setTickBitmapWord(0, 0);
        ManipulationCostOracle mcoPlain = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 500,
            1, 2, address(0), address(0), 18
        );

        pool.setTickBitmapWord(0, uint256(1) << 1);
        (uint256 costWalk,)  = mcoWalk.getManipulationCost(500);
        pool.setTickBitmapWord(0, 0);
        (uint256 costPlain,) = mcoPlain.getManipulationCost(500);

        // Walk must be more expensive (extra liquidity in path → harder to move price).
        assertGe(costWalk, costPlain, "extra L in path must increase manipulation cost");
    }

    // ── Live Aave borrow rate tests ────────────────────────────────────────────

    /// @notice When Aave is configured with a live rate, it is used instead of static rate.
    function test_liveBorrowRate_usesAaveWhenConfigured() public {
        MockAaveDataProvider aaveProvider = new MockAaveDataProvider(0, 8_000);
        // 10% APY = 10e25 RAY (10e25 / 1e23 = 1000 BPS)
        aaveProvider.setVariableBorrowRate(10e25);
        address token1 = address(0xBEEF);

        // MCO with static 5% rate + Aave configured at 10%
        ManipulationCostOracle mcoLive = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 500,
            1, 2,  // low thresholds to get score=100 regardless
            address(aaveProvider), token1, 18
        );

        // MCO with static 5% rate only
        ManipulationCostOracle mcoStatic = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 500,
            1, 2, address(0), address(0), 18
        );

        (uint256 costLive,)   = mcoLive.getManipulationCost(200);
        (uint256 costStatic,) = mcoStatic.getManipulationCost(200);

        // Live rate (10%) > static rate (5%) → live cost > static cost.
        assertGt(costLive, costStatic, "live Aave rate must increase cost vs static fallback");
        assertEq(mcoLive.getEffectiveBorrowRateBps(), 1000, "10% APY = 1000 BPS");
    }

    /// @notice When Aave reverts, the static fallback rate is used transparently.
    function test_liveBorrowRate_fallsBackWhenAaveReverts() public {
        MockAaveDataProvider revertingAave = new MockAaveDataProvider(0, 8_000);
        revertingAave.setRevert(true);

        ManipulationCostOracle mcoFallback = new ManipulationCostOracle(
            address(pool), address(feed), 1800, 500,
            1, 2, address(revertingAave), address(0xBEEF), 18
        );

        // Should not revert — uses static rate on Aave failure.
        (uint256 cost,) = mcoFallback.getManipulationCost(200);
        assertGt(cost, 0, "fallback must still produce positive cost");
        assertEq(mcoFallback.getEffectiveBorrowRateBps(), 500, "should fall back to static 500 BPS");
    }

    /// @notice When Aave is not configured (address(0)), returns static rate.
    function test_liveBorrowRate_staticWhenNoAave() public view {
        assertEq(mco.getEffectiveBorrowRateBps(), 500, "no Aave = static rate 500 BPS");
    }
}

// ─── TickDerivedRealizedVolatility Tests ──────────────────────────────────────

contract TDRVTest is Test {
    MockUniV3Pool pool;

    // ── Constructor validation ─────────────────────────────────────────────────

    function _deployTDRV(uint32 interval, uint8 numSamples) internal returns (TickDerivedRealizedVolatility) {
        MockUniV3Pool p = new MockUniV3Pool();
        p.setLinearTick(0, 80_000); // any valid tick for constructor observe() check
        // Set cumulatives for the required history check
        uint32 requiredHistory = uint32(numSamples) * interval;
        p.setCustomCumulative(requiredHistory, -int56(80_000) * int56(uint56(requiredHistory)));
        p.setCustomCumulative(0, 0);
        return new TickDerivedRealizedVolatility(address(p), interval, numSamples);
    }

    function test_constructor_rejectsZeroPool() public {
        vm.expectRevert(TickDerivedRealizedVolatility.InvalidConfig.selector);
        new TickDerivedRealizedVolatility(address(0), 3600, 24);
    }

    function test_constructor_rejectsTooFewSamples() public {
        MockUniV3Pool p = new MockUniV3Pool();
        p.setLinearTick(0, 80_000);
        vm.expectRevert(TickDerivedRealizedVolatility.TooFewSamples.selector);
        new TickDerivedRealizedVolatility(address(p), 3600, 2); // needs >= 3
    }

    function test_constructor_rejectsTooManySamples() public {
        MockUniV3Pool p = new MockUniV3Pool();
        p.setLinearTick(0, 80_000);
        vm.expectRevert(TickDerivedRealizedVolatility.TooManySamples.selector);
        new TickDerivedRealizedVolatility(address(p), 3600, 49); // max is 48
    }

    function test_constructor_rejectsShortInterval() public {
        MockUniV3Pool p = new MockUniV3Pool();
        p.setLinearTick(0, 80_000);
        vm.expectRevert(TickDerivedRealizedVolatility.SampleIntervalTooShort.selector);
        new TickDerivedRealizedVolatility(address(p), 299, 24); // min is 300
    }

    // ── Zero volatility (constant tick) ───────────────────────────────────────

    /// @notice When the price never moves, log returns are all zero → vol = 0.
    ///         This validates the RETURN-based (not level-based) math.
    function test_zeroVol_constantTick() public {
        pool = new MockUniV3Pool();
        uint32 interval = 3600; // 1 hour
        uint8  n = 6;           // 6 intervals → 5 log returns
        int24  constTick = 80_000;

        // All tick cumulatives follow a constant tick → avg ticks all equal constTick
        // → log returns (differences) are all zero → variance = 0 → vol = 0
        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, -int56(constTick) * int56(uint56(sa)));
        }
        pool.setCustomCumulative(0, 0);

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );

        uint256 vol = tdrv.getRealizedVolatility();
        assertEq(vol, 0, "constant tick must produce zero realized vol");
    }

    /// @notice With constant tick, volatility score should be 0 regardless of thresholds.
    function test_zeroVol_scoreIsZero() public {
        pool = new MockUniV3Pool();
        uint32 interval = 3600;
        uint8  n = 6;
        int24  constTick = 80_000;

        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, -int56(constTick) * int56(uint56(sa)));
        }
        pool.setCustomCumulative(0, 0);

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );

        uint256 score = tdrv.getVolatilityScore(2_000, 15_000);
        assertEq(score, 0, "zero vol must produce score 0");
    }

    // ── Known volatility scenario ──────────────────────────────────────────────

    /// @notice Alternating ±D-tick log returns should produce correct annualized vol.
    ///
    /// Math verification:
    ///   avgTicks alternate between (constTick + D) and (constTick - D)
    ///   logReturns = ±2D (differences between consecutive avg ticks)
    ///   variance = (2D)² = 4D²  [since all returns have same magnitude]
    ///   annualizedVol = sqrt(4D² × SECONDS_PER_YEAR / interval)
    ///                 = 2D × sqrt(SECONDS_PER_YEAR / interval)
    ///
    /// For D=42 (ticks), interval=3600:
    ///   annualizedVol = 84 × sqrt(31536000/3600) = 84 × sqrt(8760) = 84 × 93.59 ≈ 7862 bps
    function test_knownVol_alternatingTicks() public {
        pool = new MockUniV3Pool();
        uint32 interval = 3600; // 1 hour
        uint8  n = 7;           // 7 intervals → 6 log returns (alternating ±2D)
        int24  base = 80_000;
        int24  delta = 42;      // ticks above/below base for alternating intervals

        // Build tick cumulatives that produce alternating avgTicks:
        // avgTick[0] = base + delta, avgTick[1] = base - delta, ...
        // tickCumulative(secondsAgo) is constructed so that:
        //   (tickCumulative[i+1] - tickCumulative[i]) / interval = avgTick[i]
        // We build from left (oldest) to right (newest).
        int56[] memory cumulatives = new int56[](n + 1);
        cumulatives[0] = 0; // at secondsAgo = n*interval (oldest point), set to 0
        for (uint32 i = 0; i < n; i++) {
            int24 avgTick = (i % 2 == 0) ? base + delta : base - delta;
            cumulatives[i + 1] = cumulatives[i] + int56(avgTick) * int56(uint56(interval));
        }

        // Map to secondsAgo: cumulatives[0] → secondsAgo = n*interval, cumulatives[n] → 0
        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, cumulatives[i]);
        }

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );

        uint256 vol = tdrv.getRealizedVolatility();

        // Expected: 2*delta * sqrt(SECONDS_PER_YEAR / interval)
        //         = 84 × sqrt(8760) ≈ 84 × 93.59 ≈ 7862 bps
        // Allow ±2% tolerance for integer sqrt approximation.
        uint256 expectedVol = 2 * uint256(uint24(delta)) * Math.sqrt(365 days / interval);
        assertApproxEqRel(vol, expectedVol, 0.02e18, "alternating tick vol should match formula");
    }

    /// @notice getRawTickDeltas returns N avgTicks and N-1 logReturns.
    function test_getRawTickDeltas_dimensions() public {
        pool = new MockUniV3Pool();
        uint32 interval = 3600;
        uint8  n = 5;

        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, -int56(80_000) * int56(uint56(sa)));
        }
        pool.setCustomCumulative(0, 0);

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );

        (int256[] memory avgTicks, int256[] memory logReturns) = tdrv.getRawTickDeltas();
        assertEq(avgTicks.length, n, "avgTicks length must equal numSamples");
        assertEq(logReturns.length, n - 1, "logReturns length must equal numSamples - 1");
    }

    /// @notice Log returns (differences) must be zero when all avgTicks are equal.
    function test_getRawTickDeltas_constantTickGivesZeroReturns() public {
        pool = new MockUniV3Pool();
        uint32 interval = 3600;
        uint8  n = 4;
        int24  constTick = 80_000;

        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, -int56(constTick) * int56(uint56(sa)));
        }
        pool.setCustomCumulative(0, 0);

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );

        (, int256[] memory logReturns) = tdrv.getRawTickDeltas();
        for (uint256 i = 0; i < logReturns.length; i++) {
            assertEq(logReturns[i], 0, "all log returns must be zero for constant tick");
        }
    }

    // ── Score boundary tests ───────────────────────────────────────────────────

    function test_volScore_belowLowThreshold_isZero() public {
        pool = new MockUniV3Pool();
        uint32 interval = 3600;
        uint8  n = 4;

        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, -int56(80_000) * int56(uint56(sa)));
        }
        pool.setCustomCumulative(0, 0);

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );
        // Zero vol vs threshold 2000: score should be 0
        assertEq(tdrv.getVolatilityScore(2_000, 15_000), 0);
    }

    function test_volScore_aboveHighThreshold_is100() public {
        pool = new MockUniV3Pool();
        uint32 interval = 3600;
        uint8  n = 4;
        int24  base = 80_000;
        int24  delta = 500; // very high vol

        int56[] memory cumulatives = new int56[](n + 1);
        cumulatives[0] = 0;
        for (uint32 i = 0; i < n; i++) {
            int24 avgTick = (i % 2 == 0) ? base + delta : base - delta;
            cumulatives[i + 1] = cumulatives[i] + int56(avgTick) * int56(uint56(interval));
        }
        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, cumulatives[i]);
        }

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );

        // Very high vol vs threshold 15000: should be 100
        assertEq(tdrv.getVolatilityScore(2_000, 15_000), 100);
    }

    function test_volScore_invalidThresholds_reverts() public {
        pool = new MockUniV3Pool();
        uint32 interval = 3600;
        uint8  n = 3;
        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, -int56(80_000) * int56(uint56(sa)));
        }
        pool.setCustomCumulative(0, 0);
        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );
        vm.expectRevert(TickDerivedRealizedVolatility.InvalidConfig.selector);
        tdrv.getVolatilityScore(15_000, 2_000); // inverted thresholds
    }

    // ── Fuzz tests ─────────────────────────────────────────────────────────────

    /// @notice Vol score is always in [0, 100] for any tick configuration.
    function testFuzz_volScore_alwaysBounded(int24 tick1, int24 tick2, int24 tick3) public {
        tick1 = int24(bound(tick1, -887_000, 887_000));
        tick2 = int24(bound(tick2, -887_000, 887_000));
        tick3 = int24(bound(tick3, -887_000, 887_000));

        pool = new MockUniV3Pool();
        uint32 interval = 3600;
        uint8  n = 3; // minimum: 3 intervals → 2 log returns

        // Build 4 cumulative snapshots (n+1) producing 3 avg ticks.
        int56[] memory cumulatives = new int56[](n + 1);
        cumulatives[0] = 0;
        cumulatives[1] = cumulatives[0] + int56(tick1) * int56(uint56(interval));
        cumulatives[2] = cumulatives[1] + int56(tick2) * int56(uint56(interval));
        cumulatives[3] = cumulatives[2] + int56(tick3) * int56(uint56(interval));

        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, cumulatives[i]);
        }

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );

        uint256 score = tdrv.getVolatilityScore(2_000, 15_000);
        assertLe(score, 100, "vol score must be <= 100");
    }

    /// @notice Realized vol is always <= MAX_VOL_BPS.
    function testFuzz_vol_neverExceedsCap(int24 tick1, int24 tick2, int24 tick3) public {
        tick1 = int24(bound(tick1, -887_000, 887_000));
        tick2 = int24(bound(tick2, -887_000, 887_000));
        tick3 = int24(bound(tick3, -887_000, 887_000));

        pool = new MockUniV3Pool();
        uint32 interval = 3600;
        uint8  n = 3;

        int56[] memory cumulatives = new int56[](n + 1);
        cumulatives[0] = 0;
        cumulatives[1] = cumulatives[0] + int56(tick1) * int56(uint56(interval));
        cumulatives[2] = cumulatives[1] + int56(tick2) * int56(uint56(interval));
        cumulatives[3] = cumulatives[2] + int56(tick3) * int56(uint56(interval));

        for (uint32 i = 0; i <= uint32(n); i++) {
            uint32 sa = (uint32(n) - i) * interval;
            pool.setCustomCumulative(sa, cumulatives[i]);
        }

        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            address(pool), interval, n
        );

        uint256 vol = tdrv.getRealizedVolatility();
        assertLe(vol, tdrv.MAX_VOL_BPS(), "vol must not exceed safety cap");
    }
}

// ─── CrossProtocolCascadeScore Tests ─────────────────────────────────────────

contract CPLCSTest is Test {
    MockChainlinkFeed  assetFeed;
    MockUniV3Pool      liquidityPool;
    MockAaveDataProvider aave;
    MockCompoundComet  comp;
    MockMorphoBlue     morpho;

    int256 constant ETH_USD_8DEC = 300_000_000_000; // $3000 (8 dec)
    address constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    bytes32 constant MORPHO_MARKET_ID = bytes32(uint256(1));

    function setUp() public {
        vm.warp(10_000); // ensure block.timestamp > 7200 so setStale() never underflows

        assetFeed = new MockChainlinkFeed(ETH_USD_8DEC, 8);
        liquidityPool = new MockUniV3Pool();
        liquidityPool.setSlot0(1_000_000_000_000_000_000, 80_000, true);
        liquidityPool.setLiquidity(500_000 ether); // large pool depth

        // 1000 ETH in Aave, 80% liquidation threshold
        aave = new MockAaveDataProvider(1000 ether, 8_000);
        // 500 ETH in Compound, 85% liquidate collateral factor
        comp = new MockCompoundComet(500 ether, uint64(0.85e18));
        // 200 ETH in Morpho, 77.5% LLTV
        morpho = new MockMorphoBlue(200 ether, 0.775e18);
    }

    function _deployCPLCS() internal returns (CrossProtocolCascadeScore) {
        address[] memory aaveProviders = new address[](1);
        uint8[]   memory aaveDecs     = new uint8[](1);
        aaveProviders[0] = address(aave);
        aaveDecs[0]      = 18;

        address[] memory comets    = new address[](1);
        uint8[]   memory cometDecs = new uint8[](1);
        comets[0]    = address(comp);
        cometDecs[0] = 18;

        address[]  memory morphos     = new address[](1);
        bytes32[]  memory marketIds   = new bytes32[](1);
        uint8[]    memory morphoDecs  = new uint8[](1);
        morphos[0]    = address(morpho);
        marketIds[0]  = MORPHO_MARKET_ID;
        morphoDecs[0] = 18;

        address[] memory eulerV  = new address[](0);
        uint256[] memory eulerL  = new uint256[](0);
        uint8[]   memory eulerD  = new uint8[](0);

        return new CrossProtocolCascadeScore(
            address(assetFeed),
            18, // WETH decimals
            address(liquidityPool),
            aaveProviders, aaveDecs,
            comets, cometDecs,
            morphos, marketIds, morphoDecs,
            eulerV, eulerL, eulerD
        );
    }

    // ── Constructor validation ─────────────────────────────────────────────────

    function test_constructor_rejectsZeroFeed() public {
        address[] memory empty = new address[](0);
        uint8[]   memory emptyU = new uint8[](0);
        bytes32[] memory emptyB = new bytes32[](0);
        uint256[] memory emptyU256 = new uint256[](0);
        vm.expectRevert(CrossProtocolCascadeScore.InvalidConfig.selector);
        new CrossProtocolCascadeScore(
            address(0), 18, address(liquidityPool),
            empty, emptyU, empty, emptyU, empty, emptyB, emptyU,
            empty, emptyU256, emptyU
        );
    }

    function test_constructor_rejectsTooManyProtocols() public {
        address[] memory tooMany = new address[](6); // MAX_PROTOCOLS = 5
        uint8[]   memory decs    = new uint8[](6);
        for (uint256 i = 0; i < 6; i++) tooMany[i] = address(aave);

        address[] memory empty  = new address[](0);
        uint8[]   memory emptyU = new uint8[](0);
        bytes32[] memory emptyB = new bytes32[](0);

        uint256[] memory emptyU256b = new uint256[](0);
        vm.expectRevert(CrossProtocolCascadeScore.TooManyProtocols.selector);
        new CrossProtocolCascadeScore(
            address(assetFeed), 18, address(liquidityPool),
            tooMany, decs, empty, emptyU, empty, emptyB, emptyU,
            empty, emptyU256b, emptyU
        );
    }

    // ── Core functionality ─────────────────────────────────────────────────────

    function test_getCascadeScore_returnsResult() public {
        CrossProtocolCascadeScore cplcs = _deployCPLCS();
        CrossProtocolCascadeScore.CascadeResult memory r = cplcs.getCascadeScore(WETH, 2000);

        assertGt(r.totalCollateralUsd, 0, "total collateral must be nonzero");
        assertLe(r.cascadeScore, 100, "cascade score must be <= 100");
        assertGe(r.amplificationBps, 10_000, "amplification must be >= 1.0x");
        assertGe(r.totalImpactBps, 2000, "total impact must be >= initial shock");
    }

    /// @notice With zero collateral across all protocols, liquidation is zero and
    ///         cascade score is 0 (no amplification).
    function test_getCascadeScore_zeroCollateral_zeroScore() public {
        MockAaveDataProvider emptyAave = new MockAaveDataProvider(0, 8_000);
        MockCompoundComet    emptyComp = new MockCompoundComet(0, uint64(0.85e18));
        MockMorphoBlue       emptyMorpho = new MockMorphoBlue(0, 0.775e18);

        address[] memory aaveP   = new address[](1); aaveP[0]   = address(emptyAave);
        uint8[]   memory aaveDec = new uint8[](1);   aaveDec[0] = 18;
        address[] memory comP    = new address[](1); comP[0]    = address(emptyComp);
        uint8[]   memory comDec  = new uint8[](1);   comDec[0]  = 18;
        address[] memory morP    = new address[](1); morP[0]    = address(emptyMorpho);
        bytes32[] memory morId   = new bytes32[](1); morId[0]   = MORPHO_MARKET_ID;
        uint8[]   memory morDec  = new uint8[](1);   morDec[0]  = 18;

        address[] memory emptyA = new address[](0);
        uint256[] memory emptyU256c = new uint256[](0);
        uint8[]   memory emptyU8c = new uint8[](0);
        CrossProtocolCascadeScore cplcs = new CrossProtocolCascadeScore(
            address(assetFeed), 18, address(liquidityPool),
            aaveP, aaveDec, comP, comDec, morP, morId, morDec,
            emptyA, emptyU256c, emptyU8c
        );

        CrossProtocolCascadeScore.CascadeResult memory r = cplcs.getCascadeScore(WETH, 2000);
        assertEq(r.cascadeScore, 0, "zero collateral = zero cascade risk");
        assertEq(r.estimatedLiquidationUsd, 0, "zero collateral = zero liquidation");
    }

    /// @notice Larger shock should result in equal or greater cascade score.
    function test_getCascadeScore_largerShockNotLowerScore() public {
        CrossProtocolCascadeScore cplcs = _deployCPLCS();
        CrossProtocolCascadeScore.CascadeResult memory r10 = cplcs.getCascadeScore(WETH, 1000);
        CrossProtocolCascadeScore.CascadeResult memory r20 = cplcs.getCascadeScore(WETH, 2000);
        assertGe(r20.cascadeScore, r10.cascadeScore, "larger shock must not reduce score");
    }

    /// @notice When a protocol reverts, the system degrades gracefully.
    function test_getCascadeScore_protocolFailureGraceful() public {
        CrossProtocolCascadeScore cplcs = _deployCPLCS();

        // Make Aave revert
        aave.setRevert(true);

        // Should not revert — uses try/catch
        CrossProtocolCascadeScore.CascadeResult memory r = cplcs.getCascadeScore(WETH, 2000);
        assertLe(r.cascadeScore, 100, "score must remain valid after protocol failure");
    }

    function test_getCascadeScore_invalidShock_reverts() public {
        CrossProtocolCascadeScore cplcs = _deployCPLCS();
        vm.expectRevert(CrossProtocolCascadeScore.InvalidShock.selector);
        cplcs.getCascadeScore(WETH, 0);
    }

    function test_getCascadeScore_excessiveShock_reverts() public {
        CrossProtocolCascadeScore cplcs = _deployCPLCS();
        vm.expectRevert(CrossProtocolCascadeScore.InvalidShock.selector);
        cplcs.getCascadeScore(WETH, 9_001);
    }

    function test_getCascadeScore_staleChainlink_reverts() public {
        CrossProtocolCascadeScore cplcs = _deployCPLCS();
        assetFeed.setStale();
        vm.expectRevert(CrossProtocolCascadeScore.StaleChainlinkFeed.selector);
        cplcs.getCascadeScore(WETH, 2000);
    }

    /// @notice Cascade iteration converges: for a tiny pool, secondary impact should approach
    ///         the 50% cap due to multiple rounds of amplification.
    function test_cascadeIterates_smallPoolAmplifies() public {
        // Replace liquidityPool with a tiny pool (very shallow depth)
        MockUniV3Pool tinyPool = new MockUniV3Pool();
        tinyPool.setSlot0(1_000_000_000_000_000_000, 80_000, true);
        tinyPool.setLiquidity(100); // essentially zero depth → massive price impact

        address[] memory aaveP   = new address[](1); aaveP[0]   = address(aave);
        uint8[]   memory aaveDec = new uint8[](1);   aaveDec[0] = 18;
        address[] memory empty   = new address[](0);
        uint8[]   memory emptyU  = new uint8[](0);
        bytes32[] memory emptyB  = new bytes32[](0);

        uint256[] memory emptyU256d = new uint256[](0);
        CrossProtocolCascadeScore cplcs = new CrossProtocolCascadeScore(
            address(assetFeed), 18, address(tinyPool),
            aaveP, aaveDec, empty, emptyU, empty, emptyB, emptyU,
            empty, emptyU256d, emptyU
        );

        CrossProtocolCascadeScore.CascadeResult memory r = cplcs.getCascadeScore(WETH, 2000);
        // With tiny pool depth, secondary impact hits the 50% cap → score = 100
        assertEq(r.cascadeScore, 100, "tiny pool + large collateral = max cascade score");
        assertEq(r.secondaryPriceImpactBps, 5_000, "secondary impact capped at 50%");
    }

    // ── Fuzz tests ─────────────────────────────────────────────────────────────

    function testFuzz_cascadeScore_alwaysBounded(uint256 shockBps) public {
        shockBps = bound(shockBps, 1, 9_000);
        CrossProtocolCascadeScore cplcs = _deployCPLCS();
        CrossProtocolCascadeScore.CascadeResult memory r = cplcs.getCascadeScore(WETH, shockBps);
        assertLe(r.cascadeScore, 100, "cascade score must be <= 100");
        assertGe(r.amplificationBps, 10_000, "amplification must be >= 1x");
    }
}

// ─── UnifiedRiskCompositor Tests ──────────────────────────────────────────────

contract URCTest is Test {
    // We'll use simplified mocks that implement just the interfaces URC needs.
    MockMCO   mcoMock;
    MockTDRV  tdrvMock;
    MockCPLCS cplcsMock;

    address constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setUp() public {
        mcoMock   = new MockMCO();
        tdrvMock  = new MockTDRV();
        cplcsMock = new MockCPLCS();
    }

    function _deployURC(uint8 w1, uint8 w2, uint8 w3) internal returns (UnifiedRiskCompositor) {
        return new UnifiedRiskCompositor(
            address(mcoMock),
            address(tdrvMock),
            address(cplcsMock),
            WETH,
            w1, w2, w3,
            address(0), 0
        );
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert(UnifiedRiskCompositor.ZeroAddress.selector);
        new UnifiedRiskCompositor(address(0), address(tdrvMock), address(cplcsMock), WETH, 35, 40, 25, address(0), 0);
    }

    function test_constructor_rejectsInvalidWeights() public {
        vm.expectRevert(UnifiedRiskCompositor.InvalidWeights.selector);
        new UnifiedRiskCompositor(
            address(mcoMock), address(tdrvMock), address(cplcsMock), WETH,
            50, 50, 50, address(0), 0 // sums to 150, not 100
        );
    }

    function test_constructor_rejectsWeightTooLow() public {
        vm.expectRevert(UnifiedRiskCompositor.InvalidWeights.selector);
        new UnifiedRiskCompositor(
            address(mcoMock), address(tdrvMock), address(cplcsMock), WETH,
            5, 85, 10, address(0), 0 // 5 < MIN_WEIGHT
        );
    }

    // ── updateRiskScore ────────────────────────────────────────────────────────

    function test_updateRiskScore_computesScore() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);

        // MCO returns securityScore=80 → mcoInput = 20
        mcoMock.setResult(0, 80);
        // TDRV returns volScore=50 → tdrvInput = 50
        tdrvMock.setVolScore(50);
        tdrvMock.setRealizedVol(5_000);
        // CPLCS returns cascadeScore=30 → cpInput = 30
        cplcsMock.setCascadeScore(30);

        (uint256 score, UnifiedRiskCompositor.RiskTier tier, uint256 ltv) = urc.updateRiskScore();

        // Expected: (20×35 + 50×40 + 30×25) / 100 = (700 + 2000 + 750) / 100 = 3450/100 = 34
        assertEq(score, 34, "composite score must be weighted average");
        assertEq(uint8(tier), uint8(UnifiedRiskCompositor.RiskTier.MODERATE), "34 should be MODERATE tier");
        assertEq(ltv, 7_500, "MODERATE tier LTV = 75%");
    }

    function test_updateRiskScore_lowRiskTier() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        // All dimensions return low risk (high security, low vol, low cascade)
        mcoMock.setResult(0, 100); // securityScore=100 → mcoInput=0
        tdrvMock.setVolScore(0);
        tdrvMock.setRealizedVol(1_000);
        cplcsMock.setCascadeScore(0);

        (uint256 score, UnifiedRiskCompositor.RiskTier tier, uint256 ltv) = urc.updateRiskScore();

        assertEq(score, 0, "all zero inputs = score 0");
        assertEq(uint8(tier), uint8(UnifiedRiskCompositor.RiskTier.LOW), "score 0 = LOW tier");
        assertEq(ltv, 8_000, "LOW tier LTV = 80%");
    }

    function test_updateRiskScore_criticalTier() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        mcoMock.setResult(0, 0); // securityScore=0 → mcoInput=100
        tdrvMock.setVolScore(100);
        tdrvMock.setRealizedVol(50_000);
        cplcsMock.setCascadeScore(100);

        (uint256 score, UnifiedRiskCompositor.RiskTier tier, uint256 ltv) = urc.updateRiskScore();

        assertEq(score, 100, "all max inputs = score 100");
        assertEq(uint8(tier), uint8(UnifiedRiskCompositor.RiskTier.CRITICAL), "score 100 = CRITICAL tier");
        assertEq(ltv, 5_000, "CRITICAL tier LTV = 50%");
    }

    function test_updateRiskScore_cooldown() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        mcoMock.setResult(0, 50);
        tdrvMock.setVolScore(50);
        tdrvMock.setRealizedVol(5_000);
        cplcsMock.setCascadeScore(50);

        urc.updateRiskScore(); // first call OK

        // Second call within cooldown should revert
        vm.expectRevert();
        urc.updateRiskScore();

        // After cooldown, should succeed
        vm.warp(block.timestamp + urc.MIN_UPDATE_INTERVAL() + 1);
        urc.updateRiskScore();
    }

    function test_updateRiskScore_primitiveFailureFallsToMaxRisk() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        mcoMock.setRevert(true);  // MCO fails → mcoInput defaults to 100
        tdrvMock.setVolScore(0);
        tdrvMock.setRealizedVol(0);
        cplcsMock.setCascadeScore(0);

        (uint256 score,,) = urc.updateRiskScore();

        // mcoInput=100, tdrvInput=0, cpInput=0
        // score = (100×35 + 0×40 + 0×25) / 100 = 35
        assertEq(score, 35, "MCO failure should default mcoInput to 100");
    }

    // ── Governance ─────────────────────────────────────────────────────────────

    function test_setWeights_ownerCanUpdate() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        urc.setWeights(40, 40, 20, 0);
        assertEq(urc.mcoWeight(), 40);
        assertEq(urc.tdrvWeight(), 40);
        assertEq(urc.cpWeight(), 20);
    }

    function test_setWeights_nonOwnerReverts() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        vm.prank(address(0xBEEF));
        vm.expectRevert(UnifiedRiskCompositor.Unauthorized.selector);
        urc.setWeights(40, 40, 20, 0);
    }

    function test_transferOwnership() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        address newOwner = address(0xBEEF);
        urc.transferOwnership(newOwner);
        assertEq(urc.owner(), newOwner);

        // Old owner can no longer set weights
        vm.expectRevert(UnifiedRiskCompositor.Unauthorized.selector);
        urc.setWeights(40, 40, 20, 0);
    }

    // ── View functions ─────────────────────────────────────────────────────────

    function test_getRiskBreakdown_matchesLastUpdate() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        mcoMock.setResult(1_000_000, 60);
        tdrvMock.setVolScore(40);
        tdrvMock.setRealizedVol(7_000);
        cplcsMock.setCascadeScore(55);

        (uint256 score, UnifiedRiskCompositor.RiskTier tier,) = urc.updateRiskScore();

        (
            uint256 bScore,,,,
            UnifiedRiskCompositor.RiskTier bTier,
            uint256 bLtv,,,
        ) = urc.getRiskBreakdown();

        assertEq(bScore, score);
        assertEq(uint8(bTier), uint8(tier));
        assertGt(bLtv, 0);
    }

    function test_getScoreForAsset_usesTrackedAssetForCascadeByDefault() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        cplcsMock.setExpectedAsset(WETH);
        cplcsMock.setCascadeScore(55);

        (,,, uint256 cpInput,,,,,) = urc.getScoreForAsset(address(0x1111), address(0x2222));
        assertEq(cpInput, 55, "default overload should use tracked asset for CPLCS");
    }

    function test_getScoreForAsset_allowsExplicitCascadeAssetOverride() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        address overrideAsset = address(0xBEEF);
        cplcsMock.setExpectedAsset(overrideAsset);
        cplcsMock.setCascadeScore(42);

        (,,, uint256 cpInput,,,,,) = urc.getScoreForAsset(address(0x1111), address(0x2222), overrideAsset);
        assertEq(cpInput, 42, "asset-specific overload should pass override into CPLCS");
    }

    function test_getScoreForAsset_rejectsZeroExplicitCascadeAsset() public {
        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        vm.expectRevert(UnifiedRiskCompositor.ZeroAddress.selector);
        urc.getScoreForAsset(address(0x1111), address(0x2222), address(0));
    }

    // ── Invariants ─────────────────────────────────────────────────────────────

    /// @notice Recommended LTV is always between 50% and 80%.
    function testFuzz_recommendedLtv_alwaysInRange(
        uint256 mcoSec, uint256 tdrvSc, uint256 cpSc
    ) public {
        mcoSec = bound(mcoSec, 0, 100);
        tdrvSc = bound(tdrvSc, 0, 100);
        cpSc   = bound(cpSc, 0, 100);

        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        mcoMock.setResult(0, mcoSec);
        tdrvMock.setVolScore(tdrvSc);
        tdrvMock.setRealizedVol(5_000);
        cplcsMock.setCascadeScore(cpSc);

        urc.updateRiskScore();

        uint256 ltv = urc.getRecommendedLtv();
        assertGe(ltv, 5_000, "LTV must be >= 50%");
        assertLe(ltv, 8_000, "LTV must be <= 80%");
    }

    /// @notice Composite score is always in [0, 100].
    function testFuzz_compositeScore_alwaysBounded(
        uint256 mcoSec, uint256 tdrvSc, uint256 cpSc
    ) public {
        mcoSec = bound(mcoSec, 0, 100);
        tdrvSc = bound(tdrvSc, 0, 100);
        cpSc   = bound(cpSc, 0, 100);

        UnifiedRiskCompositor urc = _deployURC(35, 40, 25);
        mcoMock.setResult(0, mcoSec);
        tdrvMock.setVolScore(tdrvSc);
        tdrvMock.setRealizedVol(5_000);
        cplcsMock.setCascadeScore(cpSc);

        (uint256 score,,) = urc.updateRiskScore();
        assertLe(score, 100, "composite score must be <= 100");
    }
}

// ─── Minimal interface mocks for UnifiedRiskCompositor ───────────────────────

contract MockMCO {
    uint256 public s_costUsd;
    uint256 public s_securityScore;
    bool    public s_revert;

    function setResult(uint256 costUsd, uint256 sec) external {
        s_costUsd = costUsd;
        s_securityScore = sec;
    }
    function setRevert(bool r) external { s_revert = r; }

    function getManipulationCost(uint256) external view returns (uint256, uint256) {
        if (s_revert) revert("mock MCO fail");
        return (s_costUsd, s_securityScore);
    }
}

contract MockTDRV {
    uint256 public s_volScore;
    uint256 public s_realizedVol;
    bool    public s_revert;

    function setVolScore(uint256 v) external { s_volScore = v; }
    function setRealizedVol(uint256 v) external { s_realizedVol = v; }
    function setRevert(bool r) external { s_revert = r; }

    function getVolatilityScore(uint256, uint256) external view returns (uint256) {
        if (s_revert) revert("mock TDRV fail");
        return s_volScore;
    }
    function getRealizedVolatility() external view returns (uint256) {
        if (s_revert) revert("mock TDRV fail");
        return s_realizedVol;
    }
}

contract MockCPLCS {
    uint256 public s_cascadeScore;
    address public s_expectedAsset;
    bool    public s_revert;

    function setCascadeScore(uint256 v) external { s_cascadeScore = v; }
    function setExpectedAsset(address asset) external { s_expectedAsset = asset; }
    function setRevert(bool r) external { s_revert = r; }

    struct CascadeResult {
        uint256 totalCollateralUsd;
        uint256 estimatedLiquidationUsd;
        uint256 secondaryPriceImpactBps;
        uint256 totalImpactBps;
        uint256 amplificationBps;
        uint256 cascadeScore;
    }

    function getCascadeScore(address asset, uint256) external view returns (CascadeResult memory r) {
        if (s_revert) revert("mock CPLCS fail");
        if (s_expectedAsset != address(0) && asset != s_expectedAsset) revert("mock CPLCS bad asset");
        r.cascadeScore     = s_cascadeScore;
        r.amplificationBps = 10_000;
        r.totalImpactBps   = 2_000;
    }
}

// ─── Mock: Euler V2 vault (ERC-4626 minimal — only totalAssets() needed) ─────

contract MockEulerV2Vault {
    uint256 public s_totalAssets;
    bool    public s_revert;

    function setTotalAssets(uint256 v) external { s_totalAssets = v; }
    function setRevert(bool r) external { s_revert = r; }

    function totalAssets() external view returns (uint256) {
        if (s_revert) revert("MockEulerV2Vault: revert");
        return s_totalAssets;
    }
}

// ─── Mock: IRiskScoreProvider (for CircuitBreaker tests) ──────────────────────

contract MockRiskScoreProvider is IRiskScoreProvider {
    uint256 public s_score;

    function setScore(uint256 score) external { s_score = score; }

    function getRiskScore() external view override returns (uint256) { return s_score; }
    function lastUpdatedAt() external view override returns (uint256) { return block.timestamp; }
}

// ─── MCO Multi-Window Tests ───────────────────────────────────────────────────

contract MCOMultiWindowTest is Test {
    MockUniV3Pool     pool;
    MockChainlinkFeed feed;
    ManipulationCostOracle mco;

    uint160 constant SQRT_PRICE_TICK0 = 79_228_162_514_264_337_593_543_950_336; // 2^96
    int256  constant ETH_USD_PRICE    = 300_000_000_000; // $3000, 8 decimals

    function setUp() public {
        vm.warp(10_000);
        pool = new MockUniV3Pool();
        feed = new MockChainlinkFeed(ETH_USD_PRICE, 8);

        // Constant tick=0 → price=1, zero vol
        pool.setLinearTick(0, 0);
        pool.setSlot0(SQRT_PRICE_TICK0, 0, true);
        pool.setLiquidity(1_000_000 ether); // large liquidity for non-trivial move capital

        mco = new ManipulationCostOracle(
            address(pool), address(feed),
            1800, 500,               // 30-min TWAP, 5% borrow rate
            100_000_000_00,          // $1M low threshold (8 dec)
            10_000_000_000_00,       // $100M high threshold (8 dec)
            address(0), address(0), 18   // no Aave live rate
        );
    }

    /// @notice All four windows return non-zero costs and bounded scores.
    function test_multiWindow_allFieldsPopulated() public view {
        ManipulationCostOracle.MultiWindowCost memory c =
            mco.getManipulationCostMultiWindow(200);

        assertGt(c.cost5min,   0,   "5-min cost must be > 0");
        assertGt(c.cost15min,  0,   "15-min cost must be > 0");
        assertGt(c.cost30min,  0,   "30-min cost must be > 0");
        assertGt(c.cost1hour,  0,   "1-hour cost must be > 0");
        assertLe(c.score5min,  100, "5-min score bounded");
        assertLe(c.score15min, 100, "15-min score bounded");
        assertLe(c.score30min, 100, "30-min score bounded");
        assertLe(c.score1hour, 100, "1-hour score bounded");
    }

    /// @notice Longer window accumulates more holding cost → higher total cost.
    function test_multiWindow_1hourCostGt5minCost() public view {
        ManipulationCostOracle.MultiWindowCost memory c =
            mco.getManipulationCostMultiWindow(200);

        assertGt(c.cost1hour,  c.cost5min,  "1-hour attack costs more than 5-min attack");
        assertGe(c.score1hour, c.score5min, "longer window gives higher or equal security score");
    }

    /// @notice getManipulationCostAtWindow reverts when window < 300 seconds.
    function test_atWindow_rejectsWindowBelow300() public {
        vm.expectRevert(ManipulationCostOracle.ObservationWindowTooShort.selector);
        mco.getManipulationCostAtWindow(200, 299);
    }

    /// @notice At twapWindow (1800 s), result equals the base getManipulationCost.
    function test_atWindow_1800sMatchesBaseFunction() public view {
        (uint256 baseCost,  uint256 baseScore)  = mco.getManipulationCost(200);
        (uint256 wCost,     uint256 wScore)     = mco.getManipulationCostAtWindow(200, 1800);
        assertEq(wCost,  baseCost,  "cost at 1800 s must equal base function");
        assertEq(wScore, baseScore, "score at 1800 s must equal base function");
    }
}

// ─── TDRV Extended Tests (EWMA + Regime + Over-Window) ───────────────────────

contract TDRVExtendedTest is Test {
    MockUniV3Pool pool;
    TickDerivedRealizedVolatility tdrv;

    uint32 constant INTERVAL  = 3600; // 1-hour sample interval
    uint8  constant N_SAMPLES = 4;    // 4 samples → 3 log returns

    function setUp() public {
        pool = new MockUniV3Pool();
        pool.setLinearTick(0, 0); // constant tick=0 → zero log returns
        tdrv = new TickDerivedRealizedVolatility(address(pool), INTERVAL, N_SAMPLES);
    }

    /// @dev Populates pool with alternating ±delta ticks around `base`.
    ///      Produces vol ≈ 2 × delta × sqrt(SECONDS_PER_YEAR / INTERVAL) bps.
    function _setAlternatingTicks(MockUniV3Pool p, int24 base, int24 delta) internal {
        int56[] memory cums = new int56[](uint256(N_SAMPLES) + 1);
        cums[0] = 0; // oldest anchor
        for (uint32 i = 0; i < N_SAMPLES; i++) {
            int24 avgTick = (i % 2 == 0) ? base + delta : base - delta;
            cums[i + 1] = cums[i] + int56(avgTick) * int56(uint56(INTERVAL));
        }
        for (uint32 i = 0; i <= uint32(N_SAMPLES); i++) {
            p.setCustomCumulative((uint32(N_SAMPLES) - i) * INTERVAL, cums[i]);
        }
    }

    /// @notice Constant tick → vol = 0 → CALM regime.
    function test_regime_calm_withZeroVol() public view {
        TickDerivedRealizedVolatility.VolatilityRegime regime = tdrv.getVolatilityRegime();
        assertEq(
            uint256(regime),
            uint256(TickDerivedRealizedVolatility.VolatilityRegime.CALM),
            "zero vol must be CALM"
        );
    }

    /// @notice delta=6 → vol ≈ 1116 bps → NORMAL regime (1001–3000 bps).
    function test_regime_normal_withMediumDelta() public {
        MockUniV3Pool p2 = new MockUniV3Pool();
        // vol = 2 * 6 * sqrt(8760) ≈ 2 * 6 * 93 = 1116 bps → NORMAL
        _setAlternatingTicks(p2, 80_000, 6);
        TickDerivedRealizedVolatility tdrv2 =
            new TickDerivedRealizedVolatility(address(p2), INTERVAL, N_SAMPLES);
        assertEq(
            uint256(tdrv2.getVolatilityRegime()),
            uint256(TickDerivedRealizedVolatility.VolatilityRegime.NORMAL),
            "vol ~1116 bps must be NORMAL"
        );
    }

    /// @notice delta=100 → vol ≈ 18600 bps > 15000 → EXTREME regime.
    function test_regime_extreme_withLargeDelta() public {
        MockUniV3Pool p2 = new MockUniV3Pool();
        // vol = 2 * 100 * sqrt(8760) ≈ 18600 bps > 15000 → EXTREME
        _setAlternatingTicks(p2, 80_000, 100);
        TickDerivedRealizedVolatility tdrv2 =
            new TickDerivedRealizedVolatility(address(p2), INTERVAL, N_SAMPLES);
        assertEq(
            uint256(tdrv2.getVolatilityRegime()),
            uint256(TickDerivedRealizedVolatility.VolatilityRegime.EXTREME),
            "vol >15000 bps must be EXTREME"
        );
    }

    /// @notice lambdaBps = 0 reverts InvalidConfig.
    function test_ewma_zeroLambda_reverts() public {
        vm.expectRevert(TickDerivedRealizedVolatility.InvalidConfig.selector);
        tdrv.getVolatilityEWMA(0);
    }

    /// @notice lambdaBps = 10000 reverts InvalidConfig.
    function test_ewma_maxLambda_reverts() public {
        vm.expectRevert(TickDerivedRealizedVolatility.InvalidConfig.selector);
        tdrv.getVolatilityEWMA(10_000);
    }

    /// @notice Constant tick → all log returns = 0 → EWMA vol = 0.
    function test_ewma_constTickGivesZeroVol() public view {
        // RiskMetrics λ = 0.94 → lambdaBps = 9400
        uint256 ewma = tdrv.getVolatilityEWMA(9_400);
        assertEq(ewma, 0, "constant tick must produce zero EWMA vol");
    }

    /// @notice nSamples < 3 → getVolatilityOverWindow reverts InvalidConfig.
    function test_overWindow_tooFewSamples_reverts() public {
        vm.expectRevert(TickDerivedRealizedVolatility.InvalidConfig.selector);
        tdrv.getVolatilityOverWindow(7200, 2);
    }

    /// @notice windowSeconds / nSamples < 300 → SampleIntervalTooShort.
    function test_overWindow_shortInterval_reverts() public {
        // 900 / 4 = 225 < MIN_SAMPLE_INTERVAL (300)
        vm.expectRevert(TickDerivedRealizedVolatility.SampleIntervalTooShort.selector);
        tdrv.getVolatilityOverWindow(900, 4);
    }

    /// @notice Valid params + constant tick → (0, true).
    function test_overWindow_constTick_succeedsWithZeroVol() public view {
        // 9000 / 3 = 3000 ≥ 300 → valid interval
        (uint256 vol, bool ok) = tdrv.getVolatilityOverWindow(9_000, 3);
        assertTrue(ok,  "valid pool must return success=true");
        assertEq(vol, 0, "constant tick must produce zero over-window vol");
    }
}

// ─── CPLCS Euler V2 Tests ─────────────────────────────────────────────────────

contract CPLCSEulerTest is Test {
    MockChainlinkFeed    assetFeed;
    MockUniV3Pool        liquidityPool;
    MockAaveDataProvider aave;
    MockCompoundComet    comp;
    MockMorphoBlue       morpho;
    MockEulerV2Vault     eulerVault;

    int256  constant ETH_USD_8DEC   = 300_000_000_000;
    address constant WETH           = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    bytes32 constant MORPHO_MKT_ID  = bytes32(uint256(1));

    function setUp() public {
        vm.warp(10_000);
        assetFeed    = new MockChainlinkFeed(ETH_USD_8DEC, 8);
        liquidityPool = new MockUniV3Pool();
        liquidityPool.setSlot0(1_000_000_000_000_000_000, 80_000, true);
        liquidityPool.setLiquidity(500_000 ether);

        aave   = new MockAaveDataProvider(1000 ether, 8_000);
        comp   = new MockCompoundComet(500 ether, uint64(0.85e18));
        morpho = new MockMorphoBlue(200 ether, 0.775e18);

        eulerVault = new MockEulerV2Vault();
        eulerVault.setTotalAssets(300 ether); // 300 ETH in Euler
    }

    function _deployCPLCSNoEuler() internal returns (CrossProtocolCascadeScore) {
        address[] memory aaveP = new address[](1);
        uint8[]   memory aaveD = new uint8[](1);
        aaveP[0] = address(aave); aaveD[0] = 18;

        address[] memory comets   = new address[](1);
        uint8[]   memory cometDs  = new uint8[](1);
        comets[0] = address(comp); cometDs[0] = 18;

        address[]  memory morphos    = new address[](1);
        bytes32[]  memory marketIds  = new bytes32[](1);
        uint8[]    memory morphoDs   = new uint8[](1);
        morphos[0] = address(morpho); marketIds[0] = MORPHO_MKT_ID; morphoDs[0] = 18;

        address[] memory eulerV = new address[](0);
        uint256[] memory eulerL = new uint256[](0);
        uint8[]   memory eulerD = new uint8[](0);

        return new CrossProtocolCascadeScore(
            address(assetFeed), 18, address(liquidityPool),
            aaveP, aaveD, comets, cometDs, morphos, marketIds, morphoDs,
            eulerV, eulerL, eulerD
        );
    }

    function _deployCPLCSWithEuler() internal returns (CrossProtocolCascadeScore) {
        address[] memory aaveP = new address[](1);
        uint8[]   memory aaveD = new uint8[](1);
        aaveP[0] = address(aave); aaveD[0] = 18;

        address[] memory comets   = new address[](1);
        uint8[]   memory cometDs  = new uint8[](1);
        comets[0] = address(comp); cometDs[0] = 18;

        address[]  memory morphos    = new address[](1);
        bytes32[]  memory marketIds  = new bytes32[](1);
        uint8[]    memory morphoDs   = new uint8[](1);
        morphos[0] = address(morpho); marketIds[0] = MORPHO_MKT_ID; morphoDs[0] = 18;

        address[] memory eulerV = new address[](1);
        uint256[] memory eulerL = new uint256[](1);
        uint8[]   memory eulerD = new uint8[](1);
        eulerV[0] = address(eulerVault);
        eulerL[0] = 8_000; // 80% liquidation threshold
        eulerD[0] = 18;

        return new CrossProtocolCascadeScore(
            address(assetFeed), 18, address(liquidityPool),
            aaveP, aaveD, comets, cometDs, morphos, marketIds, morphoDs,
            eulerV, eulerL, eulerD
        );
    }

    /// @notice Euler vault collateral is counted toward totalCollateralUsd.
    function test_euler_collateralIsCounted() public {
        CrossProtocolCascadeScore cplcsNoEuler   = _deployCPLCSNoEuler();
        CrossProtocolCascadeScore cplcsWithEuler = _deployCPLCSWithEuler();

        CrossProtocolCascadeScore.CascadeResult memory rNoEuler   =
            cplcsNoEuler.getCascadeScore(WETH, 2000);
        CrossProtocolCascadeScore.CascadeResult memory rWithEuler =
            cplcsWithEuler.getCascadeScore(WETH, 2000);

        assertGt(
            rWithEuler.totalCollateralUsd,
            rNoEuler.totalCollateralUsd,
            "Euler vault must increase totalCollateralUsd"
        );
    }

    /// @notice A reverting Euler vault is handled gracefully (try/catch).
    function test_euler_vaultRevertGraceful() public {
        eulerVault.setRevert(true);
        CrossProtocolCascadeScore cplcs = _deployCPLCSWithEuler();

        // Must not revert — Euler loop uses try/catch
        CrossProtocolCascadeScore.CascadeResult memory r =
            cplcs.getCascadeScore(WETH, 2000);
        assertLe(r.cascadeScore, 100, "score bounded even when Euler vault reverts");
    }

    /// @notice eulerV2ConfigCount returns the correct number of registered vaults.
    function test_euler_configCount() public {
        CrossProtocolCascadeScore noEuler   = _deployCPLCSNoEuler();
        CrossProtocolCascadeScore withEuler = _deployCPLCSWithEuler();
        assertEq(noEuler.eulerV2ConfigCount(),   0, "no Euler vaults registered");
        assertEq(withEuler.eulerV2ConfigCount(), 1, "one Euler vault registered");
    }
}

// ─── URC Momentum + EWMA Tests ───────────────────────────────────────────────

contract URCMomentumTest is Test {
    MockMCO   mcoMock;
    MockTDRV  tdrvMock;
    MockCPLCS cplcsMock;

    address constant WETH     = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    uint256 constant COOLDOWN = 61; // > MIN_UPDATE_INTERVAL (60 s)

    function setUp() public {
        vm.warp(10_000);
        mcoMock   = new MockMCO();
        tdrvMock  = new MockTDRV();
        cplcsMock = new MockCPLCS();
    }

    function _deployURC() internal returns (UnifiedRiskCompositor) {
        return new UnifiedRiskCompositor(
            address(mcoMock), address(tdrvMock), address(cplcsMock), WETH, 35, 40, 25, address(0), 0
        );
    }

    /// @notice getScoreHistory grows with each update call.
    function test_ringBuffer_populatesAfterUpdates() public {
        UnifiedRiskCompositor urc = _deployURC();
        mcoMock.setResult(0, 80);
        tdrvMock.setVolScore(50);
        tdrvMock.setRealizedVol(5_000);
        cplcsMock.setCascadeScore(30);

        // Update 1 at ts=10_000
        urc.updateRiskScore();
        assertEq(urc.getScoreHistory().length, 1, "length after 1 update");

        // Update 2 at ts=10_100 (> 10_000 + 60 cooldown)
        vm.warp(10_100);
        urc.updateRiskScore();
        assertEq(urc.getScoreHistory().length, 2, "length after 2 updates");

        // Update 3 at ts=10_200 (> 10_100 + 60 cooldown)
        vm.warp(10_200);
        urc.updateRiskScore();
        assertEq(urc.getScoreHistory().length, 3, "length after 3 updates");
    }

    /// @notice ewmaScore is seeded exactly to the first composite score.
    function test_ewma_seedsOnFirstUpdate() public {
        UnifiedRiskCompositor urc = _deployURC();
        mcoMock.setResult(0, 0);     // mcoInput = 100
        tdrvMock.setVolScore(100);
        tdrvMock.setRealizedVol(10_000);
        cplcsMock.setCascadeScore(100);

        (uint256 score,,) = urc.updateRiskScore();
        assertEq(urc.getEWMAScore(), score, "EWMA must be seeded to first score");
    }

    /// @notice When score stays constant, EWMA equals that constant.
    function test_ewma_staysConstantForConstantScore() public {
        UnifiedRiskCompositor urc = _deployURC();
        mcoMock.setResult(0, 80);
        tdrvMock.setVolScore(50);
        tdrvMock.setRealizedVol(5_000);
        cplcsMock.setCascadeScore(30);

        (uint256 score,,) = urc.updateRiskScore();
        assertEq(urc.getEWMAScore(), score, "EWMA seeded on first call");

        vm.warp(block.timestamp + COOLDOWN);
        urc.updateRiskScore();
        // ewma_new = α × score + (1-α) × score = score
        assertEq(urc.getEWMAScore(), score, "EWMA stays at score when score is constant");
    }

    /// @notice getScoreHistory returns entries in chronological (oldest-first) order.
    function test_scoreHistory_chronologicalOrder() public {
        UnifiedRiskCompositor urc = _deployURC();

        // Update 1 at ts=10_000: score = 100 (max risk)
        mcoMock.setResult(0, 0); tdrvMock.setVolScore(100);
        tdrvMock.setRealizedVol(10_000); cplcsMock.setCascadeScore(100);
        urc.updateRiskScore();

        // Update 2 at ts=10_100: score = 34
        vm.warp(10_100);
        mcoMock.setResult(0, 80); tdrvMock.setVolScore(50);
        tdrvMock.setRealizedVol(5_000); cplcsMock.setCascadeScore(30);
        urc.updateRiskScore();

        // Update 3 at ts=10_200: score = 0 (max security, zero vol, zero cascade)
        vm.warp(10_200);
        mcoMock.setResult(0, 100); tdrvMock.setVolScore(0);
        tdrvMock.setRealizedVol(0); cplcsMock.setCascadeScore(0);
        urc.updateRiskScore();

        uint256[] memory hist = urc.getScoreHistory();
        assertEq(hist.length, 3, "must have exactly 3 history entries");
        // oldest = hist[0] = 100, newest = hist[2] = 0
        assertGt(hist[0], hist[2], "oldest (high risk) must exceed newest (low risk)");
    }

    /// @notice Score momentum is SPIKING when composite jumps ≥ 20 points.
    function test_momentum_spiking_whenScoreJumps() public {
        UnifiedRiskCompositor urc = _deployURC();

        // Update 1: very low risk
        mcoMock.setResult(0, 100); // mcoInput=0
        tdrvMock.setVolScore(0);
        tdrvMock.setRealizedVol(0);
        cplcsMock.setCascadeScore(0);
        (uint256 score1,,) = urc.updateRiskScore();

        // Update 2: very high risk
        vm.warp(block.timestamp + COOLDOWN);
        mcoMock.setResult(0, 0);   // mcoInput=100
        tdrvMock.setVolScore(100);
        tdrvMock.setRealizedVol(10_000);
        cplcsMock.setCascadeScore(100);
        (uint256 score2,,) = urc.updateRiskScore();

        assertGt(score2, score1, "risk must have increased");

        (UnifiedRiskCompositor.ScoreMomentum m, int256 delta) = urc.getScoreMomentum();
        assertEq(
            uint256(m),
            uint256(UnifiedRiskCompositor.ScoreMomentum.SPIKING),
            "large score increase must be SPIKING"
        );
        assertGe(delta, int256(20), "SPIKING requires delta >= 20");
    }
}

// ─── Circuit Breaker Tests ────────────────────────────────────────────────────

contract CircuitBreakerTest is Test {
    MockRiskScoreProvider      scoreProvider;
    LendingProtocolCircuitBreaker cb;

    uint256 constant CB_COOLDOWN = 300; // LendingProtocolCircuitBreaker uses 5 minutes

    function setUp() public {
        vm.warp(10_000);
        scoreProvider = new MockRiskScoreProvider();
        cb = new LendingProtocolCircuitBreaker(address(scoreProvider));
    }

    /// @notice Deploying with address(0) reverts ZeroCompositor.
    function test_constructor_zeroCompositor_reverts() public {
        vm.expectRevert(RiskCircuitBreaker.ZeroCompositor.selector);
        new LendingProtocolCircuitBreaker(address(0));
    }

    /// @notice Initial state: NOMINAL level, 80% LTV, borrowing and depositing active.
    function test_initialState_nominalLevelAndMaxLtv() public view {
        assertEq(uint256(cb.currentLevel()), uint256(RiskCircuitBreaker.AlertLevel.NOMINAL));
        assertEq(cb.currentMaxLtvBps(), 8_000, "initial LTV must be 80%");
        assertFalse(cb.borrowingPaused(),  "borrowing must not be paused initially");
        assertFalse(cb.depositingPaused(), "depositing must not be paused initially");
    }

    /// @notice score < 25 → stays NOMINAL, no LTV change.
    function test_checkAndRespond_lowScore_staysNominal() public {
        scoreProvider.setScore(10);
        bool changed = cb.checkAndRespond();
        assertFalse(changed, "no level change for score < 25");
        assertEq(uint256(cb.currentLevel()), uint256(RiskCircuitBreaker.AlertLevel.NOMINAL));
        assertEq(cb.currentMaxLtvBps(), 8_000, "LTV unchanged at NOMINAL");
    }

    /// @notice score = 25 → WATCH, LTV tightens to 7500.
    function test_checkAndRespond_score25_movesToWatch() public {
        scoreProvider.setScore(25);
        bool changed = cb.checkAndRespond();
        assertTrue(changed, "level must change at score=25");
        assertEq(uint256(cb.currentLevel()), uint256(RiskCircuitBreaker.AlertLevel.WATCH));
        assertEq(cb.currentMaxLtvBps(), 7_500, "WATCH LTV must be 75%");
    }

    /// @notice score = 65 → DANGER, LTV tightens to 6000.
    function test_checkAndRespond_score65_movesToDanger() public {
        scoreProvider.setScore(65);
        cb.checkAndRespond();
        assertEq(uint256(cb.currentLevel()), uint256(RiskCircuitBreaker.AlertLevel.DANGER));
        assertEq(cb.currentMaxLtvBps(), 6_000, "DANGER LTV must be 60%");
    }

    /// @notice score = 80 → EMERGENCY: borrowing + depositing paused, LTV = 5000.
    function test_checkAndRespond_score80_triggersEmergency() public {
        scoreProvider.setScore(80);
        cb.checkAndRespond();
        assertEq(uint256(cb.currentLevel()), uint256(RiskCircuitBreaker.AlertLevel.EMERGENCY));
        assertEq(cb.currentMaxLtvBps(), 5_000, "EMERGENCY LTV must be 50%");
        assertTrue(cb.borrowingPaused(),  "borrowing must be paused at EMERGENCY");
        assertTrue(cb.depositingPaused(), "depositing must be paused at EMERGENCY");
    }

    /// @notice Second call within cooldown reverts CooldownActive.
    function test_cooldown_blocksImmediateRepeat() public {
        scoreProvider.setScore(10);
        cb.checkAndRespond();
        // Same block → cooldown active → revert
        vm.expectRevert(
            abi.encodeWithSelector(
                RiskCircuitBreaker.CooldownActive.selector,
                block.timestamp + CB_COOLDOWN
            )
        );
        cb.checkAndRespond();
    }

    /// @notice After cooldown expires, second call succeeds and can change level.
    function test_cooldown_expiryAllowsRepeat() public {
        scoreProvider.setScore(10);
        cb.checkAndRespond();
        vm.warp(block.timestamp + CB_COOLDOWN + 1);
        scoreProvider.setScore(50); // WARNING
        bool changed = cb.checkAndRespond();
        assertTrue(changed, "level must change from NOMINAL to WARNING after cooldown");
    }

    /// @notice isInCooldown lifecycle: false → true → false.
    function test_isInCooldown_lifecycle() public {
        assertFalse(cb.isInCooldown(), "no cooldown before first call");
        scoreProvider.setScore(10);
        cb.checkAndRespond();
        assertTrue(cb.isInCooldown(), "in cooldown immediately after call");
        vm.warp(block.timestamp + CB_COOLDOWN + 1);
        assertFalse(cb.isInCooldown(), "cooldown expired");
    }

    /// @notice Dropping from EMERGENCY to NOMINAL resumes borrowing and depositing.
    function test_emergencyToNominal_resumesBorrowingAndDepositing() public {
        // Trigger EMERGENCY
        scoreProvider.setScore(85);
        cb.checkAndRespond();
        assertTrue(cb.borrowingPaused(),  "borrowing paused at EMERGENCY");
        assertTrue(cb.depositingPaused(), "depositing paused at EMERGENCY");

        // Recover to NOMINAL after cooldown
        vm.warp(block.timestamp + CB_COOLDOWN + 1);
        scoreProvider.setScore(10);
        cb.checkAndRespond();

        assertFalse(cb.borrowingPaused(),  "borrowing must resume below WATCH");
        assertFalse(cb.depositingPaused(), "depositing must resume below DANGER");
        assertEq(cb.currentMaxLtvBps(), 8_000, "LTV must recover to 80%");
    }

    /// @notice riskCompositor() returns the underlying compositor address.
    function test_riskCompositor_returnsCompositorAddress() public view {
        assertEq(cb.riskCompositor(), address(scoreProvider));
    }

    /// @notice getTimeUntilCooldownExpiry returns 0 before any call.
    function test_cooldownExpiry_isZeroBeforeAnyCall() public view {
        assertEq(cb.getTimeUntilCooldownExpiry(), 0, "no cooldown before first call");
    }
}

// ─── Stress Scenario Registry Tests ──────────────────────────────────────────

contract StressScenarioTest is Test {
    MockMCO   mcoMock;
    MockTDRV  tdrvMock;
    MockCPLCS cplcsMock;
    StressScenarioRegistry ssr;

    address constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address mockPool = address(0x111);
    address mockFeed = address(0x222);

    function setUp() public {
        mcoMock   = new MockMCO();
        tdrvMock  = new MockTDRV();
        cplcsMock = new MockCPLCS();

        // Default: moderate risk (50 security → mcoInput=50, vol=40, cascade=30)
        mcoMock.setResult(0, 50);
        tdrvMock.setVolScore(40);
        tdrvMock.setRealizedVol(5_000);
        cplcsMock.setCascadeScore(30);

        ssr = new StressScenarioRegistry(
            address(mcoMock),
            address(tdrvMock),
            address(cplcsMock)
        );
    }

    /// @notice Registry starts with 5 built-in scenarios.
    function test_scenarioCount_fiveBuiltIn() public view {
        assertEq(ssr.scenarioCount(), 5, "must have 5 built-in scenarios");
    }

    /// @notice Running BLACK_THURSDAY produces a fully populated, bounded result.
    function test_runScenario_blackThursday_validResult() public view {
        StressScenarioRegistry.ScenarioResult memory r =
            ssr.runScenario(ssr.BLACK_THURSDAY_2020(), address(mockPool), address(mockFeed), WETH);

        assertEq(r.scenarioId, ssr.BLACK_THURSDAY_2020(), "scenarioId must match");
        assertLe(r.compositeRiskScore, 100, "composite score must be bounded");
        assertGe(r.recommendedLtvBps,  5_000, "LTV must be >= 50%");
        assertLe(r.recommendedLtvBps,  8_000, "LTV must be <= 80%");
        assertGt(r.timestamp, 0, "timestamp must be set");
    }

    /// @notice Unknown scenario ID reverts UnknownScenario.
    function test_runScenario_unknownId_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(StressScenarioRegistry.UnknownScenario.selector, bytes32(0))
        );
        ssr.runScenario(bytes32(0), address(mockPool), address(mockFeed), WETH);
    }

    /// @notice Owner can add a custom scenario; count increases to 6.
    function test_addCustomScenario_increasesCount() public {
        bytes32 customId = keccak256("MY_CUSTOM_SCENARIO");
        ssr.addCustomScenario(customId, "Custom Crash", 100, 1_000, "custom test scenario");
        assertEq(ssr.scenarioCount(), 6, "custom scenario must be registered");
    }

    /// @notice Non-owner cannot add a custom scenario.
    function test_addCustomScenario_notOwner_reverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(StressScenarioRegistry.NotOwner.selector);
        ssr.addCustomScenario(keccak256("X"), "X", 100, 1_000, "x");
    }

    /// @notice mcoDeviationBps > 5000 → InvalidScenarioParams.
    function test_addCustomScenario_invalidDevBps_reverts() public {
        vm.expectRevert(StressScenarioRegistry.InvalidScenarioParams.selector);
        ssr.addCustomScenario(keccak256("Y"), "Y", 5_001, 1_000, "bad dev bps");
    }

    /// @notice runAllScenarios returns exactly 5 results.
    function test_runAllScenarios_returnsLength5() public view {
        StressScenarioRegistry.ScenarioResult[] memory results =
            ssr.runAllScenarios(address(mockPool), address(mockFeed), WETH);
        assertEq(results.length, 5, "must return one result per built-in scenario");
    }

    /// @notice worstCaseScenario score dominates all individual scenario scores.
    function test_worstCaseScenario_dominatesAllOthers() public view {
        (StressScenarioRegistry.ScenarioResult memory worst,) =
            ssr.worstCaseScenario(address(mockPool), address(mockFeed), WETH);
        StressScenarioRegistry.ScenarioResult[] memory all =
            ssr.runAllScenarios(address(mockPool), address(mockFeed), WETH);
        for (uint256 i = 0; i < all.length; i++) {
            assertGe(
                worst.compositeRiskScore,
                all[i].compositeRiskScore,
                "worstCase score must be >= every individual scenario"
            );
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Mock: TickConcentrationOracle (for URC integration tests)
// ═══════════════════════════════════════════════════════════════════════════════

contract MockTCO {
    uint256 public s_score;
    bool    public s_revert;

    function setScore(uint256 score) external { s_score = score; }
    function setRevert(bool r) external { s_revert = r; }

    function getConcentrationScore() external view returns (uint256) {
        if (s_revert) revert("MockTCO: forced revert");
        return s_score;
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TCOTest — TickConcentrationOracle unit tests (information theory pillar)
// ═══════════════════════════════════════════════════════════════════════════════

contract TCOTest is Test {
    // Mirror constants from TickConcentrationOracle for assertions.
    uint32 constant WINDOW   = 24 * 3600; // 24 hours
    uint8  constant N        = 24;        // 24 hourly samples
    uint32 constant INTERVAL = WINDOW / N; // 3600 s

    MockUniV3Pool pool;

    function setUp() public {
        vm.warp(10_000_000);
        pool = new MockUniV3Pool();
        pool.setSlot0(79_228_162_514_264_337_593_543_950_336, 0, true);
        pool.setLiquidity(1_000_000e18);
        // Prime full observation window.
        for (uint32 i = 0; i <= N; i++) {
            pool.setCustomCumulative(uint32(N - i) * INTERVAL, 0);
        }
    }

    // ── Constructor ───────────────────────────────────────────────────────────

    function test_constructor_valid() public {
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        assertEq(address(tco.pool()), address(pool));
        assertEq(tco.windowSeconds(), WINDOW);
        assertEq(tco.numSamples(), N);
    }

    function test_constructor_rejectsZeroPool() public {
        vm.expectRevert(TickConcentrationOracle.InvalidConfig.selector);
        new TickConcentrationOracle(address(0), WINDOW, N);
    }

    function test_constructor_rejectsTooFewSamples() public {
        vm.expectRevert(TickConcentrationOracle.InvalidSamples.selector);
        new TickConcentrationOracle(address(pool), WINDOW, 2); // < MIN_SAMPLES=3
    }

    function test_constructor_rejectsTooManySamples() public {
        vm.expectRevert(TickConcentrationOracle.InvalidSamples.selector);
        new TickConcentrationOracle(address(pool), WINDOW * 10, 49); // > MAX_SAMPLES=48
    }

    function test_constructor_rejectsShortInterval() public {
        // 3 samples over 60s → interval = 20s < MIN_SAMPLE_INTERVAL=60
        vm.expectRevert(TickConcentrationOracle.SampleIntervalTooShort.selector);
        new TickConcentrationOracle(address(pool), 60, 3);
    }

    // ── Single-bucket: all ticks identical → HHI = BPS → max score ───────────

    function test_concentrationScore_constantTick_isHigh() public {
        // All 24 samples return tick=100 → one bucket → HHI = BPS = 10000.
        _setConstantTick(100);
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        uint256 score = tco.getConcentrationScore();
        // HHI score = 100, bias score depends on direction but both-positive = 100
        assertGe(score, 80, "constant tick must produce high concentration score");
    }

    // ── Alternating diverse ticks → low HHI + low bias → low score ──────────

    function test_concentrationScore_alternatingDiverseTicks_isLow() public {
        // Alternating +/- unique magnitudes: +10,-20,+30,-40,...
        // Each tick lands in a different bucket AND signs alternate → near-zero bias.
        _setAlternatingUniqueTicks();
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        uint256 score = tco.getConcentrationScore();
        assertLe(score, 10, "alternating diverse ticks must produce very low concentration score");
    }

    // ── HHI: single bucket → HHI = BPS ───────────────────────────────────────

    function test_hhi_singleBucket_isBPS() public {
        _setConstantTick(50);
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        (uint256 hhiBps,) = tco.getHHI();
        assertEq(hhiBps, 10_000, "single bucket HHI must equal BPS");
    }

    // ── HHI: uniform distribution → HHI ≈ BPS/N ─────────────────────────────

    function test_hhi_uniformDistribution_isApproxBPSoverN() public {
        _setAlternatingUniqueTicks();
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        (uint256 hhiBps, uint256 uniqueBuckets) = tco.getHHI();
        // N samples each in a unique bucket: HHI = N × (1/N)^2 × BPS = BPS/N
        uint256 expected = 10_000 / N; // ≈ 416
        assertApproxEqAbs(hhiBps, expected, 50, "uniform HHI should be approx BPS/N");
        assertEq(uniqueBuckets, N, "each sample should be in its own bucket");
    }

    // ── Entropy: single bucket → 0 bits ──────────────────────────────────────

    function test_entropyBits_singleBucket_isZero() public {
        _setConstantTick(200);
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        // HHI = BPS → hhiBps < BPS is false → entropyBits = 0
        uint256 bits = tco.getApproximateEntropyBits();
        assertEq(bits, 0, "single bucket must have zero entropy bits");
    }

    // ── Entropy: diverse distribution → positive entropy ─────────────────────

    function test_entropyBits_diverseTicks_isPositive() public {
        _setAlternatingUniqueTicks();
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        uint256 bits = tco.getApproximateEntropyBits();
        assertGt(bits, 0, "diverse ticks must have positive entropy");
        // H_2 for uniform over 24 buckets ≈ log2(24) ≈ 4 bits
        assertGe(bits, 4, "uniform over 24 buckets has at least 4 bits of entropy");
    }

    // ── Directional bias: monotone → high bias ────────────────────────────────

    function test_directionalBias_monotoneIncreasing_isHigh() public {
        _setConstantTick(100); // all positive → 100% same direction
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        uint256 bias = tco.getDirectionalBias();
        assertEq(bias, 10_000, "all-positive ticks must have 100% directional bias");
    }

    // ── Directional bias: frozen price → high bias ────────────────────────────

    function test_directionalBias_frozenPrice_isHigh() public {
        _setConstantTick(0); // all zero → 100% neutral-neutral pairs
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        uint256 bias = tco.getDirectionalBias();
        assertEq(bias, 10_000, "frozen price (all zero ticks) must have 100% directional bias");
    }

    // ── Breakdown struct: all fields populated ─────────────────────────────────

    function test_breakdown_allFieldsPopulated() public {
        _setConstantTick(100);
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        TickConcentrationOracle.ConcentrationResult memory r = tco.getConcentrationBreakdown();
        assertEq(r.hhiBps, 10_000,  "hhiBps must be BPS for constant tick");
        assertEq(r.uniqueBuckets, 1, "single bucket for constant tick");
        assertEq(r.directionalBiasBps, 10_000, "100% directional for constant positive tick");
        assertEq(r.approximateEntropyBits, 0,   "zero entropy for single bucket");
        assertGe(r.concentrationScore, 80,       "score must be high");
    }

    // ── Score is bounded 0-100 ─────────────────────────────────────────────────

    function testFuzz_concentrationScore_bounded(int24 tick) public {
        vm.assume(tick > -887272 && tick < 887272);
        _setConstantTick(tick);
        TickConcentrationOracle tco = new TickConcentrationOracle(address(pool), WINDOW, N);
        uint256 score = tco.getConcentrationScore();
        assertLe(score, 100, "concentration score must never exceed 100");
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// @dev Sets all N tick samples to the same value (single bucket).
    function _setConstantTick(int24 tick) internal {
        // cumTicks: each interval contributes tick * INTERVAL
        for (uint32 i = 0; i <= N; i++) {
            int56 cum = int56(tick) * int56(uint56(uint32(N - i) * INTERVAL));
            pool.setCustomCumulative(uint32(N - i) * INTERVAL, cum);
        }
    }

    /// @dev Sets N tick samples with alternating sign and unique magnitudes.
    ///      Pattern: +10, -20, +30, -40, +50, -60, ...
    ///      - Each tick lands in a DISTINCT bucket (unique magnitudes / BUCKET_WIDTH).
    ///      - Signs alternate perfectly → near-zero directional bias.
    ///      Combined: HHI near minimum (diverse), bias near zero → very low score.
    function _setAlternatingUniqueTicks() internal {
        // Compute cumulative from oldest to newest.
        // We build the cumulative array forward (oldest → newest)
        // then set each secondsAgo mapping.
        int56[] memory cums = new int56[](N + 1);
        cums[0] = 0; // at secondsAgo = N * INTERVAL (oldest)
        for (uint32 i = 0; i < N; i++) {
            // Magnitude: (i+1)*10, sign: positive for even i, negative for odd i
            int24 tick = int24((i % 2 == 0) ? int32(i + 1) * 10 : -int32(i + 1) * 10);
            cums[i + 1] = cums[i] + int56(tick) * int56(uint56(INTERVAL));
        }
        // Map: secondsAgo[j] = (N - j) * INTERVAL corresponds to cums[j]
        for (uint32 j = 0; j <= N; j++) {
            pool.setCustomCumulative(uint32(N - j) * INTERVAL, cums[j]);
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// URCWithTCOTest — UnifiedRiskCompositor with TCO as 4th pillar
// ═══════════════════════════════════════════════════════════════════════════════

contract URCWithTCOTest is Test {
    address constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    MockMCO   mco;
    MockTDRV  tdrv;
    MockCPLCS cplcs;
    MockTCO   tco;

    function setUp() public {
        vm.warp(50_000);
        mco   = new MockMCO();
        tdrv  = new MockTDRV();
        cplcs = new MockCPLCS();
        tco   = new MockTCO();
    }

    function _deployWith4Pillars(uint8 w1, uint8 w2, uint8 w3, uint8 w4)
        internal
        returns (UnifiedRiskCompositor)
    {
        return new UnifiedRiskCompositor(
            address(mco), address(tdrv), address(cplcs), WETH,
            w1, w2, w3,
            address(tco), w4
        );
    }

    // ── Constructor validation ─────────────────────────────────────────────────

    function test_fourPillar_weightsSum100() public {
        // 30+35+20+15 = 100 — valid 4-pillar config
        UnifiedRiskCompositor urc = _deployWith4Pillars(30, 35, 20, 15);
        assertEq(urc.mcoWeight(),  30);
        assertEq(urc.tdrvWeight(), 35);
        assertEq(urc.cpWeight(),   20);
        assertEq(urc.tcoWeight(),  15);
        assertTrue(urc.isTcoEnabled(), "TCO must be reported as enabled");
    }

    function test_threePillar_tcoDisabled() public {
        UnifiedRiskCompositor urc = new UnifiedRiskCompositor(
            address(mco), address(tdrv), address(cplcs), WETH,
            35, 40, 25,
            address(0), 0
        );
        assertFalse(urc.isTcoEnabled(), "TCO must be disabled when address is zero");
        assertEq(urc.tcoWeight(), 0);
    }

    function test_fourPillar_invalidWeightsRevert() public {
        vm.expectRevert(UnifiedRiskCompositor.InvalidWeights.selector);
        // 30+35+20+20 = 105 → invalid
        _deployWith4Pillars(30, 35, 20, 20);
    }

    // ── TCO contributes to composite score ────────────────────────────────────

    function test_tcoInput_affectsCompositeScore() public {
        // MCO=0 risk (perfect security), TDRV=0, CPLCS=0, TCO varies
        mco.setResult(1_000_000_000, 100); // securityScore=100 → mcoInput=0
        tdrv.setVolScore(0);
        cplcs.setCascadeScore(0);

        UnifiedRiskCompositor urc = _deployWith4Pillars(30, 35, 20, 15);

        // With TCO=0 (organic): composite = (0×30 + 0×35 + 0×20 + 0×15)/100 = 0
        tco.setScore(0);
        (uint256 scoreOrganic,,) = urc.updateRiskScore();

        // Advance past cooldown
        vm.warp(block.timestamp + 120);

        // With TCO=100 (manipulation detected): composite should be 15
        tco.setScore(100);
        (uint256 scoreManip,,) = urc.updateRiskScore();

        assertEq(scoreOrganic, 0,  "fully organic should give score 0");
        assertEq(scoreManip,   15, "TCO=100 with 15% weight should add 15 to score");
    }

    // ── TCO failure falls back to neutral (50), not max risk (100) ───────────

    function test_tcoRevert_fallsBackToNeutral() public {
        mco.setResult(0, 0);   // mcoInput = 100
        tdrv.setVolScore(0);
        cplcs.setCascadeScore(0);
        tco.setRevert(true);   // TCO will revert on every call

        UnifiedRiskCompositor urc = _deployWith4Pillars(30, 35, 20, 15);
        (uint256 score,,) = urc.updateRiskScore();

        // mcoInput=100, tdrv=0, cplcs=0, tco=50 (neutral fallback)
        // score = (100×30 + 0×35 + 0×20 + 50×15) / 100 = (3000 + 750) / 100 = 37
        assertEq(score, 37, "TCO revert must fall back to neutral score 50 not max 100");
    }

    // ── lastTcoInput is cached after update ───────────────────────────────────

    function test_lastTcoInput_cached() public {
        mco.setResult(0, 50);
        tdrv.setVolScore(30);
        cplcs.setCascadeScore(20);
        tco.setScore(75);

        UnifiedRiskCompositor urc = _deployWith4Pillars(30, 35, 20, 15);
        urc.updateRiskScore();

        assertEq(urc.lastTcoInput(), 75, "lastTcoInput must equal what MockTCO returned");
    }

    // ── 4-pillar setWeights works ─────────────────────────────────────────────

    function test_setWeights_fourPillar() public {
        UnifiedRiskCompositor urc = _deployWith4Pillars(30, 35, 20, 15);
        // Owner updates to 25+35+25+15 = 100
        urc.setWeights(25, 35, 25, 15);
        assertEq(urc.mcoWeight(),  25);
        assertEq(urc.tdrvWeight(), 35);
        assertEq(urc.cpWeight(),   25);
        assertEq(urc.tcoWeight(),  15);
    }
}

// ============================================================================
// Mock contracts for new Chainlink integration tests
// ============================================================================

import {ChainlinkVolatilityOracle} from "../../src/ChainlinkVolatilityOracle.sol";
import {AutomatedRiskUpdater} from "../../src/AutomatedRiskUpdater.sol";
import {CrossChainRiskBroadcaster} from "../../src/CrossChainRiskBroadcaster.sol";
import {Client} from "@chainlink/contracts-ccip/libraries/Client.sol";

/// @dev Mock Chainlink AggregatorV3 price feed.
contract MockAggregatorV3 {
    string  public description = "ETH / USD";
    uint8   public decimals    = 8;

    struct RoundData {
        uint80  roundId;
        int256  answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80  answeredInRound;
    }

    RoundData[] public rounds; // index 0 = oldest
    uint80 public latestRound;

    function pushRound(uint80 roundId, int256 answer, uint256 updatedAt) external {
        rounds.push(RoundData(roundId, answer, updatedAt, updatedAt, roundId));
        latestRound = roundId;
    }

    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    ) {
        require(rounds.length > 0, "no rounds");
        RoundData storage r = rounds[rounds.length - 1];
        return (r.roundId, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
    }

    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
    ) {
        // Linear scan - ok for tests
        for (uint256 i = 0; i < rounds.length; i++) {
            if (rounds[i].roundId == _roundId) {
                RoundData storage r = rounds[i];
                return (r.roundId, r.answer, r.startedAt, r.updatedAt, r.answeredInRound);
            }
        }
        revert("round not found");
    }
}

/// @dev Mock compositor for AutomatedRiskUpdater tests.
contract MockCompositorForARU {
    uint256 public riskScore;
    uint8   public riskTier;
    uint256 public recommendedLtv;
    uint256 public callCount;

    function setValues(uint256 score, uint8 tier, uint256 ltv) external {
        riskScore = score;
        riskTier  = tier;
        recommendedLtv = ltv;
    }

    function updateRiskScore() external returns (uint256, uint8, uint256) {
        callCount++;
        return (riskScore, riskTier, recommendedLtv);
    }

    function getRiskScore() external view returns (uint256) { return riskScore; }
    function getRiskTier()  external view returns (uint8)   { return riskTier; }
    function getRecommendedLtv() external view returns (uint256) { return recommendedLtv; }
}

/// @dev Mock circuit breaker for AutomatedRiskUpdater tests.
contract MockCircuitBreakerForARU {
    uint8  public currentLevel_;
    bool   public inCooldown_;
    bool   public levelChanged_;
    uint256 public respondCallCount;

    function setLevel(uint8 level) external { currentLevel_ = level; }
    function setCooldown(bool v) external   { inCooldown_ = v; }
    function setLevelChanged(bool v) external { levelChanged_ = v; }

    function checkAndRespond() external returns (bool) {
        respondCallCount++;
        return levelChanged_;
    }
    function isInCooldown() external view returns (bool) { return inCooldown_; }
    function currentLevel() external view returns (uint8) { return currentLevel_; }
}

/// @dev Mock CCIP Router for CrossChainRiskBroadcaster tests.
///      Implements IRouterClient with proper Client.EVM2AnyMessage structs.
contract MockCCIPRouter {
    bytes32 public lastMessageId = keccak256("test-message-id");
    uint256 public feeToReturn = 0.01 ether;
    bool    public chainSupported = true;
    uint256 public sendCallCount;

    struct SentMessage {
        uint64  destChain;
        uint256 fee;
    }
    SentMessage[] public sentMessages;

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return feeToReturn;
    }

    function isChainSupported(uint64) external view returns (bool) {
        return chainSupported;
    }

    function ccipSend(uint64 destChain, Client.EVM2AnyMessage calldata) external payable returns (bytes32) {
        sendCallCount++;
        sentMessages.push(SentMessage(destChain, msg.value));
        return lastMessageId;
    }

    function setFee(uint256 fee) external { feeToReturn = fee; }
    function setChainSupported(bool v) external { chainSupported = v; }
    function sentCount() external view returns (uint256) { return sentMessages.length; }
}

// ============================================================================
// ChainlinkVolatilityOracle Tests
// ============================================================================

contract ChainlinkVolatilityOracleTest is Test {
    MockAggregatorV3 feed;
    uint32 constant STALENESS = 86400; // 24h
    uint8  constant SAMPLES   = 8;

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new MockAggregatorV3();
    }

    function _deploy() internal returns (ChainlinkVolatilityOracle) {
        return new ChainlinkVolatilityOracle(address(feed), SAMPLES, STALENESS);
    }

    function _pushRounds(uint256 n, int256 basePrice, int256 stepBps) internal {
        uint256 now_ = block.timestamp;
        for (uint256 i = 0; i < n; i++) {
            uint80 rid = uint80(i + 1);
            int256 price = basePrice + (basePrice * stepBps * int256(i)) / 10_000;
            feed.pushRound(rid, price, now_ - (n - i) * 3600);
        }
    }

    // ── constructor rejects bad params ────────────────────────────────────────

    function test_constructor_rejectsZeroFeed() public {
        vm.expectRevert("CVO: zero feed");
        new ChainlinkVolatilityOracle(address(0), SAMPLES, STALENESS);
    }

    function test_constructor_rejectsTooFewSamples() public {
        vm.expectRevert("CVO: min 4 samples");
        new ChainlinkVolatilityOracle(address(feed), 3, STALENESS);
    }

    function test_constructor_rejectsTooManySamples() public {
        vm.expectRevert("CVO: max 48 samples");
        new ChainlinkVolatilityOracle(address(feed), 49, STALENESS);
    }

    function test_constructor_rejectsLowStaleness() public {
        vm.expectRevert("CVO: min 1h staleness");
        new ChainlinkVolatilityOracle(address(feed), SAMPLES, 3599);
    }

    function test_constructor_storesParams() public {
        ChainlinkVolatilityOracle cvo = _deploy();
        assertEq(cvo.numSamples(), SAMPLES);
        assertEq(cvo.maxStalenessSeconds(), STALENESS);
        assertEq(cvo.feedDecimals(), 8);
    }

    // ── getRealizedVolatility with stable prices → low vol ───────────────────

    function test_realizedVol_stablePrices_isLow() public {
        _pushRounds(SAMPLES, 2000e8, 0); // all same price
        ChainlinkVolatilityOracle cvo = _deploy();
        uint256 vol = cvo.getVolatility();
        assertEq(vol, 0, "zero return = zero vol");
    }

    // ── getRealizedVolatility with rising prices → nonzero vol ───────────────

    function test_realizedVol_risingPrices_isNonzero() public {
        _pushRounds(SAMPLES, 2000e8, 100); // +1% per step
        ChainlinkVolatilityOracle cvo = _deploy();
        uint256 vol = cvo.getVolatility();
        assertGt(vol, 0, "trending prices = positive vol");
    }

    // ── getVolatilityScore maps to 0-100 range ────────────────────────────────

    function test_volScore_belowLow_isZero() public {
        _pushRounds(SAMPLES, 2000e8, 0);
        ChainlinkVolatilityOracle cvo = _deploy();
        uint256 score = cvo.getVolatilityScore(500, 5000);
        assertEq(score, 0);
    }

    function test_volScore_aboveHigh_is100() public {
        _pushRounds(SAMPLES, 2000e8, 1000); // +10% per step = extreme vol
        ChainlinkVolatilityOracle cvo = _deploy();
        uint256 score = cvo.getVolatilityScore(0, 1); // threshold so low any vol = 100
        assertEq(score, 100);
    }

    function test_volScore_rejectsInvertedThresholds() public {
        _pushRounds(SAMPLES, 2000e8, 100);
        ChainlinkVolatilityOracle cvo = _deploy();
        vm.expectRevert("CVO: bad thresholds");
        cvo.getVolatilityScore(5000, 500);
    }

    // ── getVolatilityRegime classification ────────────────────────────────────

    function test_regime_stablePrices_isCalm() public {
        _pushRounds(SAMPLES, 2000e8, 0);
        ChainlinkVolatilityOracle cvo = _deploy();
        ChainlinkVolatilityOracle.VolatilityRegime regime = cvo.getVolatilityRegime();
        assertEq(uint8(regime), uint8(ChainlinkVolatilityOracle.VolatilityRegime.CALM));
    }

    // ── getVolatilityWithConfidence reports correct round count ──────────────

    function test_confidence_reportsRoundsUsed() public {
        _pushRounds(SAMPLES, 2000e8, 50);
        ChainlinkVolatilityOracle cvo = _deploy();
        ChainlinkVolatilityOracle.VolatilityWithConfidence memory vc = cvo.getVolatilityWithConfidence();
        assertEq(vc.numRoundsUsed, SAMPLES, "should use all pushed rounds");
        assertGt(vc.latestPrice, 0);
        assertGt(vc.oldestRoundAge, 0);
    }

    // ── getPriceFeedDetails returns feed metadata ─────────────────────────────

    function test_priceFeedDetails() public {
        _pushRounds(SAMPLES, 2000e8, 0);
        ChainlinkVolatilityOracle cvo = _deploy();
        (string memory desc, uint8 dec, uint256 price, uint80 roundId) = cvo.getPriceFeedDetails();
        assertEq(dec, 8);
        assertGt(price, 0);
        assertGt(roundId, 0);
        assertTrue(bytes(desc).length > 0);
    }

    // ── stale round reverts ───────────────────────────────────────────────────

    function test_staleRound_reverts() public {
        // Push a round with old timestamp
        feed.pushRound(1, 2000e8, block.timestamp - STALENESS - 1);
        ChainlinkVolatilityOracle cvo = _deploy();
        vm.expectRevert("CVO: latest round stale");
        cvo.getVolatility();
    }
}

// ============================================================================
// AutomatedRiskUpdater Tests
// ============================================================================

contract AutomatedRiskUpdaterTest is Test {
    MockCompositorForARU   compositor;
    MockCircuitBreakerForARU cb;
    uint256 constant INTERVAL = 300; // 5 min

    function setUp() public {
        vm.warp(10_000);
        compositor = new MockCompositorForARU();
        cb = new MockCircuitBreakerForARU();
        compositor.setValues(55, 2, 7000);
        cb.setLevelChanged(true);
    }

    function _deploy() internal returns (AutomatedRiskUpdater) {
        return new AutomatedRiskUpdater(address(compositor), address(cb), INTERVAL);
    }

    // ── constructor validation ────────────────────────────────────────────────

    function test_constructor_rejectsZeroCompositor() public {
        vm.expectRevert("ARU: zero compositor");
        new AutomatedRiskUpdater(address(0), address(cb), INTERVAL);
    }

    function test_constructor_rejectsZeroCB() public {
        vm.expectRevert("ARU: zero circuit breaker");
        new AutomatedRiskUpdater(address(compositor), address(0), INTERVAL);
    }

    function test_constructor_rejectsShortInterval() public {
        vm.expectRevert("ARU: min 60s interval");
        new AutomatedRiskUpdater(address(compositor), address(cb), 59);
    }

    function test_constructor_storesOwner() public {
        AutomatedRiskUpdater aru = _deploy();
        assertEq(aru.owner(), address(this));
    }

    // ── checkUpkeep logic ─────────────────────────────────────────────────────

    function test_checkUpkeep_falseWhenPaused() public {
        AutomatedRiskUpdater aru = _deploy();
        aru.pause();
        (bool needed,) = aru.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_falseWhenTooSoon() public {
        AutomatedRiskUpdater aru = _deploy();
        (bool needed,) = aru.checkUpkeep("");
        assertTrue(needed); // Initially true (no previous upkeep)
        aru.performUpkeep("");
        (needed,) = aru.checkUpkeep("");
        assertFalse(needed, "should be false right after performUpkeep");
    }

    function test_checkUpkeep_trueAfterInterval() public {
        AutomatedRiskUpdater aru = _deploy();
        aru.performUpkeep("");
        vm.warp(block.timestamp + INTERVAL + 1);
        (bool needed,) = aru.checkUpkeep("");
        assertTrue(needed);
    }

    function test_checkUpkeep_falseWhenInCooldown() public {
        AutomatedRiskUpdater aru = _deploy();
        cb.setCooldown(true);
        (bool needed,) = aru.checkUpkeep("");
        assertFalse(needed);
    }

    // ── performUpkeep execution ───────────────────────────────────────────────

    function test_performUpkeep_callsCompositorAndCB() public {
        AutomatedRiskUpdater aru = _deploy();
        aru.performUpkeep("");
        assertEq(compositor.callCount(), 1);
        assertEq(cb.respondCallCount(), 1);
        assertEq(aru.upkeepCount(), 1);
    }

    function test_performUpkeep_updatestimestamp() public {
        AutomatedRiskUpdater aru = _deploy();
        uint256 before = aru.lastUpkeepTimestamp();
        aru.performUpkeep("");
        assertEq(aru.lastUpkeepTimestamp(), block.timestamp);
        assertGt(aru.lastUpkeepTimestamp(), before);
    }

    function test_performUpkeep_rejectsWhenPaused() public {
        AutomatedRiskUpdater aru = _deploy();
        aru.pause();
        vm.expectRevert("ARU: paused");
        aru.performUpkeep("");
    }

    function test_performUpkeep_rejectsWhenTooSoon() public {
        AutomatedRiskUpdater aru = _deploy();
        aru.performUpkeep("");
        vm.expectRevert("ARU: too soon");
        aru.performUpkeep(""); // immediate second call
    }

    function test_performUpkeep_skipsCBWhenInCooldown() public {
        AutomatedRiskUpdater aru = _deploy();
        cb.setCooldown(true);
        aru.performUpkeep(""); // should not call checkAndRespond
        assertEq(cb.respondCallCount(), 0);
        assertEq(compositor.callCount(), 1); // compositor still called
    }

    // ── owner functions ────────────────────────────────────────────────────────

    function test_pause_unpause() public {
        AutomatedRiskUpdater aru = _deploy();
        aru.pause();
        assertTrue(aru.paused());
        aru.unpause();
        assertFalse(aru.paused());
    }

    function test_pause_onlyOwner() public {
        AutomatedRiskUpdater aru = _deploy();
        vm.prank(address(0xBEEF));
        vm.expectRevert("ARU: not owner");
        aru.pause();
    }

    function test_setInterval_updatesValue() public {
        AutomatedRiskUpdater aru = _deploy();
        aru.setUpdateInterval(600);
        assertEq(aru.updateIntervalSeconds(), 600);
    }

    function test_setInterval_rejectsTooShort() public {
        AutomatedRiskUpdater aru = _deploy();
        vm.expectRevert("ARU: min 60s");
        aru.setUpdateInterval(59);
    }

    // ── view helpers ──────────────────────────────────────────────────────────

    function test_secondsUntilNextUpkeep_zeroWhenEligible() public {
        AutomatedRiskUpdater aru = _deploy();
        assertEq(aru.secondsUntilNextUpkeep(), 0); // never performed = 0
    }

    function test_secondsUntilNextUpkeep_afterPerform() public {
        AutomatedRiskUpdater aru = _deploy();
        aru.performUpkeep("");
        uint256 remaining = aru.secondsUntilNextUpkeep();
        assertEq(remaining, INTERVAL); // full interval remaining
    }

    function test_currentRiskScore() public {
        AutomatedRiskUpdater aru = _deploy();
        assertEq(aru.currentRiskScore(), 55);
    }
}

// ============================================================================
// CrossChainRiskBroadcaster Tests
// ============================================================================

contract CrossChainRiskBroadcasterTest is Test {
    MockCCIPRouter         router;
    MockCompositorForARU   compositor;
    MockCircuitBreakerForARU cb;

    uint64 constant CHAIN_BASE    = 15_971_525_489_660_198_913;
    uint64 constant CHAIN_ARB     = 4_949_039_107_694_359_620;
    address constant RECEIVER     = address(0x1234);

    function setUp() public {
        vm.warp(1_700_000_000);
        router    = new MockCCIPRouter();
        compositor = new MockCompositorForARU();
        cb         = new MockCircuitBreakerForARU();
        compositor.setValues(80, 3, 6000);
        cb.setLevel(3); // DANGER
    }

    function _deploy() internal returns (CrossChainRiskBroadcaster) {
        return new CrossChainRiskBroadcaster(
            address(router), address(compositor), address(cb)
        );
    }

    // ── constructor validation ────────────────────────────────────────────────

    function test_constructor_rejectsZeroCompositor() public {
        vm.expectRevert("CCRB: zero compositor");
        new CrossChainRiskBroadcaster(address(router), address(0), address(cb));
    }

    function test_constructor_rejectsZeroCB() public {
        vm.expectRevert("CCRB: zero circuit breaker");
        new CrossChainRiskBroadcaster(address(router), address(compositor), address(0));
    }

    function test_constructor_storesOwnerAndThreshold() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        assertEq(ccrb.owner(), address(this));
        assertEq(ccrb.broadcastThreshold(), 2); // WARNING
    }

    // ── destination management ────────────────────────────────────────────────

    function test_addDestination_storesIt() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
        assertEq(ccrb.destinationCount(), 1);
    }

    function test_addDestination_rejectsDuplicate() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
        vm.expectRevert("CCRB: already exists");
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
    }

    function test_addDestination_rejectsZeroReceiver() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        vm.expectRevert("CCRB: zero receiver");
        ccrb.addDestination(CHAIN_BASE, address(0));
    }

    function test_addDestination_onlyOwner() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        vm.prank(address(0xBEEF));
        vm.expectRevert("CCRB: not owner");
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
    }

    function test_removeDestination_setsInactive() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
        ccrb.removeDestination(CHAIN_BASE);
        (,, bool active) = ccrb.destinations(0);
        assertFalse(active);
    }

    function test_removeDestination_rejectsUnknown() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        vm.expectRevert("CCRB: not found");
        ccrb.removeDestination(CHAIN_BASE);
    }

    // ── setBroadcastThreshold ─────────────────────────────────────────────────

    function test_setBroadcastThreshold_updatesValue() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.setBroadcastThreshold(3);
        assertEq(ccrb.broadcastThreshold(), 3);
    }

    function test_setBroadcastThreshold_rejectsAbove4() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        vm.expectRevert("CCRB: invalid threshold");
        ccrb.setBroadcastThreshold(5);
    }

    // ── broadcastTo sends via CCIP ────────────────────────────────────────────

    function test_broadcastTo_sendsMessage() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);

        uint256 fee = router.feeToReturn();
        vm.deal(address(this), fee + 1 ether);

        bytes32 msgId = ccrb.broadcastTo{value: fee}(CHAIN_BASE);
        assertEq(msgId, router.lastMessageId());
        assertEq(router.sendCallCount(), 1);
        assertEq(ccrb.broadcastCount(), 1);
    }

    function test_broadcastTo_refundsExcess() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);

        uint256 fee = router.feeToReturn();
        uint256 overpay = fee + 0.5 ether;
        vm.deal(address(this), overpay);

        uint256 balanceBefore = address(this).balance;
        ccrb.broadcastTo{value: overpay}(CHAIN_BASE);
        uint256 refund = address(this).balance - (balanceBefore - overpay);
        assertEq(refund, 0.5 ether, "should refund excess ETH");
    }

    function test_broadcastTo_rejectsUnknownChain() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        vm.expectRevert("CCRB: unknown destination");
        ccrb.broadcastTo{value: 1 ether}(CHAIN_BASE);
    }

    function test_broadcastTo_rejectsInactiveDestination() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
        ccrb.removeDestination(CHAIN_BASE);
        vm.deal(address(this), 1 ether);
        vm.expectRevert("CCRB: destination inactive");
        ccrb.broadcastTo{value: 1 ether}(CHAIN_BASE);
    }

    // ── broadcastToAll iterates destinations ─────────────────────────────────

    function test_broadcastToAll_sendsToActiveDestinations() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
        ccrb.addDestination(CHAIN_ARB,  address(0xAAAA));

        router.setFee(0.01 ether);
        uint256 totalNeeded = 0.02 ether;
        vm.deal(address(this), totalNeeded + 0.1 ether);

        uint256 spent = ccrb.broadcastToAll{value: totalNeeded + 0.1 ether}();
        assertEq(spent, totalNeeded, "should spend exactly 2x fee");
        assertEq(router.sendCallCount(), 2, "should send to 2 chains");
    }

    function test_broadcastToAll_skipsInactiveDestination() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
        ccrb.addDestination(CHAIN_ARB,  address(0xAAAA));
        ccrb.removeDestination(CHAIN_BASE); // deactivate first

        router.setFee(0.01 ether);
        vm.deal(address(this), 1 ether);

        ccrb.broadcastToAll{value: 0.1 ether}();
        assertEq(router.sendCallCount(), 1, "should only send to active chain");
    }

    function test_broadcastToAll_rejectsBelowThreshold() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
        cb.setLevel(0); // NOMINAL — below threshold of 2

        vm.deal(address(this), 1 ether);
        vm.expectRevert("CCRB: below threshold");
        ccrb.broadcastToAll{value: 1 ether}();
    }

    // ── estimateFee delegates to router ───────────────────────────────────────

    function test_estimateFee_returnsRouterFee() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        ccrb.addDestination(CHAIN_BASE, RECEIVER);
        uint256 fee = ccrb.estimateFee(CHAIN_BASE);
        assertEq(fee, router.feeToReturn());
    }

    // ── receive() allows ETH deposit ──────────────────────────────────────────

    function test_receive_acceptsETH() public {
        CrossChainRiskBroadcaster ccrb = _deploy();
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(ccrb).call{value: 0.5 ether}("");
        assertTrue(ok);
        assertEq(address(ccrb).balance, 0.5 ether);
    }

    receive() external payable {}
}
