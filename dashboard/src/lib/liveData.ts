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
const USD_SCALE = BigInt(100_000_000);

function bn(v: bigint): number {
  return Number(v);
}

function usd1e8(v: bigint): number {
  return Number(v / USD_SCALE);
}

function toDisplayRoundId(v: bigint): number {
  if (v <= BigInt(Number.MAX_SAFE_INTEGER)) return Number(v);
  const low64Mask = (BigInt(1) << BigInt(64)) - BigInt(1);
  return Number(v & low64Mask);
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

export async function fetchLiveSnapshot(asset: string = "ETH"): Promise<Partial<OracleSnapshot>> {
  // Graceful degradation: If not ETH, fallback to the improved mock data
  // to show realistic multi-asset metrics (Sepolia only has ETH pool deployed for MCO/TDRV).
  if (asset !== "ETH") {
    return {};
  }

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
      const mcoInput = bn(rb[1]);
      const tdrvInput = bn(rb[2]);
      const cpInput = bn(rb[3]);
      const volBps = bn(rb[6]);
      const costUsd = usd1e8(rb[7] as bigint);

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
    const mcoAny = mco as any;
    let highThresholdUsd: number | undefined;

    try {
      const thresholdHigh = await mco.costThresholdHigh();
      highThresholdUsd = usd1e8(thresholdHigh as bigint);
    } catch {
      // optional on older deployments
    }

    const hasSaneThreshold = highThresholdUsd === undefined || highThresholdUsd >= 1_000_000;

    try {
      // 2% deviation query (200 bps). Prefer normalized endpoint when available.
      let costUsdScaled: number;
      let secScore: bigint;

      try {
        if (!hasSaneThreshold) throw new Error("threshold-too-low");
        const [normalizedCostUsd, normalizedScore] = await mcoAny.getManipulationCostNormalized(BigInt(200));
        costUsdScaled = usd1e8(normalizedCostUsd as bigint);
        secScore = normalizedScore as bigint;
      } catch {
        const [costUsdRaw, securityScoreRaw] = await mco.getManipulationCost(BigInt(200));
        const rawUsd = usd1e8(costUsdRaw as bigint);
        const fallbackCapUsd = hasSaneThreshold ? highThresholdUsd : 100_000_000; // $100M default UI cap
        costUsdScaled = fallbackCapUsd ? Math.min(rawUsd, fallbackCapUsd) : rawUsd;
        secScore = securityScoreRaw as bigint;
      }

      result.mco = {
        score: Math.min(100, bn(secScore)),
        costUsd: costUsdScaled,
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
      // totalCollateralUsd and estimatedLiquidationUsd are in 8-decimal USD.
      result.cplcs = {
        score: Math.min(100, bn(res[5] as bigint)),
        totalCollateralUsd: Number((res[0] as bigint) / BigInt(100_000_000)),
        amplificationBps: bn(res[4] as bigint) || 10000,
        estimatedLiquidationUsd: Number((res[1] as bigint) / BigInt(100_000_000)),
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
    const cvoAny = cvo as any;

    try {
      const [desc, , latestPrice, latestRoundId] = await cvo.getPriceFeedDetails();
      let price = Number(latestPrice as bigint) / 1e8;  // 8-decimal Chainlink price
      let feedRoundId = toDisplayRoundId(latestRoundId as bigint);

      // Prefer direct feed read when the deployed CVO ABI is inconsistent across versions.
      try {
        const feedAddr = await cvo.priceFeed();
        const feed = new ethers.Contract(
          feedAddr,
          [
            "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
          ],
          provider
        );
        const latest = await feed.latestRoundData();
        if ((latest[1] as bigint) > BigInt(0)) {
          price = Number(latest[1] as bigint) / 1e8;
        }
        feedRoundId = toDisplayRoundId(latest[0] as bigint);
      } catch {
        // keep CVO-provided round/price
      }

      let cvoVolBps: bigint = BigInt(0);
      let numRoundsUsed: bigint = BigInt(0);
      let oldestRoundAge: bigint = BigInt(0);

      try {
        const latest = await cvoAny["getVolatilityWithConfidence()"]();
        cvoVolBps = latest[0] as bigint;
        numRoundsUsed = latest[1] as bigint;
        oldestRoundAge = latest[2] as bigint;
      } catch {
        try {
          const legacy = await cvoAny["getVolatilityWithConfidence(uint8,uint32)"](BigInt(12), BigInt(90_000));
          cvoVolBps = legacy[0] as bigint;
          numRoundsUsed = legacy[1] as bigint;
          oldestRoundAge = legacy[2] as bigint;
        } catch {
          const fallbackVol = await cvo.getVolatility();
          cvoVolBps = fallbackVol as bigint;
        }
      }

      const vol = bn(cvoVolBps);
      const regime: VolatilityRegime =
        vol > 8000 ? "STRESS" : vol > 4000 ? "ELEVATED" : vol > 2000 ? "NORMAL" : "CALM";

      result.chainlink = {
        feedDescription: String(desc),
        feedPrice: price > 0 ? Math.round(price) : 0,
        feedRoundId: feedRoundId,
        cvoVolBps: vol,
        cvoRegime: regime,
        numRoundsUsed: bn(numRoundsUsed),
        oldestRoundAgeHours: Math.round(bn(oldestRoundAge) / 3600),
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
