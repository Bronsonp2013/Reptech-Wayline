# Production image for wayline-app (WAYLINE_BUILD.md §7).
#
# Keeps full dependencies (incl. the Prisma CLI + seed tooling) so the SAME image
# also runs `prisma migrate deploy` and `db:seed`. Native modules
# (@node-rs/argon2, sharp) are compiled inside the linux container — host
# node_modules are never copied in (wrong architecture).

# --- deps: install with schema present so postinstall `prisma generate` works ---
FROM node:20-slim AS deps
WORKDIR /app
COPY package.json package-lock.json prisma.config.ts ./
COPY prisma ./prisma
RUN npm ci

# --- build: generate client + build Next ---
FROM node:20-slim AS build
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
FROM node:20-slim AS runner
WORKDIR /app
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
COPY --from=build /app ./
EXPOSE 3000
# /api/health returns 200 only when Postgres answers — a real readiness signal.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://localhost:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["npm", "start"]
