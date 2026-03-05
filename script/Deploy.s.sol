// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ManipulationCostOracle}          from "../src/ManipulationCostOracle.sol";
import {TickDerivedRealizedVolatility}   from "../src/TickDerivedRealizedVolatility.sol";
import {CrossProtocolCascadeScore}       from "../src/CrossProtocolCascadeScore.sol";
import {TickConcentrationOracle}         from "../src/TickConcentrationOracle.sol";
import {UnifiedRiskCompositor}           from "../src/UnifiedRiskCompositor.sol";
import {LendingProtocolCircuitBreaker}   from "../src/RiskCircuitBreaker.sol";
import {StressScenarioRegistry}          from "../src/StressScenarioRegistry.sol";

/// @title Deploy
/// @notice Deploys the full DeFiStressOracle system to Ethereum mainnet.
///
/// @dev Usage:
///        forge script script/Deploy.s.sol \
///          --rpc-url $MAINNET_RPC_URL      \
///          --private-key $DEPLOYER_KEY     \
///          --broadcast                     \
///          --verify                        \
///          -vvvv
///
///      Dry-run (no broadcast):
///        forge script script/Deploy.s.sol --rpc-url $MAINNET_RPC_URL -vvvv
///
/// @dev Contract addresses verified against Etherscan:
///
///      WETH/USDC pool (0.05%, highest-volume):
///        0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
///      ETH/USD Chainlink feed (8 decimals, heartbeat 3600s):
///        0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
///      Aave V3 PoolDataProvider:
///        0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3
///      WETH:
///        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
///      Compound V3 USDC comet (WETH collateral supported):
///        0xc3d688B66703497DAA19211EEdff47f25384cdc3
///      Morpho Blue:
///        0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb
///      Morpho WETH/USDC market (86% LLTV, most liquid):
///        0x7dde86a1e94561d9690ec678db673c1a6396365f19254b3b3f5fd20e6bc12765
contract Deploy is Script {

    // ─── Mainnet addresses ─────────────────────────────────────────────────────

    address constant WETH_USDC_POOL = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
    address constant ETH_USD_FEED   = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant AAVE_DATA_PROV = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address constant WETH           = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant COMPOUND_COMET = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    address constant MORPHO_BLUE    = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    bytes32 constant MORPHO_MARKET_ID =
        0x7dde86a1e94561d9690ec678db673c1a6396365f19254b3b3f5fd20e6bc12765;

    // ─── Deployment parameters ─────────────────────────────────────────────────

    // TWAP window: 30 minutes. Long enough to resist single-block attacks;
    // short enough to respond to genuine price moves within an hour.
    uint32 constant TWAP_WINDOW         = 30 minutes;

    // Fallback borrow rate: 5% per year. Used when Aave V3 live rate is unavailable.
    uint256 constant FALLBACK_BORROW_BPS = 500;

    // MCO cost thresholds (8 decimal USD precision):
    //   Score 0   below $1M   → oracle considered insecure
    //   Score 100 above $100M → oracle considered economically safe
    uint256 constant COST_THRESHOLD_LOW  = 1_000_000_00;    // $1M
    uint256 constant COST_THRESHOLD_HIGH = 100_000_000_00;  // $100M

    // TDRV: hourly samples, 24-hour window.
    uint32 constant VOL_SAMPLE_INTERVAL = 1 hours;
    uint8  constant VOL_NUM_SAMPLES     = 24;

    // TCO: tick concentration oracle window + samples (24h, hourly buckets).
    uint32 constant TCO_WINDOW      = 24 hours;
    uint8  constant TCO_NUM_SAMPLES = 24;

    // URC weights (must sum to 100, 4-pillar mode with TCO enabled):
    //   MCO   30% — oracle economic security (primary for TWAP-reliant protocols)
    //   TDRV  35% — realized volatility (primary driver of liquidation risk)
    //   CPLCS 20% — cross-protocol cascade (systemic risk amplifier)
    //   TCO   15% — tick concentration entropy (information-theoretic manipulation signal)
    uint8 constant WEIGHT_MCO   = 30;
    uint8 constant WEIGHT_TDRV  = 35;
    uint8 constant WEIGHT_CPLCS = 20;
    uint8 constant WEIGHT_TCO   = 15;

    // ─── Run ──────────────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("Deployer:   ", deployer);
        console2.log("Chain ID:   ", block.chainid);
        console2.log("Block:      ", block.number);

        vm.startBroadcast(deployerKey);

        // ── 1. ManipulationCostOracle ─────────────────────────────────────────
        ManipulationCostOracle mco = new ManipulationCostOracle(
            WETH_USDC_POOL,
            ETH_USD_FEED,
            TWAP_WINDOW,
            FALLBACK_BORROW_BPS,
            COST_THRESHOLD_LOW,
            COST_THRESHOLD_HIGH,
            AAVE_DATA_PROV,     // live WETH borrow rate from Aave V3
            WETH
        );
        console2.log("MCO deployed:         ", address(mco));

        // ── 2. TickDerivedRealizedVolatility ──────────────────────────────────
        TickDerivedRealizedVolatility tdrv = new TickDerivedRealizedVolatility(
            WETH_USDC_POOL,
            VOL_SAMPLE_INTERVAL,
            VOL_NUM_SAMPLES
        );
        console2.log("TDRV deployed:        ", address(tdrv));

        // ── 3. CrossProtocolCascadeScore ──────────────────────────────────────
        address[] memory aaveProviders = new address[](1);
        uint8[]   memory aaveDecs      = new uint8[](1);
        aaveProviders[0] = AAVE_DATA_PROV;
        aaveDecs[0]      = 18;

        address[] memory comets  = new address[](1);
        uint8[]   memory cometDs = new uint8[](1);
        comets[0]  = COMPOUND_COMET;
        cometDs[0] = 18;

        address[] memory morphos   = new address[](1);
        bytes32[] memory marketIds = new bytes32[](1);
        uint8[]   memory morphoDs  = new uint8[](1);
        morphos[0]   = MORPHO_BLUE;
        marketIds[0] = MORPHO_MARKET_ID;
        morphoDs[0]  = 18;

        // Euler V2 vaults: none configured at launch (pass empty arrays).
        // Add Euler V2 vault addresses here once deployed and audited.
        address[] memory eulerVaults  = new address[](0);
        uint256[] memory eulerLiqs    = new uint256[](0);
        uint8[]   memory eulerDecs    = new uint8[](0);

        CrossProtocolCascadeScore cplcs = new CrossProtocolCascadeScore(
            ETH_USD_FEED,
            18,               // WETH decimals
            WETH_USDC_POOL,
            aaveProviders, aaveDecs,
            comets, cometDs,
            morphos, marketIds, morphoDs,
            eulerVaults, eulerLiqs, eulerDecs
        );
        console2.log("CPLCS deployed:       ", address(cplcs));

        // ── 4. TickConcentrationOracle ────────────────────────────────────────
        // Information-theoretic 4th pillar: HHI + directional bias + Renyi entropy.
        // Samples the WETH/USDC pool every hour over a 24-hour window.
        TickConcentrationOracle tco = new TickConcentrationOracle(
            WETH_USDC_POOL,
            TCO_WINDOW,
            TCO_NUM_SAMPLES
        );
        console2.log("TCO deployed:         ", address(tco));

        // ── 5. UnifiedRiskCompositor ──────────────────────────────────────────
        // 4-pillar mode: MCO 30% + TDRV 35% + CPLCS 20% + TCO 15% = 100%.
        UnifiedRiskCompositor urc = new UnifiedRiskCompositor(
            address(mco),
            address(tdrv),
            address(cplcs),
            WETH,
            WEIGHT_MCO,
            WEIGHT_TDRV,
            WEIGHT_CPLCS,
            address(tco),
            WEIGHT_TCO
        );
        console2.log("URC deployed:         ", address(urc));
        console2.log("URC owner:            ", urc.owner());

        // ── 6. LendingProtocolCircuitBreaker ──────────────────────────────────
        // Uses URC as the risk score provider. Default LTV ladder applied.
        LendingProtocolCircuitBreaker cb = new LendingProtocolCircuitBreaker(
            address(urc)
        );
        console2.log("CircuitBreaker deployed:", address(cb));

        // ── 7. StressScenarioRegistry ─────────────────────────────────────────
        // Wires MCO, TDRV, and CPLCS for historical scenario simulation.
        StressScenarioRegistry ssr = new StressScenarioRegistry(
            address(mco),
            address(tdrv),
            address(cplcs)
        );
        console2.log("ScenarioRegistry deployed:", address(ssr));

        vm.stopBroadcast();

        // ─── Deployment summary ────────────────────────────────────────────────
        console2.log("\n=== DeFiStressOracle Deployment Summary ===");
        console2.log("ManipulationCostOracle:        ", address(mco));
        console2.log("TickDerivedRealizedVolatility: ", address(tdrv));
        console2.log("CrossProtocolCascadeScore:     ", address(cplcs));
        console2.log("TickConcentrationOracle:       ", address(tco));
        console2.log("UnifiedRiskCompositor:         ", address(urc));
        console2.log("LendingProtocolCircuitBreaker: ", address(cb));
        console2.log("StressScenarioRegistry:        ", address(ssr));
        console2.log("==========================================");
        console2.log("Configuration:");
        console2.log("  Pool:          WETH/USDC 0.05%");
        console2.log("  TWAP window:  ", TWAP_WINDOW, "seconds");
        console2.log("  Vol window:   ", uint256(VOL_SAMPLE_INTERVAL) * VOL_NUM_SAMPLES, "seconds");
        console2.log("  TCO window:   ", TCO_WINDOW, "seconds");
        console2.log("  Weight MCO:  ", WEIGHT_MCO);
        console2.log("  Weight TDRV: ", WEIGHT_TDRV);
        console2.log("  Weight CPLCS:", WEIGHT_CPLCS);
        console2.log("  Weight TCO:  ", WEIGHT_TCO);
        console2.log("==========================================");
    }
}
