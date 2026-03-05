import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: {
    extend: {
      colors: {
        risk: {
          nominal: "#10b981",
          watch: "#f59e0b",
          warning: "#f97316",
          danger: "#ef4444",
          emergency: "#dc2626",
        },
        surface: {
          900: "#050b14",
          800: "#0a1628",
          700: "#0f2040",
          600: "#1a2f55",
        },
        border: {
          dim: "#1a2744",
          bright: "#2a3d66",
        },
      },
      animation: {
        "pulse-slow": "pulse 3s cubic-bezier(0.4,0,0.6,1) infinite",
        "glow-pulse": "glowPulse 2s ease-in-out infinite",
        "spin-slow": "spin 8s linear infinite",
        "float": "float 6s ease-in-out infinite",
        "scan": "scan 4s linear infinite",
      },
      keyframes: {
        glowPulse: {
          "0%, 100%": { opacity: "0.6" },
          "50%": { opacity: "1" },
        },
        float: {
          "0%, 100%": { transform: "translateY(0px)" },
          "50%": { transform: "translateY(-8px)" },
        },
        scan: {
          "0%": { transform: "translateY(-100%)" },
          "100%": { transform: "translateY(100vh)" },
        },
      },
      backgroundImage: {
        "grid-pattern":
          "linear-gradient(rgba(99,102,241,0.05) 1px, transparent 1px), linear-gradient(90deg, rgba(99,102,241,0.05) 1px, transparent 1px)",
      },
      backgroundSize: {
        "grid": "40px 40px",
      },
      fontFamily: {
        mono: ["'JetBrains Mono'", "'Fira Code'", "monospace"],
      },
      boxShadow: {
        "glow-green": "0 0 20px rgba(16,185,129,0.4)",
        "glow-yellow": "0 0 20px rgba(245,158,11,0.4)",
        "glow-orange": "0 0 20px rgba(249,115,22,0.4)",
        "glow-red": "0 0 20px rgba(239,68,68,0.4)",
        "glow-indigo": "0 0 20px rgba(99,102,241,0.4)",
        "card": "0 4px 24px rgba(0,0,0,0.4), inset 0 1px 0 rgba(255,255,255,0.04)",
      },
    },
  },
  plugins: [],
};
export default config;
