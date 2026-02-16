import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";

const DEFAULT_CONTRACTS = path.resolve(
  process.cwd(),
  "..",
  "ethblox-app",
  "data",
  "sim-runs",
  "local-reseed-8545",
  "contracts.json",
);

const BUILD_ABI = [
  "function nextTokenId() view returns (uint256)",
  "function exists(uint256) view returns (bool)",
  "function ownerOf(uint256) view returns (address)",
  "function kindOf(uint256) view returns (uint8)",
  "function lockedBloxOf(uint256) view returns (uint256)",
];

const DIST_ABI_WITH_USAGE = [
  "function bwScore(uint256) view returns (int256)",
  "function lastUsedAt(uint256) view returns (uint256)",
];

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {
    rpc: process.env.RPC_URL || "http://127.0.0.1:8545",
    contracts: process.env.CONTRACTS_JSON || DEFAULT_CONTRACTS,
    runId: process.env.RUN_ID || `emissions-${Date.now()}`,
    outDir: process.env.OUT_DIR || path.resolve(process.cwd(), "data", "emissions-runs"),
    poolBlox: Number(process.env.POOL_BLOX || "1000000"),
    wLocked: Number(process.env.W_LOCKED || "0.7"),
    wBw: Number(process.env.W_BW || "0.3"),
    model: process.env.EMISSIONS_MODEL || "multiplier",
    bwRange: process.env.BW_RANGE || "1,5",
    decayHalfLifeDays: Number(process.env.DECAY_HALF_LIFE_DAYS || "90"),
    decayFloor: Number(process.env.DECAY_FLOOR || "0.25"),
    decaySource: process.env.DECAY_SOURCE || "build_use",
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--rpc") opts.rpc = args[++i];
    else if (a === "--contracts") opts.contracts = args[++i];
    else if (a === "--run-id") opts.runId = args[++i];
    else if (a === "--out") opts.outDir = args[++i];
    else if (a === "--pool-blox") opts.poolBlox = Number(args[++i]);
    else if (a === "--w-locked") opts.wLocked = Number(args[++i]);
    else if (a === "--w-bw") opts.wBw = Number(args[++i]);
    else if (a === "--model") opts.model = args[++i];
    else if (a === "--bw-range") opts.bwRange = args[++i];
    else if (a === "--decay-half-life-days") opts.decayHalfLifeDays = Number(args[++i]);
    else if (a === "--decay-floor") opts.decayFloor = Number(args[++i]);
    else if (a === "--decay-source") opts.decaySource = args[++i];
  }
  return opts;
}

function gradeByPct(p) {
  if (p >= 20) return "A";
  if (p >= 10) return "B";
  if (p >= 5) return "C";
  if (p >= 1) return "D";
  return "E";
}

function parseBwRange(rangeStr) {
  const [a, b] = String(rangeStr)
    .split(",")
    .map((v) => Number(v.trim()));
  if (!Number.isFinite(a) || !Number.isFinite(b) || a <= 0 || b < a) {
    throw new Error(`Invalid --bw-range '${rangeStr}'. Expected 'min,max' with min>0 and max>=min`);
  }
  return [a, b];
}

function decayForDays(days, halfLifeDays, floor) {
  if (halfLifeDays <= 0) return 1;
  const lambda = Math.log(2) / halfLifeDays;
  const raw = Math.exp(-Math.max(0, days) * lambda);
  return Math.max(floor, Math.min(1, raw));
}

