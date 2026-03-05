import type {
  OracleSnapshot,
  AlertLevel,
  RiskTier,
  VolatilityRegime,
  ScoreMomentum,
  StressScenario,
} from "./types";

const SCENARIOS: StressScenario[] = [
  {
    id: "BLACK_THURSDAY_2020",
    name: "Black Thursday",
    event: "ETH -60% / MakerDAO crisis",
    shockBps: 6000,
    compositeScore: 87,
    ltvBps: 5200,
    cascadeScore: 92,
    manipCostUsd: 1_200_000,
    isWorstCase: false,
  },
  {
    id: "LUNA_COLLAPSE_2022",
    name: "Luna Collapse",
    event: "Hyperinflation, $40B wiped",
    shockBps: 9900,
    compositeScore: 96,
    ltvBps: 5000,
    cascadeScore: 98,
    manipCostUsd: 800_000,
    isWorstCase: false,
  },
  {
    id: "FTX_COLLAPSE_2022",
    name: "FTX Collapse",
    event: "ETH -40% contagion",
    shockBps: 4000,
    compositeScore: 79,
    ltvBps: 5500,
    cascadeScore: 81,
    manipCostUsd: 2_800_000,
    isWorstCase: false,
  },
  {
    id: "STABLECOIN_DEPEG_2023",
    name: "USDC Depeg",
    event: "SVB bank-run, USDC at $0.87",
    shockBps: 1300,
    compositeScore: 64,
    ltvBps: 6100,
    cascadeScore: 61,
    manipCostUsd: 5_400_000,
    isWorstCase: false,
  },
  {
    id: "SYNTHETIC_WORST_CASE",
    name: "Synthetic Worst Case",
    event: "-90% shock, max cascade",
    shockBps: 9000,
    compositeScore: 99,
    ltvBps: 5000,
    cascadeScore: 99,
    manipCostUsd: 400_000,
    isWorstCase: true,
  },
];

function clamp(v: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, v));
}

function noise(range: number) {
  return (Math.random() - 0.5) * 2 * range;
}

function alertFromScore(score: number): AlertLevel {
  if (score >= 80) return 4;
  if (score >= 65) return 3;
  if (score >= 50) return 2;
  if (score >= 25) return 1;
  return 0;
}

function tierFromScore(score: number): RiskTier {
  if (score >= 65) return "CRITICAL";
  if (score >= 50) return "HIGH";
  if (score >= 25) return "MODERATE";
  return "LOW";
}

function momentumFromDelta(delta: number): ScoreMomentum {
  if (delta > 12) return "SPIKING";
  if (delta > 4) return "RISING";
  if (delta < -12) return "PLUNGING";
  if (delta < -4) return "FALLING";
  return "STABLE";
}

function regimeFromVol(volBps: number): VolatilityRegime {
  if (volBps > 12000) return "EXTREME";
  if (volBps > 8000) return "STRESS";
  if (volBps > 5000) return "ELEVATED";
  if (volBps > 2000) return "NORMAL";
  return "CALM";
}

// Mutable simulation state
let _tick = 0;
let _stressEventCountdown = 0;
let _compositeBase = 42;
let _history: number[] = [42, 40, 44, 41, 43, 39, 45, 42];
let _ewma = 42;
let _volBase = 4800;
let _costBase = 14_000_000;
let _blockNumber = 20_500_000;
let _upkeepCount = 0;
let _ccipBroadcasts = 0;
let _lastUpkeepTs = Math.floor(Date.now() / 1000) - 180;

