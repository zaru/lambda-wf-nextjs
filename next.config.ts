import type { NextConfig } from "next";

// CloudFront 経由では、オリジンに届く Host（Web Function のエンドポイント名）と
// ブラウザの Origin（独自ドメイン）が一致しない。Server Actions が拒否されないよう、
// 独自ドメインを許可する。next.config はビルド時に評価されるので、CI でも同じ値を渡す
const allowedOrigins = (process.env.SERVER_ACTIONS_ALLOWED_ORIGINS ?? "wf.dev.id.basicinc.jp")
  .split(",")
  .map((origin) => origin.trim())
  .filter(Boolean);

const nextConfig: NextConfig = {
  output: "standalone",
  poweredByHeader: false,
  experimental: {
    serverActions: {
      allowedOrigins,
    },
  },
};

export default nextConfig;
