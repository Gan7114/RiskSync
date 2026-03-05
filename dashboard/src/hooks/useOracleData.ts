"use client";

import { useState, useEffect, useRef } from "react";
import { generateSnapshot } from "@/lib/mockData";
import { isLive } from "@/lib/contracts";
import type { OracleSnapshot } from "@/lib/types";

const POLL_INTERVAL_MS = 3000;
const PRICE_REFRESH_MS = 30_000;

async function fetchEthPrice(): Promise<number | null> {
  try {
    const res = await fetch(
      "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
      { cache: "no-store" }
    );
    if (!res.ok) return null;
    const json = await res.json();
    return Math.round(json?.ethereum?.usd ?? 0) || null;
  } catch {
    return null;
  }
}

export function useOracleData() {
  const [data, setData] = useState<OracleSnapshot | null>(null);
  const [simMode] = useState(!isLive());
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const priceRef = useRef<number | null>(null);

  // Fetch real ETH price once on mount, then every 30s
  useEffect(() => {
    let cancelled = false;
    const refresh = async () => {
      const price = await fetchEthPrice();
      if (!cancelled && price) priceRef.current = price;
    };
    refresh();
    const id = setInterval(refresh, PRICE_REFRESH_MS);
    return () => { cancelled = true; clearInterval(id); };
  }, []);

  useEffect(() => {
    const snapshot = () => {
      const s = generateSnapshot();
      // Overlay real ETH price when available
      if (priceRef.current) {
        s.chainlink.feedPrice = priceRef.current;
      }
      return s;
    };

    setData(snapshot());

    timerRef.current = setInterval(() => {
      if (simMode) setData(snapshot());
      // Live mode: ethers.js calls would go here
    }, POLL_INTERVAL_MS);

    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [simMode]);

  return { data, simMode };
}
