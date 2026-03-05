"use client";

import { useEffect, useState } from "react";
import { motion } from "framer-motion";
import { Shield, ShieldAlert, Timer, Zap } from "lucide-react";
import type { AlertLevel } from "@/lib/types";
import { ALERT_COLORS, ALERT_LABELS } from "@/lib/types";

interface Props {
  alertLevel: AlertLevel;
  isInCooldown: boolean;
  cooldownSecondsLeft: number;
}

const RUNG_ACTIONS: Record<AlertLevel, string> = {
  0: "No action — protocol operating normally",
  1: "Monitoring — soft alert issued",
  2: "LTV tightened — max LTV reduced by 5%",
  3: "Borrows paused — new positions blocked",
  4: "Protocol halted — deposits suspended",
};

export default function CircuitBreaker({ alertLevel, isInCooldown, cooldownSecondsLeft }: Props) {
  const [countdown, setCountdown] = useState(cooldownSecondsLeft);

  useEffect(() => {
    setCountdown(cooldownSecondsLeft);
    if (!isInCooldown || cooldownSecondsLeft <= 0) return;
    const t = setInterval(() => setCountdown(c => Math.max(0, c - 1)), 1000);
    return () => clearInterval(t);
  }, [isInCooldown, cooldownSecondsLeft]);

  const color = ALERT_COLORS[alertLevel];
  const isActive = alertLevel >= 2;

  return (
    <div className="glass gradient-border p-4 flex flex-col gap-4">
      <div className="flex items-center justify-between">
        <div>
          <div className="text-[10px] text-slate-500 tracking-widest">CIRCUIT BREAKER</div>
          <div className="text-sm font-bold text-slate-200">LendingProtocol Guard</div>
        </div>
        <motion.div
          animate={isActive ? { scale: [1, 1.1, 1] } : { scale: 1 }}
          transition={{ duration: 1, repeat: isActive ? Infinity : 0 }}
        >
          {isActive ? (
            <ShieldAlert className="w-6 h-6" style={{ color }} />
          ) : (
            <Shield className="w-6 h-6 text-emerald-500" />
          )}
        </motion.div>
      </div>

      {/* Current action */}
      <motion.div
        className="p-3 rounded-lg border"
        style={{
          borderColor: `${color}40`,
          background: `${color}10`,
        }}
        key={alertLevel}
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ duration: 0.4 }}
      >
        <div className="flex items-center gap-2 mb-1">
          <Zap className="w-3.5 h-3.5" style={{ color }} />
          <div className="text-xs font-bold tracking-wider" style={{ color }}>
            {ALERT_LABELS[alertLevel]}
          </div>
        </div>
        <div className="text-[11px] text-slate-400">{RUNG_ACTIONS[alertLevel]}</div>
      </motion.div>

      {/* 5-rung progress */}
      <div className="flex gap-1.5">
        {([0, 1, 2, 3, 4] as AlertLevel[]).map(l => {
          const active = l === alertLevel;
          const passed = alertLevel >= l;
          const c = ALERT_COLORS[l];
          return (
            <motion.div
              key={l}
              className="flex-1 h-2 rounded-full"
              style={{
                background: passed ? c : "#0f2040",
                boxShadow: active ? `0 0 8px ${c}` : "none",
              }}
              animate={active ? { opacity: [1, 0.5, 1] } : { opacity: 1 }}
              transition={{ duration: 1, repeat: active ? Infinity : 0 }}
            />
          );
        })}
      </div>
      <div className="flex justify-between text-[10px] text-slate-700">
        {(["NOM", "WCH", "WRN", "DGR", "EMG"] as const).map(l => (
          <span key={l}>{l}</span>
        ))}
      </div>

      {/* Cooldown */}
      <div className="border-t border-[#1a2744] pt-3 flex items-center gap-3">
        <Timer className="w-4 h-4 text-slate-600" />
        <div className="flex-1">
          <div className="text-[10px] text-slate-600 mb-1">COOLDOWN (300s window)</div>
          {isInCooldown && countdown > 0 ? (
            <div className="flex items-center gap-2">
              <div className="flex-1 h-1.5 bg-[#0f2040] rounded-full overflow-hidden">
                <motion.div
                  className="h-full bg-amber-500 rounded-full"
                  animate={{ width: `${(countdown / 300) * 100}%` }}
                  transition={{ duration: 1 }}
                />
              </div>
              <div className="text-xs font-mono text-amber-400 font-bold w-12 text-right">
                {countdown}s
              </div>
            </div>
          ) : (
            <div className="text-xs font-mono text-emerald-500">READY — permissionless trigger</div>
          )}
        </div>
      </div>

      <div className="text-[10px] text-slate-600">
        checkAndRespond() callable by any EOA · same-block response · zero governance delay
      </div>
    </div>
  );
}
