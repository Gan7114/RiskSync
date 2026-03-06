"use client";

import { motion } from "framer-motion";
import { Activity, Cpu, Radio, Wifi } from "lucide-react";
import type { OracleSnapshot, Asset } from "@/lib/types";
import { ChevronDown } from "lucide-react";
import { useState } from "react";

interface Props {
  data: OracleSnapshot | null;
  simMode: boolean;
  assets: Asset[];
  activeAsset: string;
  setActiveAsset: (symbol: string) => void;
}

export default function Header({ data, simMode, assets, activeAsset, setActiveAsset }: Props) {
  const [isOpen, setIsOpen] = useState(false);
  const selected = assets.find((a) => a.symbol === activeAsset);

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

      {/* Center Left: Asset Selector */}
      <div className="relative z-50">
        <button
          onClick={() => setIsOpen(!isOpen)}
          className="flex items-center gap-2 px-4 py-2 bg-[#1e293b] hover:bg-[#334155] border border-slate-700 rounded-lg text-slate-200 font-bold transition-colors"
        >
          {selected?.name ?? "Select Asset"} ({activeAsset})
          {selected && !selected.enabled && (
            <span className="text-[10px] px-1.5 py-0.5 rounded bg-red-950/60 text-red-300 border border-red-700">
              DISABLED
            </span>
          )}
          <ChevronDown className="w-4 h-4 text-slate-400" />
        </button>

        {isOpen && (
          <div className="absolute top-12 left-0 w-48 bg-[#0f172a] border border-slate-800 rounded-lg shadow-xl overflow-hidden">
            {assets.map((asset) => (
              <button
                key={asset.symbol}
                onClick={() => {
                  setActiveAsset(asset.symbol);
                  setIsOpen(false);
                }}
                className={`w-full text-left px-4 py-3 hover:bg-[#1e293b] transition-colors ${activeAsset === asset.symbol ? "text-indigo-400 bg-[#1e293b]/50" : "text-slate-300"
                  }`}
              >
                <div className="font-bold flex items-center gap-2">
                  {asset.symbol}
                  {!asset.enabled && (
                    <span className="text-[10px] px-1.5 py-0.5 rounded bg-red-950/60 text-red-300 border border-red-700">
                      DISABLED
                    </span>
                  )}
                </div>
                <div className="text-xs text-slate-500">{asset.name}</div>
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Center Right: status ticker */}
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
            <span className="text-slate-200">{simMode ? "POLL 3s" : "POLL 10s"}</span>
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
