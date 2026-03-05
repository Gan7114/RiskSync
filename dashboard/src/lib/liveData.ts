/**
 * liveData.ts — reads real on-chain data from Sepolia contracts.
 * Returns a Partial<OracleSnapshot> merged on top of the mock baseline.
 * Every contract call is wrapped in try/catch; failed calls leave the
 * corresponding mock field in place (graceful degradation).
 */

import { ethers } from "ethers";
import { ADDRESSES, RPC_URL } from "./contracts";
import {
  URC_ABI,
  MCO_ABI,
  TDRV_ABI,
  CPLCS_ABI,
  TCO_ABI,
  CIRCUIT_BREAKER_ABI,
  CVO_ABI,
} from "./abis";
import type {
  OracleSnapshot,
  AlertLevel,
  RiskTier,
  VolatilityRegime,
  ScoreMomentum,
} from "./types";

// ─── Mapping helpers ──────────────────────────────────────────────────────────

const TIER_MAP: RiskTier[] = ["LOW", "MODERATE", "HIGH", "CRITICAL"];
const REGIME_MAP: VolatilityRegime[] = [
  "CALM",
  "NORMAL",
  "ELEVATED",
  "STRESS",
  "EXTREME",
];
const MOMENTUM_MAP: ScoreMomentum[] = [
  "PLUNGING",
  "FALLING",
  "STABLE",
  "RISING",
  "SPIKING",
];

function bn(v: bigint): number {
  return Number(v);
}

// ─── Provider singleton ───────────────────────────────────────────────────────

let _provider: ethers.JsonRpcProvider | null = null;
function getProvider(): ethers.JsonRpcProvider {
  if (!_provider) {
    _provider = new ethers.JsonRpcProvider(RPC_URL);
  }
  return _provider;
}

// ─── Main fetch ───────────────────────────────────────────────────────────────

