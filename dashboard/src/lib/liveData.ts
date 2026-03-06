import { ethers } from "ethers";
import { ADDRESSES, RPC_URL, isMultiAssetLive } from "./contracts";
import {
  ARU_ABI,
  ASSET_REGISTRY_ABI,
  CCRB_ABI,
  CVO_ABI,
  CIRCUIT_BREAKER_ABI,
  CPLCS_ABI,
  MCO_ABI,
  MULTI_ASSET_ROUTER_ABI,
  TCO_ABI,
  TDRV_ABI,
  URC_ABI,
} from "./abis";
import type {
  AlertLevel,
  Asset,
  OracleSnapshot,
  RiskTier,
  ScoreMomentum,
  VolatilityRegime,
} from "./types";

const TIER_MAP: RiskTier[] = ["LOW", "MODERATE", "HIGH", "CRITICAL"];
const REGIME_MAP: VolatilityRegime[] = ["CALM", "NORMAL", "ELEVATED", "STRESS", "EXTREME"];
const MOMENTUM_MAP: ScoreMomentum[] = ["PLUNGING", "FALLING", "STABLE", "RISING", "SPIKING"];
const USD_SCALE = BigInt(100_000_000);

const ADDRESS_METADATA: Record<string, { symbol: string; name: string }> = {
  "0xc02aa39b223fe8d0a0e5c4f27ead9083c756cc2": { symbol: "ETH", name: "Ethereum" },
  "0x7b79995e5f793a07bc00c21412e50ecae098e7f9": { symbol: "ETH", name: "Ethereum" },
  "0x2260fac5e5542a773aa44fbcfedf7c193bc2c599": { symbol: "BTC", name: "Bitcoin" },
  "0x517f2982701695d4e52f1ecfbef3ba31df470161": { symbol: "BTC", name: "Bitcoin" },
  "0x514910771af9ca656af840dff83e8264ecf986ca": { symbol: "LINK", name: "Chainlink" },
  "0x779877a7b0d9e8603169ddbd7836e478b4624789": { symbol: "LINK", name: "Chainlink" },
  "0x7fc66500c84a76ad7e9c93437bfc5ac33e2ddae9": { symbol: "AAVE", name: "Aave" },
};

const ERC20_META_ABI = [
  "function symbol() view returns (string)",
  "function name() view returns (string)",
];

const CHAINLINK_FEED_ABI = [
  "function description() view returns (string)",
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
];

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

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}

function scoreToAlertLevel(score: number): AlertLevel {
  if (score >= 80) return 4;
  if (score >= 65) return 3;
  if (score >= 50) return 2;
  if (score >= 25) return 1;
  return 0;
}

function regimeFromVol(volBps: number): VolatilityRegime {
  if (volBps > 12000) return "EXTREME";
  if (volBps > 8000) return "STRESS";
  if (volBps > 5000) return "ELEVATED";
  if (volBps > 2000) return "NORMAL";
  return "CALM";
}

let _provider: ethers.JsonRpcProvider | null = null;
function getProvider(): ethers.JsonRpcProvider {
  if (!_provider) {
    _provider = new ethers.JsonRpcProvider(RPC_URL);
  }
  return _provider;
}

type RegistryConfig = {
  pool: string;
  feed: string;
  token1Decimals: number;
  shockBps: number;
  mcoThresholdLow: number;
  mcoThresholdHigh: number;
  enabled: boolean;
};

function decodeRegistryConfig(cfg: any): RegistryConfig {
  const pool = String(cfg.pool ?? cfg[1] ?? ethers.ZeroAddress);
  const feed = String(cfg.feed ?? cfg[2] ?? ethers.ZeroAddress);
  const token1Decimals = Number(cfg.token1Decimals ?? cfg[3] ?? 18);
  const shockBps = Number(cfg.shockBps ?? cfg[4] ?? 2000);
  const mcoThresholdLow = Number(cfg.mcoThresholdLow ?? cfg[5] ?? 0);
  const mcoThresholdHigh = Number(cfg.mcoThresholdHigh ?? cfg[6] ?? 0);
  const enabled = Boolean(cfg.enabled ?? cfg[7]);
  return {
    pool,
    feed,
    token1Decimals,
    shockBps,
    mcoThresholdLow,
    mcoThresholdHigh,
    enabled,
  };
}

