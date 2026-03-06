// Contract addresses — set via environment variables after deployment.
// If an address is empty the dashboard runs in simulation mode.
export const ADDRESSES = {
  ASSET_REGISTRY:  process.env.NEXT_PUBLIC_ASSET_REGISTRY_ADDRESS ?? "",
  MULTI_ASSET_ROUTER: process.env.NEXT_PUBLIC_MULTI_ASSET_ROUTER_ADDRESS ?? "",
  ARU:             process.env.NEXT_PUBLIC_ARU_ADDRESS ?? "",
  CCRB:            process.env.NEXT_PUBLIC_CCRB_ADDRESS ?? "",
  URC:             process.env.NEXT_PUBLIC_URC_ADDRESS ?? "",
  MCO:             process.env.NEXT_PUBLIC_MCO_ADDRESS ?? "",
  TDRV:            process.env.NEXT_PUBLIC_TDRV_ADDRESS ?? "",
  CPLCS:           process.env.NEXT_PUBLIC_CPLCS_ADDRESS ?? "",
  TCO:             process.env.NEXT_PUBLIC_TCO_ADDRESS ?? "",
  CIRCUIT_BREAKER: process.env.NEXT_PUBLIC_CIRCUIT_BREAKER_ADDRESS ?? "",
  STRESS_REGISTRY: process.env.NEXT_PUBLIC_STRESS_REGISTRY_ADDRESS ?? "",
  CVO:             process.env.NEXT_PUBLIC_CVO_ADDRESS ?? "",
  // Sepolia WETH (mainnet: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
  WETH:            "0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9",
};

export const RPC_URL =
  process.env.NEXT_PUBLIC_RPC_URL ??
  process.env.NEXT_PUBLIC_MAINNET_RPC_URL ??
  "https://rpc.sepolia.org";

export function isLive(): boolean {
  const multiAssetLive = Boolean(ADDRESSES.ASSET_REGISTRY && ADDRESSES.MULTI_ASSET_ROUTER && ADDRESSES.MCO);
  const legacyLive = Boolean(ADDRESSES.URC && ADDRESSES.MCO);
  return multiAssetLive || legacyLive;
}

export function isMultiAssetLive(): boolean {
  return Boolean(ADDRESSES.ASSET_REGISTRY && ADDRESSES.MULTI_ASSET_ROUTER);
}