export async function fetchLiveSnapshot(): Promise<Partial<OracleSnapshot>> {
  const provider = getProvider();
  const result: Partial<OracleSnapshot> = {};

  // ── URC ──────────────────────────────────────────────────────────────────
  if (ADDRESSES.URC) {
    const urc = new ethers.Contract(ADDRESSES.URC, URC_ABI, provider);

    try {
      const rb = await urc.getRiskBreakdown();
      // getRiskBreakdown returns:
      // (compositeScore, mcoInput, tdrvInput, cpInput, tier, recommendedLtv,
      //  realizedVolBps, manipulationCostUsd, updatedAt)
      const composite = bn(rb[0]);
      const tier = bn(rb[4]);
      const ltvBps = bn(rb[5]);

      result.compositeScore = composite;
      result.ltvBps = ltvBps > 0 ? ltvBps : 8000;
      result.riskTier = TIER_MAP[Math.min(tier, 3)] ?? "LOW";
      result.alertLevel = (
        composite >= 80 ? 4 : composite >= 65 ? 3 : composite >= 50 ? 2 : composite >= 25 ? 1 : 0
      ) as AlertLevel;

      // Pillar sub-scores from composite breakdown
      const mcoInput  = bn(rb[1]);
      const tdrvInput = bn(rb[2]);
      const cpInput   = bn(rb[3]);
      const volBps    = bn(rb[6]);
      const costUsd   = bn(rb[7]);

      if (mcoInput > 0 || costUsd > 0) {
        result.mco = {
          score: Math.min(100, mcoInput),
          costUsd: costUsd,
          borrowRateBps: 500,
        };
      }
      if (tdrvInput > 0 || volBps > 0) {
        result.tdrv = {
          score: Math.min(100, tdrvInput),
          volBps: volBps,
          regime: volBps > 8000 ? "STRESS" : volBps > 4000 ? "ELEVATED" : volBps > 2000 ? "NORMAL" : "CALM",
          ewmaVol: volBps,
        };
      }
      if (cpInput > 0) {
        result.cplcs = {
          score: Math.min(100, cpInput),
          totalCollateralUsd: 0,
          amplificationBps: 10000,
          estimatedLiquidationUsd: 0,
        };
      }
    } catch {
      // leave mock values
    }

    try {
      const history = await urc.getScoreHistory();
      const scores = Array.from(history as bigint[]).map(bn);
      if (scores.length > 0) result.scoreHistory = scores;
    } catch {
      // leave mock
    }

    try {
      const ewma = await urc.getEWMAScore();
      result.ewmaScore = bn(ewma as bigint);
    } catch {
      // leave mock
    }

    try {
      const [mom] = await urc.getScoreMomentum();
      result.momentum = MOMENTUM_MAP[Math.min(bn(mom as bigint), 4)] ?? "STABLE";
    } catch {
      // leave mock
    }
  }

  // ── MCO ──────────────────────────────────────────────────────────────────
  if (ADDRESSES.MCO) {
    const mco = new ethers.Contract(ADDRESSES.MCO, MCO_ABI, provider);

    try {
      // 2% deviation query (200 bps)
      const [costUsd, secScore] = await mco.getManipulationCost(BigInt(200));
      result.mco = {
        score: Math.min(100, bn(secScore as bigint)),
        costUsd: bn(costUsd as bigint),
        borrowRateBps: result.mco?.borrowRateBps ?? 500,
      };
    } catch {
      // leave mock
    }

    try {
      const rate = await mco.getEffectiveBorrowRateBps();
      if (result.mco) result.mco.borrowRateBps = bn(rate as bigint);
    } catch {
      // leave mock
    }
  }

  // ── TDRV ─────────────────────────────────────────────────────────────────
  if (ADDRESSES.TDRV) {
    const tdrv = new ethers.Contract(ADDRESSES.TDRV, TDRV_ABI, provider);

    try {
      const volBps = await tdrv.getRealizedVolatility();
      const regime = await tdrv.getVolatilityRegime();
      const regimeNum = bn(regime as bigint);
      result.tdrv = {
        score: result.tdrv?.score ?? 0,
        volBps: bn(volBps as bigint),
        regime: REGIME_MAP[Math.min(regimeNum, 4)] ?? "NORMAL",
        ewmaVol: bn(volBps as bigint),
      };
    } catch {
      // leave mock
    }
  }

  // ── CPLCS ────────────────────────────────────────────────────────────────
  if (ADDRESSES.CPLCS) {
    const cplcs = new ethers.Contract(ADDRESSES.CPLCS, CPLCS_ABI, provider);

    try {
      // 20% price shock (2000 bps), Sepolia WETH
      const res = await cplcs.getCascadeScore(ADDRESSES.WETH, BigInt(2000));
      // (totalCollateralUsd, estimatedLiquidationUsd, secondaryImpactBps, totalImpactBps, amplificationBps, cascadeScore)
      result.cplcs = {
        score: Math.min(100, bn(res[5] as bigint)),
        totalCollateralUsd: bn(res[0] as bigint),
        amplificationBps: bn(res[4] as bigint) || 10000,
        estimatedLiquidationUsd: bn(res[1] as bigint),
      };
    } catch {
      // leave mock
    }
  }

  // ── TCO ──────────────────────────────────────────────────────────────────
  if (ADDRESSES.TCO) {
    const tco = new ethers.Contract(ADDRESSES.TCO, TCO_ABI, provider);

    try {
      const bd = await tco.getConcentrationBreakdown();
      // (hhiBps, uniqueBuckets, directionalBiasBps, approximateEntropyBits, concentrationScore)
      result.tco = {
        score: Math.min(100, bn(bd[4] as bigint)),
        hhiBps: bn(bd[0] as bigint),
        entropyBits: bn(bd[3] as bigint),
        biasBps: bn(bd[2] as bigint),
      };
    } catch {
      // leave mock
    }
  }

  // ── Circuit Breaker ───────────────────────────────────────────────────────
  if (ADDRESSES.CIRCUIT_BREAKER) {
    const cb = new ethers.Contract(ADDRESSES.CIRCUIT_BREAKER, CIRCUIT_BREAKER_ABI, provider);

    try {
      const [inCooldown, timeLeft, level] = await Promise.all([
        cb.isInCooldown(),
        cb.getTimeUntilCooldownExpiry(),
        cb.currentLevel(),
      ]);
      result.circuitBreaker = {
        isInCooldown: Boolean(inCooldown),
        cooldownSecondsLeft: bn(timeLeft as bigint),
        alertLevel: Math.min(4, bn(level as bigint)) as AlertLevel,
      };
    } catch {
      // leave mock
    }
  }

  // ── Chainlink Volatility Oracle ───────────────────────────────────────────
  if (ADDRESSES.CVO) {
    const cvo = new ethers.Contract(ADDRESSES.CVO, CVO_ABI, provider);

    try {
      const [desc, , latestPrice, latestRoundId] = await cvo.getPriceFeedDetails();
      const [cvoVolBps, numRoundsUsed, oldestRoundAge] =
        await cvo.getVolatilityWithConfidence(BigInt(12), BigInt(90000));

      const price = Number(latestPrice) / 1e8;  // 8-decimal Chainlink price
      const vol = bn(cvoVolBps as bigint);
      const regime: VolatilityRegime =
        vol > 8000 ? "STRESS" : vol > 4000 ? "ELEVATED" : vol > 2000 ? "NORMAL" : "CALM";

      result.chainlink = {
        feedDescription: String(desc),
        feedPrice: price > 0 ? Math.round(price) : 0,
        feedRoundId: bn(latestRoundId as bigint),
        cvoVolBps: vol,
        cvoRegime: regime,
        numRoundsUsed: bn(numRoundsUsed as bigint),
        oldestRoundAgeHours: Math.round(bn(oldestRoundAge as bigint) / 3600),
        // Automation / CCIP stats — keep mock values (updated by keepers)
        lastUpkeepTimestamp: Date.now() / 1000,
        nextUpkeepIn: 300,
        upkeepCount: 0,
        ccipBroadcasts: 0,
        destinationCount: 3,
        broadcastThreshold: 2,
      };
    } catch {
      // leave mock
    }
  }

  // Timestamp
  result.timestamp = Date.now();

  return result;
}
