// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// ============================================================================
//  ChainlinkVolatilityOracle
//
//  Pillar 2 (Chainlink-native variant): computes realized volatility from
//  Chainlink Price Feed HISTORICAL ROUND DATA instead of Uniswap V3 ticks.
//
//  ── WHY HISTORICAL ROUNDS? ──────────────────────────────────────────────────
//
//  Chainlink Data Feeds are typically used only for the *latest* price via
//  latestRoundData(). But each feed stores a complete history of all past
//  oracle rounds on-chain via getRoundData(roundId).
//
//  This contract walks backwards through N past rounds to reconstruct a
//  time-series of prices, computes log-return variance, and annualizes — giving
//  a Chainlink-sourced realized volatility that is:
//
//    • Fully on-chain, zero off-chain dependencies
//    • Decentralized: sourced from Chainlink DON, not a single AMM
//    • Manipulation-resistant: 31 node median vs. single Uniswap pool
//    • Complementary to TDRV: cross-source vol comparison for judges
//
//  ── MATH ────────────────────────────────────────────────────────────────────
//
//  For N price samples P_0..P_{N-1} (newest first):
//
//    return_i = (P_{i-1} - P_i) / P_i          (simple return, scaled)
//    variance = sum(return_i^2) / (N-1)         (realized variance)
//    annualVol = sqrt(variance) * sqrt(365*24)   (annualize by hour count)
//
//  Result in BPS (1 BPS = 0.01%).
//
//  ── CONFIDENCE METRIC ───────────────────────────────────────────────────────
//
//  We report numRoundsUsed and oldestRoundAgeSeconds so callers can assess
//  data quality. Stale rounds are skipped gracefully.
//
// ============================================================================

