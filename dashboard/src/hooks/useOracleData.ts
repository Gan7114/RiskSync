"use client";

import { useState, useEffect, useRef } from "react";
import { generateSnapshot } from "@/lib/mockData";
import { isLive } from "@/lib/contracts";
import { fetchLiveSnapshot } from "@/lib/liveData";
import type { OracleSnapshot } from "@/lib/types";

// Simulation refreshes every 3s; live mode polls contracts every 10s (RPC rate-limit friendly)
const SIM_POLL_MS  = 3_000;
const LIVE_POLL_MS = 10_000;
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
  const live = isLive();
  const [data, setData] = useState<OracleSnapshot | null>(null);
  const [simMode] = useState(!live);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const priceRef = useRef<number | null>(null);

  // Real ETH price from CoinGecko — overlaid in both sim and live modes
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
    // Build a snapshot: start from mock baseline, overlay live data, overlay real ETH price
    const buildSnapshot = async (): Promise<OracleSnapshot> => {
      const base = generateSnapshot();

      if (live) {
        try {
          const liveData = await fetchLiveSnapshot();
          // Deep-merge: live data wins field-by-field over the mock baseline
          Object.assign(base, liveData);
          if (liveData.mco)  Object.assign(base.mco,  liveData.mco);
          if (liveData.tdrv) Object.assign(base.tdrv, liveData.tdrv);
          if (liveData.cplcs) Object.assign(base.cplcs, liveData.cplcs);
          if (liveData.tco)  Object.assign(base.tco,  liveData.tco);
          if (liveData.circuitBreaker) Object.assign(base.circuitBreaker, liveData.circuitBreaker);
          if (liveData.chainlink) Object.assign(base.chainlink, liveData.chainlink);
        } catch {
          // live fetch failed — serve the mock baseline silently
        }
      }

      // Always overlay real ETH price if available (works in both modes)
      if (priceRef.current) {
        base.chainlink.feedPrice = priceRef.current;
      }

      return base;
    };

    // Initial load
    buildSnapshot().then(setData);

    const interval = live ? LIVE_POLL_MS : SIM_POLL_MS;
    timerRef.current = setInterval(() => {
      buildSnapshot().then(setData);
    }, interval);

    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [live]);

  return { data, simMode };
}
