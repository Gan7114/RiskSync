"use client";

import { useState, useEffect, useRef } from "react";
import { generateDisabledSnapshot, generateSnapshot } from "@/lib/mockData";
import { isLive } from "@/lib/contracts";
import { fetchConfiguredAssets, fetchLiveSnapshot } from "@/lib/liveData";
import type { Asset, OracleSnapshot } from "@/lib/types";
import { SUPPORTED_ASSETS } from "@/lib/types";

const SIM_POLL_MS = 3_000;
const LIVE_POLL_MS = 10_000;
const ASSET_POLL_MS = 30_000;
const PRICE_REFRESH_MS = 30_000;

const ASSET_TO_CG_ID: Record<string, string> = {
  ETH: "ethereum",
  BTC: "bitcoin",
  LINK: "chainlink",
  UNI: "uniswap",
  AAVE: "aave",
};

function rootSymbol(symbol: string): string {
  return symbol.split("-")[0];
}

async function fetchAssetPrice(assetSymbol: string): Promise<number | null> {
  const root = rootSymbol(assetSymbol);
  const cgId = ASSET_TO_CG_ID[root] ?? "ethereum";
  try {
    const res = await fetch(
      `https://api.coingecko.com/api/v3/simple/price?ids=${cgId}&vs_currencies=usd`,
      { cache: "no-store" }
    );
    if (!res.ok) return null;
    const json = await res.json();
    return Math.round(json?.[cgId]?.usd ?? 0) || null;
  } catch {
    return null;
  }
}

export function useOracleData(activeAsset: string = "ETH") {
  const live = isLive();
  const [data, setData] = useState<OracleSnapshot | null>(null);
  const [assets, setAssets] = useState<Asset[]>(SUPPORTED_ASSETS);
  const [simMode, setSimMode] = useState(!live);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const assetsTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const priceRef = useRef<number | null>(null);
  const historyRef = useRef<Record<string, number[]>>({});

  useEffect(() => {
    if (!live) {
      setAssets(SUPPORTED_ASSETS);
      return;
    }

    let cancelled = false;
    const refreshAssets = async () => {
      const configured = await fetchConfiguredAssets();
      if (!cancelled && configured.length > 0) {
        setAssets(configured);
      }
    };

    refreshAssets();
    assetsTimerRef.current = setInterval(refreshAssets, ASSET_POLL_MS);

    return () => {
      cancelled = true;
      if (assetsTimerRef.current) clearInterval(assetsTimerRef.current);
    };
  }, [live]);

  useEffect(() => {
    let cancelled = false;
    priceRef.current = null;
    const refresh = async () => {
      const price = await fetchAssetPrice(activeAsset);
      if (!cancelled && price) priceRef.current = price;
    };
    refresh();
    const id = setInterval(refresh, PRICE_REFRESH_MS);
    return () => {
      cancelled = true;
      clearInterval(id);
    };
  }, [activeAsset]);

  useEffect(() => {
    const activeConfig = assets.find((a) => a.symbol === activeAsset);
    const activeSymbol = activeConfig?.symbol ?? activeAsset;
    const activeAddress = activeConfig?.address ?? activeSymbol;
    const activeEnabled = activeConfig?.enabled ?? true;
    const activeConfigured = activeConfig?.configured ?? false;

    const buildSnapshot = async (): Promise<OracleSnapshot> => {
      if (live && activeConfigured && !activeEnabled) {
        const disabled = generateDisabledSnapshot(
          activeSymbol,
          activeAddress,
          true,
          "Asset is registered but disabled (missing infra or intentionally off)."
        );
        if (priceRef.current) disabled.chainlink.feedPrice = priceRef.current;
        return disabled;
      }

      const base = generateSnapshot(activeSymbol);
      base.asset = activeSymbol;
      base.assetAddress = activeAddress;
      base.assetConfigured = activeConfigured || !live;
      base.assetEnabled = activeEnabled || !live;
      base.assetStatusNote = live ? "LIVE" : "SIMULATION";

      if (live) {
        try {
          const liveData = await fetchLiveSnapshot(activeSymbol, activeAddress, activeEnabled);
          Object.assign(base, liveData);
          if (liveData.mco) Object.assign(base.mco, liveData.mco);
          if (liveData.tdrv) Object.assign(base.tdrv, liveData.tdrv);
          if (liveData.cplcs) Object.assign(base.cplcs, liveData.cplcs);
          if (liveData.tco) Object.assign(base.tco, liveData.tco);
          if (liveData.circuitBreaker) Object.assign(base.circuitBreaker, liveData.circuitBreaker);
          if (liveData.chainlink) Object.assign(base.chainlink, liveData.chainlink);
        } catch {
          // keep baseline
        }
      }

      if (priceRef.current) {
        base.chainlink.feedPrice = priceRef.current;
      }

      // Multi-asset live mode returns a single latest point from router state.
      // Keep a local ring buffer so chart and trend panels do not collapse to one dot.
      if (live) {
        const key = activeAddress.toLowerCase();
        const prev = historyRef.current[key] ?? [];
        const score = Math.max(0, Math.min(100, Number(base.compositeScore ?? 0)));
        const next = [score, ...prev].slice(0, 8);
        historyRef.current[key] = next;
        base.scoreHistory = next;
      }

      return base;
    };

    buildSnapshot().then((snapshot) => {
      setData(snapshot);
      setSimMode(!live);
    });

    const interval = live ? LIVE_POLL_MS : SIM_POLL_MS;
    timerRef.current = setInterval(() => {
      buildSnapshot().then(setData);
    }, interval);

    return () => {
      if (timerRef.current) clearInterval(timerRef.current);
    };
  }, [live, activeAsset, assets]);

  return { data, simMode, assets };
}
