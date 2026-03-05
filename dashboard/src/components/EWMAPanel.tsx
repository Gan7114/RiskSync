"use client";

import { motion } from "framer-motion";
import {
  TrendingUp, TrendingDown, Minus, ChevronsUp, ChevronsDown,
} from "lucide-react";
import type { ScoreMomentum, AlertLevel } from "@/lib/types";
import { ALERT_COLORS } from "@/lib/types";

const MOMENTUM_CONFIG: Record<ScoreMomentum, {
  label: string; color: string; icon: React.ElementType; desc: string;
}> = {
  SPIKING:    { label: "SPIKING",    color: "#dc2626", icon: ChevronsUp,   desc: "Risk rising sharply" },
  RISING:     { label: "RISING",     color: "#f97316", icon: TrendingUp,   desc: "Upward pressure" },
  STABLE:     { label: "STABLE",     color: "#10b981", icon: Minus,        desc: "Risk contained" },
  FALLING:    { label: "FALLING",    color: "#6366f1", icon: TrendingDown, desc: "Conditions improving" },
  PLUNGING:   { label: "PLUNGING",   color: "#818cf8", icon: ChevronsDown, desc: "Risk deflating fast" },
};

interface Props {
  ewmaScore: number;
  momentum: ScoreMomentum;
  compositeScore: number;
  alertLevel: AlertLevel;
}

export default function EWMAPanel({ ewmaScore, momentum, compositeScore, alertLevel }: Props) {
  const m = MOMENTUM_CONFIG[momentum];
  const MIcon = m.icon;
  const color = ALERT_COLORS[alertLevel];

  // EWMA smoothing bar
  const diff = compositeScore - ewmaScore;

  return (
    <div className="glass gradient-border p-4 flex flex-col gap-4">
      <div className="text-[10px] text-slate-500 tracking-widest">EWMA & MOMENTUM</div>

      {/* EWMA score */}
      <div className="flex items-center gap-4">
        <div className="flex flex-col">
          <div className="text-[10px] text-slate-600">EWMA SCORE</div>
          <motion.div
            className="text-4xl font-bold tabular leading-none text-indigo-400"
            key={ewmaScore}
            initial={{ opacity: 0.6 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.3 }}
          >
            {ewmaScore}
          </motion.div>
          <div className="text-[10px] text-slate-600 mt-0.5">alpha = 30%</div>
        </div>

        <div className="flex-1 flex flex-col gap-2">
          {/* Composite vs EWMA bar */}
          <div className="flex items-center gap-2 text-[10px] text-slate-600">
            <span>COMPOSITE</span>
            <span style={{ color }}>{compositeScore}</span>
            <span className="text-slate-700">vs EWMA</span>
            <span className="text-indigo-400">{ewmaScore}</span>
          </div>
          <div className="relative h-2 bg-[#0f2040] rounded-full overflow-hidden">
            <motion.div
              className="absolute top-0 left-0 h-full rounded-full"
              style={{ backgroundColor: "#6366f1", width: `${ewmaScore}%` }}
              animate={{ width: `${ewmaScore}%` }}
              transition={{ type: "spring", stiffness: 60, damping: 15 }}
            />
            <motion.div
              className="absolute top-0 h-full rounded-full opacity-60"
              style={{ backgroundColor: color, left: `${Math.min(ewmaScore, compositeScore)}%` }}
              animate={{
                left: `${Math.min(ewmaScore, compositeScore)}%`,
                width: `${Math.abs(diff)}%`,
              }}
              transition={{ type: "spring", stiffness: 60, damping: 15 }}
            />
          </div>
          <div className="text-[10px]" style={{ color: diff > 0 ? "#ef4444" : "#10b981" }}>
            {diff > 0 ? `+${diff.toFixed(0)}` : diff.toFixed(0)} spread
          </div>
        </div>
      </div>

      {/* Momentum badge */}
      <motion.div
        className="flex items-center gap-3 p-3 rounded-lg border"
        style={{
          borderColor: `${m.color}30`,
          background: `${m.color}10`,
        }}
        key={momentum}
        initial={{ opacity: 0, x: -8 }}
        animate={{ opacity: 1, x: 0 }}
        transition={{ duration: 0.3 }}
      >
        <MIcon className="w-5 h-5" style={{ color: m.color }} />
        <div>
          <div className="text-sm font-bold tracking-wider" style={{ color: m.color }}>{m.label}</div>
          <div className="text-[10px] text-slate-500">{m.desc}</div>
        </div>
      </motion.div>

      {/* Smoothing info */}
      <div className="text-[10px] text-slate-600 border-t border-[#1a2744] pt-2">
        EWMA = 0.30 × score + 0.70 × prev · Seeded to first composite
      </div>
    </div>
  );
}
