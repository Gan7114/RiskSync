"use client";

import { useOracleData } from "@/hooks/useOracleData";
import Header from "@/components/Header";
import RiskGauge from "@/components/RiskGauge";
import AlertLadder from "@/components/AlertLadder";
import LTVMeter from "@/components/LTVMeter";
import PillarCard from "@/components/PillarCard";
import ScoreChart from "@/components/ScoreChart";
import EWMAPanel from "@/components/EWMAPanel";
import StressPanel from "@/components/StressPanel";
import CircuitBreaker from "@/components/CircuitBreaker";
import ChainlinkPanel from "@/components/ChainlinkPanel";
import { motion } from "framer-motion";
import { useEffect, useState } from "react";

function formatUsd(n: number) {
  if (!Number.isFinite(n) || n <= 0) return "$0";
  if (n >= 1e12) return `$${(n / 1e12).toFixed(2)}T`;
  if (n >= 1e9) return `$${(n / 1e9).toFixed(2)}B`;
  if (n >= 1e6) return `$${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `$${(n / 1e3).toFixed(0)}K`;
  if (n >= 1) return `$${n.toFixed(0)}`;
  return `$${n.toFixed(2)}`;
}

function bpsToPercent(bps: number, decimals = 2) {
  return `${(bps / 100).toFixed(decimals)}%`;
}

export default function Dashboard() {
  const [activeAsset, setActiveAsset] = useState<string>("ETH");
  const { data, simMode, assets } = useOracleData(activeAsset);

  useEffect(() => {
    if (assets.length === 0) return;
    if (!assets.some((a) => a.symbol === activeAsset)) {
      setActiveAsset(assets[0].symbol);
    }
  }, [assets, activeAsset]);

  if (!data) {
    return (
      <div className="min-h-screen grid-bg flex items-center justify-center">
        <motion.div
          className="text-indigo-400 text-sm font-mono tracking-widest"
          animate={{ opacity: [1, 0.3, 1] }}
          transition={{ duration: 1.2, repeat: Infinity }}
        >
          INITIALIZING ORACLE...
        </motion.div>
      </div>
    );
  }

  const { mco, tdrv, cplcs, tco } = data;

  // Regime badge color
  const regimeColors: Record<string, string> = {
    CALM: "#10b981", NORMAL: "#6366f1", ELEVATED: "#f59e0b",
    STRESS: "#f97316", EXTREME: "#dc2626",
  };

  return (
    <div className="min-h-screen grid-bg">
      <Header
        data={data}
        simMode={simMode}
        assets={assets}
        activeAsset={activeAsset}
        setActiveAsset={setActiveAsset}
      />

      <main className="p-4 lg:p-6 flex flex-col gap-5 max-w-[1600px] mx-auto">
        {!data.assetEnabled && (
          <motion.div
            className="glass gradient-border p-4 text-sm text-amber-200 border border-amber-500/30"
            initial={{ opacity: 0, y: 8 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.25 }}
          >
            <div className="font-bold tracking-wide">ASSET DISABLED</div>
            <div className="text-xs text-amber-100 mt-1">
              {data.assetStatusNote || "This asset is configured as disabled in AssetRegistry. Live risk updates are intentionally off."}
            </div>
          </motion.div>
        )}

        {/* ── ROW 1: Gauge + Alert + LTV ─────────────────────────────────── */}
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">

          {/* Risk Gauge */}
          <motion.div
            className="glass gradient-border p-6 flex flex-col items-center gap-2 col-span-1"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5 }}
          >
            <div className="text-[10px] text-slate-500 tracking-widest self-start">COMPOSITE RISK SCORE</div>
            <RiskGauge
              score={data.compositeScore}
              alertLevel={data.alertLevel}
              riskTier={data.riskTier}
              ewmaScore={data.ewmaScore}
            />
          </motion.div>

          {/* Alert Ladder */}
          <motion.div
            className="col-span-1"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5, delay: 0.1 }}
          >
            <AlertLadder alertLevel={data.alertLevel} />
          </motion.div>

          {/* LTV + EWMA stacked */}
          <motion.div
            className="col-span-1 flex flex-col gap-4"
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.5, delay: 0.2 }}
          >
            <LTVMeter ltvBps={data.ltvBps} alertLevel={data.alertLevel} />
            <EWMAPanel
              ewmaScore={data.ewmaScore}
              momentum={data.momentum}
              compositeScore={data.compositeScore}
              alertLevel={data.alertLevel}
            />
          </motion.div>
        </div>

        {/* ── ROW 2: Four Pillars ─────────────────────────────────────────── */}
        <motion.div
          className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-4"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.25 }}
        >
          <PillarCard
            title="Manipulation Cost"
            pillarId="PILLAR 1 — MCO"
            weight="30%"
            score={mco.score}
            alertLevel={data.alertLevel}
            description="USD cost to manipulate the Uniswap V3 TWAP via tick-bitmap liquidity walk. High cost = low oracle attack risk."
            metrics={[
              { label: "ATTACK COST", value: formatUsd(mco.costUsd), highlight: true },
              { label: "BORROW RATE", value: bpsToPercent(mco.borrowRateBps) },
              { label: "WINDOW", value: "30 min TWAP" },
              { label: "PROTOCOL", value: "Aave V3" },
            ]}
          />
          <PillarCard
            title="Realized Volatility"
            pillarId="PILLAR 2 — TDRV"
            weight="35%"
            score={tdrv.score}
            alertLevel={data.alertLevel}
            description="24-hour annualized realized vol from Uniswap V3 observations. High vol = wider position swings = lower safe LTV."
            badge={tdrv.regime}
            badgeColor={regimeColors[tdrv.regime]}
            metrics={[
              { label: "ANNUAL VOL", value: bpsToPercent(tdrv.volBps), highlight: true },
              { label: "EWMA VOL", value: bpsToPercent(tdrv.ewmaVol) },
              { label: "SAMPLES", value: "24 × 1h" },
              { label: "REGIME", value: tdrv.regime },
            ]}
          />
          <PillarCard
            title="Cascade Score"
            pillarId="PILLAR 3 — CPLCS"
            weight="20%"
            score={cplcs.score}
            alertLevel={data.alertLevel}
            description="Cross-protocol liquidation cascade via iterative convergence across Aave, Compound, Morpho, and Euler V2."
            metrics={[
              { label: "COLLATERAL", value: formatUsd(cplcs.totalCollateralUsd), highlight: true },
              { label: "AT RISK", value: formatUsd(cplcs.estimatedLiquidationUsd) },
              { label: "AMPLIF.", value: `${(cplcs.amplificationBps / 100).toFixed(1)}%` },
              { label: "STATUS", value: data.assetEnabled ? "enabled" : "disabled" },
            ]}
          />
          <PillarCard
            title="Tick Entropy"
            pillarId="PILLAR 4 — TCO"
            weight="15%"
            score={tco.score}
            alertLevel={data.alertLevel}
            description="Information-theoretic manipulation detection via HHI + Renyi entropy on the tick observation sequence."
            badge={`H₂=${tco.entropyBits} bits`}
            badgeColor="#8b5cf6"
            metrics={[
              { label: "HHI", value: `${(tco.hhiBps / 100).toFixed(1)}%`, highlight: true },
              { label: "ENTROPY", value: `${tco.entropyBits} bits` },
              { label: "DIR BIAS", value: bpsToPercent(tco.biasBps) },
              { label: "ORGANIC?", value: tco.score < 40 ? "YES" : "SUSPECT" },
            ]}
          />
        </motion.div>

        {/* ── ROW 3: Score Chart ──────────────────────────────────────────── */}
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.3 }}
        >
          <ScoreChart
            scoreHistory={data.scoreHistory}
            ewmaScore={data.ewmaScore}
            alertLevel={data.alertLevel}
          />
        </motion.div>

        {/* ── ROW 4: Chainlink Integration ────────────────────────────── */}
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.35 }}
        >
          <ChainlinkPanel data={data.chainlink} />
        </motion.div>

        {/* ── ROW 5: Stress + Circuit Breaker ────────────────────────────── */}
        <motion.div
          className="grid grid-cols-1 lg:grid-cols-3 gap-4"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.5, delay: 0.4 }}
        >
          <div className="lg:col-span-2">
            <StressPanel scenarios={data.scenarios} />
          </div>
          <div className="lg:col-span-1">
            <CircuitBreaker
              alertLevel={data.circuitBreaker.alertLevel}
              isInCooldown={data.circuitBreaker.isInCooldown}
              cooldownSecondsLeft={data.circuitBreaker.cooldownSecondsLeft}
            />
          </div>
        </motion.div>

        {/* ── Footer ─────────────────────────────────────────────────────── */}
        <div className="text-center text-[10px] text-slate-700 py-4 border-t border-[#1a2744]">
          DEFISTRESSORACLE · 4-PILLAR ON-CHAIN RISK MIDDLEWARE · MULTI-ASSET REGISTRY ROUTED ·{" "}
          <span className="text-indigo-700">MCO 30% + TDRV 35% + CPLCS 20% + TCO 15%</span>
          {" "}·{" "}
          <span className="text-[#375bd2]">Chainlink Price Feeds + Automation + CCIP</span>
        </div>

      </main>
    </div>
  );
}