async function resolveAssetMeta(provider: ethers.JsonRpcProvider, assetAddress: string): Promise<{ symbol: string; name: string }> {
  const lower = assetAddress.toLowerCase();
  if (ADDRESS_METADATA[lower]) return ADDRESS_METADATA[lower];

  try {
    const token = new ethers.Contract(assetAddress, ERC20_META_ABI, provider) as any;
    const [symbolRaw, nameRaw] = await Promise.all([token.symbol(), token.name()]);
    const symbol = String(symbolRaw ?? "").trim();
    const name = String(nameRaw ?? "").trim();
    if (symbol.length > 0) {
      return {
        symbol: symbol.toUpperCase(),
        name: name.length > 0 ? name : symbol.toUpperCase(),
      };
    }
  } catch {
    // noop
  }

  const short = `${assetAddress.slice(0, 6)}...${assetAddress.slice(-4)}`;
  return { symbol: short, name: short };
}

export async function fetchConfiguredAssets(): Promise<Asset[]> {
  if (!isMultiAssetLive() || !ADDRESSES.ASSET_REGISTRY) return [];

  const provider = getProvider();
  const registry = new ethers.Contract(ADDRESSES.ASSET_REGISTRY, ASSET_REGISTRY_ABI, provider) as any;

  let addresses: string[] = [];
  try {
    const raw = await registry.getSupportedAssets();
    addresses = (raw as string[]).map((a) => String(a));
  } catch {
    return [];
  }

  const assets = await Promise.all(
    addresses.map(async (address) => {
      try {
        const cfg = decodeRegistryConfig(await registry.getConfig(address));
        const meta = await resolveAssetMeta(provider, address);
        return {
          symbol: meta.symbol,
          name: meta.name,
          address,
          enabled: cfg.enabled,
          configured: true,
        } as Asset;
      } catch {
        return null;
      }
    })
  );

  const filtered = assets.filter((a): a is Asset => a !== null);
  filtered.sort((a, b) => {
    if (a.enabled !== b.enabled) return a.enabled ? -1 : 1;
    return a.symbol.localeCompare(b.symbol);
  });

  // De-duplicate symbols for dropdown stability.
  const seen = new Map<string, number>();
  for (const asset of filtered) {
    const n = seen.get(asset.symbol) ?? 0;
    if (n > 0) {
      asset.symbol = `${asset.symbol}-${asset.address.slice(2, 6)}`;
    }
    seen.set(asset.symbol, n + 1);
  }

  return filtered;
}

export async function fetchLiveSnapshot(
  assetSymbol: string = "ETH",
  assetAddress: string = "",
  assetEnabled: boolean = true
): Promise<Partial<OracleSnapshot>> {
  if (!assetEnabled) {
    return {
      asset: assetSymbol,
      assetAddress,
      assetEnabled: false,
      assetConfigured: true,
      assetStatusNote: "DISABLED",
      timestamp: Date.now(),
    };
  }

  const multiAssetReady = isMultiAssetLive() && Boolean(assetAddress);
  if (multiAssetReady) {
    return fetchMultiAssetSnapshot(assetSymbol, assetAddress);
  }

  return fetchLegacySnapshot(assetSymbol);
}

