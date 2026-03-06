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

const ASSET_BASE_CONFIGS: Record<string, any> = {
  ETH: { vol: 4500, cost: 45_000_000, collateral: 2_500_000_000, hhi: 1200 },
  BTC: { vol: 3500, cost: 85_000_000, collateral: 4_200_000_000, hhi: 800 },
  LINK: { vol: 6800, cost: 15_000_000, collateral: 450_000_000, hhi: 2500 },
  UNI: { vol: 7500, cost: 10_000_000, collateral: 320_000_000, hhi: 3200 },
  AAVE: { vol: 8200, cost: 6_000_000, collateral: 180_000_000, hhi: 4500 },
};

// Mutable simulation state keyed by asset
const _state: Record<string, any> = {};

function getAssetState(asset: string) {
  if (!_state[asset]) {
    const cfg = ASSET_BASE_CONFIGS[asset] || ASSET_BASE_CONFIGS.ETH;
    _state[asset] = {
      compositeBase: 35 + noise(15),
      history: [35, 34, 36, 35, 37, 34, 35, 35],
      ewma: 35,
      volBase: cfg.vol + noise(cfg.vol * 0.1),
      costBase: cfg.cost + noise(cfg.cost * 0.1),
      collateralBase: cfg.collateral + noise(cfg.collateral * 0.05),
      hhiBase: cfg.hhi + noise(cfg.hhi * 0.1),
      stressEventCountdown: 0,
    };
  }
  return _state[asset];
}

let _tick = 0;
let _blockNumber = 20_500_000;
let _upkeepCount = 0;
let _ccipBroadcasts = 0;
let _lastUpkeepTs = Math.floor(Date.now() / 1000) - 180;

export function generateSnapshot(asset: string = "ETH"): OracleSnapshot {
  _tick++;
  _blockNumber += Math.floor(Math.random() * 3) + 1;

  const st = getAssetState(asset);

  // Occasionally trigger a stress event
  if (st.stressEventCountdown === 0 && Math.random() < 0.04) {
    st.stressEventCountdown = 5;
  }

  let targetComposite: number;
  if (st.stressEventCountdown > 0) {
    st.stressEventCountdown--;
    const intensity = st.stressEventCountdown > 3 ? 1 : st.stressEventCountdown / 3;
    targetComposite = 42 + intensity * 38 + noise(4);
  } else {
    targetComposite = st.compositeBase + noise(5);
  }

  const compositeScore = clamp(Math.round(targetComposite), 0, 100);
  st.compositeBase = clamp(st.compositeBase + noise(1.5), 30, 60);

  // Update history ring buffer
  st.history = [compositeScore, ...st.history.slice(0, 7)];

  // EWMA: alpha = 0.3
  st.ewma = Math.round(0.3 * compositeScore + 0.7 * st.ewma);

  const prevScore = st.history[1] ?? compositeScore;
  const delta = compositeScore - prevScore;
  const momentum = momentumFromDelta(delta);
  const alertLevel = alertFromScore(compositeScore);
  const riskTier = tierFromScore(compositeScore);

  // MCO: high manipulation cost = low risk = low score
  const mcoScoreRaw = clamp(15 + (st.costBase < 10_000_000 ? 40 : 10) + noise(5), 5, 95);
  const costUsd = st.costBase + noise(st.costBase * 0.05);
  st.costBase = clamp(st.costBase + noise(st.costBase * 0.01), 2_000_000, 150_000_000);
  const borrowRateBps = clamp(480 + Math.round(noise(40)), 300, 700);

  // TDRV
  const volBps = clamp(st.volBase + Math.round(noise(st.volBase * 0.1)), 500, 25000);
  st.volBase = clamp(st.volBase + noise(st.volBase * 0.01), 1000, 20000);
  const tdrvScore = clamp(5 + (volBps / 20000) * 90 + noise(4), 0, 100);

  // CPLCS
  const cplcsScore = clamp(10 + (st.collateralBase < 500_000_000 ? 50 : 15) + noise(8), 5, 95);
  const amplificationBps = clamp(11000 + Math.round(noise(3000)), 10000, 25000);
  const totalCollateralUsd = st.collateralBase + noise(st.collateralBase * 0.02);
  st.collateralBase = clamp(st.collateralBase + noise(st.collateralBase * 0.005), 50_000_000, 10_000_000_000);
  const estimatedLiquidationUsd = (totalCollateralUsd * cplcsScore) / 1000; // conservative ratio

  // TCO
  const hhiBps = clamp(st.hhiBase + Math.round(noise(st.hhiBase * 0.1)), 100, 9500);
  st.hhiBase = clamp(st.hhiBase + noise(st.hhiBase * 0.01), 100, 9900);
  const entropyBits = clamp(Math.log2(10000 / hhiBps), 0, 6.6); // log2(100) to log2(1)
  const biasBps = clamp(5500 + Math.round(noise(2000)), 5000, 10000);
  const tcoScore = clamp(Math.round((hhiBps / 10000) * 100 + noise(5)), 0, 100);

  // LTV: 8000 - score * 30 (higher risk → lower LTV)
  const ltvBps = clamp(8000 - compositeScore * 30, 5000, 8000);

  // Circuit breaker
  const cooldownSecondsLeft = alertLevel >= 2 ? Math.floor(Math.random() * 240) : 0;
  const isInCooldown = cooldownSecondsLeft > 0;

  // Chainlink simulation
  const nowTs = Math.floor(Date.now() / 1000);
  const cvoVolBps = clamp(Math.round(volBps * 1.08 + noise(200)), 800, 20000);

  const ASSET_BASE_PRICES: Record<string, number> = {
    ETH: 3200,
    BTC: 65000,
    LINK: 18,
    UNI: 8,
    AAVE: 135,
  };
  const basePrice = ASSET_BASE_PRICES[asset] || 3200;
  const feedPrice = clamp(basePrice + Math.round(noise(basePrice * 0.05)), basePrice * 0.5, basePrice * 2);

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
    ewmaScore: st.ewma,
    momentum,
    scoreHistory: [...st.history],
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
      feedDescription: `${asset} / USD`,
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
    asset,
  };
}
