"use client";

import { motion } from "framer-motion";
import { TrendingUp, TrendingDown, Minus } from "lucide-react";
import type { AlertLevel } from "@/lib/types";
import { ALERT_COLORS } from "@/lib/types";

interface Metric { label: string; value: string; highlight?: boolean }

interface Props {
  title: string;
  weight: string;
  pillarId: string;
  score: number;
  prevScore?: number;
  alertLevel: AlertLevel;
  description: string;
  metrics: Metric[];
  badge?: string;
  badgeColor?: string;
}

function MiniBar({ score, color }: { score: number; color: string }) {
  return (
    <div className="h-1.5 bg-[#0f2040] rounded-full overflow-hidden">
      <motion.div
        className="h-full rounded-full"
        style={{ backgroundColor: color }}
        animate={{ width: `${score}%` }}
        transition={{ type: "spring", stiffness: 60, damping: 15 }}
      />
    </div>
  );
}

export default function PillarCard({
  title, weight, pillarId, score, prevScore,
  alertLevel, description, metrics, badge, badgeColor,
}: Props) {
  const color = ALERT_COLORS[alertLevel];
  const delta = prevScore !== undefined ? score - prevScore : 0;
  const Trend = delta > 1 ? TrendingUp : delta < -1 ? TrendingDown : Minus;
  const trendColor = delta > 1 ? "#ef4444" : delta < -1 ? "#10b981" : "#64748b";

  return (
    <motion.div
      className="glass gradient-border p-4 flex flex-col gap-3 relative overflow-hidden"
      style={{ boxShadow: `0 4px 24px rgba(0,0,0,0.4), inset 0 1px 0 rgba(255,255,255,0.04)` }}
      whileHover={{ scale: 1.01, boxShadow: `0 8px 32px rgba(0,0,0,0.5), 0 0 0 1px ${color}30` }}
      transition={{ duration: 0.2 }}
    >
      {/* Background accent */}
      <div
        className="absolute top-0 right-0 w-24 h-24 rounded-full opacity-5 blur-xl pointer-events-none"
        style={{ background: color, transform: "translate(30%, -30%)" }}
      />

      {/* Header */}
      <div className="flex items-start justify-between">
        <div>
          <div className="text-[10px] text-slate-500 tracking-widest font-mono">{pillarId}</div>
          <div className="text-sm font-bold text-slate-100 mt-0.5">{title}</div>
        </div>
        <div className="text-right">
          <div className="text-[10px] text-slate-600 tracking-wider">WEIGHT</div>
          <div className="text-sm font-bold text-indigo-400">{weight}</div>
        </div>
      </div>

      {/* Score */}
      <div className="flex items-center gap-3">
        <div>
          <motion.div
            className="text-4xl font-bold tabular leading-none"
            style={{ color }}
            key={score}
            initial={{ opacity: 0.6, scale: 0.95 }}
            animate={{ opacity: 1, scale: 1 }}
            transition={{ duration: 0.25 }}
          >
            {score}
          </motion.div>
          <div className="text-[10px] text-slate-600 mt-0.5">/ 100</div>
        </div>

        <div className="flex-1 flex flex-col gap-1.5">
          <MiniBar score={score} color={color} />
          <div className="flex items-center gap-1">
            <Trend className="w-3 h-3" style={{ color: trendColor }} />
            <span className="text-[10px]" style={{ color: trendColor }}>
              {delta > 0 ? `+${delta.toFixed(0)}` : delta.toFixed(0)}
            </span>
          </div>
        </div>

        {badge && (
          <div
            className="px-2 py-0.5 rounded-full text-[10px] font-bold tracking-wider border"
            style={{
              color: badgeColor ?? "#6366f1",
              borderColor: `${badgeColor ?? "#6366f1"}40`,
              background: `${badgeColor ?? "#6366f1"}12`,
            }}
          >
            {badge}
          </div>
        )}
      </div>

      {/* Description */}
      <p className="text-[11px] text-slate-500 leading-relaxed border-t border-[#1a2744] pt-2">
        {description}
      </p>

      {/* Metrics */}
      <div className="grid grid-cols-2 gap-x-4 gap-y-1.5">
        {metrics.map((m, i) => (
          <div key={i} className="flex flex-col">
            <div className="text-[10px] text-slate-600 tracking-wider">{m.label}</div>
            <div
              className={`text-xs font-mono font-semibold ${m.highlight ? "" : "text-slate-300"}`}
              style={m.highlight ? { color } : undefined}
            >
              {m.value}
            </div>
          </div>
        ))}
      </div>
    </motion.div>
  );
}