async function fetchMultiAssetSnapshot(assetSymbol: string, assetAddress: string): Promise<Partial<OracleSnapshot>> {
  const provider = getProvider();
  const result: Partial<OracleSnapshot> = {
    asset: assetSymbol,
    assetAddress,
    assetEnabled: true,
    assetConfigured: true,
    assetStatusNote: "LIVE",
  };

  const router = new ethers.Contract(ADDRESSES.MULTI_ASSET_ROUTER, MULTI_ASSET_ROUTER_ABI, provider) as any;
  const registry = new ethers.Contract(ADDRESSES.ASSET_REGISTRY, ASSET_REGISTRY_ABI, provider) as any;

  let config: RegistryConfig | null = null;
  try {
    config = decodeRegistryConfig(await registry.getConfig(assetAddress));
    if (!config.enabled) {
      result.assetEnabled = false;
      result.assetStatusNote = "DISABLED";
      result.timestamp = Date.now();
      return result;
    }
  } catch {
    result.assetConfigured = false;
    result.assetStatusNote = "NOT_CONFIGURED";
  }

  try {
    const state = await router.assetRiskState(assetAddress);
    const score = bn(state[0] as bigint);
    const mcoInput = bn(state[1] as bigint);
    const tdrvInput = bn(state[2] as bigint);
    const cpInput = bn(state[3] as bigint);
    const tcoInput = bn(state[4] as bigint);
    const tier = bn(state[5] as bigint);
    const ltvBps = bn(state[6] as bigint);
    const realizedVolBps = bn(state[7] as bigint);
    const manipUsd = usd1e8(state[8] as bigint);
    const ewma = bn(state[9] as bigint);

    result.compositeScore = clamp(score, 0, 100);
    result.alertLevel = scoreToAlertLevel(score);
    result.riskTier = TIER_MAP[Math.min(tier, 3)] ?? "LOW";
    result.ltvBps = ltvBps;
    result.ewmaScore = ewma;
    result.momentum = "STABLE";

    result.mco = {
      score: clamp(mcoInput, 0, 100),
      costUsd: Math.max(0, manipUsd),
      borrowRateBps: 500,
    };
    result.tdrv = {
      score: clamp(tdrvInput, 0, 100),
      volBps: realizedVolBps,
      regime: regimeFromVol(realizedVolBps),
      ewmaVol: realizedVolBps,
    };
    result.cplcs = {
      score: clamp(cpInput, 0, 100),
      totalCollateralUsd: 0,
      amplificationBps: 10_000,
      estimatedLiquidationUsd: 0,
    };
    result.tco = {
      score: clamp(tcoInput, 0, 100),
      hhiBps: 0,
      entropyBits: 0,
      biasBps: 0,
    };
    result.scoreHistory = [score];
  } catch {
    // keep mock baseline values from caller
  }

  if (ADDRESSES.MCO && config) {
    const mco = new ethers.Contract(ADDRESSES.MCO, MCO_ABI, provider) as any;
    try {
      const [rawCostUsd, securityScore] = await mco.getManipulationCostForPool(
        config.pool,
        config.feed,
        BigInt(200),
        config.token1Decimals
      );
      const rawUsd = usd1e8(rawCostUsd as bigint);
      const highCapUsd = Math.floor(config.mcoThresholdHigh / 1e8);
      const normalizedUsd = highCapUsd > 0 ? Math.min(rawUsd, highCapUsd) : rawUsd;
      result.mco = {
        score: clamp(100 - bn(securityScore as bigint), 0, 100),
        costUsd: normalizedUsd,
        borrowRateBps: result.mco?.borrowRateBps ?? 500,
      };
    } catch {
      // noop
    }

    try {
      const rate = await mco.getEffectiveBorrowRateBps();
      if (result.mco) result.mco.borrowRateBps = bn(rate as bigint);
    } catch {
      // noop
    }
  }

  if (ADDRESSES.TDRV && config) {
    const tdrv = new ethers.Contract(ADDRESSES.TDRV, TDRV_ABI, provider) as any;
    try {
      const [volBps, volScore] = await Promise.all([
        tdrv.getRealizedVolatilityForPool(config.pool, BigInt(3600), BigInt(24)),
        tdrv.getVolatilityScoreForPool(config.pool, BigInt(3600), BigInt(24), BigInt(2000), BigInt(15000)),
      ]);
      result.tdrv = {
        score: clamp(bn(volScore as bigint), 0, 100),
        volBps: bn(volBps as bigint),
        regime: regimeFromVol(bn(volBps as bigint)),
        ewmaVol: bn(volBps as bigint),
      };
    } catch {
      // noop
    }
  }

  if (ADDRESSES.CPLCS && config) {
    const cplcs = new ethers.Contract(ADDRESSES.CPLCS, CPLCS_ABI, provider) as any;
    try {
      const r = await cplcs.getCascadeScore(assetAddress, BigInt(config.shockBps));
      result.cplcs = {
        score: clamp(bn(r[5] as bigint), 0, 100),
        totalCollateralUsd: usd1e8(r[0] as bigint),
        amplificationBps: bn(r[4] as bigint),
        estimatedLiquidationUsd: usd1e8(r[1] as bigint),
      };
    } catch {
      // noop
    }
  }

  if (ADDRESSES.TCO && config) {
    const tco = new ethers.Contract(ADDRESSES.TCO, TCO_ABI, provider) as any;
    try {
      const bd = await tco.getConcentrationBreakdownForPool(config.pool, BigInt(86_400), BigInt(24));
      result.tco = {
        score: clamp(bn(bd[4] as bigint), 0, 100),
        hhiBps: bn(bd[0] as bigint),
        entropyBits: bn(bd[3] as bigint),
        biasBps: bn(bd[2] as bigint),
      };
    } catch {
      // noop
    }
  }

  await applyCircuitBreakerData(result, provider);
  await applyChainlinkPanelData(result, provider, config?.feed ?? "");

  result.timestamp = Date.now();
  return result;
}

