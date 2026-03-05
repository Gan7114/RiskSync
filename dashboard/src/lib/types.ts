export type AlertLevel = 0 | 1 | 2 | 3 | 4;
export type RiskTier = "LOW" | "MODERATE" | "HIGH" | "CRITICAL";
export type VolatilityRegime = "CALM" | "NORMAL" | "ELEVATED" | "STRESS" | "EXTREME";
export type ScoreMomentum = "PLUNGING" | "FALLING" | "STABLE" | "RISING" | "SPIKING";

export const ALERT_LABELS: Record<AlertLevel, string> = {
  0: "NOMINAL",
  1: "WATCH",
  2: "WARNING",
  3: "DANGER",
  4: "EMERGENCY",
};

export const ALERT_COLORS: Record<AlertLevel, string> = {
  0: "#10b981",
  1: "#f59e0b",
  2: "#f97316",
  3: "#ef4444",
  4: "#dc2626",
};

export const ALERT_GLOW: Record<AlertLevel, string> = {
  0: "0 0 24px rgba(16,185,129,0.5)",
  1: "0 0 24px rgba(245,158,11,0.5)",
  2: "0 0 24px rgba(249,115,22,0.5)",
  3: "0 0 24px rgba(239,68,68,0.5)",
  4: "0 0 32px rgba(220,38,38,0.7)",
};

export interface MCOData {
  score: number;
  costUsd: number;
  borrowRateBps: number;
}

export interface TDRVData {
  score: number;
  volBps: number;
  regime: VolatilityRegime;
  ewmaVol: number;
}

export interface CPLCSData {
  score: number;
  totalCollateralUsd: number;
  amplificationBps: number;
  estimatedLiquidationUsd: number;
}

export interface TCOData {
  score: number;
  hhiBps: number;
  entropyBits: number;
  biasBps: number;
}

export interface CircuitBreakerData {
  isInCooldown: boolean;
  cooldownSecondsLeft: number;
  alertLevel: AlertLevel;
}

export interface StressScenario {
  id: string;
  name: string;
  event: string;
  shockBps: number;
  compositeScore: number;
  ltvBps: number;
  cascadeScore: number;
  manipCostUsd: number;
  isWorstCase: boolean;
}

export interface OracleSnapshot {
  compositeScore: number;
  alertLevel: AlertLevel;
  riskTier: RiskTier;
  ltvBps: number;
  ewmaScore: number;
  momentum: ScoreMomentum;
  scoreHistory: number[];
  mco: MCOData;
  tdrv: TDRVData;
  cplcs: CPLCSData;
  tco: TCOData;
  circuitBreaker: CircuitBreakerData;
  scenarios: StressScenario[];
  blockNumber: number;
  timestamp: number;
  tick: number;
}
