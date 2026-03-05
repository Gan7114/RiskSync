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
import {ChainlinkVolatilityOracle}       from "../src/ChainlinkVolatilityOracle.sol";
import {AutomatedRiskUpdater}            from "../src/AutomatedRiskUpdater.sol";
import {CrossChainRiskBroadcaster}       from "../src/CrossChainRiskBroadcaster.sol";

/// @title DeploySepolia
/// @notice Deploys the full DeFiStressOracle system to Ethereum Sepolia testnet.
///
/// @dev Usage:
///        source .env
///        forge script script/DeploySepolia.s.sol \
///          --rpc-url $SEPOLIA_RPC_URL      \
///          --private-key $PRIVATE_KEY      \
///          --broadcast                     \
///          --verify                        \
///          -vvvv
///
///      Dry-run (no broadcast):
///        forge script script/DeploySepolia.s.sol --rpc-url $SEPOLIA_RPC_URL -vvvv
///
/// @dev Sepolia addresses:
///
///      ETH/USDC Uniswap V3 pool (Sepolia):
///        0x6Ce0896eAE6D4BD668fDe41BB784548fb8F59b50
///      ETH/USD Chainlink feed (Sepolia, 8 decimals):
///        0x694AA1769357215DE4FAC081bf1f309aDC325306
///      Aave V3 PoolDataProvider (Sepolia):
///        0x3e9708d80f7B3e43118013075F7e95CE3AB31F31
///      WETH (Sepolia):
///        0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9
///      Chainlink CCIP Router (Sepolia):
///        0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59
contract DeploySepolia is Script {

    // ─── Sepolia addresses ─────────────────────────────────────────────────────

    address constant WETH_USDC_POOL  = 0x6Ce0896eAE6D4BD668fDe41BB784548fb8F59b50;
    address constant ETH_USD_FEED    = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    address constant AAVE_DATA_PROV  = 0x3e9708d80f7B3e43118013075F7e95CE3AB31F31;
    address constant WETH            = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;
    // Chainlink CCIP Router (Ethereum Sepolia):
    address constant CCIP_ROUTER     = 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59;

    // Compound V3 and Morpho Blue are not reliably deployed on Sepolia.
    // CPLCS will use Aave-only mode with empty Compound + Morpho arrays.

    // ─── Deployment parameters (testnet-friendly: shorter windows) ─────────────

    // TWAP window: 5 minutes (minimum allowed by MCO).
    // Sepolia pools accumulate observations faster; shorter window = quicker data.
    uint32 constant TWAP_WINDOW         = 300;           // 5 minutes

    // Fallback borrow rate: 5% per year.
    uint256 constant FALLBACK_BORROW_BPS = 500;

    // MCO cost thresholds (8 decimal USD precision):
    uint256 constant COST_THRESHOLD_LOW  = 1_000_000_00;    // $1M
    uint256 constant COST_THRESHOLD_HIGH = 100_000_000_00;  // $100M

    // TDRV: 5-minute intervals, 6 samples = 30-minute vol window.
    uint32 constant VOL_SAMPLE_INTERVAL = 5 minutes;
    uint8  constant VOL_NUM_SAMPLES     = 6;

    // TCO: 18-minute window, 3 samples (minimum allowed: 3).
    // Each sample covers 6 minutes of tick data.
    uint32 constant TCO_WINDOW      = 18 minutes;
    uint8  constant TCO_NUM_SAMPLES = 3;

    // Chainlink Volatility Oracle: 12 rounds (~12 hours of Sepolia feed data).
    uint8  constant CVO_SAMPLES     = 12;
    uint32 constant CVO_STALENESS   = 25 hours;

    // AutomatedRiskUpdater: 5-minute heartbeat.
    uint256 constant ARU_INTERVAL   = 5 minutes;

    // URC weights (must sum to 100):
    uint8 constant WEIGHT_MCO   = 30;
    uint8 constant WEIGHT_TDRV  = 35;
    uint8 constant WEIGHT_CPLCS = 20;
    uint8 constant WEIGHT_TCO   = 15;

    // ─── Run ──────────────────────────────────────────────────────────────────

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console2.log("Deployer:   ", deployer);
        console2.log("Chain ID:   ", block.chainid);
        console2.log("Block:      ", block.number);
        console2.log("Network:    Ethereum Sepolia (testnet)");

        vm.startBroadcast(deployerKey);

        // ── 1. ManipulationCostOracle ─────────────────────────────────────────
        ManipulationCostOracle mco = new ManipulationCostOracle(
            WETH_USDC_POOL,
            ETH_USD_FEED,
            TWAP_WINDOW,
            FALLBACK_BORROW_BPS,
            COST_THRESHOLD_LOW,
            COST_THRESHOLD_HIGH,
            AAVE_DATA_PROV,     // live WETH borrow rate from Aave V3 Sepolia
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
        // Aave V3 is the only protocol on Sepolia; Compound + Morpho use empty arrays.
        address[] memory aaveProviders = new address[](1);
        uint8[]   memory aaveDecs      = new uint8[](1);
        aaveProviders[0] = AAVE_DATA_PROV;
        aaveDecs[0]      = 18;

        address[] memory comets    = new address[](0);
        uint8[]   memory cometDs   = new uint8[](0);

        address[] memory morphos   = new address[](0);
        bytes32[] memory marketIds = new bytes32[](0);
        uint8[]   memory morphoDs  = new uint8[](0);

        address[] memory eulerVaults = new address[](0);
        uint256[] memory eulerLiqs   = new uint256[](0);
        uint8[]   memory eulerDecs   = new uint8[](0);

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
        TickConcentrationOracle tco = new TickConcentrationOracle(
            WETH_USDC_POOL,
            TCO_WINDOW,
            TCO_NUM_SAMPLES
        );
        console2.log("TCO deployed:         ", address(tco));

        // ── 5. UnifiedRiskCompositor ──────────────────────────────────────────
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

        // ── 6. LendingProtocolCircuitBreaker ──────────────────────────────────
        LendingProtocolCircuitBreaker cb = new LendingProtocolCircuitBreaker(
            address(urc)
        );
        console2.log("CircuitBreaker deployed:", address(cb));

        // ── 7. StressScenarioRegistry ─────────────────────────────────────────
        StressScenarioRegistry ssr = new StressScenarioRegistry(
            address(mco),
            address(tdrv),
            address(cplcs)
        );
        console2.log("ScenarioRegistry deployed:", address(ssr));

        // ── 8. ChainlinkVolatilityOracle ──────────────────────────────────────
        ChainlinkVolatilityOracle cvo = new ChainlinkVolatilityOracle(
            ETH_USD_FEED,
            CVO_SAMPLES,
            CVO_STALENESS
        );
        console2.log("ChainlinkVolOracle deployed:", address(cvo));

        // ── 9. AutomatedRiskUpdater ───────────────────────────────────────────
        AutomatedRiskUpdater aru = new AutomatedRiskUpdater(
            address(urc),
            address(cb),
            ARU_INTERVAL
        );
        console2.log("AutomatedRiskUpdater deployed:", address(aru));

        // ── 10. CrossChainRiskBroadcaster ─────────────────────────────────────
        CrossChainRiskBroadcaster ccrb = new CrossChainRiskBroadcaster(
            CCIP_ROUTER,
            address(urc),
            address(cb)
        );
        console2.log("CrossChainBroadcaster deployed:", address(ccrb));

        vm.stopBroadcast();

        // ─── Deployment summary ────────────────────────────────────────────────
        console2.log("\n=== DeFiStressOracle Sepolia Deployment Summary ===");
        console2.log("Network:                       Ethereum Sepolia (chainId 11155111)");
        console2.log("ManipulationCostOracle:        ", address(mco));
        console2.log("TickDerivedRealizedVolatility: ", address(tdrv));
        console2.log("CrossProtocolCascadeScore:     ", address(cplcs));
        console2.log("TickConcentrationOracle:       ", address(tco));
        console2.log("UnifiedRiskCompositor:         ", address(urc));
        console2.log("LendingProtocolCircuitBreaker: ", address(cb));
        console2.log("StressScenarioRegistry:        ", address(ssr));
        console2.log("ChainlinkVolatilityOracle:     ", address(cvo));
        console2.log("AutomatedRiskUpdater:          ", address(aru));
        console2.log("CrossChainRiskBroadcaster:     ", address(ccrb));
        console2.log("===================================================");
        console2.log("Configuration:");
        console2.log("  Pool:          ETH/USDC (Sepolia Uniswap V3)");
        console2.log("  TWAP window:  ", TWAP_WINDOW, "seconds");
        console2.log("  Vol window:   ", uint256(VOL_SAMPLE_INTERVAL) * VOL_NUM_SAMPLES, "seconds");
        console2.log("  TCO window:   ", TCO_WINDOW, "seconds");
        console2.log("  CVO rounds:  ", CVO_SAMPLES);
        console2.log("  Weight MCO:  ", WEIGHT_MCO);
        console2.log("  Weight TDRV: ", WEIGHT_TDRV);
        console2.log("  Weight CPLCS:", WEIGHT_CPLCS);
        console2.log("  Weight TCO:  ", WEIGHT_TCO);
        console2.log("===================================================");
        console2.log("\nNext steps:");
        console2.log("  1. Copy the 10 addresses above into dashboard/.env.local");
        console2.log("  2. Register ARU with Chainlink Automation on Sepolia");
        console2.log("  3. Fund CCRB with LINK for CCIP broadcasts");
        console2.log("  4. cd dashboard && vercel --prod");
    }
}
