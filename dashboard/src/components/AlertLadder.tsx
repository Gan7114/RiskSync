"use client";

import { motion } from "framer-motion";
import { AlertTriangle, Shield, Eye, Zap, Flame } from "lucide-react";
import type { AlertLevel } from "@/lib/types";
import { ALERT_COLORS, ALERT_LABELS } from "@/lib/types";

const RUNGS: { level: AlertLevel; icon: React.ElementType; threshold: string }[] = [
  { level: 4, icon: Flame,         threshold: "≥ 80" },
  { level: 3, icon: Zap,           threshold: "≥ 65" },
  { level: 2, icon: AlertTriangle, threshold: "≥ 50" },
  { level: 1, icon: Eye,           threshold: "≥ 25" },
  { level: 0, icon: Shield,        threshold: "0–24" },
];

interface Props { alertLevel: AlertLevel }

export default function AlertLadder({ alertLevel }: Props) {
  return (
    <div className="glass gradient-border p-4 flex flex-col gap-1.5">
      <div className="text-[10px] text-slate-500 tracking-widest mb-1">ALERT LADDER</div>
      {RUNGS.map(({ level, icon: Icon, threshold }) => {
        const active = alertLevel === level;
        const passed = alertLevel >= level;
        const color = ALERT_COLORS[level];

        return (
          <motion.div
            key={level}
            className="flex items-center gap-2.5 px-3 py-2 rounded-lg transition-all"
            style={{
              background: active ? `${color}18` : passed ? `${color}08` : "transparent",
              border: `1px solid ${active ? color + "50" : passed ? color + "20" : "#1a2744"}`,
              boxShadow: active ? `0 0 16px ${color}30` : "none",
            }}
            animate={active ? { scale: [1, 1.01, 1] } : { scale: 1 }}
            transition={{ duration: 1.5, repeat: active ? Infinity : 0 }}
          >
            <Icon
              className="w-3.5 h-3.5 flex-shrink-0"
              style={{ color: passed ? color : "#374151" }}
            />
            <div className="flex-1 min-w-0">
              <div
                className="text-xs font-bold tracking-wider"
                style={{ color: passed ? color : "#374151" }}
              >
                {ALERT_LABELS[level]}
              </div>
              <div className="text-[10px] text-slate-600">{threshold}</div>
            </div>
            {active && (
              <motion.div
                className="w-1.5 h-1.5 rounded-full flex-shrink-0"
                style={{ backgroundColor: color }}
                animate={{ opacity: [1, 0.2, 1] }}
                transition={{ duration: 0.8, repeat: Infinity }}
              />
            )}
          </motion.div>
        );
      })}
    </div>
  );
}
