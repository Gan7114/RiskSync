"use client";

import { motion } from "framer-motion";
import { AlertTriangle, Skull, TrendingDown } from "lucide-react";
import type { StressScenario } from "@/lib/types";

interface Props { scenarios: StressScenario[] }

function formatUsd(n: number) {
  if (n >= 1e9) return `$${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `$${(n / 1e6).toFixed(1)}M`;
  return `$${(n / 1e3).toFixed(0)}K`;
}

function scoreColor(s: number) {
  if (s >= 80) return "#dc2626";
  if (s >= 65) return "#ef4444";
  if (s >= 50) return "#f97316";
  if (s >= 25) return "#f59e0b";
  return "#10b981";
}

function formatPctFromBps(bps: number) {
  return `${(bps / 100).toFixed(2)}%`;
}

function formatBps(bps: number) {
  return `${bps.toLocaleString()} bps`;
}

export default function StressPanel({ scenarios }: Props) {
  const worst = scenarios.find(s => s.isWorstCase);

  return (
    <div className="glass gradient-border p-4 flex flex-col gap-3">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-[10px] text-slate-500 tracking-widest">STRESS SCENARIOS</div>
          <div className="text-sm font-bold text-slate-200">Historical & Synthetic Crisis Replay</div>
        </div>
        <div className="flex items-center gap-1.5 text-[10px] text-red-500 border border-red-900 bg-red-950 px-2 py-1 rounded-full">
          <Skull className="w-3 h-3" />
          ON-CHAIN VERIFIABLE
        </div>
      </div>

      <div className="overflow-x-auto overflow-y-visible [overscroll-behavior-x:contain] [overscroll-behavior-y:auto]">
        <table className="w-full text-xs font-mono">
          <thead>
            <tr className="text-[10px] text-slate-600 tracking-wider">
              <th className="text-left pb-2 pr-3">SCENARIO</th>
              <th className="text-right pb-2 pr-3">SHOCK</th>
              <th className="text-right pb-2 pr-3">RISK</th>
              <th className="text-right pb-2 pr-3">LTV</th>
              <th className="text-right pb-2 pr-3">CASCADE</th>
              <th className="text-right pb-2">MANIP COST</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-[#1a2744]">
            {scenarios.map((s, i) => {
              const rColor = scoreColor(s.compositeScore);
              const isWorst = s.isWorstCase;

              return (
                <motion.tr
                  key={s.id}
                  className="group"
                  initial={{ opacity: 0, x: -12 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: i * 0.06, duration: 0.3 }}
                  style={isWorst ? { background: "rgba(220,38,38,0.05)" } : undefined}
                >
                  <td className="py-2.5 pr-3">
                    <div className="flex items-center gap-2">
                      {isWorst ? (
                        <Skull className="w-3 h-3 text-red-500 flex-shrink-0" />
                      ) : (
                        <AlertTriangle className="w-3 h-3 text-slate-600 flex-shrink-0" />
                      )}
                      <div>
                        <div className={`font-bold ${isWorst ? "text-red-400" : "text-slate-200"}`}>
                          {s.name}
                        </div>
                        <div className="text-[10px] text-slate-600">{s.event}</div>
                      </div>
                    </div>
                  </td>
                  <td className="py-2.5 pr-3 text-right">
                    <span className="text-red-400 font-bold">-{formatPctFromBps(s.shockBps)}</span>
                    <div className="text-[10px] text-slate-600">({formatBps(s.shockBps)})</div>
                  </td>
                  <td className="py-2.5 pr-3 text-right">
                    <span className="font-bold" style={{ color: rColor }}>{s.compositeScore}</span>
                  </td>
                  <td className="py-2.5 pr-3 text-right">
                    <span className="text-slate-300">{formatPctFromBps(s.ltvBps)}</span>
                    <div className="text-[10px] text-slate-600">({formatBps(s.ltvBps)})</div>
                  </td>
                  <td className="py-2.5 pr-3 text-right">
                    <div className="inline-flex items-center gap-1">
                      <TrendingDown className="w-3 h-3" style={{ color: rColor }} />
                      <span style={{ color: rColor }}>{s.cascadeScore}</span>
                    </div>
                  </td>
                  <td className="py-2.5 text-right">
                    <span className="text-slate-400">{formatUsd(s.manipCostUsd)}</span>
                  </td>
                </motion.tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {worst && (
        <motion.div
          className="flex items-center gap-3 p-3 rounded-lg bg-red-950 border border-red-900 text-xs"
          animate={{ opacity: [1, 0.7, 1] }}
          transition={{ duration: 2, repeat: Infinity }}
        >
          <Skull className="w-4 h-4 text-red-400 flex-shrink-0" />
          <div>
            <span className="text-red-400 font-bold">Worst Case: </span>
            <span className="text-red-300">{worst.name}</span>
            <span className="text-red-600 ml-2">— Score {worst.compositeScore}/100, LTV {formatPctFromBps(worst.ltvBps)} ({formatBps(worst.ltvBps)})</span>
          </div>
        </motion.div>
      )}
    </div>
  );
}
