// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================================
//  StressScenarioRegistry
//
//  On-chain library of historical DeFi stress scenarios.  Runs all three risk
//  primitives under each scenario's parameters and returns a full breakdown.
//
//  Why this matters vs. Gauntlet / Chaos Labs:
//    Gauntlet has hundreds of scenarios stored off-chain in private databases.
//    This contract makes 5 canonical scenarios (and user-defined custom ones)
//    permanently verifiable on-chain — any protocol or user can replay them
//    at any time against current market conditions.
//
//  Built-in Scenarios:
//    BLACK_THURSDAY_2020   — ETH -60% in 24 h, MakerDAO liquidation crisis
//    LUNA_COLLAPSE_2022    — LUNA hyperinflation, $40 B wiped in 72 h
//    FTX_COLLAPSE_2022     — FTX insolvency, ETH -40% contagion
//    STABLECOIN_DEPEG_2023 — SVB bank-run, USDC temporarily at $0.87
//    SYNTHETIC_WORST_CASE  — Synthetic -90% shock, maximum cascade
// ============================================================================

interface IManipulationCostOracleSSR {
    function getManipulationCost(uint256 targetDeviationBps)
        external
        view
        returns (uint256 costUsd, uint256 securityScore);
        
    function getManipulationCostForPool(address pool, address feed, uint256 targetDeviationBps)
        external
        view
        returns (uint256 costUsd, uint256 securityScore);
}

interface ITickDerivedRealizedVolatilitySSR {
    function getRealizedVolatility() external view returns (uint256);
    function getVolatilityScore(uint256 lowBps, uint256 highBps)
        external
        view
        returns (uint256);
        
    function getRealizedVolatilityForPool(address pool, uint32 interval, uint8 nSamples) external view returns (uint256);
    function getVolatilityScoreForPool(address pool, uint32 interval, uint8 nSamples, uint256 lowBps, uint256 highBps)
        external
        view
        returns (uint256);
}

interface ICrossProtocolCascadeScoreSSR {
    struct CascadeResult {
        uint256 totalCollateralUsd;
        uint256 estimatedLiquidationUsd;
        uint256 secondaryPriceImpactBps;
        uint256 totalImpactBps;
        uint256 amplificationBps;
        uint256 cascadeScore;
    }

    function getCascadeScore(address asset, uint256 shockBps)
        external
        view
        returns (CascadeResult memory);
}

