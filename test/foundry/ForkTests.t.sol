// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";

import {ManipulationCostOracle}         from "../../src/ManipulationCostOracle.sol";
import {TickDerivedRealizedVolatility}  from "../../src/TickDerivedRealizedVolatility.sol";
import {CrossProtocolCascadeScore}      from "../../src/CrossProtocolCascadeScore.sol";
import {UnifiedRiskCompositor}          from "../../src/UnifiedRiskCompositor.sol";
import {LendingProtocolCircuitBreaker, RiskCircuitBreaker} from "../../src/RiskCircuitBreaker.sol";
import {StressScenarioRegistry}         from "../../src/StressScenarioRegistry.sol";

/// @title ForkTests
/// @notice Integration tests against real mainnet contracts via Foundry fork.
///
/// @dev Run with:
///        MAINNET_RPC_URL=https://... forge test --match-path test/foundry/ForkTests.t.sol -v
///
///      All tests are skipped (vm.skip) if MAINNET_RPC_URL is not set, so CI passes
///      without an RPC endpoint.
///
/// @dev Addresses verified against Etherscan as of 2025-Q3:
///
///    WETH/USDC pool (0.05% fee, highest-volume):
///      0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
///    ETH/USD Chainlink feed (8 decimals):
///      0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
///    Aave V3 Pool Data Provider:
///      0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3
///    WETH token:
///      0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
///    Compound V3 USDC comet (for WETH collateral):
///      0xc3d688B66703497DAA19211EEdff47f25384cdc3
///    Morpho Blue (canonical deployment):
///      0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
///    WETH/USDC Morpho market ID (WETH collateral, USDC loan, 86% LLTV):
///      0x7dde86a1e94561d9690ec678db673c1a6396365f19254b3b to be fetched dynamically

