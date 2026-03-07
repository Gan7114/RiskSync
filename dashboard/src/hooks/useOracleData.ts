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
const LIVE_FETCH_TIMEOUT_MS = 6_000;

function withTimeout<T>(promise: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("Live snapshot timeout")), timeoutMs);
    promise
      .then((v) => {
        clearTimeout(t);
        resolve(v);
      })
      .catch((e) => {
        clearTimeout(t);
        reject(e);
      });
  });
}

export function useOracleData(activeAsset: string = "ETH") {
  const live = isLive();
  const [data, setData] = useState<OracleSnapshot | null>(() => {
    const initial = generateSnapshot(activeAsset);
    initial.asset = activeAsset;
    initial.assetAddress = activeAsset;
    initial.assetConfigured = !live;
    initial.assetEnabled = true;
    initial.assetStatusNote = live ? "BOOTSTRAP" : "SIMULATION";
    return initial;
  });
  const [assets, setAssets] = useState<Asset[]>(live ? [] : SUPPORTED_ASSETS);
  const [simMode, setSimMode] = useState(!live);
  const timerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const assetsTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const historyRef = useRef<Record<string, number[]>>({});

  useEffect(() => {
    if (!live) {
      setAssets(SUPPORTED_ASSETS);
      return;
    }

    let cancelled = false;
    const refreshAssets = async () => {
      const configured = await fetchConfiguredAssets();
      if (!cancelled) {
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
          const liveData = await withTimeout(
            fetchLiveSnapshot(activeSymbol, activeAddress, activeEnabled),
            LIVE_FETCH_TIMEOUT_MS
          );
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
