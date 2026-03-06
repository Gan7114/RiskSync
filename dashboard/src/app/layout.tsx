import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "RiskSync — Risk Dashboard",
  description: "4-pillar on-chain risk middleware — live manipulation cost, volatility, cascade, and entropy scores",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body className="scan-overlay">{children}</body>
    </html>
  );
}