export function generateSnapshot(): OracleSnapshot {
  _tick++;
  _blockNumber += Math.floor(Math.random() * 3) + 1;

  // Occasionally trigger a stress event
  if (_stressEventCountdown === 0 && Math.random() < 0.04) {
    _stressEventCountdown = 5;
  }

  let targetComposite: number;
  if (_stressEventCountdown > 0) {
    _stressEventCountdown--;
    const intensity = _stressEventCountdown > 3 ? 1 : _stressEventCountdown / 3;
    targetComposite = 42 + intensity * 38 + noise(4);
  } else {
    targetComposite = _compositeBase + noise(5);
  }

  const compositeScore = clamp(Math.round(targetComposite), 0, 100);
  _compositeBase = clamp(_compositeBase + noise(1.5), 30, 60);

  // Update history ring buffer
  _history = [compositeScore, ..._history.slice(0, 7)];

  // EWMA: alpha = 0.3
  _ewma = Math.round(0.3 * compositeScore + 0.7 * _ewma);

  const prevScore = _history[1] ?? compositeScore;
  const delta = compositeScore - prevScore;
  const momentum = momentumFromDelta(delta);
  const alertLevel = alertFromScore(compositeScore);
  const riskTier = tierFromScore(compositeScore);

  // MCO: high manipulation cost = low risk = low score
  const mcoScoreRaw = clamp(20 + (compositeScore * 0.4) + noise(6), 5, 95);
  const costUsd = clamp(_costBase + noise(3_000_000), 2_000_000, 80_000_000);
  _costBase = clamp(_costBase + noise(500_000), 4_000_000, 40_000_000);
  const borrowRateBps = clamp(480 + Math.round(noise(40)), 300, 700);

  // TDRV
  const volBps = clamp(_volBase + Math.round(noise(1500)), 1000, 18000);
  _volBase = clamp(_volBase + noise(300), 2000, 12000);
  const tdrvScore = clamp(10 + (volBps / 18000) * 85 + noise(6), 0, 100);

  // CPLCS
  const cplcsScore = clamp(15 + (compositeScore * 0.45) + noise(8), 5, 95);
  const amplificationBps = clamp(11000 + Math.round(noise(3000)), 10000, 25000);
  const totalCollateralUsd = clamp(2_100_000_000 + noise(400_000_000), 1_000_000_000, 4_000_000_000);
  const estimatedLiquidationUsd = (totalCollateralUsd * cplcsScore) / 100;

  // TCO
  const hhiBps = clamp(2000 + Math.round(noise(1500)), 500, 9000);
  const entropyBits = clamp(Math.floor(Math.log2(10000 / hhiBps)), 0, 6);
  const biasBps = clamp(5500 + Math.round(noise(2000)), 5000, 10000);
  const tcoScore = clamp(Math.round((hhiBps / 10000) * 60 + ((biasBps - 5000) / 5000) * 40 + noise(5)), 0, 100);

  // LTV: 8000 - score * 30 (higher risk → lower LTV)
  const ltvBps = clamp(8000 - compositeScore * 30, 5000, 8000);

  // Circuit breaker
  const cooldownSecondsLeft = alertLevel >= 2 ? Math.floor(Math.random() * 240) : 0;
  const isInCooldown = cooldownSecondsLeft > 0;

  // Chainlink simulation
  const nowTs = Math.floor(Date.now() / 1000);
  const cvoVolBps = clamp(Math.round(volBps * 1.08 + noise(200)), 800, 20000);
  const feedPrice = clamp(3200 + Math.round(noise(200)), 2000, 5000);
  const nextUpkeepIn = clamp(_lastUpkeepTs + 300 - nowTs, 0, 300);
  if (nextUpkeepIn === 0) {
    _upkeepCount++;
    _lastUpkeepTs = nowTs;
    if (alertLevel >= 2) _ccipBroadcasts++;
  }

  return {
    compositeScore,
    alertLevel,
    riskTier,
    ltvBps,
    ewmaScore: _ewma,
    momentum,
    scoreHistory: [..._history],
    mco: {
      score: Math.round(mcoScoreRaw),
      costUsd: Math.round(costUsd),
      borrowRateBps,
    },
    tdrv: {
      score: Math.round(tdrvScore),
      volBps: Math.round(volBps),
      regime: regimeFromVol(volBps),
      ewmaVol: Math.round(volBps * 0.85),
    },
    cplcs: {
      score: Math.round(cplcsScore),
      totalCollateralUsd: Math.round(totalCollateralUsd),
      amplificationBps: Math.round(amplificationBps),
      estimatedLiquidationUsd: Math.round(estimatedLiquidationUsd),
    },
    tco: {
      score: Math.round(tcoScore),
      hhiBps: Math.round(hhiBps),
      entropyBits,
      biasBps: Math.round(biasBps),
    },
    circuitBreaker: {
      isInCooldown,
      cooldownSecondsLeft,
      alertLevel,
    },
    chainlink: {
      feedDescription: "ETH / USD",
      feedPrice,
      feedRoundId: 110000 + _upkeepCount,
      cvoVolBps,
      cvoRegime: regimeFromVol(cvoVolBps),
      numRoundsUsed: 24,
      oldestRoundAgeHours: 24,
      lastUpkeepTimestamp: _lastUpkeepTs,
      nextUpkeepIn,
      upkeepCount: _upkeepCount,
      ccipBroadcasts: _ccipBroadcasts,
      destinationCount: 3,
      broadcastThreshold: 2,
    },
    scenarios: SCENARIOS,
    blockNumber: _blockNumber,
    timestamp: Date.now(),
    tick: _tick,
  };
}