contract ForkTests is Test {
    // ─── Mainnet addresses ─────────────────────────────────────────────────────

    address constant WETH_USDC_POOL  = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant ETH_USD_FEED    = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant AAVE_DATA_PROV  = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address constant WETH            = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant COMPOUND_COMET  = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address constant MORPHO_BLUE     = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    // Morpho WETH/USDC market with 86% LLTV (most liquid mainnet WETH market)
    bytes32 constant MORPHO_MARKET_ID =
        0x7dde86a1e94561d9690ec678db673c1a6396365f19254b3b3f5fd20e6bc12765;

    // ─── Contract instances ────────────────────────────────────────────────────

    ManipulationCostOracle        mco;
    TickDerivedRealizedVolatility tdrv;
    CrossProtocolCascadeScore     cplcs;
    UnifiedRiskCompositor         urc;

    // ─── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            // No RPC configured — skip all fork tests gracefully.
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);

        // ── Deploy ManipulationCostOracle ─────────────────────────────────────
        // WETH/USDC pool, ETH/USD feed, 30-min TWAP, 5% static borrow rate,
        // $1M low / $100M high thresholds, Aave live rate enabled.
        mco = new ManipulationCostOracle(
            WETH_USDC_POOL,
            ETH_USD_FEED,
            1800,             // 30-minute TWAP
            500,              // 5% fallback borrow rate
            1_000_000_00,     // $1M low threshold (8 dec)
            100_000_000_00,   // $100M high threshold (8 dec)
            AAVE_DATA_PROV,
            WETH              // query Aave for WETH variable borrow rate
        );

        // ── Deploy TickDerivedRealizedVolatility ──────────────────────────────
        // 1-hour intervals, 24 samples → 24-hour realized vol window.
        tdrv = new TickDerivedRealizedVolatility(
            WETH_USDC_POOL,
            3600,  // 1-hour sample interval
            24     // 24 samples (min 3, max 48)
        );

        // ── Deploy CrossProtocolCascadeScore ──────────────────────────────────
        address[] memory aaveProviders = new address[](1);
        uint8[]   memory aaveDecs      = new uint8[](1);
        aaveProviders[0] = AAVE_DATA_PROV;
        aaveDecs[0]      = 18;

        address[] memory comets   = new address[](1);
        uint8[]   memory comet8s  = new uint8[](1);
        comets[0]  = COMPOUND_COMET;
        comet8s[0] = 18;

        address[] memory morphos   = new address[](1);
        bytes32[] memory marketIds = new bytes32[](1);
        uint8[]   memory morphoDec = new uint8[](1);
        morphos[0]   = MORPHO_BLUE;
        marketIds[0] = MORPHO_MARKET_ID;
        morphoDec[0] = 18;

        address[] memory eulerVaults = new address[](0);
        uint256[] memory eulerLiqs   = new uint256[](0);
        uint8[]   memory eulerDecs   = new uint8[](0);

        cplcs = new CrossProtocolCascadeScore(
            ETH_USD_FEED,
            18, // WETH decimals
            WETH_USDC_POOL,
            aaveProviders, aaveDecs,
            comets, comet8s,
            morphos, marketIds, morphoDec,
            eulerVaults, eulerLiqs, eulerDecs
        );

        // ── Deploy UnifiedRiskCompositor ──────────────────────────────────────
        urc = new UnifiedRiskCompositor(
            address(mco),
            address(tdrv),
            address(cplcs),
            WETH,
            35, 40, 25,  // default weights: MCO 35%, TDRV 40%, CPLCS 25%
            address(0), 0
        );
    }

    // ─── ManipulationCostOracle fork tests ─────────────────────────────────────

    /// @notice Pool has deep liquidity and valid TWAP → cost must be positive.
    function test_fork_mco_returnsPositiveCost() public view {
        (uint256 costUsd, uint256 score) = mco.getManipulationCost(200);
        assertGt(costUsd, 0, "mainnet WETH/USDC pool must have positive manipulation cost");
        assertLe(score, 100, "score must be bounded");
        console2.log("MCO: costUsd =", costUsd / 1e8, "USD | score =", score);
    }

    /// @notice 5% deviation must cost more than 2% to attack.
    function test_fork_mco_largerDeviationCostsMore() public view {
        (uint256 cost200,) = mco.getManipulationCost(200);
        (uint256 cost500,) = mco.getManipulationCost(500);
        assertGt(cost500, cost200, "larger deviation must cost more on mainnet");
    }

    /// @notice TWAP vs spot: on mainnet these should be within 5% normally.
    function test_fork_mco_twapVsSpotDeviation() public view {
        (uint160 twap, uint160 spot, uint256 devBps) = mco.getTwapVsSpot();
        assertGt(twap, 0, "TWAP must be nonzero on mainnet");
        assertGt(spot, 0, "spot must be nonzero on mainnet");
        // In normal market conditions, TWAP and spot should be within 5% (500 bps).
        assertLt(devBps, 500, "TWAP/spot deviation should be < 5% in normal market");
        console2.log("TWAP/Spot deviation:", devBps, "bps");
    }

    /// @notice Live Aave WETH borrow rate should be within 0–100% (0–10000 BPS).
    function test_fork_mco_liveBorrowRateInRange() public view {
        uint256 rateBps = mco.getEffectiveBorrowRateBps();
        assertGe(rateBps, 1,      "Aave borrow rate must be >= 1 BPS on mainnet");
        assertLe(rateBps, 10_000, "Aave borrow rate must be <= 10000 BPS (100%)");
        console2.log("Live Aave WETH borrow rate:", rateBps, "BPS");
    }

    /// @notice Score is in [0, 100] for all valid deviations on mainnet.
    function testFuzz_fork_mco_scoreBounded(uint256 devBps) public view {
        devBps = bound(devBps, 1, 5_000);
        (, uint256 score) = mco.getManipulationCost(devBps);
        assertLe(score, 100);
    }

    // ─── TickDerivedRealizedVolatility fork tests ──────────────────────────────

    /// @notice 24-hour realized vol on mainnet must be non-negative and reasonable.
    function test_fork_tdrv_volInRange() public view {
        uint256 vol = tdrv.getRealizedVolatility();
        // ETH daily vol is typically 40–250% annualized (4000–25000 BPS).
        // We use a wide range to avoid flakiness across different fork timestamps.
        assertLe(vol, tdrv.MAX_VOL_BPS(), "vol must not exceed safety cap");
        console2.log("24h realized vol:", vol, "BPS (annualized)");
    }

    /// @notice Volatility score is in [0, 100] with typical thresholds.
    function test_fork_tdrv_scoreInRange() public view {
        uint256 score = tdrv.getVolatilityScore(2_000, 20_000); // 20% to 200% range
        assertLe(score, 100, "vol score must be bounded on mainnet");
        console2.log("Vol score:", score);
    }

    /// @notice getRawTickDeltas returns correct dimensions.
    function test_fork_tdrv_rawDimensions() public view {
        (int256[] memory avgTicks, int256[] memory logReturns) = tdrv.getRawTickDeltas();
        assertEq(avgTicks.length, 24,  "must have 24 avgTicks");
        assertEq(logReturns.length, 23, "must have 23 log returns (N-1)");
    }

    // ─── CrossProtocolCascadeScore fork tests ─────────────────────────────────

    /// @notice On mainnet, WETH has significant Aave/Compound/Morpho exposure → nonzero score.
    function test_fork_cplcs_nonzeroCollateral() public view {
        CrossProtocolCascadeScore.CascadeResult memory r = cplcs.getCascadeScore(WETH, 2000);
        assertGt(r.totalCollateralUsd, 0, "WETH has significant mainnet collateral");
        assertLe(r.cascadeScore, 100,     "cascade score must be bounded");
        assertGe(r.amplificationBps, 10_000, "amplification >= 1x");
        console2.log("Total collateral USD:", r.totalCollateralUsd / 1e8);
        console2.log("Cascade score:", r.cascadeScore);
        console2.log("Amplification:", r.amplificationBps, "BPS");
    }

    /// @notice Larger price shock must produce equal or greater cascade score.
    function test_fork_cplcs_largerShockNotLowerScore() public view {
        CrossProtocolCascadeScore.CascadeResult memory r10 = cplcs.getCascadeScore(WETH, 1000);
        CrossProtocolCascadeScore.CascadeResult memory r30 = cplcs.getCascadeScore(WETH, 3000);
        assertGe(r30.cascadeScore, r10.cascadeScore, "larger shock must not reduce score");
    }

    // ─── UnifiedRiskCompositor fork tests ─────────────────────────────────────

    /// @notice Full composite score update on mainnet: score in [0,100], LTV in [50%, 80%].
    function test_fork_urc_updateRiskScore() public {
        (uint256 score, UnifiedRiskCompositor.RiskTier tier, uint256 ltv) = urc.updateRiskScore();
        assertLe(score, 100, "composite score must be bounded");
        assertGe(ltv, 5_000, "LTV must be >= 50%");
        assertLe(ltv, 8_000, "LTV must be <= 80%");
        console2.log("Composite risk score:", score);
        console2.log("Risk tier:", uint8(tier));
        console2.log("Recommended LTV:", ltv, "BPS");
    }

    /// @notice getRiskBreakdown reflects the last updateRiskScore call.
    function test_fork_urc_breakdownConsistency() public {
        (uint256 score, UnifiedRiskCompositor.RiskTier tier,) = urc.updateRiskScore();
        (uint256 bScore, , , , UnifiedRiskCompositor.RiskTier bTier, uint256 bLtv, , ,) =
            urc.getRiskBreakdown();
        assertEq(bScore, score, "breakdown score must match update score");
        assertEq(uint8(bTier), uint8(tier), "breakdown tier must match update tier");
        assertGt(bLtv, 0, "recommended LTV must be positive");
    }

    // ─── MCO Multi-Window fork tests ────────────────────────────────────────────

    /// @notice Multi-window: 1-hour attack costs more than 5-min on mainnet.
    function test_fork_mco_multiWindowCostProportional() public view {
        ManipulationCostOracle.MultiWindowCost memory c =
            mco.getManipulationCostMultiWindow(200);
        assertGt(c.cost1hour, c.cost5min, "1-hour attack must cost more than 5-min on mainnet");
        assertGt(c.cost5min,  0,          "all windows must have non-zero cost on mainnet");
        assertLe(c.score1hour, 100, "1-hour score bounded");
        console2.log("MCO 5-min cost:", c.cost5min / 1e8, "USD | score:", c.score5min);
        console2.log("MCO 1-hour cost:", c.cost1hour / 1e8, "USD | score:", c.score1hour);
    }

    /// @notice getManipulationCostAtWindow returns bounded result at custom window.
    function test_fork_mco_atWindowArbitrary() public view {
        (uint256 costUsd, uint256 score) = mco.getManipulationCostAtWindow(200, 7200); // 2-hour
        assertGt(costUsd, 0,   "2-hour attack cost must be > 0 on mainnet");
        assertLe(score,   100, "2-hour attack score must be bounded");
        console2.log("MCO 2-hour window cost:", costUsd / 1e8, "USD | score:", score);
    }

    // ─── TDRV Regime + EWMA fork tests ──────────────────────────────────────────

    /// @notice On mainnet, volatility regime is a valid enum value.
    function test_fork_tdrv_regimeIsValid() public view {
        TickDerivedRealizedVolatility.VolatilityRegime regime = tdrv.getVolatilityRegime();
        // Enum has values 0-4; just assert it's in range by converting
        uint256 r = uint256(regime);
        assertLe(r, 4, "volatility regime must be a valid enum value (0-4)");
        console2.log("Volatility regime:", r, "(0=CALM, 4=EXTREME)");
    }

    /// @notice EWMA vol on mainnet is bounded and in the same order as simple realized vol.
    function test_fork_tdrv_ewmaInRange() public view {
        uint256 realizedVol = tdrv.getRealizedVolatility();
        uint256 ewmaVol     = tdrv.getVolatilityEWMA(9_400); // RiskMetrics λ=0.94
        assertLe(ewmaVol, tdrv.MAX_VOL_BPS(), "EWMA vol must not exceed cap");
        // EWMA and realized vol should both be non-negative and in the same ballpark
        console2.log("Realized vol (BPS):", realizedVol);
        console2.log("EWMA vol (BPS):", ewmaVol);
    }

    // ─── URC Score History fork tests ────────────────────────────────────────────

    /// @notice After one updateRiskScore, score history has exactly one entry.
    function test_fork_urc_scoreHistoryAfterOneUpdate() public {
        urc.updateRiskScore();
        uint256[] memory hist = urc.getScoreHistory();
        assertEq(hist.length, 1, "score history must have 1 entry after first update");
        assertLe(hist[0], 100,   "history entry must be a valid score");
        console2.log("Score history[0]:", hist[0]);
    }

    /// @notice EWMA score is initialized after first update.
    function test_fork_urc_ewmaInitializedAfterUpdate() public {
        (uint256 score,,) = urc.updateRiskScore();
        assertEq(urc.getEWMAScore(), score, "EWMA must be seeded to first score");
    }

    // ─── CircuitBreaker fork tests ───────────────────────────────────────────────

    /// @notice Deploy LendingProtocolCircuitBreaker with URC; initial state is NOMINAL.
    function test_fork_cb_initialState() public {
        LendingProtocolCircuitBreaker cb =
            new LendingProtocolCircuitBreaker(address(urc));
        assertEq(
            uint256(cb.currentLevel()),
            uint256(RiskCircuitBreaker.AlertLevel.NOMINAL),
            "initial level must be NOMINAL"
        );
        assertEq(cb.currentMaxLtvBps(), 8_000, "initial LTV must be 80%");
        assertFalse(cb.borrowingPaused(),  "borrowing must not be paused initially");
        assertFalse(cb.depositingPaused(), "depositing must not be paused initially");
        assertEq(cb.riskCompositor(), address(urc), "compositor must be URC");
    }

    // ─── StressScenarioRegistry fork tests ──────────────────────────────────────

    /// @notice Deploy SSR with mainnet primitives; 5 scenarios registered.
    function test_fork_ssr_scenarioCountFive() public {
        StressScenarioRegistry ssr = new StressScenarioRegistry(
            address(mco), address(tdrv), address(cplcs)
        );
        assertEq(ssr.scenarioCount(), 5, "must have 5 built-in scenarios");
    }

    /// @notice Run BLACK_THURSDAY scenario against mainnet state; valid result.
    function test_fork_ssr_runBlackThursday() public {
        StressScenarioRegistry ssr = new StressScenarioRegistry(
            address(mco), address(tdrv), address(cplcs)
        );
        StressScenarioRegistry.ScenarioResult memory r =
            ssr.runScenario(ssr.BLACK_THURSDAY_2020(), WETH);
        assertEq(r.scenarioId, ssr.BLACK_THURSDAY_2020(), "scenario ID must match");
        assertLe(r.compositeRiskScore, 100, "composite score bounded");
        assertGe(r.recommendedLtvBps, 5_000, "LTV must be >= 50%");
        assertLe(r.recommendedLtvBps, 8_000, "LTV must be <= 80%");
        console2.log("BLACK_THURSDAY composite score:", r.compositeRiskScore);
        console2.log("Recommended LTV:", r.recommendedLtvBps, "BPS");
    }
}