async function fetchLegacySnapshot(assetSymbol: string): Promise<Partial<OracleSnapshot>> {
  const provider = getProvider();
  const result: Partial<OracleSnapshot> = {
    asset: assetSymbol,
    assetAddress: assetSymbol,
    assetEnabled: assetSymbol === "ETH",
    assetConfigured: assetSymbol === "ETH",
    assetStatusNote: assetSymbol === "ETH" ? "LIVE_LEGACY" : "DISABLED",
  };

  if (assetSymbol !== "ETH") {
    result.timestamp = Date.now();
    return result;
  }

  if (ADDRESSES.URC) {
    const urc = new ethers.Contract(ADDRESSES.URC, URC_ABI, provider) as any;
    try {
      const rb = await urc.getRiskBreakdown();
      const composite = bn(rb[0] as bigint);
      const tier = bn(rb[4] as bigint);
      const ltvBps = bn(rb[5] as bigint);

      result.compositeScore = composite;
      result.ltvBps = ltvBps > 0 ? ltvBps : 8000;
      result.riskTier = TIER_MAP[Math.min(tier, 3)] ?? "LOW";
      result.alertLevel = scoreToAlertLevel(composite);

      const mcoInput = bn(rb[1] as bigint);
      const tdrvInput = bn(rb[2] as bigint);
      const cpInput = bn(rb[3] as bigint);
      const volBps = bn(rb[6] as bigint);
      const costUsd = usd1e8(rb[7] as bigint);

      result.mco = {
        score: clamp(mcoInput, 0, 100),
        costUsd,
        borrowRateBps: 500,
      };
      result.tdrv = {
        score: clamp(tdrvInput, 0, 100),
        volBps,
        regime: regimeFromVol(volBps),
        ewmaVol: volBps,
      };
      result.cplcs = {
        score: clamp(cpInput, 0, 100),
        totalCollateralUsd: 0,
        amplificationBps: 10_000,
        estimatedLiquidationUsd: 0,
      };
    } catch {
      // noop
    }

    try {
      const history = await urc.getScoreHistory();
      const scores = Array.from(history as bigint[]).map(bn);
      if (scores.length > 0) result.scoreHistory = scores;
    } catch {
      // noop
    }

    try {
      const ewma = await urc.getEWMAScore();
      result.ewmaScore = bn(ewma as bigint);
    } catch {
      // noop
    }

    try {
      const [mom] = await urc.getScoreMomentum();
      result.momentum = MOMENTUM_MAP[Math.min(bn(mom as bigint), 4)] ?? "STABLE";
    } catch {
      // noop
    }
  }

  await applyCircuitBreakerData(result, provider);
  await applyChainlinkPanelData(result, provider);
  result.timestamp = Date.now();
  return result;
}

async function applyCircuitBreakerData(result: Partial<OracleSnapshot>, provider: ethers.JsonRpcProvider): Promise<void> {
  if (!ADDRESSES.CIRCUIT_BREAKER) return;

  try {
    const cb = new ethers.Contract(ADDRESSES.CIRCUIT_BREAKER, CIRCUIT_BREAKER_ABI, provider) as any;
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
    // noop
  }
}

