"use client";

import { motion } from "framer-motion";
import type { AlertLevel } from "@/lib/types";
import { ALERT_COLORS } from "@/lib/types";

interface Props { ltvBps: number; alertLevel: AlertLevel }

export default function LTVMeter({ ltvBps, alertLevel }: Props) {
  const ltv = ltvBps / 100; // percent
  const color = ALERT_COLORS[alertLevel];

  // 50–80% range → 0–100% fill
  const fill = ((ltv - 50) / 30) * 100;

  return (
    <div className="glass gradient-border p-4 flex flex-col gap-3">
      <div className="text-[10px] text-slate-500 tracking-widest">RECOMMENDED LTV</div>

      <div className="flex items-end gap-2">
        <motion.div
          className="text-4xl font-bold tabular"
          style={{ color }}
          key={Math.round(ltv)}
          initial={{ opacity: 0, y: 6 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ duration: 0.3 }}
        >
          {ltv.toFixed(1)}
        </motion.div>
        <div className="text-xl font-bold text-slate-400 mb-0.5">%</div>
      </div>

      {/* Bar */}
      <div className="relative h-3 bg-surface-700 rounded-full overflow-hidden border border-[#1a2744]">
        {/* Zone markers */}
        <div className="absolute top-0 bottom-0 left-0" style={{ right: "33.3%", background: "rgba(239,68,68,0.08)" }} />
        <div className="absolute top-0 bottom-0 left-[33.3%]" style={{ right: "0%", background: "rgba(16,185,129,0.04)" }} />

        <motion.div
          className="absolute top-0 left-0 h-full rounded-full"
          style={{ backgroundColor: color, boxShadow: `0 0 8px ${color}` }}
          animate={{ width: `${Math.max(2, fill)}%` }}
          transition={{ type: "spring", stiffness: 60, damping: 15 }}
        />
      </div>

      <div className="flex justify-between text-[10px] text-slate-600">
        <span>50% MIN</span>
        <span>65%</span>
        <span>80% MAX</span>
      </div>

      <div className="pt-1 border-t border-[#1a2744]">
        <div className="text-[10px] text-slate-500">
          {ltvBps} BPS — {ltv >= 72 ? "PERMISSIVE" : ltv >= 60 ? "STANDARD" : "CONSERVATIVE"}
        </div>
      </div>
    </div>
  );
}