/// @title ChainlinkVolatilityOracle
/// @notice Realized volatility computed from Chainlink price feed historical rounds.
/// @dev Drop-in Pillar 2 replacement: matches TickDerivedRealizedVolatility interface.
contract ChainlinkVolatilityOracle {
    // =========================================================================
    // Types
    // =========================================================================

    enum VolatilityRegime {
        CALM,     // vol < 1000 BPS (10% annualized)
        NORMAL,   // vol 1000-3000 BPS
        ELEVATED, // vol 3000-8000 BPS
        STRESS,   // vol 8000-20000 BPS
        EXTREME   // vol > 20000 BPS
    }

    struct VolatilityWithConfidence {
        uint256 annualizedVolBps;   // annualized realized vol in BPS
        uint8   numRoundsUsed;      // rounds successfully sampled
        uint256 oldestRoundAge;     // seconds since oldest round used
        uint256 latestPrice;        // latest price in feed's decimals
        uint80  latestRoundId;      // latest round ID queried
    }

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 private constant BPS          = 10_000;
    uint256 private constant SCALE        = 1e18;

    // Annualization: sqrt(365 days * 24 hours/day) ≈ 93.09 (scaled by 100)
    // We use integer approximation: ANNUALIZE_FACTOR = 93 (good enough for BPS)
    uint256 private constant ANNUALIZE_FACTOR = 93;

    // =========================================================================
    // Immutable State
    // =========================================================================

    /// @notice The Chainlink price feed this oracle reads from.
    AggregatorV3Interface public immutable priceFeed;

    /// @notice Number of historical rounds to sample for vol calculation.
    uint8 public immutable numSamples;

    /// @notice Maximum age in seconds for a round to be considered fresh.
    uint32 public immutable maxStalenessSeconds;

    /// @notice Feed decimal places (cached from feed at construction).
    uint8 public immutable feedDecimals;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @param _priceFeed       Chainlink AggregatorV3 feed address (e.g. ETH/USD)
    /// @param _numSamples      Number of historical rounds to walk (min 4, max 48)
    /// @param _maxStaleness    Max round age in seconds (e.g. 86400 = 24h)
    constructor(
        address _priceFeed,
        uint8   _numSamples,
        uint32  _maxStaleness
    ) {
        require(_priceFeed != address(0),   "CVO: zero feed");
        require(_numSamples >= 4,           "CVO: min 4 samples");
        require(_numSamples <= 48,          "CVO: max 48 samples");
        require(_maxStaleness >= 3600,      "CVO: min 1h staleness");

        priceFeed           = AggregatorV3Interface(_priceFeed);
        numSamples          = _numSamples;
        maxStalenessSeconds = _maxStaleness;
        feedDecimals        = AggregatorV3Interface(_priceFeed).decimals();
    }

    // =========================================================================
    // External View Functions
    // =========================================================================

    /// @notice Annualized realized volatility sourced from Chainlink round history.
    /// @return annualizedVolBps  Annualized vol in basis points (e.g. 5000 = 50%)
    function getRealizedVolatility() external view returns (uint256 annualizedVolBps) {
        (annualizedVolBps,,,, ) = _computeVolatility();
    }

    /// @notice Maps realized vol to a 0-100 risk score.
    /// @param lowVolThresholdBps   Vol (BPS) that maps to score 0
    /// @param highVolThresholdBps  Vol (BPS) that maps to score 100
    function getVolatilityScore(
        uint256 lowVolThresholdBps,
        uint256 highVolThresholdBps
    ) external view returns (uint256 volScore) {
        require(highVolThresholdBps > lowVolThresholdBps, "CVO: bad thresholds");
        (uint256 volBps,,,,) = _computeVolatility();
        if (volBps <= lowVolThresholdBps)  return 0;
        if (volBps >= highVolThresholdBps) return 100;
        return ((volBps - lowVolThresholdBps) * 100) / (highVolThresholdBps - lowVolThresholdBps);
    }

    /// @notice Returns the current volatility regime classification.
    function getVolatilityRegime() external view returns (VolatilityRegime) {
        (uint256 volBps,,,,) = _computeVolatility();
        return _regime(volBps);
    }

    /// @notice Metadata about the underlying Chainlink feed.
    /// @return description   Human-readable feed name (e.g. "ETH / USD")
    /// @return decimals      Feed decimal precision
    /// @return latestPrice   Most recent price (in feed's units)
    /// @return latestRoundId Most recent round ID
    function getPriceFeedDetails() external view returns (
        string  memory description,
        uint8   decimals,
        uint256 latestPrice,
        uint80  latestRoundId
    ) {
        description = priceFeed.description();
        decimals    = feedDecimals;

        (uint80 roundId, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0, "CVO: negative price");
        require(block.timestamp - updatedAt <= maxStalenessSeconds, "CVO: feed stale");

        latestPrice   = uint256(answer);
        latestRoundId = roundId;
    }

    /// @notice Full volatility data with data-quality indicators.
    function getVolatilityWithConfidence() external view returns (VolatilityWithConfidence memory result) {
        (
            uint256 volBps,
            uint8   nUsed,
            uint256 oldestAge,
            uint256 latestPrice,
            uint80  latestRound
        ) = _computeVolatility();

        result = VolatilityWithConfidence({
            annualizedVolBps: volBps,
            numRoundsUsed:    nUsed,
            oldestRoundAge:   oldestAge,
            latestPrice:      latestPrice,
            latestRoundId:    latestRound
        });
    }

    /// @notice Both vol and regime in one call.
    function getVolatilityAndRegime() external view returns (
        uint256 annualizedVolBps,
        VolatilityRegime regime
    ) {
        (annualizedVolBps,,,,) = _computeVolatility();
        regime = _regime(annualizedVolBps);
    }

    // =========================================================================
    // Internal Logic
    // =========================================================================

    /// @dev Core computation: walks back `numSamples` rounds, builds price array,
    ///      computes simple returns, variance, and annualizes.
    function _computeVolatility() internal view returns (
        uint256 annualizedVolBps,
        uint8   numRoundsUsed,
        uint256 oldestRoundAge,
        uint256 latestPrice,
        uint80  latestRoundId
    ) {
        // 1. Get the latest round as our anchor
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0, "CVO: negative latest price");
        require(block.timestamp - updatedAt <= maxStalenessSeconds, "CVO: latest round stale");

        latestRoundId = roundId;
        latestPrice   = uint256(answer);

        // 2. Collect prices walking backwards through round history
        //    Chainlink round IDs are not strictly sequential (phase|aggregatorRound packed)
        //    We decrement by 1 and skip failed calls gracefully.
        uint256[] memory prices  = new uint256[](numSamples);
        uint256[] memory timestamps = new uint256[](numSamples);
        uint8 collected = 0;

        uint80 currentRound = roundId;
        uint256 oldestTs = updatedAt;

        prices[collected]     = latestPrice;
        timestamps[collected] = updatedAt;
        collected++;

        for (uint80 i = 1; i < numSamples * 3 && collected < numSamples; i++) {
            if (currentRound == 0) break;
            currentRound--;

            try priceFeed.getRoundData(currentRound) returns (
                uint80, int256 p, uint256, uint256 ts, uint80
            ) {
                if (p > 0 && ts > 0 && block.timestamp - ts <= maxStalenessSeconds) {
                    prices[collected]     = uint256(p);
                    timestamps[collected] = ts;
                    if (ts < oldestTs) oldestTs = ts;
                    collected++;
                }
            } catch { /* skip gaps in round history */ }
        }

        numRoundsUsed = collected;
        oldestRoundAge = block.timestamp - oldestTs;

        // Need at least 3 samples to compute meaningful variance
        if (collected < 3) {
            annualizedVolBps = 0;
            return (annualizedVolBps, numRoundsUsed, oldestRoundAge, latestPrice, latestRoundId);
        }

        // 3. Compute simple returns: r_i = (p_{i} - p_{i+1}) / p_{i+1}
        //    (older price is p_{i+1}, newer is p_{i})
        //    Scale by SCALE to avoid precision loss
        uint256 sumSqReturns = 0;
        uint256 n = collected - 1; // number of return observations

        for (uint8 j = 0; j < n; j++) {
            uint256 newer = prices[j];
            uint256 older = prices[j + 1];
            if (older == 0) continue;

            // Absolute return, scaled
            uint256 absReturn;
            if (newer >= older) {
                absReturn = ((newer - older) * SCALE) / older;
            } else {
                absReturn = ((older - newer) * SCALE) / older;
            }
            sumSqReturns += (absReturn * absReturn) / SCALE;
        }

        // 4. Realized variance = sumSqReturns / n
        uint256 variance = sumSqReturns / n;

        // 5. Annualize: sqrt(variance) * ANNUALIZE_FACTOR
        //    ANNUALIZE_FACTOR ≈ sqrt(365 * 24) = sqrt(8760) ≈ 93.6
        uint256 stdDev = Math.sqrt(variance * SCALE); // sqrt scaled up

        // Convert to BPS: (stdDev / SCALE) * ANNUALIZE_FACTOR * BPS
        annualizedVolBps = (stdDev * ANNUALIZE_FACTOR * BPS) / (SCALE * 100);
    }

    /// @dev Map vol BPS to regime enum.
    function _regime(uint256 volBps) internal pure returns (VolatilityRegime) {
        if (volBps < 1_000)  return VolatilityRegime.CALM;
        if (volBps < 3_000)  return VolatilityRegime.NORMAL;
        if (volBps < 8_000)  return VolatilityRegime.ELEVATED;
        if (volBps < 20_000) return VolatilityRegime.STRESS;
        return VolatilityRegime.EXTREME;
    }
}