async function main() {
  const opts = parseArgs();
  const provider = new ethers.JsonRpcProvider(opts.rpc);
  await provider.getBlockNumber();
  const nowTs = Number((await provider.getBlock("latest")).timestamp);
  const [bwMinMult, bwMaxMult] = parseBwRange(opts.bwRange);

  const contracts = JSON.parse(fs.readFileSync(opts.contracts, "utf8"));
  const build = new ethers.Contract(contracts.buildNFT, BUILD_ABI, provider);
  const dist = new ethers.Contract(contracts.distributor, DIST_ABI_WITH_USAGE, provider);

  const next = Number(await build.nextTokenId());
  const tokenRows = [];
  for (let id = 1; id < next; id++) {
    const exists = await build.exists(id).catch(() => false);
    if (!exists) continue;
    const owner = (await build.ownerOf(id)).toLowerCase();
    const kind = Number(await build.kindOf(id));
    const lockedWei = await build.lockedBloxOf(id);
    const locked = Number(ethers.formatEther(lockedWei));
    const bwRaw = await dist.bwScore(id).catch(() => 0n);
    const bw = Number(bwRaw > 0n ? bwRaw : 0n);
    const lastUsedAt = Number(await dist.lastUsedAt(id).catch(() => 0n));
    const daysSinceUse = lastUsedAt > 0 ? (nowTs - lastUsedAt) / 86400 : 3650;
    tokenRows.push({
      tokenId: id,
      owner,
      kind,
      lockedBlox: locked,
      bwScore: bw,
      lastUsedAt,
      daysSinceUse,
    });
  }

  const byOwner = new Map();
  for (const t of tokenRows) {
    const cur = byOwner.get(t.owner) || {
      owner: t.owner,
      tokens: 0,
      lockedBlox: 0,
      bwScore: 0,
      weightedDaysSinceUseNumerator: 0,
      avgDaysSinceUse: 3650,
    };
    cur.tokens += 1;
    cur.lockedBlox += t.lockedBlox;
    cur.bwScore += t.bwScore;
    cur.weightedDaysSinceUseNumerator += t.lockedBlox * t.daysSinceUse;
    byOwner.set(t.owner, cur);
  }
  const owners = Array.from(byOwner.values());
  if (owners.length === 0) throw new Error("No active tokens found");

  for (const o of owners) {
    o.avgDaysSinceUse =
      o.lockedBlox > 0 ? o.weightedDaysSinceUseNumerator / o.lockedBlox : 3650;
  }

  if (opts.model === "blend") {
    const lockedNormDen = owners.reduce((s, o) => s + Math.sqrt(Math.max(0, o.lockedBlox)), 0);
    const bwNormDen = owners.reduce((s, o) => s + Math.max(1, o.bwScore), 0);
    for (const o of owners) {
      const lockedNorm =
        lockedNormDen > 0 ? Math.sqrt(Math.max(0, o.lockedBlox)) / lockedNormDen : 0;
      const bwNorm = bwNormDen > 0 ? Math.max(1, o.bwScore) / bwNormDen : 0;
      const blended = opts.wLocked * lockedNorm + opts.wBw * bwNorm;
      o.lockedPct = lockedNorm * 100;
      o.bwPct = bwNorm * 100;
      o.sharePct = blended * 100;
      o.emissionBlox = opts.poolBlox * blended;
      o.grade = gradeByPct(o.sharePct);
      o.bwMultiplier = 1;
      o.decayFactor = 1;
      o.adjustedBwMultiplier = 1;
      o.effectiveLocked = o.lockedBlox;
    }
  } else if (opts.model === "multiplier") {
    const minBwScore = Math.min(...owners.map((o) => o.bwScore));
    const maxBwScore = Math.max(...owners.map((o) => o.bwScore));
    let effectiveDen = 0;
    for (const o of owners) {
      const t =
        maxBwScore === minBwScore ? 0 : (o.bwScore - minBwScore) / (maxBwScore - minBwScore);
      const bwMultiplier = bwMinMult + (bwMaxMult - bwMinMult) * t;
      const decayFactor = decayForDays(o.avgDaysSinceUse, opts.decayHalfLifeDays, opts.decayFloor);
      const adjustedBwMultiplier = 1 + (bwMultiplier - 1) * decayFactor;
      const effectiveLocked = o.lockedBlox * adjustedBwMultiplier;
      o.bwMultiplier = bwMultiplier;
      o.decayFactor = decayFactor;
      o.adjustedBwMultiplier = adjustedBwMultiplier;
      o.effectiveLocked = effectiveLocked;
      effectiveDen += effectiveLocked;
    }
    for (const o of owners) {
      const share = effectiveDen > 0 ? o.effectiveLocked / effectiveDen : 0;
      o.sharePct = share * 100;
      o.emissionBlox = opts.poolBlox * share;
      o.grade = gradeByPct(o.sharePct);
      o.lockedPct = 0;
      o.bwPct = 0;
    }
  } else {
    throw new Error(`Unknown --model '${opts.model}'. Use blend|multiplier`);
  }

  owners.sort((a, b) => b.sharePct - a.sharePct);

  const runDir = path.join(opts.outDir, opts.runId);
  fs.mkdirSync(runDir, { recursive: true });
  const decaySourceNote =
    opts.decaySource === "license_use"
      ? "license_use requested; currently using Distributor.lastUsedAt until dedicated license-use timestamp is added on-chain"
      : "using Distributor.lastUsedAt";
  const formula =
    opts.model === "blend"
      ? "share = wLocked*sqrt(lock)/sum(sqrt(lock)) + wBw*bw/sum(bw)"
      : "bwMultiplier = lerp(bwMin,bwMax, normalizedOwnerBw); adjustedMultiplier = 1 + (bwMultiplier-1)*max(decayFloor, exp(-ln(2)*daysSinceUse/halfLifeDays)); effectiveLocked = lockedBlox*adjustedMultiplier; share = effectiveLocked/sum(effectiveLocked)";
  const summary = {
    runId: opts.runId,
    rpc: opts.rpc,
    contracts,
    poolBlox: opts.poolBlox,
    model: opts.model,
    bwRange: { min: bwMinMult, max: bwMaxMult },
    decay: {
      source: opts.decaySource,
      sourceNote: decaySourceNote,
      halfLifeDays: opts.decayHalfLifeDays,
      floor: opts.decayFloor,
    },
    formula,
    weights: { locked: opts.wLocked, bw: opts.wBw },
    tokenCount: tokenRows.length,
    ownerCount: owners.length,
    owners: owners.map((o) => ({
      owner: o.owner,
      tokens: o.tokens,
      lockedBlox: o.lockedBlox,
      bwScore: o.bwScore,
      avgDaysSinceUse: o.avgDaysSinceUse,
      bwMultiplier: o.bwMultiplier,
      decayFactor: o.decayFactor,
      adjustedBwMultiplier: o.adjustedBwMultiplier,
      effectiveLocked: o.effectiveLocked,
      sharePct: o.sharePct,
      emissionBlox: o.emissionBlox,
      grade: o.grade,
    })),
  };
  fs.writeFileSync(path.join(runDir, "summary.json"), JSON.stringify(summary, null, 2));
  fs.writeFileSync(path.join(runDir, "tokens.json"), JSON.stringify(tokenRows, null, 2));

  const csv = [
    "owner,tokens,locked_blox,bw_score,avg_days_since_use,bw_multiplier,decay_factor,adjusted_bw_multiplier,effective_locked,share_pct,emission_blox,grade",
    ...owners.map((o) =>
      [
        o.owner,
        o.tokens,
        o.lockedBlox.toFixed(4),
        o.bwScore,
        o.avgDaysSinceUse.toFixed(4),
        o.bwMultiplier.toFixed(6),
        o.decayFactor.toFixed(6),
        o.adjustedBwMultiplier.toFixed(6),
        o.effectiveLocked.toFixed(4),
        o.sharePct.toFixed(4),
        o.emissionBlox.toFixed(4),
        o.grade,
      ].join(","),
    ),
  ];
  fs.writeFileSync(path.join(runDir, "owner-emissions.csv"), `${csv.join("\n")}\n`);

  console.log(JSON.stringify(summary, null, 2));
  console.log(`Outputs written to: ${runDir}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
