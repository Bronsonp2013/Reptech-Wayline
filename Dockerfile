# Production image for wayline-app (WAYLINE_BUILD.md §7).
#
# Keeps the Prisma CLI + seed tooling (`prisma`, `tsx` are runtime dependencies) so
# the SAME image also runs `prisma migrate deploy` and `db:seed` — but the build-only
# toolchain is pruned from the final layer. Dependencies are installed INSIDE the linux
# container — host node_modules are never copied in (wrong architecture). Note
# @node-rs/argon2 ships prebuilt binaries; this image has no build toolchain, so if a
# prebuild is ever missing for the target platform `npm ci` fails rather than falling
# back to compiling.

# --- deps: install with schema present so postinstall `prisma generate` works ---
FROM node:22-slim AS deps
WORKDIR /app
COPY package.json package-lock.json prisma.config.ts ./
COPY prisma ./prisma
RUN npm ci

# --- build: generate client + build Next ---
FROM node:22-slim AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npx prisma generate
# A placeholder DATABASE_URL (inline, not ENV — so it's never baked into a layer)
# only satisfies the lib/db module-load guard while building; the app connects with
# the real runtime value from the container environment.
RUN DATABASE_URL="postgresql://placeholder:placeholder@localhost:5432/placeholder?schema=public" \
    npm run build

# --- runner ---
FROM node:22-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=build /app ./
# Drop devDependencies (eslint, vitest, jsdom, typescript, prettier, @types/*) from the
# shipped image — they're build-time only and are pure attack surface in production.
# `prisma` + `tsx` survive as runtime deps, so migrate/seed still run from this image.
RUN npm prune --omit=dev
# Run unprivileged (WAYLINE_SECURITY.md §9). The node base image ships a `node` user.
RUN chown -R node:node /app
USER node
EXPOSE 3000
# /api/health returns 200 only when Postgres answers — a real readiness signal.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://localhost:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["npm", "start"]
