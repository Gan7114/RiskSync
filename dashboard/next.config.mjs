/** @type {import('next').NextConfig} */
const nextConfig = {
  // Keep dev and production artifacts separate so `next build` does not
  // invalidate the live `next dev` session and break `/_next/static/*` assets.
  distDir: process.env.NODE_ENV === "development" ? ".next-dev" : ".next",
};
export default nextConfig;
