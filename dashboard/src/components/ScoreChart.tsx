"use client";

import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip,
  ReferenceLine, ResponsiveContainer, Line, ComposedChart,
} from "recharts";
import type { AlertLevel } from "@/lib/types";
import { ALERT_COLORS } from "@/lib/types";

interface Props {
  scoreHistory: number[];
  ewmaScore: number;
  alertLevel: AlertLevel;
}

const CustomTooltip = ({ active, payload }: { active?: boolean; payload?: { value: number; name: string }[] }) => {
  if (!active || !payload?.length) return null;
  return (
    <div className="glass px-3 py-2 text-xs font-mono">
      {payload.map((p, i) => (
        <div key={i} className="flex gap-2">
          <span className="text-slate-500">{p.name}:</span>
          <span className="text-slate-100 font-bold">{p.value?.toFixed(1)}</span>
        </div>
      ))}
    </div>
  );
};

export default function ScoreChart({ scoreHistory, ewmaScore, alertLevel }: Props) {
  const color = ALERT_COLORS[alertLevel];

  // scoreHistory is newest-first; reverse for chart (oldest first)
  const chartData = [...scoreHistory].reverse().map((score, i) => ({
    t: `T-${scoreHistory.length - 1 - i}`,
    score,
    ewma: Math.round(ewmaScore * 0.85 + score * 0.15), // approximate per-point EWMA
  }));

  return (
    <div className="glass gradient-border p-4 flex flex-col gap-3 h-full">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-[10px] text-slate-500 tracking-widest">SCORE HISTORY</div>
          <div className="text-sm font-bold text-slate-200">Ring Buffer (8 ticks)</div>
        </div>
        <div className="flex items-center gap-4 text-[11px]">
          <div className="flex items-center gap-1.5">
            <div className="w-3 h-0.5 rounded" style={{ backgroundColor: color }} />
            <span className="text-slate-500">Composite</span>
          </div>
          <div className="flex items-center gap-1.5">
            <div className="w-3 h-0.5 rounded bg-indigo-400" />
            <span className="text-slate-500">EWMA</span>
          </div>
        </div>
      </div>

      <ResponsiveContainer width="100%" height={200}>
        <ComposedChart data={chartData} margin={{ top: 4, right: 8, left: -24, bottom: 0 }}>
          <defs>
            <linearGradient id="scoreGrad" x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stopColor={color} stopOpacity={0.25} />
              <stop offset="95%" stopColor={color} stopOpacity={0.02} />
            </linearGradient>
          </defs>
          <CartesianGrid strokeDasharray="3 3" stroke="#1a2744" vertical={false} />
          <XAxis
            dataKey="t"
            tick={{ fill: "#475569", fontSize: 10, fontFamily: "monospace" }}
            tickLine={false}
            axisLine={false}
          />
          <YAxis
            domain={[0, 100]}
            tick={{ fill: "#475569", fontSize: 10, fontFamily: "monospace" }}
            tickLine={false}
            axisLine={false}
            ticks={[0, 25, 50, 65, 80, 100]}
          />
          <Tooltip content={<CustomTooltip />} />

          {/* Threshold lines */}
          <ReferenceLine y={25} stroke="#f59e0b" strokeDasharray="4 4" strokeOpacity={0.4} strokeWidth={1} />
          <ReferenceLine y={50} stroke="#f97316" strokeDasharray="4 4" strokeOpacity={0.4} strokeWidth={1} />
          <ReferenceLine y={65} stroke="#ef4444" strokeDasharray="4 4" strokeOpacity={0.4} strokeWidth={1} />
          <ReferenceLine y={80} stroke="#dc2626" strokeDasharray="4 4" strokeOpacity={0.4} strokeWidth={1} />

          <Area
            type="monotone"
            dataKey="score"
            name="Score"
            stroke={color}
            strokeWidth={2.5}
            fill="url(#scoreGrad)"
            dot={{ fill: color, r: 3, strokeWidth: 0 }}
            activeDot={{ r: 5, fill: color, stroke: "#050b14", strokeWidth: 2 }}
            isAnimationActive
          />
          <Line
            type="monotone"
            dataKey="ewma"
            name="EWMA"
            stroke="#6366f1"
            strokeWidth={1.5}
            dot={false}
            strokeDasharray="4 2"
            isAnimationActive
          />
        </ComposedChart>
      </ResponsiveContainer>

      <div className="flex gap-4 pt-1 border-t border-[#1a2744]">
        {[
          { label: "CURRENT", val: scoreHistory[0] ?? 0 },
          { label: "AVG", val: scoreHistory.length ? Math.round(scoreHistory.reduce((a, b) => a + b, 0) / scoreHistory.length) : 0 },
          { label: "MAX", val: scoreHistory.length ? Math.max(...scoreHistory) : 0 },
          { label: "MIN", val: scoreHistory.length ? Math.min(...scoreHistory) : 0 },
        ].map(({ label, val }) => (
          <div key={label} className="flex flex-col">
            <div className="text-[10px] text-slate-600">{label}</div>
            <div className="text-sm font-bold font-mono text-slate-200">{val}</div>
          </div>
        ))}
      </div>
    </div>
  );
}
