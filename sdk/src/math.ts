export const Q128 = 1n << 128n;
export const BPS = 10_000n;
export const PPM = 1_000_000n;
export const PPB = 1_000_000_000n;

/** floor(a * b / d) — bigint is arbitrary precision, so this is exact. */
export function mulDiv(a: bigint, b: bigint, d: bigint): bigint {
  return (a * b) / d;
}

/** Floor integer square root, matching OpenZeppelin Math.sqrt semantics. */
export function isqrt(v: bigint): bigint {
  if (v < 2n) return v;
  let x = v;
  let next = v / 2n + 1n;
  while (next < x) {
    x = next;
    next = (v / next + next) / 2n;
  }
  return x;
}
