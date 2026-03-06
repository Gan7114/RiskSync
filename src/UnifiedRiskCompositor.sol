// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// ─── Primitive Interfaces ─────────────────────────────────────────────────────

interface IManipulationCostOracle {
    function getManipulationCost(uint256 targetDeviationBps)
        external
        view
        returns (uint256 costUsd, uint256 securityScore);

    function getManipulationCostForPool(address pool, address feed, uint256 targetDeviationBps)
        external
        view
        returns (uint256 costUsd, uint256 securityScore);
}

interface ITickDerivedRealizedVolatility {
    function getVolatilityScore(
        uint256 lowVolThresholdBps,
        uint256 highVolThresholdBps
    ) external view returns (uint256 volScore);

    function getRealizedVolatility() external view returns (uint256 annualizedVolBps);

    function getVolatilityScoreForPool(
        address pool,
        uint32 interval,
        uint8 nSamples,
        uint256 lowVolThresholdBps,
        uint256 highVolThresholdBps
    ) external view returns (uint256 volScore);

    function getRealizedVolatilityForPool(address pool, uint32 interval, uint8 nSamples) external view returns (uint256 annualizedVolBps);
}

interface ICrossProtocolCascadeScore {
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
        returns (CascadeResult memory result);
}

/// @notice Minimal interface for the TickConcentrationOracle (4th pillar).
interface ITickConcentrationOracle {
    /// @notice Returns the composite 0-100 manipulation concentration risk score.
    ///         0 = organic (high entropy). 100 = fully concentrated (zero entropy).
    function getConcentrationScore() external view returns (uint256);

    function getConcentrationScoreForPool(address pool, uint32 windowSeconds, uint8 numSamples) external view returns (uint256);
}

