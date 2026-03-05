"use client";

import { useState, useEffect, useRef } from "react";
import { generateSnapshot } from "@/lib/mockData";
import { isLive } from "@/lib/contracts";
import type { OracleSnapshot } from "@/lib/types";

const POLL_INTERVAL_MS = 3000;

export function useOracleData() {
  const [data, setData] = useState<OracleSnapshot | null>(null);
  const [simMode] = useState(!isLive());
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    // Initial snapshot
    setData(generateSnapshot());

    timerRef.current = setInterval(() => {
      if (simMode) {
        setData(generateSnapshot());
      }
      // Live mode: ethers.js calls would go here
    }, POLL_INTERVAL_MS);

    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [simMode]);

  return { data, simMode };
}