async function applyChainlinkPanelData(
  result: Partial<OracleSnapshot>,
  provider: ethers.JsonRpcProvider,
  preferredFeedAddress: string = ""
): Promise<void> {
  const nowTs = Math.floor(Date.now() / 1000);

  let feedDescription = result.asset ? `${result.asset} / USD` : "ASSET / USD";
  let feedPrice = 0;
  let feedRoundId = 0;
  let feedUpdatedAt = 0;

  let cvoVolBps = 0;
  let numRoundsUsed = 0;
  let oldestRoundAgeHours = 0;

  let upkeepCount = 0;
  let lastUpkeepTimestamp = nowTs;
  let nextUpkeepIn = 300;
  let upkeepIntervalSeconds = 300;

  let ccipBroadcasts = 0;
  let destinationCount = 3;
  let broadcastThreshold = 2;

  const tryReadFeed = async (feedAddress: string): Promise<boolean> => {
    if (!feedAddress || feedAddress === ethers.ZeroAddress) return false;
    try {
      const feed = new ethers.Contract(feedAddress, CHAINLINK_FEED_ABI, provider) as any;
      const [desc, dec, latest] = await Promise.all([
        feed.description(),
        feed.decimals(),
        feed.latestRoundData(),
      ]);
      const answer = latest[1] as bigint;
      if (answer <= BigInt(0)) return false;

      const decimals = Number(dec as bigint | number);
      if (!Number.isFinite(decimals) || decimals < 0 || decimals > 18) return false;

      feedDescription = String(desc);
      feedPrice = Number(answer) / Math.pow(10, decimals);
      feedRoundId = toDisplayRoundId(latest[0] as bigint);
      feedUpdatedAt = Number(latest[3] as bigint);
      return true;
    } catch {
      return false;
    }
  };

  let cvoFeedAddress = "";
  if (ADDRESSES.CVO) {
    try {
      const cvo = new ethers.Contract(ADDRESSES.CVO, CVO_ABI, provider) as any;
      cvoFeedAddress = String(await cvo.priceFeed());
    } catch {
      // noop
    }
  }

  const preferredLoaded = await tryReadFeed(preferredFeedAddress);
  if (!preferredLoaded) {
    await tryReadFeed(cvoFeedAddress);
  }

  if (ADDRESSES.CVO) {
    const cvo = new ethers.Contract(ADDRESSES.CVO, CVO_ABI, provider) as any;
    try {
      let oldestRoundAgeSecs = 0;
      try {
        const latest = await cvo.getVolatilityWithConfidence();
        cvoVolBps = bn(latest[0] as bigint);
        numRoundsUsed = bn(latest[1] as bigint);
        oldestRoundAgeSecs = bn(latest[2] as bigint);
      } catch {
        try {
          const legacy = await cvo["getVolatilityWithConfidence(uint8,uint32)"](BigInt(12), BigInt(90_000));
          cvoVolBps = bn(legacy[0] as bigint);
          numRoundsUsed = bn(legacy[1] as bigint);
          oldestRoundAgeSecs = bn(legacy[2] as bigint);
        } catch {
          cvoVolBps = bn(await cvo.getVolatility());
        }
      }

      if (oldestRoundAgeSecs > 0) {
        oldestRoundAgeHours = Math.round(oldestRoundAgeSecs / 3600);
      }
    } catch {
      // noop
    }
  }

  if (oldestRoundAgeHours === 0 && feedUpdatedAt > 0) {
    oldestRoundAgeHours = Math.max(0, Math.round((nowTs - feedUpdatedAt) / 3600));
  }

  if (ADDRESSES.ARU) {
    try {
      const aru = new ethers.Contract(ADDRESSES.ARU, ARU_ABI, provider) as any;
      const [count, lastTs, nextSecs, intervalSecs] = await Promise.all([
        aru.upkeepCount(),
        aru.lastUpkeepTimestamp(),
        aru.secondsUntilNextUpkeep(),
        aru.updateIntervalSeconds(),
      ]);

      upkeepCount = bn(count as bigint);
      lastUpkeepTimestamp = bn(lastTs as bigint) || lastUpkeepTimestamp;
      nextUpkeepIn = Math.max(0, bn(nextSecs as bigint));
      upkeepIntervalSeconds = Math.max(60, bn(intervalSecs as bigint));
    } catch {
      // noop
    }
  }

  if (nextUpkeepIn === 0 && lastUpkeepTimestamp > 0) {
    const elapsed = Math.max(0, nowTs - lastUpkeepTimestamp);
    const rem = upkeepIntervalSeconds - (elapsed % upkeepIntervalSeconds);
    nextUpkeepIn = rem === upkeepIntervalSeconds ? 0 : rem;
  }

  if (ADDRESSES.CCRB) {
    try {
      const ccrb = new ethers.Contract(ADDRESSES.CCRB, CCRB_ABI, provider) as any;
      const [count, dests, threshold] = await Promise.all([
        ccrb.broadcastCount(),
        ccrb.destinationCount(),
        ccrb.broadcastThreshold(),
      ]);
      ccipBroadcasts = bn(count as bigint);
      destinationCount = bn(dests as bigint);
      broadcastThreshold = Math.min(4, bn(threshold as bigint));
    } catch {
      // noop
    }
  }

  const regime: VolatilityRegime =
    cvoVolBps > 8000 ? "STRESS" : cvoVolBps > 4000 ? "ELEVATED" : cvoVolBps > 2000 ? "NORMAL" : "CALM";

  result.chainlink = {
    feedDescription,
    feedPrice: feedPrice > 0 ? Math.round(feedPrice) : 0,
    feedRoundId,
    cvoVolBps,
    cvoRegime: regime,
    numRoundsUsed,
    oldestRoundAgeHours,
    lastUpkeepTimestamp,
    nextUpkeepIn,
    upkeepIntervalSeconds,
    upkeepCount,
    ccipBroadcasts,
    destinationCount,
    broadcastThreshold,
  };
}
