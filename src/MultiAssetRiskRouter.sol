// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AssetRegistry} from "./AssetRegistry.sol";

interface IManipulationCostOracleRouter {
    function getManipulationCostForPool(
        address _pool,
        address _token1UsdFeed,
        uint256 targetDeviationBps
    ) external view returns (uint256 costUsd, uint256 securityScore);

    function getManipulationCostForPool(
        address _pool,
        address _token1UsdFeed,
        uint256 targetDeviationBps,
        uint8 token1Decimals
    ) external view returns (uint256 costUsd, uint256 securityScore);

    function getManipulationCostForPoolWithDecimals(
        address _pool,
        address _token1UsdFeed,
        uint256 targetDeviationBps,
        uint8 token1Decimals
    ) external view returns (uint256 costUsd, uint256 securityScore);
}

interface ITickDerivedRealizedVolatilityRouter {
    function getVolatilityScoreForPool(
        address pool,
        uint32 interval,
        uint8 nSamples,
        uint256 lowVolThresholdBps,
        uint256 highVolThresholdBps
    ) external view returns (uint256 volScore);

    function getRealizedVolatilityForPool(
        address pool,
        uint32 interval,
        uint8 nSamples
    ) external view returns (uint256 annualizedVolBps);
}

interface ICrossProtocolCascadeScoreRouter {
    struct CascadeResult {
        uint256 totalCollateralUsd;
        uint256 estimatedLiquidationUsd;
        uint256 secondaryPriceImpactBps;
        uint256 totalImpactBps;
        uint256 amplificationBps;
        uint256 cascadeScore;
    }

    function getCascadeScore(address cascadeAsset, uint256 shockBps)
        external
        view
        returns (CascadeResult memory result);
}

interface ITickConcentrationOracleRouter {
    function getConcentrationScoreForPool(address pool, uint32 windowSeconds, uint8 numSamples)
        external
        view
        returns (uint256);
}