/// @title StressScenarioRegistry
/// @notice On-chain stress testing library with 5 historical DeFi crisis scenarios.
contract StressScenarioRegistry {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice A named stress scenario with parameterized shock values.
    struct Scenario {
        bytes32 id;
        string name;
        /// @dev BPS deviation used for TWAP manipulation cost query (e.g. 500 = 5%)
        uint256 mcoDeviationBps;
        /// @dev BPS price shock used for cascade simulation (e.g. 5000 = 50% drop)
        uint256 cplcsShockBps;
        string description;
    }

    /// @notice Full result from running one scenario.
    struct ScenarioResult {
        bytes32 scenarioId;
        string name;
        uint256 manipulationCostUsd;
        uint256 mcoScore;
        uint256 realizedVolBps;
        uint256 tdrvScore;
        uint256 totalCascadeCollateralUsd;
        uint256 cascadeScore;
        uint256 compositeRiskScore;
        uint256 recommendedLtvBps;
        uint256 timestamp;
    }

    // =========================================================================
    // Built-in Scenario IDs
    // =========================================================================

    bytes32 public constant BLACK_THURSDAY_2020 = keccak256("BLACK_THURSDAY_2020");
    bytes32 public constant LUNA_COLLAPSE_2022 = keccak256("LUNA_COLLAPSE_2022");
    bytes32 public constant FTX_COLLAPSE_2022 = keccak256("FTX_COLLAPSE_2022");
    bytes32 public constant STABLECOIN_DEPEG_2023 = keccak256("STABLECOIN_DEPEG_2023");
    bytes32 public constant SYNTHETIC_WORST_CASE = keccak256("SYNTHETIC_WORST_CASE");

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 private constant BPS = 10_000;

    /// @dev Weights matching the UnifiedRiskCompositor defaults (35/40/25).
    uint256 private constant WEIGHT_MCO = 35;
    uint256 private constant WEIGHT_TDRV = 40;
    uint256 private constant WEIGHT_CPLCS = 25;

    /// @dev Vol thresholds matching URC defaults.
    uint256 private constant VOL_LOW_BPS = 2_000;
    uint256 private constant VOL_HIGH_BPS = 15_000;

    uint256 private constant MAX_CUSTOM_SCENARIOS = 20;

    // =========================================================================
    // LTV mapping (mirrors UnifiedRiskCompositor)
    // =========================================================================

    uint256 private constant LTV_LOW = 8_000;
    uint256 private constant LTV_MODERATE = 7_500;
    uint256 private constant LTV_HIGH = 6_500;
    uint256 private constant LTV_CRITICAL = 5_000;

    // =========================================================================
    // State
    // =========================================================================

    IManipulationCostOracleSSR public immutable mco;
    ITickDerivedRealizedVolatilitySSR public immutable tdrv;
    ICrossProtocolCascadeScoreSSR public immutable cplcs;

    address public owner;

    mapping(bytes32 => Scenario) public scenarios;
    mapping(bytes32 => ScenarioResult) public lastResults;
    bytes32[] public scenarioIds;

    // =========================================================================
    // Errors
    // =========================================================================

    error UnknownScenario(bytes32 id);
    error ScenarioAlreadyExists(bytes32 id);
    error ScenarioLimitReached();
    error InvalidScenarioParams();
    error ZeroAddress();
    error NotOwner();

    // =========================================================================
    // Events
    // =========================================================================

    event ScenarioRun(
        bytes32 indexed scenarioId,
        uint256 compositeRiskScore,
        uint256 recommendedLtvBps,
        uint256 timestamp
    );

    event CustomScenarioAdded(bytes32 indexed id, string name, uint256 mcoDeviationBps, uint256 cplcsShockBps);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address _mco, address _tdrv, address _cplcs) {
        if (_mco == address(0) || _tdrv == address(0) || _cplcs == address(0)) revert ZeroAddress();

        mco = IManipulationCostOracleSSR(_mco);
        tdrv = ITickDerivedRealizedVolatilitySSR(_tdrv);
        cplcs = ICrossProtocolCascadeScoreSSR(_cplcs);
        owner = msg.sender;

        // -------------------------------------------------------------------
        // Register the 5 canonical historical scenarios
        // -------------------------------------------------------------------

        _addScenario(
            BLACK_THURSDAY_2020,
            "Black Thursday 2020",
            500, // 5% TWAP deviation — low because oracles lagged behind spot crash
            5000, // 50% price shock — ETH dropped 60% peak-to-trough in ~6 hours
            "March 12, 2020: ETH crashed 60% in 24h. Keeper bots failed to liquidate"
            " $8M+ of MakerDAO CDPs due to gas congestion and oracle lag, causing"
            " $4M+ in bad debt. The first major DeFi liquidation cascade failure."
        );

        _addScenario(
            LUNA_COLLAPSE_2022,
            "LUNA / UST Collapse 2022",
            1000, // 10% TWAP deviation — sustained attack on UST peg
            8000, // 80% shock — LUNA lost 99.9% of value in 72 hours
            "May 7-13, 2022: UST depegged from $1 triggering a death-spiral."
            " LUNA hyperinflated from $60 to near zero in 72h, $40B+ wiped."
            " Cascade liquidations hit Anchor Protocol, Mirror, and cross-chain pools."
        );

        _addScenario(
            FTX_COLLAPSE_2022,
            "FTX Insolvency 2022",
            300, // 3% TWAP deviation — market-wide sell pressure
            3500, // 35% shock — ETH dropped ~40% over 2 weeks
            "Nov 7-11, 2022: FTX insolvency contagion. BTC/ETH both -40% over"
            " two weeks as Alameda Research positions were force-liquidated and"
            " counterparty credit dried up. Solana ecosystem -80%."
        );

        _addScenario(
            STABLECOIN_DEPEG_2023,
            "USDC Stablecoin Depeg 2023",
            50, // 0.5% TWAP deviation — small but cascading
            500, // 5% shock — USDC touched $0.87 briefly; DAI/FRAX followed
            "March 10-11, 2023: Silicon Valley Bank bank-run froze $3.3B of"
            " Circle's reserves. USDC depegged to $0.87, causing DAI to slip to"
            " $0.91. Stablecoin-collateralized lending protocols faced sudden"
            " collateral value drops across Aave, Compound, and MakerDAO."
        );

        _addScenario(
            SYNTHETIC_WORST_CASE,
            "Synthetic Worst-Case",
            2000, // 20% TWAP deviation — extreme oracle manipulation
            9000, // 90% shock — theoretical maximum cascade
            "Synthetic scenario combining maximum oracle manipulation pressure"
            " with a near-total price collapse. Used for worst-case capital"
            " adequacy stress testing. Not based on a real event."
        );
    }

    // =========================================================================
    // Core: Run Scenarios
    // =========================================================================

    /// @notice Runs a single named scenario against current on-chain state.
    /// @param scenarioId  One of the 5 built-in constants or a custom scenario ID.
    /// @param pool        The UniswapV3 pool to analyze.
    /// @param feed        The Chainlink price feed for the asset.
    /// @param asset       The tracked asset address (e.g. WETH) passed to CPLCS.
    /// @return result     Full ScenarioResult struct with all risk metrics.
    function runScenario(bytes32 scenarioId, address pool, address feed, address asset)
        external
        view
        returns (ScenarioResult memory result)
    {
        Scenario storage s = scenarios[scenarioId];
        if (bytes(s.name).length == 0) revert UnknownScenario(scenarioId);

        // ------------------------------------------------------------------
        // MCO: manipulation cost at scenario TWAP deviation
        // ------------------------------------------------------------------
        uint256 costUsd;
        uint256 mcoScore;
        try mco.getManipulationCostForPool(pool, feed, s.mcoDeviationBps) returns (uint256 c, uint256 sc) {
            costUsd = c;
            mcoScore = sc;
        } catch {
            costUsd = 0;
            mcoScore = 0; // unknown → worst case mcoInput = 100
        }

        // ------------------------------------------------------------------
        // TDRV: current realized vol (scenario does not change on-chain vol)
        // ------------------------------------------------------------------
        uint256 volBps;
        uint256 tdrvScore;
        try tdrv.getRealizedVolatilityForPool(pool, 60, 60) returns (uint256 v) {
            volBps = v;
        } catch {}
        try tdrv.getVolatilityScoreForPool(pool, 60, 60, VOL_LOW_BPS, VOL_HIGH_BPS) returns (uint256 vs) {
            tdrvScore = vs;
        } catch {
            tdrvScore = 100;
        }

        // ------------------------------------------------------------------
        // CPLCS: cascade at scenario shock
        // ------------------------------------------------------------------
        uint256 totalCollateral;
        uint256 cascadeScore;
        try cplcs.getCascadeScore(asset, s.cplcsShockBps) returns (
            ICrossProtocolCascadeScoreSSR.CascadeResult memory cr
        ) {
            totalCollateral = cr.totalCollateralUsd;
            cascadeScore = cr.cascadeScore;
        } catch {
            cascadeScore = 100;
        }

        // ------------------------------------------------------------------
        // Composite: MCO input is inverted (high security = low risk)
        // ------------------------------------------------------------------
        uint256 mcoInput = mcoScore >= 100 ? 0 : 100 - mcoScore;
        uint256 composite = (mcoInput * WEIGHT_MCO + tdrvScore * WEIGHT_TDRV + cascadeScore * WEIGHT_CPLCS)
            / (WEIGHT_MCO + WEIGHT_TDRV + WEIGHT_CPLCS);
        if (composite > 100) composite = 100;

        result = ScenarioResult({
            scenarioId: scenarioId,
            name: s.name,
            manipulationCostUsd: costUsd,
            mcoScore: mcoScore,
            realizedVolBps: volBps,
            tdrvScore: tdrvScore,
            totalCascadeCollateralUsd: totalCollateral,
            cascadeScore: cascadeScore,
            compositeRiskScore: composite,
            recommendedLtvBps: _scoreToLtv(composite),
            timestamp: block.timestamp
        });
    }

    /// @notice Runs all registered scenarios and returns an array of results.
    /// @dev    Gas-intensive — intended for off-chain `eth_call`, not on-chain use.
    function runAllScenarios(address pool, address feed, address asset)
        external
        view
        returns (ScenarioResult[] memory results)
    {
        results = new ScenarioResult[](scenarioIds.length);
        for (uint256 i = 0; i < scenarioIds.length; i++) {
            results[i] = this.runScenario(scenarioIds[i], pool, feed, asset);
        }
    }

    /// @notice Runs all scenarios and returns the one with the highest composite score.
    function worstCaseScenario(address pool, address feed, address asset)
        external
        view
        returns (ScenarioResult memory worst, bytes32 worstId)
    {
        for (uint256 i = 0; i < scenarioIds.length; i++) {
            ScenarioResult memory r = this.runScenario(scenarioIds[i], pool, feed, asset);
            if (r.compositeRiskScore > worst.compositeRiskScore) {
                worst = r;
                worstId = scenarioIds[i];
            }
        }
    }

    // =========================================================================
    // Custom Scenario Management
    // =========================================================================

    /// @notice Adds a custom scenario (owner only).
    /// @param id              Unique bytes32 identifier (use keccak256 of a string).
    /// @param name            Human-readable name.
    /// @param mcoDeviationBps TWAP deviation BPS for MCO query (1-5000).
    /// @param cplcsShockBps   Price shock BPS for CPLCS query (1-9999).
    /// @param description     Free-text description.
    function addCustomScenario(
        bytes32 id,
        string calldata name,
        uint256 mcoDeviationBps,
        uint256 cplcsShockBps,
        string calldata description
    ) external {
        if (msg.sender != owner) revert NotOwner();
        if (bytes(scenarios[id].name).length != 0) revert ScenarioAlreadyExists(id);
        if (scenarioIds.length >= MAX_CUSTOM_SCENARIOS + 5) revert ScenarioLimitReached();
        if (mcoDeviationBps == 0 || mcoDeviationBps > 5000) revert InvalidScenarioParams();
        if (cplcsShockBps == 0 || cplcsShockBps >= BPS) revert InvalidScenarioParams();

        _addScenario(id, name, mcoDeviationBps, cplcsShockBps, description);
        emit CustomScenarioAdded(id, name, mcoDeviationBps, cplcsShockBps);
    }

    // =========================================================================
    // Views
    // =========================================================================

    /// @notice Returns the total number of registered scenarios.
    function scenarioCount() external view returns (uint256) {
        return scenarioIds.length;
    }

    /// @notice Returns scenario metadata for a given ID.
    function getScenario(bytes32 id) external view returns (Scenario memory) {
        return scenarios[id];
    }

    // =========================================================================
    // Ownership
    // =========================================================================

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _addScenario(
        bytes32 id,
        string memory name,
        uint256 mcoDeviationBps,
        uint256 cplcsShockBps,
        string memory description
    ) internal {
        scenarios[id] = Scenario({
            id: id,
            name: name,
            mcoDeviationBps: mcoDeviationBps,
            cplcsShockBps: cplcsShockBps,
            description: description
        });
        scenarioIds.push(id);
    }

    function _scoreToLtv(uint256 score) internal pure returns (uint256) {
        if (score <= 25) return LTV_LOW;
        if (score <= 50) return LTV_MODERATE;
        if (score <= 75) return LTV_HIGH;
        return LTV_CRITICAL;
    }
}
