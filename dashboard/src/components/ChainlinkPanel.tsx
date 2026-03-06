"use client";

import { motion } from "framer-motion";
import type { ChainlinkData, VolatilityRegime } from "@/lib/types";

const REGIME_COLOR: Record<VolatilityRegime, string> = {
  CALM:     "#10b981",
  NORMAL:   "#22d3ee",
  ELEVATED: "#f59e0b",
  STRESS:   "#f97316",
  EXTREME:  "#dc2626",
};

function fmt(n: number) {
  return n.toLocaleString("en-US");
}

function fmtBps(bps: number) {
  return (bps / 100).toFixed(0) + "%";
}

function fmtAge(hours: number) {
  if (hours < 1) return `${Math.round(hours * 60)}m`;
  return `${hours.toFixed(0)}h`;
}

function fmtCountdown(secs: number) {
  const m = Math.floor(secs / 60);
  const s = secs % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

interface RowProps { label: string; value: string; accent?: string }
function Row({ label, value, accent }: RowProps) {
  return (
    <div className="flex justify-between items-center py-1.5 border-b border-white/5 last:border-0">
      <span className="text-xs text-slate-400">{label}</span>
      <span className="text-xs font-mono font-semibold" style={accent ? { color: accent } : { color: "#e2e8f0" }}>
        {value}
      </span>
    </div>
  );
}

interface Props {
  data: ChainlinkData;
}

export default function ChainlinkPanel({ data }: Props) {
  const regimeColor = REGIME_COLOR[data.cvoRegime];
  const upkeepInterval = Math.max(60, data.upkeepIntervalSeconds || 300);
  const upkeepRemaining = Math.max(0, Math.min(upkeepInterval, data.nextUpkeepIn));

  return (
    <motion.div
      className="glass rounded-2xl p-5 border border-white/8"
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.5 }}
    >
      {/* Header */}
      <div className="flex items-center gap-3 mb-4">
        {/* Chainlink hexagon logo approximation */}
        <div className="w-8 h-8 flex items-center justify-center rounded-lg bg-[#375bd2]/20 border border-[#375bd2]/40">
          <svg viewBox="0 0 24 24" width="18" height="18" fill="#375bd2">
            <path d="M12 2 L20 7 L20 17 L12 22 L4 17 L4 7 Z" fillOpacity={0.25} stroke="#375bd2" strokeWidth="1.5" />
            <text x="12" y="16" textAnchor="middle" fontSize="8" fill="#375bd2" fontWeight="bold">CL</text>
          </svg>
        </div>
        <div>
          <h3 className="text-sm font-bold text-slate-100">Chainlink Integration</h3>
          <p className="text-xs text-slate-500">Price Feeds · Automation · CCIP</p>
        </div>
        {/* Live indicator */}
        <div className="ml-auto flex items-center gap-1.5">
          <motion.div
            className="w-2 h-2 rounded-full bg-[#375bd2]"
            animate={{ opacity: [1, 0.3, 1] }}
            transition={{ duration: 2, repeat: Infinity }}
          />
          <span className="text-xs text-[#375bd2] font-semibold">ACTIVE</span>
        </div>
      </div>

      <div className="grid grid-cols-3 gap-4">

        {/* Price Feeds */}
        <div className="bg-[#0a1628]/60 rounded-xl p-3 border border-[#375bd2]/20">
          <div className="flex items-center gap-1.5 mb-2">
            <div className="w-1.5 h-1.5 rounded-full bg-[#375bd2]" />
            <span className="text-xs font-bold text-[#375bd2] uppercase tracking-wide">Price Feeds</span>
          </div>
          <div className="text-center mb-2">
            <div className="text-xl font-mono font-bold text-slate-100">
              ${fmt(data.feedPrice)}
            </div>
            <div className="text-xs text-slate-500">{data.feedDescription}</div>
          </div>
          <Row label="Round ID"     value={`#${fmt(data.feedRoundId)}`} />
          <Row label="Rounds Used"  value={`${data.numRoundsUsed} samples`} />
          <Row label="History Age"  value={fmtAge(data.oldestRoundAgeHours)} />
          {/* Realized Vol bar */}
          <div className="mt-2">
            <div className="flex justify-between mb-1">
              <span className="text-xs text-slate-400">CL Realized Vol</span>
              <span className="text-xs font-mono" style={{ color: regimeColor }}>
                {fmtBps(data.cvoVolBps)} ann.
              </span>
            </div>
            <div className="h-1.5 bg-slate-800 rounded-full overflow-hidden">
              <motion.div
                className="h-full rounded-full"
                style={{ backgroundColor: regimeColor }}
                initial={{ width: 0 }}
                animate={{ width: `${Math.min(100, (data.cvoVolBps / 20000) * 100)}%` }}
                transition={{ duration: 0.8, ease: "easeOut" }}
              />
            </div>
            <div className="text-right mt-0.5">
              <span
                className="text-xs font-bold px-1.5 py-0.5 rounded"
                style={{ color: regimeColor, backgroundColor: `${regimeColor}18` }}
              >
                {data.cvoRegime}
              </span>
            </div>
          </div>
        </div>

        {/* Automation */}
        <div className="bg-[#0a1628]/60 rounded-xl p-3 border border-emerald-500/20">
          <div className="flex items-center gap-1.5 mb-2">
            <div className="w-1.5 h-1.5 rounded-full bg-emerald-500" />
            <span className="text-xs font-bold text-emerald-400 uppercase tracking-wide">Automation</span>
          </div>
          {/* Countdown ring */}
          <div className="flex justify-center mb-2">
            <div className="relative w-16 h-16">
              <svg viewBox="0 0 64 64" className="w-full h-full -rotate-90">
                <circle cx="32" cy="32" r="28" fill="none" stroke="#1e293b" strokeWidth="5" />
                <motion.circle
                  cx="32" cy="32" r="28"
                  fill="none"
                  stroke="#10b981"
                  strokeWidth="5"
                  strokeLinecap="round"
                  strokeDasharray={`${2 * Math.PI * 28}`}
                  animate={{
                    strokeDashoffset: `${2 * Math.PI * 28 * (1 - (upkeepRemaining / upkeepInterval))}`
                  }}
                  transition={{ duration: 0.6 }}
                />
              </svg>
              <div className="absolute inset-0 flex items-center justify-center">
                <span className="text-sm font-mono font-bold text-emerald-400">
                  {fmtCountdown(upkeepRemaining)}
                </span>
              </div>
            </div>
          </div>
          <div className="text-center text-xs text-slate-500 mb-2">next upkeep</div>
          <Row label="Performed" value={`${data.upkeepCount} times`} />
          <Row
            label="Last Upkeep"
            value={`${Math.floor((Date.now() / 1000 - data.lastUpkeepTimestamp) / 60)}m ago`}
          />
          <Row label="Interval" value={`${Math.round(upkeepInterval / 60)} min`} />
          {/* Heartbeat bar */}
          <div className="mt-2">
            <div className="flex gap-1">
              {Array.from({ length: 8 }).map((_, i) => (
                <motion.div
                  key={i}
                  className="flex-1 rounded-sm"
                  style={{ height: `${8 + Math.sin(i + data.upkeepCount) * 4}px` }}
                  animate={{ backgroundColor: i < 7 ? "#10b981" : "#22d3ee", opacity: [0.5, 1, 0.5] }}
                  transition={{ duration: 1.5, delay: i * 0.1, repeat: Infinity }}
                />
              ))}
            </div>
          </div>
        </div>

        {/* CCIP */}
        <div className="bg-[#0a1628]/60 rounded-xl p-3 border border-violet-500/20">
          <div className="flex items-center gap-1.5 mb-2">
            <div className="w-1.5 h-1.5 rounded-full bg-violet-400" />
            <span className="text-xs font-bold text-violet-400 uppercase tracking-wide">CCIP</span>
          </div>
          {/* Broadcast counter */}
          <div className="text-center mb-2">
            <motion.div
              key={data.ccipBroadcasts}
              initial={{ scale: 1.4, color: "#a78bfa" }}
              animate={{ scale: 1, color: "#e2e8f0" }}
              transition={{ duration: 0.4 }}
              className="text-2xl font-mono font-bold"
            >
              {data.ccipBroadcasts}
            </motion.div>
            <div className="text-xs text-slate-500">broadcasts sent</div>
          </div>
          <Row label="Active Chains"  value={`${data.destinationCount} destinations`} />
          <Row
            label="Threshold"
            value={["NOMINAL","WATCH","WARNING","DANGER","EMERGENCY"][data.broadcastThreshold]}
            accent="#f97316"
          />
          {/* Chain badges */}
          <div className="mt-2 flex gap-1.5 flex-wrap">
            {["Base", "Arb", "OP"].map((chain) => (
              <span
                key={chain}
                className="text-xs px-2 py-0.5 rounded-full border font-semibold"
                style={{ borderColor: "#7c3aed40", color: "#a78bfa", backgroundColor: "#7c3aed18" }}
              >
                {chain}
              </span>
            ))}
          </div>
        </div>

      </div>
    </motion.div>
  );
}
