# CoinFlip DApp

Monorepo for the CoinFlip decentralized application.

## Structure

- **`/contracts`** – Hardhat project with Solidity smart contracts
- **`/frontend`** – Next.js 14 app with TypeScript

## Prerequisites

- Node.js 18+
- npm 7+ (for workspaces)

## Setup

From the repo root, install dependencies for all packages:

```bash
npm install
```

## Scripts

From the root:

- `npm run contracts:compile` – Compile Solidity contracts
- `npm run contracts:test` – Run contract tests
- `npm run frontend:dev` – Start Next.js dev server
- `npm run frontend:build` – Build Next.js for production

Or run scripts from each package directory:

```bash
cd contracts && npm run compile
cd frontend && npm run dev
```

## License

Private / Unlicense