/// @title MultiAssetRiskRouter
/// @notice Composes MCO/TDRV/CPLCS/TCO into per-asset cached risk states.
contract MultiAssetRiskRouter is Ownable {
    using Math for uint256;

    AssetRegistry public immutable registry;
    IManipulationCostOracleRouter public immutable mco;
    ITickDerivedRealizedVolatilityRouter public immutable tdrv;
    ICrossProtocolCascadeScoreRouter public immutable cplcs;
    ITickConcentrationOracleRouter public immutable tco;

    enum RiskTier {
        LOW,
        MODERATE,
        HIGH,
        CRITICAL
    }

    struct RiskState {
        uint256 score;
        uint256 mcoInput;
        uint256 tdrvInput;
        uint256 cpInput;
        uint256 tcoInput;
        RiskTier tier;
        uint256 recommendedLtv;
        uint256 realizedVolBps;
        uint256 manipulationCostUsd;
        uint256 ewmaScore;
        uint256 updatedAt;
    }

    mapping(address => RiskState) public assetRiskState;

    uint256 public constant MIN_UPDATE_INTERVAL = 60;
    uint256 public constant DEFAULT_DEVIATION_BPS = 200;

    uint32 public constant TDRV_INTERVAL = 1 hours;
    uint8 public constant TDRV_SAMPLES = 24;
    uint256 public constant LOW_VOL_THRESHOLD_BPS = 2_000;
    uint256 public constant HIGH_VOL_THRESHOLD_BPS = 15_000;

    uint32 public constant TCO_WINDOW_SECONDS = 24 hours;
    uint8 public constant TCO_SAMPLES = 24;

    uint256 private constant LTV_LOW = 8_000;
    uint256 private constant LTV_MODERATE = 7_500;
    uint256 private constant LTV_HIGH = 6_500;
    uint256 private constant LTV_CRITICAL = 5_000;

    uint256 private constant TIER_MODERATE_THRESHOLD = 26;
    uint256 private constant TIER_HIGH_THRESHOLD = 51;
    uint256 private constant TIER_CRITICAL_THRESHOLD = 76;
    uint256 private constant EWMA_ALPHA_BPS = 3_000;

    uint8 public mcoWeight;
    uint8 public tdrvWeight;
    uint8 public cpWeight;
    uint8 public tcoWeight;

    event RiskUpdated(
        address indexed asset,
        uint256 score,
        RiskTier tier,
        uint256 recommendedLtv,
        uint256 updatedAt,
        uint256 mcoInput,
        uint256 tdrvInput,
        uint256 cpInput,
        uint256 tcoInput
    );
    event AssetUpdateFailed(address indexed asset, bytes reason);
    event WeightsUpdated(uint8 mcoWeight, uint8 tdrvWeight, uint8 cpWeight, uint8 tcoWeight);

    error AssetNotConfigured();
    error AssetNotEnabled();
    error CooldownActive(uint256 nextAllowed);
    error InvalidWeights();

    constructor(
        address _registry,
        address _mco,
        address _tdrv,
        address _cplcs,
        address _tco,
        uint8 _mcoWeight,
        uint8 _tdrvWeight,
        uint8 _cpWeight,
        uint8 _tcoWeight
    ) Ownable(msg.sender) {
        registry = AssetRegistry(_registry);
        mco = IManipulationCostOracleRouter(_mco);
        tdrv = ITickDerivedRealizedVolatilityRouter(_tdrv);
        cplcs = ICrossProtocolCascadeScoreRouter(_cplcs);
        tco = ITickConcentrationOracleRouter(_tco);
        setWeights(_mcoWeight, _tdrvWeight, _cpWeight, _tcoWeight);
    }

    function setWeights(uint8 _mcoWeight, uint8 _tdrvWeight, uint8 _cpWeight, uint8 _tcoWeight)
        public
        onlyOwner
    {
        uint256 total = uint256(_mcoWeight) + uint256(_tdrvWeight) + uint256(_cpWeight) + uint256(_tcoWeight);
        if (total != 100) revert InvalidWeights();
        if (address(tco) == address(0) && _tcoWeight != 0) revert InvalidWeights();

        mcoWeight = _mcoWeight;
        tdrvWeight = _tdrvWeight;
        cpWeight = _cpWeight;
        tcoWeight = _tcoWeight;

        emit WeightsUpdated(_mcoWeight, _tdrvWeight, _cpWeight, _tcoWeight);
    }

    /// @notice Update one configured asset. Reverts on disabled/config/cooldown issues.
    function updateRiskForAsset(address asset)
        external
        returns (uint256 score, RiskTier tier, uint256 recommendedLtv)
    {
        (score, tier, recommendedLtv) = _updateRiskForAsset(asset);
    }

    /// @notice Update multiple assets and isolate failures.
    function updateRiskForAssets(address[] calldata assets) external returns (uint256 updatedCount, uint256 failedCount) {
        for (uint256 i = 0; i < assets.length; ) {
            try this.updateRiskForAsset(assets[i]) {
                updatedCount++;
            } catch (bytes memory reason) {
                failedCount++;
                emit AssetUpdateFailed(assets[i], reason);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice IRiskScoreProvider compatibility.
    function getRiskScore(address asset) external view returns (uint256) {
        return assetRiskState[asset].score;
    }

    /// @notice Single-asset compatibility: returns first enabled asset score.
    function getRiskScore() external view returns (uint256) {
        address fallbackAsset = _firstEnabledAsset();
        if (fallbackAsset == address(0)) return 0;
        return assetRiskState[fallbackAsset].score;
    }

    /// @notice Timestamp of latest score update for a specific asset.
    function lastUpdatedAt(address asset) external view returns (uint256) {
        return assetRiskState[asset].updatedAt;
    }

    /// @notice Single-asset compatibility: timestamp for first enabled asset.
    function lastUpdatedAt() external view returns (uint256) {
        address fallbackAsset = _firstEnabledAsset();
        if (fallbackAsset == address(0)) return 0;
        return assetRiskState[fallbackAsset].updatedAt;
    }

    function _updateRiskForAsset(address asset)
        internal
        returns (uint256 score, RiskTier tier, uint256 recommendedLtv)
    {
        AssetRegistry.AssetConfig memory config;
        try registry.getConfig(asset) returns (AssetRegistry.AssetConfig memory cfg) {
            config = cfg;
        } catch {
            revert AssetNotConfigured();
        }

        if (!config.enabled) revert AssetNotEnabled();

        RiskState storage state = assetRiskState[asset];
        uint256 nowTs = block.timestamp;
        if (state.updatedAt != 0 && nowTs < state.updatedAt + MIN_UPDATE_INTERVAL) {
            revert CooldownActive(state.updatedAt + MIN_UPDATE_INTERVAL);
        }

        (uint256 mcoInput, uint256 manipCostUsd) = _readMco(config);
        (uint256 tdrvInput, uint256 realizedVolBps) = _readTdrv(config.pool);
        uint256 cpInput = _readCp(config.asset, config.shockBps);
        uint256 tcoInput = _readTco(config.pool);

        uint256 weightedSum = (uint256(mcoWeight) * mcoInput) + (uint256(tdrvWeight) * tdrvInput)
            + (uint256(cpWeight) * cpInput) + (uint256(tcoWeight) * tcoInput);
        uint256 composite = weightedSum / 100;

        (RiskTier resolvedTier, uint256 ltv) = _tierForScore(composite);
        uint256 newEwma = state.updatedAt == 0
            ? composite
            : ((composite * EWMA_ALPHA_BPS) + (state.ewmaScore * (10_000 - EWMA_ALPHA_BPS))) / 10_000;

        state.score = composite;
        state.mcoInput = mcoInput;
        state.tdrvInput = tdrvInput;
        state.cpInput = cpInput;
        state.tcoInput = tcoInput;
        state.tier = resolvedTier;
        state.recommendedLtv = ltv;
        state.realizedVolBps = realizedVolBps;
        state.manipulationCostUsd = manipCostUsd;
        state.ewmaScore = newEwma;
        state.updatedAt = nowTs;

        emit RiskUpdated(asset, composite, resolvedTier, ltv, nowTs, mcoInput, tdrvInput, cpInput, tcoInput);

        return (composite, resolvedTier, ltv);
    }

    function _readMco(AssetRegistry.AssetConfig memory config) internal view returns (uint256 mcoInput, uint256 manipCostUsd) {
        uint256 costUsd;
        uint256 score;

        // Prefer decimals-aware overload.
        try mco.getManipulationCostForPool(config.pool, config.feed, DEFAULT_DEVIATION_BPS, config.token1Decimals)
        returns (uint256 _costUsd, uint256 _score) {
            costUsd = _costUsd;
            score = _score;
        } catch {
            // Backward compatibility path for old deployments.
            try mco.getManipulationCostForPoolWithDecimals(
                config.pool, config.feed, DEFAULT_DEVIATION_BPS, config.token1Decimals
            ) returns (uint256 _costUsd, uint256 _score) {
                costUsd = _costUsd;
                score = _score;
            } catch {
                try mco.getManipulationCostForPool(config.pool, config.feed, DEFAULT_DEVIATION_BPS) returns (
                    uint256 _costUsd,
                    uint256 _score
                ) {
                    costUsd = _costUsd;
                    score = _score;
                } catch {
                    return (100, 0);
                }
            }
        }

        // Score normalization to per-asset config thresholds.
        if (costUsd <= config.mcoThresholdLow) {
            score = 0;
        } else if (costUsd >= config.mcoThresholdHigh) {
            score = 100;
        } else {
            score = Math.mulDiv(costUsd - config.mcoThresholdLow, 100, config.mcoThresholdHigh - config.mcoThresholdLow);
        }

        mcoInput = 100 - Math.min(score, 100);
        manipCostUsd = costUsd;
    }

    function _readTdrv(address pool) internal view returns (uint256 tdrvInput, uint256 realizedVolBps) {
        tdrvInput = 100;
        realizedVolBps = 0;

        try tdrv.getVolatilityScoreForPool(pool, TDRV_INTERVAL, TDRV_SAMPLES, LOW_VOL_THRESHOLD_BPS, HIGH_VOL_THRESHOLD_BPS)
        returns (uint256 score) {
            tdrvInput = Math.min(score, 100);
        } catch { }

        try tdrv.getRealizedVolatilityForPool(pool, TDRV_INTERVAL, TDRV_SAMPLES) returns (uint256 vol) {
            realizedVolBps = vol;
        } catch { }
    }

    function _readCp(address asset, uint256 shockBps) internal view returns (uint256 cpInput) {
        cpInput = 100;
        try cplcs.getCascadeScore(asset, shockBps) returns (ICrossProtocolCascadeScoreRouter.CascadeResult memory r) {
            cpInput = Math.min(r.cascadeScore, 100);
        } catch { }
    }

    function _readTco(address pool) internal view returns (uint256 tcoInput) {
        if (address(tco) == address(0) || tcoWeight == 0) return 0;
        tcoInput = 50;
        try tco.getConcentrationScoreForPool(pool, TCO_WINDOW_SECONDS, TCO_SAMPLES) returns (uint256 score) {
            tcoInput = Math.min(score, 100);
        } catch { }
    }

    function _tierForScore(uint256 score) internal pure returns (RiskTier tier, uint256 recommendedLtv) {
        tier = RiskTier.LOW;
        recommendedLtv = LTV_LOW;

        if (score >= TIER_CRITICAL_THRESHOLD) {
            tier = RiskTier.CRITICAL;
            recommendedLtv = LTV_CRITICAL;
        } else if (score >= TIER_HIGH_THRESHOLD) {
            tier = RiskTier.HIGH;
            recommendedLtv = LTV_HIGH;
        } else if (score >= TIER_MODERATE_THRESHOLD) {
            tier = RiskTier.MODERATE;
            recommendedLtv = LTV_MODERATE;
        }
    }

    function _firstEnabledAsset() internal view returns (address) {
        try registry.getEnabledAssets() returns (address[] memory enabled) {
            if (enabled.length > 0) return enabled[0];
        } catch { }
        return address(0);
    }
}

