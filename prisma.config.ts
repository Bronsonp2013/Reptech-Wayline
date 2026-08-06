// Loads .env for the Prisma CLI (migrate/generate/db). The runtime client reads
// the same DATABASE_URL via env() in prisma/schema.prisma — single source of truth.
import "dotenv/config";
import { defineConfig } from "prisma/config";

export default defineConfig({
  schema: "prisma/schema.prisma",
  migrations: {
    path: "prisma/migrations",
  },
  // Prisma 7 CLI (migrate/db) reads the connection URL from here, not the schema.
  datasource: {
    url: process.env.DATABASE_URL,
  },
});
