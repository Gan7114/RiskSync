// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// ─── Protocol Interfaces ─────────────────────────────────────────────────────

/// @notice Aave V3 Pool Data Provider interface (subset used).
interface IAaveV3DataProvider {
    function getReserveData(address asset)
        external
        view
        returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        );

    function getReserveConfigurationData(address asset)
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );
}

/// @notice Compound V3 (Comet) interface (subset used).
interface ICompoundV3Comet {
    struct TotalsCollateral {
        uint128 totalSupplyAsset;
        uint128 _reserved;
    }

    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }

    function totalsCollateral(address asset) external view returns (TotalsCollateral memory);
    function getAssetInfoByAddress(address asset) external view returns (AssetInfo memory);
    function decimals() external view returns (uint8);
}

/// @notice Morpho Blue interface (subset used).
interface IMorphoBlue {
    struct Market {
        uint128 totalSupplyAssets;
        uint128 totalSupplyShares;
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
        uint128 lastUpdate;
        uint128 fee;
    }

    struct MarketParams {
        address loanToken;
        address collateralToken;
        address oracle;
        address irm;
        uint256 lltv;
    }

    function market(bytes32 id) external view returns (Market memory);
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
}

/// @notice Euler V2 vault interface (ERC-4626 compatible).
///         Euler V2 vaults expose totalAssets() for collateral accounting and
///         a vault-level LTV/liquidation threshold configured at deployment.
///         Spark (SparkLend by MakerDAO) uses the same IAaveV3DataProvider interface
///         as Aave V3 — add it directly to the aaveDataProviders array.
interface IEulerV2Vault {
    /// @dev ERC-4626: Total assets managed by this vault (in asset-native units).
    function totalAssets() external view returns (uint256);
}

/// @notice Uniswap V3 pool interface for pool depth reads.
interface IUniswapV3PoolCPCS {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );

    function liquidity() external view returns (uint128);
}

