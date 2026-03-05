"use client";

import { useEffect, useRef } from "react";
import { motion, useSpring, useTransform } from "framer-motion";
import { ALERT_COLORS, ALERT_LABELS } from "@/lib/types";
import type { AlertLevel } from "@/lib/types";

interface Props {
  score: number;
  alertLevel: AlertLevel;
  riskTier: string;
  ewmaScore: number;
}

const CX = 150, CY = 155, R = 110;
const START_ANGLE = 225; // degrees from 12-o'clock, clockwise
const SWEEP = 270;

function toRad(deg: number) {
  return ((deg - 90) * Math.PI) / 180;
}

function polar(angleDeg: number) {
  const r = toRad(angleDeg);
  return { x: CX + R * Math.cos(r), y: CY + R * Math.sin(r) };
}

function arc(start: number, end: number, color: string, strokeWidth = 14) {
  const a = polar(start);
  const b = polar(end);
  const sweep = ((end - start) % 360 + 360) % 360;
  const large = sweep > 180 ? 1 : 0;
  return (
    <path
      d={`M ${a.x.toFixed(2)} ${a.y.toFixed(2)} A ${R} ${R} 0 ${large} 1 ${b.x.toFixed(2)} ${b.y.toFixed(2)}`}
      stroke={color}
      strokeWidth={strokeWidth}
      fill="none"
      strokeLinecap="round"
    />
  );
}

// Track segments: green 0-33%, yellow 33-55%, orange 55-75%, red 75-100%
const TRACK_SEGMENTS = [
  { from: 0, to: 0.33, color: "#064e3b" },
  { from: 0.33, to: 0.55, color: "#713f12" },
  { from: 0.55, to: 0.75, color: "#7c2d12" },
  { from: 0.75, to: 1, color: "#450a0a" },
];

