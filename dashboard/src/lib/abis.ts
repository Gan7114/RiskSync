// Minimal ABIs for dashboard read operations
export const URC_ABI = [
  "function getRiskBreakdown() view returns (uint256 compositeScore, uint256 mcoInput, uint256 tdrvInput, uint256 cpInput, uint8 tier, uint256 recommendedLtv, uint256 realizedVolBps, uint256 manipulationCostUsd, uint256 updatedAt)",
  "function getScoreHistory() view returns (uint256[] memory scores)",
  "function getEWMAScore() view returns (uint256)",
  "function getScoreMomentum() view returns (uint8 momentum, int256 delta)",
  "function isTcoEnabled() view returns (bool)",
];

export const MCO_ABI = [
  "function getManipulationCost(uint256 targetDeviationBps) view returns (uint256 costUsd, uint256 securityScore)",
  "function getManipulationCostNormalized(uint256 targetDeviationBps) view returns (uint256 normalizedCostUsd, uint256 securityScore, bool capped)",
  "function getManipulationCostBreakdown(uint256 targetDeviationBps) view returns (uint256 rawCostUsd, uint256 normalizedCostUsd, uint256 securityScore, bool capped)",
  "function getEffectiveBorrowRateBps() view returns (uint256)",
  "function costThresholdHigh() view returns (uint256)",
  "function getTwapVsSpot() view returns (uint160 twapSqrtPriceX96, uint160 spotSqrtPriceX96, uint256 deviationBps)",
];

export const TDRV_ABI = [
  "function getRealizedVolatility() view returns (uint256 annualizedVolBps)",
  "function getVolatilityScore(uint256 lowVolThresholdBps, uint256 highVolThresholdBps) view returns (uint256 volScore)",
  "function getVolatilityRegime() view returns (uint8)",
  "function getVolatilityEWMA(uint256 lambdaBps) view returns (uint256 ewmaVolBps)",
];

export const CPLCS_ABI = [
  "function getCascadeScore(address asset, uint256 shockBps) view returns (uint256 totalCollateralUsd, uint256 estimatedLiquidationUsd, uint256 secondaryPriceImpactBps, uint256 totalImpactBps, uint256 amplificationBps, uint256 cascadeScore)",
];

export const TCO_ABI = [
  "function getConcentrationScore() view returns (uint256)",
  "function getConcentrationBreakdown() view returns (uint256 hhiBps, uint256 uniqueBuckets, uint256 directionalBiasBps, uint256 approximateEntropyBits, uint256 concentrationScore)",
  "function getHHI() view returns (uint256 hhiBps, uint256 uniqueBuckets)",
  "function getApproximateEntropyBits() view returns (uint256 entropyBits)",
  "function getDirectionalBias() view returns (uint256 biasBps)",
];

export const CIRCUIT_BREAKER_ABI = [
  "function isInCooldown() view returns (bool)",
  "function getTimeUntilCooldownExpiry() view returns (uint256)",
  "function currentLevel() view returns (uint8)",
  "function checkAndRespond() returns (bool levelChanged)",
];

export const CVO_ABI = [
  "function priceFeed() view returns (address)",
  "function getPriceFeedDetails() view returns (string memory description, uint8 decimals, uint256 latestPrice, uint80 latestRoundId)",
  "function getVolatilityWithConfidence() view returns (uint256 annualizedVolBps, uint8 numRoundsUsed, uint256 oldestRoundAge, uint256 latestPrice, uint80 latestRoundId)",
  "function getVolatilityWithConfidence(uint8 numRounds, uint32 maxStalenessSecs) view returns (uint256 annualizedVolBps, uint256 numRoundsUsed, uint256 oldestRoundAgeSeconds)",
  "function getVolatility() view returns (uint256 annualizedVolBps)",
];
