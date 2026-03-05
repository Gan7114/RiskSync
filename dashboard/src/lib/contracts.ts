// Contract addresses — set via environment variables after deployment.
// If an address is empty the dashboard runs in simulation mode.
export const ADDRESSES = {
  URC: process.env.NEXT_PUBLIC_URC_ADDRESS ?? "",
  MCO: process.env.NEXT_PUBLIC_MCO_ADDRESS ?? "",
  TDRV: process.env.NEXT_PUBLIC_TDRV_ADDRESS ?? "",
  CPLCS: process.env.NEXT_PUBLIC_CPLCS_ADDRESS ?? "",
  TCO: process.env.NEXT_PUBLIC_TCO_ADDRESS ?? "",
  CIRCUIT_BREAKER: process.env.NEXT_PUBLIC_CIRCUIT_BREAKER_ADDRESS ?? "",
  STRESS_REGISTRY: process.env.NEXT_PUBLIC_STRESS_REGISTRY_ADDRESS ?? "",
  WETH: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
};

export const MAINNET_RPC =
  process.env.NEXT_PUBLIC_MAINNET_RPC_URL ??
  "https://eth.llamarpc.com";

export function isLive(): boolean {
  return Boolean(ADDRESSES.URC && ADDRESSES.MCO);
}