/// @title UnifiedRiskCompositor
/// @notice Aggregates three on-chain risk primitives into a single composite risk score
///         and risk tier for use by lending protocols, guardrail hooks, and liquidation engines.
///
/// @dev ── ARCHITECTURE ────────────────────────────────────────────────────────────
///
///      This compositor connects three novel primitives:
///
///        MCO  (ManipulationCostOracle)       → Oracle Economic Security Score (0-100)
///        TDRV (TickDerivedRealizedVolatility) → Market Volatility Score       (0-100)
///        CPLCS (CrossProtocolCascadeScore)    → Cascade Risk Score            (0-100)
///
///      Composite score formula:
///        riskScore = (mcoWeight × mcoInput + tdrvWeight × tdrvInput + cpWeight × cpInput)
///                    / totalWeight
///
///      Where mcoInput = (100 - securityScore) — high manipulation cost = low risk input.
///
///      ── WHY THREE INDEPENDENT DIMENSIONS ────────────────────────────────────────
///
///      Existing oracle systems collapse risk into one axis: "is the price wrong?"
///      Real DeFi risk has three independent dimensions:
///
///        1. ORACLE SECURITY: Can the price be manipulated? (MCO)
///           High manipulation cost → oracle is trustworthy
///           Low cost → oracle can be exploited cheaply
///
///        2. MARKET VOLATILITY: How fast is the price moving? (TDRV)
///           Low realized vol → LTV can be higher
///           High realized vol → LTV must be reduced (positions go underwater faster)
///
///        3. CASCADE RISK: If price drops, how bad does it get? (CPLCS)
///           Low amplification → isolated protocol, manageable
///           High amplification → cross-protocol cascade, systemic event
///
///      A protocol can have SAFE oracle, LOW volatility, but HIGH cascade risk
///      (e.g., ETH in a bull market with $10B of cross-protocol leverage).
///      Only by combining all three do you get a complete picture.
///
///      ── DYNAMIC LTV ──────────────────────────────────────────────────────────────
///
///      The compositor outputs a recommended maximum LTV based on the composite score:
///        LOW tier      (score 0-25)  → LTV 80%
///        MODERATE tier (score 26-50) → LTV 75%
///        HIGH tier     (score 51-75) → LTV 65%
///        CRITICAL tier (score 76-100)→ LTV 50%
///
///      This replaces static governance-set LTV parameters with real-time
///      risk-responsive parameters — the first truly dynamic LTV system
///      that combines oracle security, volatility, and cross-protocol cascade risk.
///
/// @dev ── GOVERNANCE ──────────────────────────────────────────────────────────────
///      Weights are configurable by the owner within bounded ranges.
///      All three primitives are immutable addresses set at deployment.
///      Cooldown enforced on score reads to prevent griefing.
contract UnifiedRiskCompositor {
    using Math for uint256;

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InvalidConfig();
    error InvalidWeights();
    error Unauthorized();
    error CooldownActive(uint256 nextAllowed);
    error ZeroAddress();

    // ─── Constants ────────────────────────────────────────────────────────────

    uint256 public constant MIN_UPDATE_INTERVAL = 60;   // 1 minute cooldown
    uint256 public constant MAX_WEIGHT          = 70;   // No single dimension > 70%
    uint256 public constant MIN_WEIGHT          = 10;   // No single dimension < 10%

    // Default target deviations and shock used when querying primitives.
    uint256 public constant DEFAULT_DEVIATION_BPS = 200;  // 2% — typical oracle exploit threshold
    uint256 public constant DEFAULT_SHOCK_BPS     = 2000; // 20% — severe market stress scenario

    // Volatility thresholds for scoring.
    uint256 public constant LOW_VOL_THRESHOLD_BPS  = 2_000;  // 20% annualized = calm
    uint256 public constant HIGH_VOL_THRESHOLD_BPS = 15_000; // 150% annualized = extreme

    // ─── Risk Tiers & Momentum ───────────────────────────────────────────────

    enum RiskTier { LOW, MODERATE, HIGH, CRITICAL }

    /// @notice Score trend over recent updates.
    enum ScoreMomentum {
        PLUNGING,  // delta <= -20: rapid risk reduction
        FALLING,   // delta  [-20, -5): cooling off
        STABLE,    //  |delta| < 5:    steady state
        RISING,    // delta   (5, +20]: building risk
        SPIKING    // delta >= +20: rapid risk escalation
    }

    // LTV caps per risk tier (in BPS).
    uint256 private constant LTV_LOW      = 8_000; // 80%
    uint256 private constant LTV_MODERATE = 7_500; // 75%
    uint256 private constant LTV_HIGH     = 6_500; // 65%
    uint256 private constant LTV_CRITICAL = 5_000; // 50%

    // Score boundaries for tier classification.
    uint256 private constant TIER_MODERATE_THRESHOLD = 26;
    uint256 private constant TIER_HIGH_THRESHOLD     = 51;
    uint256 private constant TIER_CRITICAL_THRESHOLD = 76;

    // ─── State ────────────────────────────────────────────────────────────────

    address public owner;

    IManipulationCostOracle        public immutable mco;
    ITickDerivedRealizedVolatility public immutable tdrv;
    ICrossProtocolCascadeScore     public immutable cplcs;

    /// @notice Optional 4th pillar: information-theoretic tick concentration oracle.
    ///         address(0) = disabled (3-pillar mode, weights MCO/TDRV/CPLCS sum to 100).
    ITickConcentrationOracle       public immutable tco;

    /// @notice Collateral asset tracked by the cascade score contract.
    address public immutable trackedAsset;

    // Weights for composite score (must sum to 100).
    uint8 public mcoWeight;   // default 35 (3-pillar) / 30 (4-pillar)
    uint8 public tdrvWeight;  // default 40 (3-pillar) / 35 (4-pillar)
    uint8 public cpWeight;    // default 25 (3-pillar) / 20 (4-pillar)
    uint8 public tcoWeight;   // default 0  (3-pillar) / 15 (4-pillar)

    // Cached state updated by updateRiskScore().
    uint256 public lastCompositeScore;
    uint256 public lastMcoInput;
    uint256 public lastTdrvInput;
    uint256 public lastCpInput;
    uint256 public lastTcoInput;       // 0 when TCO is disabled
    uint256 public lastUpdatedAt;
    uint256 public lastRealizedVolBps;
    uint256 public lastManipulationCostUsd;

    // ── Score history ring buffer (last 8 scores) ─────────────────────────────
    uint256[8] private _scoreHistory;
    uint8 private _historyHead;   // index of next write slot (circular)
    uint8 private _historyCount;  // how many slots are populated (max 8)

    // ── EWMA score (α = 30%) ──────────────────────────────────────────────────
    /// @notice Exponentially smoothed composite score (α=30%).
    ///         Converges faster than a simple moving average to trend changes.
    uint256 public ewmaScore;

    /// @dev EWMA smoothing factor in BPS: alpha = 3_000 → 30%.
    uint256 private constant EWMA_ALPHA_BPS = 3_000;

    // ─── Events ───────────────────────────────────────────────────────────────

    event RiskScoreUpdated(
        uint256 compositeScore,
        uint256 mcoInput,
        uint256 tdrvInput,
        uint256 cpInput,
        RiskTier tier,
        uint256 recommendedLtvBps,
        uint256 timestamp
    );

    event WeightsUpdated(uint8 mcoWeight, uint8 tdrvWeight, uint8 cpWeight, uint8 tcoWeight);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param _mco          ManipulationCostOracle address.
    /// @param _tdrv         TickDerivedRealizedVolatility address.
    /// @param _cplcs        CrossProtocolCascadeScore address.
    /// @param _trackedAsset Collateral asset address (e.g., WETH) passed to CPLCS.
    /// @param _mcoWeight    Weight for MCO input (must sum to 100 with others).
    /// @param _tdrvWeight   Weight for TDRV input.
    /// @param _cpWeight     Weight for CPLCS input.
    /// @param _tco          TickConcentrationOracle address. Pass address(0) to disable.
    /// @param _tcoWeight    Weight for TCO input. Must be 0 when _tco == address(0).
    ///                      When enabled, all four weights must sum to 100.
    constructor(
        address _mco,
        address _tdrv,
        address _cplcs,
        address _trackedAsset,
        uint8 _mcoWeight,
        uint8 _tdrvWeight,
        uint8 _cpWeight,
        address _tco,
        uint8   _tcoWeight
    ) {
        if (_mco == address(0) || _tdrv == address(0) || _cplcs == address(0)) revert ZeroAddress();
        if (_trackedAsset == address(0)) revert ZeroAddress();
        _validateWeights(_mcoWeight, _tdrvWeight, _cpWeight, _tco != address(0), _tcoWeight);

        mco          = IManipulationCostOracle(_mco);
        tdrv         = ITickDerivedRealizedVolatility(_tdrv);
        cplcs        = ICrossProtocolCascadeScore(_cplcs);
        tco          = ITickConcentrationOracle(_tco);
        trackedAsset = _trackedAsset;

        mcoWeight  = _mcoWeight;
        tdrvWeight = _tdrvWeight;
        cpWeight   = _cpWeight;
        tcoWeight  = _tcoWeight;

        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @notice Returns true when the TickConcentrationOracle pillar is active.
    function isTcoEnabled() external view returns (bool) {
        return address(tco) != address(0);
    }

    // ─── Primary Interface ────────────────────────────────────────────────────

    /// @notice Recomputes and caches the composite risk score from all three primitives.
    /// @dev    Permissionless — anyone can trigger an update after the cooldown.
    ///         Uses try/catch per primitive so a single failure returns a conservative score.
    ///
    /// @return compositeScore 0-100 composite risk score.
    /// @return tier           Current risk tier.
    /// @return recommendedLtv Recommended maximum LTV in BPS.
    function updateRiskScore()
        external
        returns (
            uint256 compositeScore,
            RiskTier tier,
            uint256 recommendedLtv
        )
    {
        uint256 nowTs = block.timestamp;
        if (lastUpdatedAt != 0 && nowTs < lastUpdatedAt + MIN_UPDATE_INTERVAL) {
            revert CooldownActive(lastUpdatedAt + MIN_UPDATE_INTERVAL);
        }

        // ── 1. MCO: Oracle Economic Security ─────────────────────────────────
        // mcoInput = 100 - securityScore: high security → low risk input.
        uint256 mcoInput = 100; // default to max risk if MCO fails
        uint256 manipCostUsd = 0;
        try mco.getManipulationCost(DEFAULT_DEVIATION_BPS) returns (
            uint256 costUsd,
            uint256 securityScore
        ) {
            mcoInput = 100 - Math.min(securityScore, 100);
            manipCostUsd = costUsd;
        } catch {}

        // ── 2. TDRV: Realized Volatility ─────────────────────────────────────
        uint256 tdrvInput = 100; // default to max risk if TDRV fails
        uint256 realizedVol = 0;
        try tdrv.getVolatilityScore(LOW_VOL_THRESHOLD_BPS, HIGH_VOL_THRESHOLD_BPS) returns (
            uint256 volScore
        ) {
            tdrvInput = volScore;
        } catch {}
        try tdrv.getRealizedVolatility() returns (uint256 vol) {
            realizedVol = vol;
        } catch {}

        // ── 3. CPLCS: Cross-Protocol Cascade Risk ────────────────────────────
        uint256 cpInput = 100; // default to max risk if CPLCS fails
        try cplcs.getCascadeScore(trackedAsset, DEFAULT_SHOCK_BPS) returns (
            ICrossProtocolCascadeScore.CascadeResult memory result
        ) {
            cpInput = result.cascadeScore;
        } catch {}

        // ── 4. TCO: Tick Concentration (Information-Theoretic) ─────────────
        // tcoInput = 0 when TCO disabled (tcoWeight = 0 → no contribution).
        // Default to 50 (neutral) on failure so one bad TCO read doesn't spike risk.
        uint256 tcoInput = 0;
        if (address(tco) != address(0)) {
            try tco.getConcentrationScore() returns (uint256 cScore) {
                tcoInput = cScore;
            } catch {
                tcoInput = 50; // neutral fallback — less conservative than 100
            }
        }

        // ── 5. Composite score ────────────────────────────────────────────────
        // When TCO disabled, tcoWeight = 0 and tcoInput = 0 → no effect.
        uint256 w1 = uint256(mcoWeight);
        uint256 w2 = uint256(tdrvWeight);
        uint256 w3 = uint256(cpWeight);
        uint256 w4 = uint256(tcoWeight);
        uint256 totalW = w1 + w2 + w3 + w4; // = 100 always (validated in constructor)
        compositeScore = (mcoInput * w1 + tdrvInput * w2 + cpInput * w3 + tcoInput * w4) / totalW;

        // ── 6. Cache ──────────────────────────────────────────────────────────
        lastCompositeScore       = compositeScore;
        lastMcoInput             = mcoInput;
        lastTdrvInput            = tdrvInput;
        lastCpInput              = cpInput;
        lastTcoInput             = tcoInput;
        lastUpdatedAt            = nowTs;
        lastRealizedVolBps       = realizedVol;
        lastManipulationCostUsd  = manipCostUsd;

        // ── 7. Score history ring buffer ──────────────────────────────────────
        _scoreHistory[_historyHead] = compositeScore;
        _historyHead = uint8((_historyHead + 1) % 8);
        if (_historyCount < 8) _historyCount++;

        // ── 8. EWMA update (α = 30%) ──────────────────────────────────────────
        // ewma_new = α × score + (1-α) × ewma_old
        if (_historyCount == 1) {
            ewmaScore = compositeScore; // initialise on first observation
        } else {
            ewmaScore = (EWMA_ALPHA_BPS * compositeScore + (10_000 - EWMA_ALPHA_BPS) * ewmaScore) / 10_000;
        }

        tier           = _scoreToTier(compositeScore);
        recommendedLtv = _tierToLtv(tier);

        emit RiskScoreUpdated(compositeScore, mcoInput, tdrvInput, cpInput, tier, recommendedLtv, nowTs);
    }

    /// @notice Returns the cached composite score without triggering an update.
    function getRiskScore() external view returns (uint256) {
        return lastCompositeScore;
    }

    /// @notice Returns the cached risk tier.
    function getRiskTier() external view returns (RiskTier) {
        return _scoreToTier(lastCompositeScore);
    }

    /// @notice Returns the dynamic recommended LTV based on current risk tier.
    function getRecommendedLtv() external view returns (uint256 ltvBps) {
        return _tierToLtv(_scoreToTier(lastCompositeScore));
    }

    /// @notice Returns a full breakdown of the last computed risk state.
    function getRiskBreakdown()
        external
        view
        returns (
            uint256 compositeScore,
            uint256 mcoInput,
            uint256 tdrvInput,
            uint256 cpInput,
            RiskTier tier,
            uint256 recommendedLtv,
            uint256 realizedVolBps,
            uint256 manipulationCostUsd,
            uint256 updatedAt
        )
    {
        compositeScore      = lastCompositeScore;
        mcoInput            = lastMcoInput;
        tdrvInput           = lastTdrvInput;
        cpInput             = lastCpInput;
        tier                = _scoreToTier(lastCompositeScore);
        recommendedLtv      = _tierToLtv(tier);
        realizedVolBps      = lastRealizedVolBps;
        manipulationCostUsd = lastManipulationCostUsd;
        updatedAt           = lastUpdatedAt;
    }

    /// @notice Returns a full breakdown of the risk state for an arbitrary pool/feed pair.
    /// @dev Uses the compositor's tracked asset for cascade modeling (default behavior).
    function getScoreForAsset(address pool, address feed)
        external
        view
        returns (
            uint256 compositeScore,
            uint256 mcoInput,
            uint256 tdrvInput,
            uint256 cpInput,
            RiskTier tier,
            uint256 recommendedLtv,
            uint256 realizedVolBps,
            uint256 manipulationCostUsd,
            uint256 tcoInput
        )
    {
        return _getScoreForAsset(pool, feed, trackedAsset);
    }

    /// @notice Returns a full breakdown for an arbitrary pool/feed pair with explicit cascade asset.
    /// @dev    Useful when the pool under analysis differs from the collateral asset used in CPLCS.
    function getScoreForAsset(address pool, address feed, address cascadeAsset)
        external
        view
        returns (
            uint256 compositeScore,
            uint256 mcoInput,
            uint256 tdrvInput,
            uint256 cpInput,
            RiskTier tier,
            uint256 recommendedLtv,
            uint256 realizedVolBps,
            uint256 manipulationCostUsd,
            uint256 tcoInput
        )
    {
        if (cascadeAsset == address(0)) revert ZeroAddress();
        return _getScoreForAsset(pool, feed, cascadeAsset);
    }

    function _getScoreForAsset(address pool, address feed, address cascadeAsset)
        internal
        view
        returns (
            uint256 compositeScore,
            uint256 mcoInput,
            uint256 tdrvInput,
            uint256 cpInput,
            RiskTier tier,
            uint256 recommendedLtv,
            uint256 realizedVolBps,
            uint256 manipulationCostUsd,
            uint256 tcoInput
        )
    {
        // ── 1. MCO for specified pool and feed ──────────────────────────────
        mcoInput = 100;
        try mco.getManipulationCostForPool(pool, feed, DEFAULT_DEVIATION_BPS) returns (
            uint256 costUsd,
            uint256 securityScore
        ) {
            mcoInput = 100 - Math.min(securityScore, 100);
            manipulationCostUsd = costUsd;
        } catch {}

        // ── 2. TDRV for specified pool ──────────────────────────────────────
        tdrvInput = 100;
        // Using same defaults as constructor deployments: 60s interval, 60 samples = 1 hr window.
        try tdrv.getVolatilityScoreForPool(pool, 60, 60, LOW_VOL_THRESHOLD_BPS, HIGH_VOL_THRESHOLD_BPS) returns (
            uint256 volScore
        ) {
            tdrvInput = volScore;
        } catch {}
        try tdrv.getRealizedVolatilityForPool(pool, 60, 60) returns (uint256 vol) {
            realizedVolBps = vol;
        } catch {}

        // ── 3. CPLCS: cross protocol cascade ────────────────────────────────
        cpInput = 100;
        try cplcs.getCascadeScore(cascadeAsset, DEFAULT_SHOCK_BPS) returns (
            ICrossProtocolCascadeScore.CascadeResult memory result
        ) {
            cpInput = result.cascadeScore;
        } catch {}

        // ── 4. TCO for specified pool ───────────────────────────────────────
        tcoInput = 0;
        if (address(tco) != address(0)) {
            // Using typical defaults: 24h window (86400s), 24 samples.
            try tco.getConcentrationScoreForPool(pool, 86400, 24) returns (uint256 cScore) {
                tcoInput = cScore;
            } catch {
                tcoInput = 50;
            }
        }

        uint256 w1 = uint256(mcoWeight);
        uint256 w2 = uint256(tdrvWeight);
        uint256 w3 = uint256(cpWeight);
        uint256 w4 = uint256(tcoWeight);
        uint256 totalW = w1 + w2 + w3 + w4;

        compositeScore = (mcoInput * w1 + tdrvInput * w2 + cpInput * w3 + tcoInput * w4) / totalW;
        tier           = _scoreToTier(compositeScore);
        recommendedLtv = _tierToLtv(tier);
    }

    // ─── Score History & Momentum ────────────────────────────────────────────

    /// @notice Returns the last N composite scores in chronological order (oldest first).
    /// @dev    The ring buffer stores up to 8 scores.  Fewer are returned if
    ///         fewer updates have occurred.
    /// @return scores Array of historical composite scores (oldest first).
    function getScoreHistory() external view returns (uint256[] memory scores) {
        uint8 count = _historyCount;
        scores = new uint256[](count);
        if (count == 0) return scores;

        // _historyHead points to the NEXT write slot.
        // The oldest entry is at (_historyHead - count + 8) % 8.
        uint8 startIdx = uint8((_historyHead + 8 - count) % 8);
        for (uint8 i = 0; i < count; ) {
            scores[i] = _scoreHistory[(startIdx + i) % 8];
            unchecked { ++i; }
        }
    }

    /// @notice Returns the exponentially weighted moving average score (α=30%).
    /// @dev    More responsive to recent changes than a simple moving average.
    ///         Returns 0 until the first updateRiskScore() call.
    function getEWMAScore() external view returns (uint256) {
        return ewmaScore;
    }

    /// @notice Returns the score momentum based on the last two updates.
    /// @dev    Compares the most recent score against the one before it.
    ///         Returns STABLE with delta=0 if fewer than 2 updates have occurred.
    /// @return momentum Categorical trend direction.
    /// @return delta    Signed score change (positive = risk rising, negative = falling).
    function getScoreMomentum()
        external
        view
        returns (ScoreMomentum momentum, int256 delta)
    {
        if (_historyCount < 2) return (ScoreMomentum.STABLE, 0);

        // Most recent score is at head-1 (wrapping), second-most-recent at head-2.
        uint8 latestIdx = uint8((_historyHead + 8 - 1) % 8);
        uint8 prevIdx   = uint8((_historyHead + 8 - 2) % 8);

        int256 latest = int256(_scoreHistory[latestIdx]);
        int256 prev   = int256(_scoreHistory[prevIdx]);
        delta = latest - prev;

        if (delta <= -20) return (ScoreMomentum.PLUNGING, delta);
        if (delta <   -5) return (ScoreMomentum.FALLING,  delta);
        if (delta <    5) return (ScoreMomentum.STABLE,   delta);
        if (delta <   20) return (ScoreMomentum.RISING,   delta);
        return (ScoreMomentum.SPIKING, delta);
    }

    // ─── Governance ───────────────────────────────────────────────────────────

    /// @notice Updates dimension weights. All active weights must sum to 100.
    /// @dev    When TCO is disabled, _tcoWeight must be 0.
    ///         When TCO is enabled, all four weights must sum to 100.
    function setWeights(uint8 _mcoWeight, uint8 _tdrvWeight, uint8 _cpWeight, uint8 _tcoWeight) external {
        if (msg.sender != owner) revert Unauthorized();
        _validateWeights(_mcoWeight, _tdrvWeight, _cpWeight, address(tco) != address(0), _tcoWeight);
        mcoWeight  = _mcoWeight;
        tdrvWeight = _tdrvWeight;
        cpWeight   = _cpWeight;
        tcoWeight  = _tcoWeight;
        emit WeightsUpdated(_mcoWeight, _tdrvWeight, _cpWeight, _tcoWeight);
    }

    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _scoreToTier(uint256 score) internal pure returns (RiskTier) {
        if (score < TIER_MODERATE_THRESHOLD) return RiskTier.LOW;
        if (score < TIER_HIGH_THRESHOLD)     return RiskTier.MODERATE;
        if (score < TIER_CRITICAL_THRESHOLD) return RiskTier.HIGH;
        return RiskTier.CRITICAL;
    }

    function _tierToLtv(RiskTier tier) internal pure returns (uint256) {
        if (tier == RiskTier.LOW)      return LTV_LOW;
        if (tier == RiskTier.MODERATE) return LTV_MODERATE;
        if (tier == RiskTier.HIGH)     return LTV_HIGH;
        return LTV_CRITICAL;
    }

    /// @dev Validates weights for both 3-pillar (tcoEnabled=false) and 4-pillar modes.
    ///      3-pillar: w1+w2+w3 = 100, w4 must be 0, each of w1/w2/w3 in [MIN,MAX].
    ///      4-pillar: w1+w2+w3+w4 = 100, all four in [MIN,MAX].
    function _validateWeights(uint8 w1, uint8 w2, uint8 w3, bool tcoEnabled, uint8 w4) internal pure {
        if (!tcoEnabled) {
            if (w4 != 0) revert InvalidWeights();
            if (uint256(w1) + uint256(w2) + uint256(w3) != 100) revert InvalidWeights();
        } else {
            if (uint256(w1) + uint256(w2) + uint256(w3) + uint256(w4) != 100) revert InvalidWeights();
            if (w4 < MIN_WEIGHT || w4 > MAX_WEIGHT) revert InvalidWeights();
        }
        if (w1 < MIN_WEIGHT || w1 > MAX_WEIGHT) revert InvalidWeights();
        if (w2 < MIN_WEIGHT || w2 > MAX_WEIGHT) revert InvalidWeights();
        if (w3 < MIN_WEIGHT || w3 > MAX_WEIGHT) revert InvalidWeights();
    }
}
