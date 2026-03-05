"use client";

import { motion } from "framer-motion";
import { Activity, Cpu, Radio, Wifi } from "lucide-react";
import type { OracleSnapshot } from "@/lib/types";

interface Props {
  data: OracleSnapshot | null;
  simMode: boolean;
}

export default function Header({ data, simMode }: Props) {
  return (
    <header className="glass gradient-border sticky top-0 z-50 px-6 py-3 flex items-center justify-between">
      {/* Left: branding */}
      <div className="flex items-center gap-3">
        <div className="relative">
          <div className="w-8 h-8 rounded-lg bg-indigo-600 flex items-center justify-center">
            <Activity className="w-4 h-4 text-white" />
          </div>
          <motion.div
            className="absolute -top-0.5 -right-0.5 w-2.5 h-2.5 rounded-full bg-emerald-400"
            animate={{ scale: [1, 1.4, 1], opacity: [1, 0.6, 1] }}
            transition={{ duration: 2, repeat: Infinity }}
          />
        </div>
        <div>
          <div className="text-sm font-bold text-white tracking-widest">
            DEFI<span className="text-indigo-400">STRESS</span>ORACLE
          </div>
          <div className="text-[10px] text-slate-500 tracking-wider">
            4-PILLAR RISK MIDDLEWARE
          </div>
        </div>
      </div>

      {/* Center: status ticker */}
      {data && (
        <div className="hidden md:flex items-center gap-6 text-[11px] text-slate-400 font-mono">
          <span className="flex items-center gap-1.5">
            <Cpu className="w-3 h-3 text-indigo-400" />
            BLOCK <span className="text-slate-200">{data.blockNumber.toLocaleString()}</span>
          </span>
          <span className="flex items-center gap-1.5">
            <Activity className="w-3 h-3 text-indigo-400" />
            TICK <span className="text-slate-200">#{data.tick}</span>
          </span>
          <span className="flex items-center gap-1.5">
            <Wifi className="w-3 h-3 text-indigo-400" />
            <span className="text-slate-200">POLL 3s</span>
          </span>
        </div>
      )}

      {/* Right: mode badge */}
      <div className="flex items-center gap-3">
        <motion.div
          className="flex items-center gap-2 px-3 py-1.5 rounded-full text-[11px] font-bold tracking-wider border"
          style={
            simMode
              ? { color: "#f59e0b", borderColor: "rgba(245,158,11,0.3)", background: "rgba(245,158,11,0.08)" }
              : { color: "#10b981", borderColor: "rgba(16,185,129,0.3)", background: "rgba(16,185,129,0.08)" }
          }
          animate={{ opacity: [1, 0.7, 1] }}
          transition={{ duration: 2, repeat: Infinity }}
        >
          <Radio className="w-3 h-3" />
          {simMode ? "SIMULATION" : "LIVE"}
        </motion.div>
      </div>
    </header>
  );
}