export default function RiskGauge({ score, alertLevel, riskTier, ewmaScore }: Props) {
  const springScore = useSpring(score, { stiffness: 80, damping: 20 });
  const scoreDisplay = useTransform(springScore, Math.round);

  useEffect(() => {
    springScore.set(score);
  }, [score, springScore]);

  const color = ALERT_COLORS[alertLevel];
  const label = ALERT_LABELS[alertLevel];

  // Needle angle
  const needleAngle = START_ANGLE + (score / 100) * SWEEP;
  const needleTip = polar(needleAngle);
  const needleBase1 = polar(needleAngle + 90);
  const needleBase2 = polar(needleAngle - 90);
  const pivotR = 8;

  const ewmaAngle = START_ANGLE + (ewmaScore / 100) * SWEEP;
  const ewmaPoint = polar(ewmaAngle);

  return (
    <div className="flex flex-col items-center gap-2">
      <svg
        viewBox="0 0 300 220"
        className="w-full max-w-xs"
        style={{ filter: `drop-shadow(0 0 16px ${color}44)` }}
      >
        <defs>
          <filter id="glow">
            <feGaussianBlur stdDeviation="3" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
          <filter id="strongGlow">
            <feGaussianBlur stdDeviation="5" result="blur" />
            <feMerge>
              <feMergeNode in="blur" />
              <feMergeNode in="blur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>
        </defs>

        {/* Background track segments */}
        {TRACK_SEGMENTS.map((seg, i) => {
          const sa = START_ANGLE + seg.from * SWEEP;
          const ea = START_ANGLE + seg.to * SWEEP;
          return (
            <g key={i} opacity="0.6">
              {arc(sa, ea, seg.color, 16)}
            </g>
          );
        })}

        {/* Tick marks */}
        {Array.from({ length: 11 }).map((_, i) => {
          const angle = START_ANGLE + (i / 10) * SWEEP;
          const r = toRad(angle);
          const outer = 130, inner = i % 5 === 0 ? 118 : 122;
          return (
            <line
              key={i}
              x1={CX + outer * Math.cos(r)}
              y1={CY + outer * Math.sin(r)}
              x2={CX + inner * Math.cos(r)}
              y2={CY + inner * Math.sin(r)}
              stroke={i % 5 === 0 ? "#4b5563" : "#1f2937"}
              strokeWidth={i % 5 === 0 ? 2 : 1}
            />
          );
        })}

        {/* Progress arc */}
        {score > 0 && (
          <motion.g
            filter="url(#glow)"
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.5 }}
          >
            {arc(START_ANGLE, START_ANGLE + (score / 100) * SWEEP, color, 14)}
          </motion.g>
        )}

        {/* EWMA marker */}
        <motion.circle
          cx={ewmaPoint.x}
          cy={ewmaPoint.y}
          r={4}
          fill="#6366f1"
          filter="url(#glow)"
          animate={{ opacity: [1, 0.5, 1] }}
          transition={{ duration: 1.5, repeat: Infinity }}
        />

        {/* Needle */}
        <motion.g
          animate={{ rotate: [0, 0] }}
          transition={{ type: "spring", stiffness: 80, damping: 20 }}
        >
          <motion.line
            x1={CX + (pivotR + 2) * Math.cos(toRad(needleAngle))}
            y1={CY + (pivotR + 2) * Math.sin(toRad(needleAngle))}
            x2={needleTip.x * 0.92 + CX * 0.08}
            y2={needleTip.y * 0.92 + CY * 0.08}
            stroke={color}
            strokeWidth={2.5}
            strokeLinecap="round"
            filter="url(#strongGlow)"
          />
        </motion.g>

        {/* Pivot circle */}
        <circle cx={CX} cy={CY} r={pivotR} fill="#0a1628" stroke={color} strokeWidth={2} />
        <circle cx={CX} cy={CY} r={3} fill={color} />

        {/* Score text */}
        <motion.text
          x={CX}
          y={CY + 42}
          textAnchor="middle"
          fontSize="48"
          fontWeight="700"
          fontFamily="JetBrains Mono, monospace"
          fill="white"
          className="tabular"
        >
          {score}
        </motion.text>
        <text x={CX} y={CY + 60} textAnchor="middle" fontSize="11" fill="#64748b" fontFamily="monospace">
          / 100
        </text>

        {/* EWMA label */}
        <text x={CX} y={CY - 52} textAnchor="middle" fontSize="10" fill="#6366f1" fontFamily="monospace">
          EWMA {ewmaScore}
        </text>

        {/* Labels */}
        <text x={polar(START_ANGLE).x - 6} y={polar(START_ANGLE).y + 16} textAnchor="middle" fontSize="9" fill="#374151">
          0
        </text>
        <text x={polar(START_ANGLE + SWEEP).x + 6} y={polar(START_ANGLE + SWEEP).y + 16} textAnchor="middle" fontSize="9" fill="#374151">
          100
        </text>
      </svg>

      {/* Alert badge */}
      <motion.div
        className="flex items-center gap-2 px-5 py-1.5 rounded-full text-sm font-bold tracking-widest border"
        style={{
          color,
          borderColor: `${color}40`,
          backgroundColor: `${color}12`,
          boxShadow: `0 0 20px ${color}30`,
        }}
        animate={{ boxShadow: [`0 0 12px ${color}25`, `0 0 28px ${color}50`, `0 0 12px ${color}25`] }}
        transition={{ duration: 2, repeat: Infinity }}
        key={alertLevel}
      >
        <motion.div
          className="w-2 h-2 rounded-full"
          style={{ backgroundColor: color }}
          animate={{ scale: [1, 1.5, 1], opacity: [1, 0.5, 1] }}
          transition={{ duration: 1.2, repeat: Infinity }}
        />
        {label}
      </motion.div>

      <div className="text-xs text-slate-500 tracking-wider">RISK TIER: <span className="text-slate-300">{riskTier}</span></div>
    </div>
  );
}