/// @title CrossProtocolCascadeScore
/// @notice Measures CROSS-PROTOCOL LIQUIDATION CASCADE RISK for a given asset
///         by reading live on-chain exposure from Aave V3, Compound V3, and Morpho Blue.
///
/// @dev ── THE NOVEL INSIGHT ──────────────────────────────────────────────────────
///
///      Every lending protocol measures its own risk in ISOLATION:
///        - Aave knows Aave's exposure to ETH
///        - Compound knows Compound's exposure to ETH
///        - Morpho knows Morpho's exposure to ETH
///
///      None of them answer: "If ETH drops 20%, what happens when ALL PROTOCOLS
///      liquidate at the same time?"
///
///      The cascade problem:
///        1. ETH drops 15% (initial shock)
///        2. Aave liquidates $500M in ETH collateral → more ETH selling
///        3. That selling causes an additional 3% ETH drop
///        4. That 3% drop triggers Compound liquidations → more ETH selling
///        5. That triggers Morpho liquidations...
///        6. Total impact = 15% + 3% + 2% + 1% = 21% (not just 15%)
///
///      The "cascade amplification" factor = totalImpact / initialShock = 21/15 = 1.4x
///
///      This is why:
///        - LUNA collapse: initial depeg was 10%, final was 100% (10x amplification)
///        - March 2020 crash: ETH hit -60% intraday partly due to liquidation cascades
///        - These events caught every protocol off guard because they measured in isolation
///
///      ── WHAT THIS CONTRACT DOES ─────────────────────────────────────────────────
///
///      1. Reads REAL ON-CHAIN aggregate collateral exposure from 3 major protocols
///      2. Models the liquidation fraction at the given shock level
///      3. Estimates the additional DEX price impact from cascaded liquidations
///      4. Computes the amplification factor: how much worse the cascade makes the initial shock
///      5. Returns a 0-100 cascade risk score
///
///      ── WHAT NO EXISTING CONTRACT DOES ─────────────────────────────────────────
///
///      No single on-chain contract currently:
///        - Aggregates collateral exposure across multiple protocols simultaneously
///        - Models the price feedback loop between liquidations and pool depth
///        - Exposes cascade amplification as a queryable on-chain function
///
///      Gauntlet models cross-protocol contagion off-chain.
///      This contract makes it real-time and on-chain.
///
/// @dev ── PROTOCOL CONFIGURATION ─────────────────────────────────────────────────
///      The contract accepts configurable protocol lists at deploy time.
///      Any combination of Aave V3, Compound V3, and Morpho Blue can be included.
///      Uses try/catch for all external reads so a single protocol outage
///      does not break the entire cascade score calculation.
contract CrossProtocolCascadeScore {
    using Math for uint256;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidConfig();
    error InvalidShock();
    error InvalidPool();
    error StaleChainlinkFeed();
    error InvalidChainlinkData();
    error TooManyProtocols();

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 private constant BPS           = 10_000;
    uint256 private constant MAX_SCORE     = 100;
    uint256 private constant Q96           = 0x1000000000000000000000000;
    uint256 private constant MAX_STALENESS = 3600;

    /// @notice Maximum number of configured protocols per type to bound gas.
    uint8 public constant MAX_PROTOCOLS = 5;

    /// @notice Cascade amplification above which score = 100.
    ///         2x = a 10% shock turns into a 20% total impact before settling.
    uint256 public constant AMPLIFICATION_SCORE_CAP_BPS = 20_000; // 2.0x

    /// @notice Maximum cascade iteration rounds.
    ///         Real cascades converge geometrically: round 1 → 50% of subsequent impact,
    ///         round 2 → 25%, etc. 8 rounds captures >99.6% of the total cascade effect.
    uint8 public constant MAX_CASCADE_ITERATIONS = 8;

    /// @notice Convergence threshold in BPS. Iteration stops when additional
    ///         secondary impact falls below this (1 bps = 0.01%).
    uint256 public constant CASCADE_CONVERGENCE_BPS = 1;

    // ─── Protocol Configuration Structs ──────────────────────────────────────

    struct AaveConfig {
        IAaveV3DataProvider dataProvider;
        uint8 assetDecimals;
    }

    struct CompoundConfig {
        ICompoundV3Comet comet;
        uint8 assetDecimals;
    }

    struct MorphoConfig {
        IMorphoBlue morpho;
        bytes32 marketId;
        uint8 assetDecimals;
    }

    /// @notice Euler V2 ERC-4626 vault configuration.
    /// @dev    liquidationThresholdBps is set by the deployer to match the vault's
    ///         configured LTV (e.g., 7500 for a 75% LTV vault).
    struct EulerV2Config {
        IEulerV2Vault vault;
        uint256 liquidationThresholdBps; // vault-level LTV (e.g., 7500 = 75%)
        uint8 assetDecimals;
    }

    // ─── Cascade Result ───────────────────────────────────────────────────────

    struct CascadeResult {
        uint256 totalCollateralUsd;       // Aggregate collateral across all protocols (1e8)
        uint256 estimatedLiquidationUsd;  // Estimated liquidation volume at shockBps (1e8)
        uint256 secondaryPriceImpactBps;  // Additional price drop from cascade liquidations
        uint256 totalImpactBps;           // initialShock + secondaryImpact
        uint256 amplificationBps;         // totalImpact / initialShock in BPS (10000 = 1x)
        uint256 cascadeScore;             // 0-100 risk score
    }

    // ─── Immutables ───────────────────────────────────────────────────────────

    AggregatorV3Interface public immutable assetUsdFeed;
    uint8 public immutable assetFeedDecimals;
    uint8 public immutable assetDecimals;

    IUniswapV3PoolCPCS public immutable liquidityPool;

    AaveConfig[] private _aaveConfigs;
    CompoundConfig[] private _compoundConfigs;
    MorphoConfig[] private _morphoConfigs;
    EulerV2Config[] private _eulerV2Configs;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _assetUsdFeed          Chainlink feed for the tracked asset (e.g., ETH/USD).
    /// @param _assetDecimals         Decimals of the tracked asset (e.g., 18 for WETH).
    /// @param _liquidityPool         Uniswap V3 pool used to estimate DEX liquidation impact.
    /// @param aaveDataProviders      Aave V3 (or Spark — same interface) data providers.
    /// @param aaveAssetDecimals      Decimals for the asset in each Aave/Spark instance.
    /// @param cometAddresses         Compound V3 Comet addresses to query.
    /// @param cometAssetDecs         Decimals for the asset in each Comet instance.
    /// @param morphoAddresses        Morpho Blue addresses to query.
    /// @param morphoMarketIds        Market IDs (bytes32) for each Morpho instance.
    /// @param morphoAssetDecs        Decimals for the asset in each Morpho market.
    /// @param eulerVaultAddresses    Euler V2 ERC-4626 vault addresses (optional, pass empty).
    /// @param eulerLiqThresholdsBps  Liquidation thresholds per Euler vault in BPS.
    /// @param eulerAssetDecs         Asset decimals per Euler vault.
    constructor(
        address _assetUsdFeed,
        uint8 _assetDecimals,
        address _liquidityPool,
        address[] memory aaveDataProviders,
        uint8[] memory aaveAssetDecimals,
        address[] memory cometAddresses,
        uint8[] memory cometAssetDecs,
        address[] memory morphoAddresses,
        bytes32[] memory morphoMarketIds,
        uint8[] memory morphoAssetDecs,
        address[] memory eulerVaultAddresses,
        uint256[] memory eulerLiqThresholdsBps,
        uint8[] memory eulerAssetDecs
    ) {
        if (_assetUsdFeed == address(0) || _liquidityPool == address(0)) revert InvalidConfig();
        if (_assetDecimals > 18) revert InvalidConfig();

        if (aaveDataProviders.length > MAX_PROTOCOLS) revert TooManyProtocols();
        if (cometAddresses.length > MAX_PROTOCOLS) revert TooManyProtocols();
        if (morphoAddresses.length > MAX_PROTOCOLS) revert TooManyProtocols();
        if (eulerVaultAddresses.length > MAX_PROTOCOLS) revert TooManyProtocols();

        if (aaveDataProviders.length != aaveAssetDecimals.length) revert InvalidConfig();
        if (cometAddresses.length != cometAssetDecs.length) revert InvalidConfig();
        if (morphoAddresses.length != morphoMarketIds.length) revert InvalidConfig();
        if (morphoAddresses.length != morphoAssetDecs.length) revert InvalidConfig();
        if (eulerVaultAddresses.length != eulerLiqThresholdsBps.length) revert InvalidConfig();
        if (eulerVaultAddresses.length != eulerAssetDecs.length) revert InvalidConfig();

        assetUsdFeed = AggregatorV3Interface(_assetUsdFeed);
        assetDecimals = _assetDecimals;
        liquidityPool = IUniswapV3PoolCPCS(_liquidityPool);

        uint8 dec = assetUsdFeed.decimals();
        if (dec > 18) revert InvalidConfig();
        assetFeedDecimals = dec;

        for (uint256 i; i < aaveDataProviders.length; ) {
            if (aaveDataProviders[i] == address(0)) revert InvalidConfig();
            _aaveConfigs.push(AaveConfig({
                dataProvider: IAaveV3DataProvider(aaveDataProviders[i]),
                assetDecimals: aaveAssetDecimals[i]
            }));
            unchecked { ++i; }
        }

        for (uint256 i; i < cometAddresses.length; ) {
            if (cometAddresses[i] == address(0)) revert InvalidConfig();
            _compoundConfigs.push(CompoundConfig({
                comet: ICompoundV3Comet(cometAddresses[i]),
                assetDecimals: cometAssetDecs[i]
            }));
            unchecked { ++i; }
        }

        for (uint256 i; i < morphoAddresses.length; ) {
            if (morphoAddresses[i] == address(0)) revert InvalidConfig();
            _morphoConfigs.push(MorphoConfig({
                morpho: IMorphoBlue(morphoAddresses[i]),
                marketId: morphoMarketIds[i],
                assetDecimals: morphoAssetDecs[i]
            }));
            unchecked { ++i; }
        }

        for (uint256 i; i < eulerVaultAddresses.length; ) {
            if (eulerVaultAddresses[i] == address(0)) revert InvalidConfig();
            if (eulerLiqThresholdsBps[i] == 0 || eulerLiqThresholdsBps[i] > BPS) revert InvalidConfig();
            _eulerV2Configs.push(EulerV2Config({
                vault: IEulerV2Vault(eulerVaultAddresses[i]),
                liquidationThresholdBps: eulerLiqThresholdsBps[i],
                assetDecimals: eulerAssetDecs[i]
            }));
            unchecked { ++i; }
        }
    }

    // ─── Primary Interface ────────────────────────────────────────────────────

    /// @notice Computes the cross-protocol cascade score for a given shock scenario.
    ///
    /// @dev Algorithm:
    ///        1. Read current asset USD price from Chainlink
    ///        2. Read total collateral (in asset units) from each configured protocol
    ///        3. Convert to USD using current price
    ///        4. Estimate liquidation fraction at shockBps using avg liquidation threshold
    ///           Model: positions within (100% - avgLT) of LT are at risk
    ///           fractionAtRisk ≈ shockBps / (10000 - avgLiquidationThreshold)
    ///        5. estimatedLiquidation = totalCollateral × fractionAtRisk
    ///        6. Secondary price impact = estimatedLiquidation / (2 × poolDepthUsd)
    ///           (factor of 2: pool depth available on both sides)
    ///        7. totalImpact = shockBps + secondaryImpactBps
    ///        8. amplification = totalImpact × 10000 / shockBps (in BPS)
    ///        9. cascadeScore = linear scale from 1.0x to AMPLIFICATION_SCORE_CAP_BPS
    ///
    /// @param asset    The collateral asset address (must match configured Chainlink feed).
    /// @param shockBps Initial price shock in basis points (e.g., 1000 = 10% drop).
    ///
    /// @return result  Full cascade analysis.
    function getCascadeScore(address asset, uint256 shockBps)
        external
        view
        returns (CascadeResult memory result)
    {
        if (asset == address(0)) revert InvalidConfig();
        if (shockBps == 0 || shockBps > 9_000) revert InvalidShock();

        uint256 assetUsdPrice = _readAssetUsdPrice();

        // 1. Aggregate total collateral exposure across all protocols.
        (uint256 totalCollateralAsset, uint256 weightedLiqThresholdBps) =
            _aggregateCollateralAndThreshold(asset);

        // 2. Convert collateral to USD (1e8 precision).
        result.totalCollateralUsd = Math.mulDiv(
            totalCollateralAsset,
            assetUsdPrice,
            10 ** uint256(assetDecimals)
        );

        // 3. Safety margin: how far price must drop before positions start liquidating.
        //    Model: positions are uniformly distributed near their liquidation threshold.
        //    safetyMarginBps = 10000 - weightedLiqThresholdBps
        //    (e.g., 80% LT → 20% safety margin; a 20% drop liquidates everyone at threshold)
        uint256 safetyMarginBps = BPS > weightedLiqThresholdBps
            ? BPS - weightedLiqThresholdBps
            : 100; // minimum 1% safety margin to avoid division by zero

        uint256 poolDepthUsd = _readPoolDepthUsd(assetUsdPrice);

        // 4. ITERATIVE CASCADE MODEL — extracted to avoid stack-too-deep.
        //    See _runCascadeIterations() for the full algorithm description.
        (uint256 totalLiquidationUsd, uint256 totalSecondaryImpactBps) =
            _runCascadeIterations(result.totalCollateralUsd, shockBps, safetyMarginBps, poolDepthUsd);

        result.estimatedLiquidationUsd  = totalLiquidationUsd;
        result.secondaryPriceImpactBps  = totalSecondaryImpactBps;

        // 5. Total impact = initial shock + all cascade rounds of secondary impact.
        result.totalImpactBps = shockBps + result.secondaryPriceImpactBps;

        // 6. Amplification factor in BPS (10000 = 1.0x no cascade, 20000 = 2.0x severe cascade).
        result.amplificationBps = Math.mulDiv(result.totalImpactBps, BPS, shockBps);

        // 7. Score: linear from 10000 (1.0x = no cascade = score 0)
        //           to AMPLIFICATION_SCORE_CAP_BPS (score 100).
        uint256 amplificationAbove1x = result.amplificationBps > BPS
            ? result.amplificationBps - BPS
            : 0;
        uint256 scoreRange = AMPLIFICATION_SCORE_CAP_BPS - BPS;

        result.cascadeScore = amplificationAbove1x >= scoreRange
            ? MAX_SCORE
            : Math.mulDiv(amplificationAbove1x, MAX_SCORE, scoreRange);
    }

    /// @notice Returns the total tracked collateral across all configured protocols.
    /// @param asset The collateral asset to query.
    /// @return totalCollateralUsd Total USD value of collateral (1e8 precision).
    function getTotalCollateralUsd(address asset)
        external
        view
        returns (uint256 totalCollateralUsd)
    {
        uint256 assetUsdPrice = _readAssetUsdPrice();
        (uint256 totalCollateralAsset, ) = _aggregateCollateralAndThreshold(asset);
        totalCollateralUsd = Math.mulDiv(
            totalCollateralAsset,
            assetUsdPrice,
            10 ** uint256(assetDecimals)
        );
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    /// @dev Runs the iterative cascade convergence model.
    ///
    ///      Real cascades proceed in rounds:
    ///        Round 0: initial shock = shockBps (exogenous event)
    ///        Each round k:
    ///          accumulatedDrop increases by this round's impact
    ///          fractionAtRisk = min(accumulatedDrop / safetyMargin, 100%)
    ///          incrementalLiquidation = collateral × (fractionAtRisk - alreadyLiquidated)
    ///          secondaryImpact[k] = incrementalLiquidation / (2 × poolDepth)
    ///          accumulatedDrop increases by secondaryImpact[k]
    ///        Stop when secondaryImpact < CASCADE_CONVERGENCE_BPS or MAX_CASCADE_ITERATIONS reached.
    ///
    ///      Extracted from getCascadeScore() to give it its own stack frame and avoid
    ///      the EVM stack-too-deep error from the parent function's many locals.
    ///
    /// @return totalLiquidationUsd     Cumulative USD value liquidated across all rounds (1e8).
    /// @return totalSecondaryImpactBps Cumulative secondary price impact in BPS (capped at 5000).
    function _runCascadeIterations(
        uint256 totalCollateralUsd,
        uint256 shockBps,
        uint256 safetyMarginBps,
        uint256 poolDepthUsd
    ) internal pure returns (uint256 totalLiquidationUsd, uint256 totalSecondaryImpactBps) {
        uint256 accumulatedDropBps   = shockBps;
        uint256 alreadyLiquidatedBps = 0;

        for (uint8 iter = 0; iter < MAX_CASCADE_ITERATIONS; ) {
            // Fraction of total collateral now underwater.
            uint256 fractionAtRiskBps = accumulatedDropBps >= safetyMarginBps
                ? BPS
                : Math.mulDiv(accumulatedDropBps, BPS, safetyMarginBps);

            // Incremental fraction newly at risk this round.
            uint256 incrementalFractionBps = fractionAtRiskBps > alreadyLiquidatedBps
                ? fractionAtRiskBps - alreadyLiquidatedBps
                : 0;

            if (incrementalFractionBps == 0) break;

            uint256 roundLiquidationUsd = Math.mulDiv(totalCollateralUsd, incrementalFractionBps, BPS);
            totalLiquidationUsd += roundLiquidationUsd;
            alreadyLiquidatedBps = fractionAtRiskBps;

            // Secondary price impact: selling into DEX pool.
            uint256 roundImpactBps = 0;
            if (poolDepthUsd > 0) {
                roundImpactBps = Math.mulDiv(roundLiquidationUsd, BPS, 2 * poolDepthUsd);
            }

            totalSecondaryImpactBps += roundImpactBps;
            accumulatedDropBps += roundImpactBps;

            if (roundImpactBps <= CASCADE_CONVERGENCE_BPS) break;

            unchecked { ++iter; }
        }

        // Cap secondary impact at 50% — a price drop beyond this would trigger other
        // mechanisms (circuit breakers, protocol pauses) not modelled here.
        if (totalSecondaryImpactBps > 5_000) totalSecondaryImpactBps = 5_000;
    }

    /// @dev Reads and aggregates collateral exposure from all configured protocols.
    ///      Uses try/catch per protocol — a single protocol failure does not revert.
    ///
    /// @return totalAssetUnits        Total collateral in asset-native units (1e{assetDecimals}).
    /// @return weightedLiqThreshold   Collateral-weighted average liquidation threshold (BPS).
    function _aggregateCollateralAndThreshold(address asset)
        internal
        view
        returns (uint256 totalAssetUnits, uint256 weightedLiqThreshold)
    {
        uint256 weightedSum = 0;
        uint256 totalForWeight = 0;

        // ── Aave V3 ──────────────────────────────────────────────────────────
        uint256 aaveLen = _aaveConfigs.length;
        for (uint256 i; i < aaveLen; ) {
            try _aaveConfigs[i].dataProvider.getReserveData(asset) returns (
                uint256, uint256, uint256 totalAToken, uint256, uint256,
                uint256, uint256, uint256, uint256, uint256, uint256, uint40
            ) {
                uint256 collateral = _scaleToAssetDecimals(totalAToken, _aaveConfigs[i].assetDecimals);
                totalAssetUnits += collateral;

                // Fetch liquidation threshold for weighting.
                try _aaveConfigs[i].dataProvider.getReserveConfigurationData(asset) returns (
                    uint256, uint256, uint256 liqThreshold, uint256, uint256,
                    bool, bool, bool, bool, bool
                ) {
                    // Aave liquidation threshold is in BPS (e.g., 8000 = 80%).
                    weightedSum += collateral * liqThreshold;
                    totalForWeight += collateral;
                } catch {}
            } catch {}
            unchecked { ++i; }
        }

        // ── Compound V3 ──────────────────────────────────────────────────────
        uint256 compLen = _compoundConfigs.length;
        for (uint256 i; i < compLen; ) {
            try _compoundConfigs[i].comet.totalsCollateral(asset) returns (
                ICompoundV3Comet.TotalsCollateral memory totals
            ) {
                uint256 collateral = _scaleToAssetDecimals(
                    uint256(totals.totalSupplyAsset),
                    _compoundConfigs[i].assetDecimals
                );
                totalAssetUnits += collateral;

                // Compound liquidateCollateralFactor is in 1e18; convert to BPS.
                try _compoundConfigs[i].comet.getAssetInfoByAddress(asset) returns (
                    ICompoundV3Comet.AssetInfo memory info
                ) {
                    // liquidateCollateralFactor is 1e18 scaled (e.g., 0.9e18 = 90% = 9000 bps)
                    uint256 liqThreshBps = Math.mulDiv(uint256(info.liquidateCollateralFactor), BPS, 1e18);
                    weightedSum += collateral * liqThreshBps;
                    totalForWeight += collateral;
                } catch {}
            } catch {}
            unchecked { ++i; }
        }

        // ── Morpho Blue ───────────────────────────────────────────────────────
        uint256 morphoLen = _morphoConfigs.length;
        for (uint256 i; i < morphoLen; ) {
            try _morphoConfigs[i].morpho.market(_morphoConfigs[i].marketId) returns (
                IMorphoBlue.Market memory mkt
            ) {
                uint256 collateral = _scaleToAssetDecimals(
                    uint256(mkt.totalSupplyAssets),
                    _morphoConfigs[i].assetDecimals
                );
                totalAssetUnits += collateral;

                // Morpho LLTV is in 1e18; convert to BPS.
                try _morphoConfigs[i].morpho.idToMarketParams(_morphoConfigs[i].marketId) returns (
                    IMorphoBlue.MarketParams memory params
                ) {
                    uint256 lltvBps = Math.mulDiv(params.lltv, BPS, 1e18);
                    weightedSum += collateral * lltvBps;
                    totalForWeight += collateral;
                } catch {}
            } catch {}
            unchecked { ++i; }
        }

        // ── Euler V2 (ERC-4626) ───────────────────────────────────────────────
        // Euler V2 vaults expose totalAssets() for the total collateral held.
        // Liquidation threshold is statically configured at deployment time.
        // Spark (SparkLend) uses AaveV3DataProvider — add to aaveDataProviders array.
        uint256 eulerLen = _eulerV2Configs.length;
        for (uint256 i; i < eulerLen; ) {
            try _eulerV2Configs[i].vault.totalAssets() returns (uint256 total) {
                uint256 collateral = _scaleToAssetDecimals(total, _eulerV2Configs[i].assetDecimals);
                totalAssetUnits += collateral;
                weightedSum += collateral * _eulerV2Configs[i].liquidationThresholdBps;
                totalForWeight += collateral;
            } catch {}
            unchecked { ++i; }
        }

        // Compute collateral-weighted average liquidation threshold.
        weightedLiqThreshold = totalForWeight > 0
            ? weightedSum / totalForWeight
            : 8_000; // fallback: assume 80% LT if no data
    }

    /// @dev Estimates the USD depth of the configured Uniswap V3 pool.
    ///      Uses current liquidity and sqrtPriceX96 to approximate value in pool.
    ///      poolDepthUsd ≈ 2 × liquidity × spotPrice^(0.5) / Q48
    ///      Simplified: depth ≈ liquidity × sqrtPriceX96 / Q96 × 2 × spotPrice
    function _readPoolDepthUsd(uint256 assetUsdPrice) internal view returns (uint256 depthUsd) {
        try liquidityPool.slot0() returns (
            uint160 sqrtPriceX96, int24, uint16, uint16, uint16, uint8, bool unlocked
        ) {
            if (!unlocked || sqrtPriceX96 == 0) return 0;

            try liquidityPool.liquidity() returns (uint128 currentLiquidity) {
                if (currentLiquidity == 0) return 0;

                // Approximate token0 in range: amount0 ≈ liquidity / sqrtPrice (in Q96)
                // amount0 = liquidity × Q96 / sqrtPriceX96 (simplified one-sided)
                uint256 token0Amount = Math.mulDiv(
                    uint256(currentLiquidity),
                    Q96,
                    uint256(sqrtPriceX96)
                );

                // USD value of token0 side (1e8 precision from Chainlink).
                depthUsd = Math.mulDiv(
                    token0Amount,
                    assetUsdPrice,
                    10 ** uint256(assetDecimals)
                );

                // Pool has both sides; double for total depth approximation.
                depthUsd = depthUsd * 2;
            } catch {
                return 0;
            }
        } catch {
            return 0;
        }
    }

    /// @dev Reads the asset USD price from Chainlink. Reverts if stale or invalid.
    function _readAssetUsdPrice() internal view returns (uint256) {
        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = assetUsdFeed.latestRoundData();

        if (answer <= 0 || updatedAt == 0 || answeredInRound < roundId) {
            revert InvalidChainlinkData();
        }
        if (block.timestamp > updatedAt + MAX_STALENESS) {
            revert StaleChainlinkFeed();
        }

        return uint256(answer);
    }

    /// @dev Scales a value from protocol-native decimals to assetDecimals (1e{assetDecimals}).
    function _scaleToAssetDecimals(uint256 value, uint8 fromDecimals)
        internal
        view
        returns (uint256)
    {
        uint8 to = assetDecimals;
        if (fromDecimals == to) return value;
        if (fromDecimals < to) return value * (10 ** uint256(to - fromDecimals));
        return value / (10 ** uint256(fromDecimals - to));
    }

    // ─── View helpers ─────────────────────────────────────────────────────────

    function aaveConfigCount() external view returns (uint256) { return _aaveConfigs.length; }
    function compoundConfigCount() external view returns (uint256) { return _compoundConfigs.length; }
    function morphoConfigCount() external view returns (uint256) { return _morphoConfigs.length; }
    function eulerV2ConfigCount() external view returns (uint256) { return _eulerV2Configs.length; }
}
