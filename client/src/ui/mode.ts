/**
 * Two modes, chosen by the writer (scope v5 §"two modes — fast by default").
 *
 * A chat has no single right answer: one person wants to speak now, another
 * wants not to be seen speaking. So the choice is explicit:
 *
 *  - `fast`: the message goes out at once. The anonymity set is the traffic of
 *    the last minute, so it is not a fixed size: the composer shows the live
 *    count, and with no other traffic that count is one — this message and
 *    nothing else. The delay is zero and the set is stated as it is, never
 *    dressed up as a fixed neighbourhood.
 *  - `silent`: on the 1:1 plane the message joins a 10-minute bucket that is padded
 *    to 120 with decoys and shuffled before publication, so the write moment is
 *    hidden in a 120-wide set. A plaintext room publishes no decoys, so its bucket
 *    holds `k` writes; the moment is hidden there too, the author set is not.
 *    Delay ≤ 10 min.
 *
 * `DEFAULT_MODE` is `silent`: it is the fail-safe for a request that carries no
 * usable choice, and the safe direction for a privacy switch is the slower one.
 * The application itself opens in `fast` (scope v5: "fast by default"), and
 * passes that choice in explicitly, so a product decision never hides inside a
 * fallback.
 *
 * The choice lives in memory only. There is no `localStorage`, no
 * `sessionStorage`, no cookie, no URL parameter: a mode remembered across
 * reloads is a mode that a shared machine can read back, and a mode that can be
 * read back is a statement about the writer.
 */

export type Mode = "fast" | "silent";

/** Fail-safe for an unknown request. The app opens in `fast`; see main.ts. */
export const DEFAULT_MODE: Mode = "silent";

/** Delay bound per mode, in milliseconds, for UI copy and queue tests. */
export const MODE_DELAY_MS: Record<Mode, number> = {
  fast: 0,
  silent: 10 * 60 * 1000,
};

/**
 * Bucket size per mode. `silent` is the 120-wide bucket; the `fast` entry is
 * nominal — `anonymityCount(mode, recent)` reads the last minute's traffic for
 * fast mode instead of this number.
 */
export const MODE_ANONYMITY_SET: Record<Mode, number> = {
  fast: 5,
  silent: 120,
};

/**
 * The live neighbourhood number, as the composer shows it.
 *
 * Silent mode is a target, so the number is the bucket size. Fast mode is
 * whatever was published in the last minute; with no traffic it is one, which
 * is the honest answer ("your message and nothing else").
 */
export function anonymityCount(mode: Mode, recent = 1): number {
  if (mode === "silent") return MODE_ANONYMITY_SET.silent;
  const count = Math.trunc(recent);
  return Number.isFinite(count) && count > 1 ? count : 1;
}

export function isMode(value: unknown): value is Mode {
  return value === "fast" || value === "silent";
}

/**
 * The mode to use for a request that may carry a preference.
 *
 * Anything that is not a mode — a missing value, a stale string from an older
 * build, a hand-edited query parameter — falls back to the default instead of
 * throwing. A wrong mode is a privacy decision, so the safe direction is the
 * slower one.
 */
export function chooseMode(requested?: unknown): Mode {
  return isMode(requested) ? requested : DEFAULT_MODE;
}

/**
 * One line of copy, suitable for a label next to the switch.
 *
 * The percentage is scope v5's own copy (lines 75 and 78) and it describes the
 * decoy set, not a measured anonymity guarantee: four decoys plus the message
 * is a 1-in-5 set, and 120 is a 1-in-120 set. Fast mode is never sold as
 * equally private — its sentence says "goes out at once" first.
 */
export function describeMode(mode: Mode): string {
  return mode === "fast"
    ? "your write moment ~80% hidden, the message goes out at once"
    : "your write moment ~99% hidden";
}

export interface ModeChoice {
  mode: Mode;
  /**
   * True the first time `fast` is chosen. The UI asks once before switching to
   * the mode that shortens the delay, then remembers the answer — in memory.
   */
  firstTime: boolean;
}

export interface ModeSwitch {
  current(): Mode;
  choose(requested: unknown): ModeChoice;
  /** Test hook and "forgot it" path; not reachable from storage because there is none. */
  reset(): void;
}

export function createModeSwitch(initial: Mode = DEFAULT_MODE): ModeSwitch {
  let mode: Mode = initial;
  let fastConfirmed = initial === "fast";

  return {
    current: () => mode,
    choose(requested: unknown): ModeChoice {
      const next = chooseMode(requested);
      const firstTime = next === "fast" && !fastConfirmed;
      if (next === "fast") fastConfirmed = true;
      mode = next;
      return { mode: next, firstTime };
    },
    reset(): void {
      mode = initial;
      fastConfirmed = initial === "fast";
    },
  };
}
