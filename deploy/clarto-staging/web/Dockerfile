# syntax=docker/dockerfile:1
# Preview of the CLARTO website (TanStack Start) with the property catalog, built
# from the branch under review as a Node server. Production stays on Lovable
# (Cloudflare Workers); this image only serves the no-password, noindex preview.
# Source comes from the `src` build context (scripts/upload-web.sh).
FROM oven/bun:1.4.2 AS build
WORKDIR /app
COPY --from=src . .
ENV CI=1 NITRO_PRESET=node-server VITE_SITE_URL=https://clarto.es
RUN bun install --frozen-lockfile && bun run build

FROM node:22.18-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOST=0.0.0.0
COPY --from=build /app/.output ./.output
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=5 \
  CMD node -e "fetch('http://127.0.0.1:3000/').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))"
CMD ["node", ".output/server/index.mjs"]
