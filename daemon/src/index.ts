/**
 * Quay quote updater daemon.
 *
 * Reads a market config, polls a price source each tick (Arcus spot router by
 * default — public, prices the actual tokenized stocks on Robinhood Chain;
 * Alpaca or a fixed price as alternatives), builds a QuoteState around the
 * mid, and pushes it to the venue via updateQuote (the daemon key must be an
 * authorized updater on the book).
 *
 * Usage:
 *   RPC_URL=... UPDATER_PRIVATE_KEY=0x... node src/index.ts markets/aapl-usdg.json
 *
 * Failure model: any tick that cannot fetch a price or land a transaction is
 * logged and skipped — the on-chain quote then decays and expires, which is
 * the venue's intended "no update -> no trade" behavior.
 */
import { readFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, defineChain, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { quayAbi } from '../../sdk/src/abi.ts';
import { Q128 } from '../../sdk/src/math.ts';

interface MarketConfig {
  venue: `0x${string}`;
  bookId: `0x${string}`;
  stockSymbol: string;
  stockToken: `0x${string}`;
  stockDecimals: number;
  quoteToken: `0x${string}`;
  quoteDecimals: number;
  priceSource: 'arcus' | 'alpaca' | 'fixed';
  fixedPriceUsd?: number;
  spreadBps: number;
  maxIn0: string; // stock atoms
  maxIn1: string; // quote atoms
  freshSeconds: number;
  validSeconds: number;
  decayBpsPerSecond: number;
  maxDecayBps: number;
  intervalMs: number;
}

const ARCUS_ROUTER = 'https://router.spot.arcus.xyz';

function loadConfig(): MarketConfig {
  const path = process.argv[2];
  if (path === undefined) {
    console.error('usage: node src/index.ts <market-config.json>');
    process.exit(1);
  }
  return JSON.parse(readFileSync(path, 'utf8')) as MarketConfig;
}

function requireEnv(name: string): string {
  const v = process.env[name];
  if (v === undefined || v === '') {
    console.error(`missing env ${name}`);
    process.exit(1);
  }
  return v;
}

/** Mid price in quote-token atoms per whole share (e.g. USDG 6-dec: $190 -> 190e6). */
async function fetchMidQuoteAtoms(cfg: MarketConfig, chainId: number): Promise<bigint | null> {
  const scale = 10 ** cfg.quoteDecimals;
  if (cfg.priceSource === 'fixed') {
    if (cfg.fixedPriceUsd === undefined) throw new Error('fixedPriceUsd required');
    return BigInt(Math.round(cfg.fixedPriceUsd * scale));
  }
  try {
    if (cfg.priceSource === 'arcus') {
      // Indicative buy of $1,000 of stock; best venue px = reference mid.
      const sellAmount = 1000 * scale;
      const url =
        `${ARCUS_ROUTER}/price?chainId=${chainId}&sellToken=${cfg.quoteToken}` +
        `&buyToken=${cfg.stockToken}&sellAmount=${sellAmount}`;
      const res = await fetch(url, { signal: AbortSignal.timeout(5000) });
      if (!res.ok) return null;
      const data = (await res.json()) as { all?: { buyAmount: string }[] };
      const fills = data.all ?? [];
      let bestShares = 0n;
      for (const q of fills) {
        const shares = BigInt(q.buyAmount);
        if (shares > bestShares) bestShares = shares;
      }
      if (bestShares === 0n) return null;
      // px = sellAmount / shares, in quote atoms per share.
      return (BigInt(sellAmount) * 10n ** BigInt(cfg.stockDecimals)) / bestShares;
    }
    // Alpaca: latest trade price.
    const res = await fetch(
      `https://data.alpaca.markets/v2/stocks/${cfg.stockSymbol}/trades/latest`,
      {
        headers: {
          'APCA-API-KEY-ID': requireEnv('ALPACA_KEY_ID'),
          'APCA-API-SECRET-KEY': requireEnv('ALPACA_SECRET_KEY'),
        },
        signal: AbortSignal.timeout(5000),
      },
    );
    if (!res.ok) return null;
    const data = (await res.json()) as { trade?: { p?: number } };
    const px = data.trade?.p;
    if (px === undefined || px <= 0) return null;
    return BigInt(Math.round(px * scale));
  } catch {
    return null;
  }
}

async function main(): Promise<void> {
  const cfg = loadConfig();
  const rpcUrl = requireEnv('RPC_URL');
  const account = privateKeyToAccount(requireEnv('UPDATER_PRIVATE_KEY') as `0x${string}`);
  const maxTicks = Number(process.env['DAEMON_MAX_TICKS'] ?? 0); // 0 = run forever

  const probe = createPublicClient({ transport: http(rpcUrl) });
  const chainId = await probe.getChainId();
  const chain = defineChain({
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
  const wallet = createWalletClient({ account, chain, transport: http(rpcUrl) });

  const stored = await publicClient.readContract({
    address: cfg.venue,
    abi: quayAbi,
    functionName: 'getQuoteState',
    args: [cfg.bookId],
  });
  let nonce = stored.nonce + 1n;

  console.log(
    `[daemon] ${cfg.stockSymbol} book=${cfg.bookId.slice(0, 10)}… ` +
      `source=${cfg.priceSource} updater=${account.address} startNonce=${nonce}`,
  );

  let running = true;
  process.on('SIGINT', () => {
    running = false;
  });

  // Price/2^128 conversion: quote atoms per share -> per stock atom in Q128.
  const perAtom = (quoteAtomsPerShare: bigint): bigint =>
    (quoteAtomsPerShare * Q128) / 10n ** BigInt(cfg.stockDecimals);

  let ticks = 0;
  while (running && (maxTicks === 0 || ticks < maxTicks)) {
    const started = Date.now();
    ticks++;
    const mid = await fetchMidQuoteAtoms(cfg, chainId);
    if (mid === null) {
      console.log(`[tick ${ticks}] no price; skipping (quote will decay)`);
    } else {
      const spread = (mid * BigInt(cfg.spreadBps)) / 10_000n;
      const now = BigInt(Math.floor(Date.now() / 1000));
      try {
        const hash = await wallet.writeContract({
          address: cfg.venue,
          abi: quayAbi,
          functionName: 'updateQuote',
          args: [
            cfg.bookId,
            {
              nonce,
              updatedAt: 0n, // stamped by the venue
              freshUntil: now + BigInt(cfg.freshSeconds),
              validUntil: now + BigInt(cfg.validSeconds),
              decayBpsPerSecond: cfg.decayBpsPerSecond,
              maxDecayBps: cfg.maxDecayBps,
              bidPxX128: perAtom(mid - spread),
              askPxX128: perAtom(mid + spread),
              maxIn0: BigInt(cfg.maxIn0),
              maxIn1: BigInt(cfg.maxIn1),
              sourceHash: `0x${ticks.toString(16).padStart(64, '0')}`,
            },
          ],
        });
        await publicClient.waitForTransactionReceipt({ hash });
        const midUsd = Number(mid) / 10 ** cfg.quoteDecimals;
        console.log(`[tick ${ticks}] mid=$${midUsd.toFixed(2)} nonce=${nonce} tx=${hash}`);
        nonce++;
      } catch (err) {
        console.log(`[tick ${ticks}] tx failed: ${(err as Error).message.split('\n')[0]}`);
      }
    }
    const elapsed = Date.now() - started;
    const wait = cfg.intervalMs - elapsed;
    if (wait > 0 && running && (maxTicks === 0 || ticks < maxTicks)) {
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  console.log('[daemon] stopped');
}

await main();
