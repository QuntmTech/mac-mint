import type { NextConfig } from "next";

// NEXT_BASE_PATH lets the same export be served under a sub-route (e.g. /home2 for the A/B test).
const basePath = process.env.NEXT_BASE_PATH || undefined;
const config: NextConfig = { output: "export", basePath };
export default config;
