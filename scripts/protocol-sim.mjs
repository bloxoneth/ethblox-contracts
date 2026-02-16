import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { ethers } from "ethers";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const CONTRACTS_ROOT = path.resolve(__dirname, "..");
const APP_ROOT = path.resolve(CONTRACTS_ROOT, "..", "ethblox-app");

const DENSITIES = [1, 8, 27, 64, 125];
const MAX_SIDE = 10;
const KIND_BUILD_BASE = 1;
const GAS_MINT = 5_000_000n;
const UNIQUE_BRICK_SIZES = 55;

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    rpcUrl: process.env.RPC_URL || "http://127.0.0.1:8545",
    chainMode: process.env.CHAIN_MODE || "deploy-local",
    runId: process.env.RUN_ID || `run-${Date.now()}`,
    outDir: process.env.OUT_DIR || path.join(APP_ROOT, "data", "sim-runs"),
    seed: Number(process.env.SEED || "1337"),
    autoStartAnvil: process.env.AUTO_START_ANVIL !== "0",
    anvilPort: Number(process.env.ANVIL_PORT || "8545")
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--rpc") out.rpcUrl = args[++i];
    else if (a === "--mode") out.chainMode = args[++i];
    else if (a === "--run-id") out.runId = args[++i];
    else if (a === "--out") out.outDir = args[++i];
    else if (a === "--seed") out.seed = Number(args[++i]);
    else if (a === "--no-anvil") out.autoStartAnvil = false;
    else if (a === "--anvil-port") out.anvilPort = Number(args[++i]);
  }
  return out;
}

function ensureDir(p) {
  fs.mkdirSync(p, { recursive: true });
}

function writeJson(p, data) {
  fs.writeFileSync(p, JSON.stringify(data, null, 2));
}

function mulberry32(seed) {
  let t = seed >>> 0;
  return function rand() {
    t += 0x6D2B79F5;
    let r = Math.imul(t ^ (t >>> 15), 1 | t);
    r ^= r + Math.imul(r ^ (r >>> 7), 61 | r);
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  };
}

function randInt(rand, min, max) {
  return Math.floor(rand() * (max - min + 1)) + min;
}

function toHash(label) {
  return ethers.keccak256(ethers.toUtf8Bytes(label));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForRpc(provider, tries = 40) {
  for (let i = 0; i < tries; i++) {
    try {
      await provider.getBlockNumber();
      return true;
    } catch {
      await sleep(300);
    }
  }
  return false;
}

async function ensureRpcWithAnvil(opts) {
  const provider = new ethers.JsonRpcProvider(opts.rpcUrl);
  if (await waitForRpc(provider, 3)) {
    return { provider, anvilProc: null };
  }
  if (!opts.autoStartAnvil) {
    throw new Error(`RPC unavailable at ${opts.rpcUrl} and auto-start disabled`);
  }

  const anvilProc = spawn(
    "anvil",
    ["--host", "127.0.0.1", "--port", String(opts.anvilPort), "--chain-id", "31337"],
    { stdio: "ignore" }
  );

  const ok = await waitForRpc(provider, 60);
  if (!ok) {
    anvilProc.kill("SIGTERM");
    throw new Error("Anvil failed to start in time");
  }
  return { provider, anvilProc };
}

function readArtifact(rel) {
  const p = path.join(CONTRACTS_ROOT, "out", rel);
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

async function deployContract(signer, artifactRel, args = []) {
  const artifact = readArtifact(artifactRel);
  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode.object, signer);
  const contract = await factory.deploy(...args);
  await contract.waitForDeployment();
  return contract;
}

function expect(condition, msg) {
  if (!condition) throw new Error(msg);
}

async function expectRevert(fn, reason) {
  try {
    const result = await fn();
    if (result && typeof result.wait === "function") {
      await result.wait();
    }
  } catch (err) {
    const m = String(err?.shortMessage || err?.message || err);
    if (reason && !m.includes(reason)) {
      throw new Error(`Expected revert containing '${reason}', got '${m}'`);
    }
    return;
  }
  throw new Error(`Expected revert '${reason}' but call succeeded`);
}

function parseBuildMinted(buildNFT, receipt) {
  for (const log of receipt.logs) {
    try {
      const parsed = buildNFT.interface.parseLog(log);
      if (parsed?.name === "BuildMinted") {
        return Number(parsed.args.tokenId);
      }
    } catch {
      // ignore non-BuildNFT logs
    }
  }
  throw new Error("BuildMinted event not found");
}

function parseRebalanceOk(registry, receipt) {
  for (const log of receipt.logs) {
    try {
      const parsed = registry.interface.parseLog(log);
      if (parsed?.name === "RebalanceExecuted") {
        return parsed.args.ok;
      }
    } catch {
      // ignore non-registry logs
    }
  }
  throw new Error("RebalanceExecuted event not found");
}

function sizeKey(w, d) {
  return `${w}x${d}`;
}

function generateShape(rand, width, depth) {
  const voxelCount = randInt(rand, 8, 24);
  const voxels = [];
  const seen = new Set();

  while (voxels.length < voxelCount) {
    const x = randInt(rand, 0, Math.max(1, width) - 1);
    const y = randInt(rand, 0, 4);
    const z = randInt(rand, 0, Math.max(1, depth) - 1);
    const k = `${x},${y},${z}`;
    if (seen.has(k)) continue;
    seen.add(k);
    voxels.push({ x, y, z, t: randInt(rand, 0, 5) });
  }

  return voxels;
}

function renderShapeSvg(voxels, width, depth) {
  const W = 420;
  const H = 280;
  const sx = W / Math.max(1, width + depth + 2);
  const sy = H / 16;
  const points = voxels
    .map((v) => {
      const px = Math.round((v.x + v.z + 1) * sx);
      const py = Math.round(H - (v.y + 1) * sy - v.z * 2);
      const color = ["#111", "#1f77b4", "#2ca02c", "#ff7f0e", "#d62728", "#9467bd"][v.t % 6];
      return `<circle cx="${px}" cy="${py}" r="4" fill="${color}" />`;
    })
    .join("\n");

  return `<?xml version="1.0" encoding="UTF-8"?>\n<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">\n<rect width="100%" height="100%" fill="#f5f5f5" />\n${points}\n</svg>\n`;
}

async function main() {
  const opts = parseArgs();
  const { provider, anvilProc } = await ensureRpcWithAnvil(opts);
  const runDir = path.join(opts.outDir, opts.runId);
  const metadataDir = path.join(runDir, "metadata");
  const imagesDir = path.join(runDir, "images");
  ensureDir(runDir);
  ensureDir(metadataDir);
  ensureDir(imagesDir);

  const txLog = [];
  const invariantLog = [];
  const minted = [];

  const deployer = await provider.getSigner(0);
  const alice = await provider.getSigner(1);
  const bob = await provider.getSigner(2);
  const carol = await provider.getSigner(3);
  const dave = await provider.getSigner(4);
  const eve = await provider.getSigner(5);

  const deployerAddr = await deployer.getAddress();
  const aliceAddr = await alice.getAddress();
  const bobAddr = await bob.getAddress();
  const carolAddr = await carol.getAddress();
  const daveAddr = await dave.getAddress();
  const eveAddr = await eve.getAddress();

  let blox;
  let distributor;
  let licenseNFT;
  let licenseRegistry;
  let buildNFT;

  if (opts.chainMode === "deploy-local") {
    const nonce = await provider.getTransactionCount(deployerAddr);
    const predictedBuildAddr = ethers.getCreateAddress({ from: deployerAddr, nonce: nonce + 4 });

    blox = await deployContract(deployer, "BLOX.sol/BLOX.json", [deployerAddr]);
    distributor = await deployContract(deployer, "Distributor.sol/Distributor.json", [blox.target, deployerAddr]);
    licenseNFT = await deployContract(deployer, "LicenseNFT.sol/LicenseNFT.json", ["ipfs://licenses/{id}.json"]);
    licenseRegistry = await deployContract(deployer, "LicenseRegistry.sol/LicenseRegistry.json", [predictedBuildAddr, licenseNFT.target, deployerAddr]);
    buildNFT = await deployContract(deployer, "BuildNFT.sol/BuildNFT.json", [
      blox.target,
      distributor.target,
      deployerAddr,
      deployerAddr,
      licenseRegistry.target,
      licenseNFT.target,
      1_000_000
    ]);

    await (await licenseNFT.setRegistry(licenseRegistry.target)).wait();
    await (await distributor.setBuildNFT(buildNFT.target)).wait();
    await (await distributor.setProtocolTreasury(deployerAddr)).wait();

    await (await buildNFT.setKindEnabled(1, true)).wait();
    await (await buildNFT.setKindEnabled(2, true)).wait();
    await (await buildNFT.setKindEnabled(3, true)).wait();

    await (await licenseRegistry.setKeeper(deployerAddr, true)).wait();
    await (await licenseRegistry.setRouterWhitelist(deployerAddr, true)).wait();
    await (await licenseRegistry.setRebalanceGuards(60n, ethers.parseEther("0.0001"), 1_000n, 1800n)).wait();
  } else {
    const env = process.env;
    expect(env.BLOX && env.DISTRIBUTOR && env.LICENSE_NFT && env.LICENSE_REGISTRY && env.BUILD_NFT, "missing address env vars for existing mode");

    const bloxArtifact = readArtifact("BLOX.sol/BLOX.json");
    blox = new ethers.Contract(env.BLOX, bloxArtifact.abi, deployer);

    const distArtifact = readArtifact("Distributor.sol/Distributor.json");
    distributor = new ethers.Contract(env.DISTRIBUTOR, distArtifact.abi, deployer);

    const lNFTArtifact = readArtifact("LicenseNFT.sol/LicenseNFT.json");
    licenseNFT = new ethers.Contract(env.LICENSE_NFT, lNFTArtifact.abi, deployer);

    const lRegArtifact = readArtifact("LicenseRegistry.sol/LicenseRegistry.json");
    licenseRegistry = new ethers.Contract(env.LICENSE_REGISTRY, lRegArtifact.abi, deployer);

    const buildArtifact = readArtifact("BuildNFT.sol/BuildNFT.json");
    buildNFT = new ethers.Contract(env.BUILD_NFT, buildArtifact.abi, deployer);
  }

  const users = [alice, bob, carol, dave, eve];
  console.log("[sim] Deploy/init complete. Funding users...");
  for (const user of users) {
    const u = await user.getAddress();
    await (await blox.transfer(u, ethers.parseEther("10000000"))).wait();
    await (await blox.connect(user).approve(buildNFT.target, ethers.MaxUint256)).wait();
    await (await licenseNFT.connect(user).setApprovalForAll(buildNFT.target, true)).wait();
  }

  const feePerMint = await buildNFT.FEE_PER_MINT();
  const rand = mulberry32(opts.seed);

  const bricksByDensity = new Map();
  const sizeCoverage = new Set();

  await expectRevert(
    async () => {
      await buildNFT.connect(alice).mint(
        toHash("preunlock-build"),
        10,
        "ipfs://preunlock",
        [],
        [],
        KIND_BUILD_BASE,
        0,
        0,
        1,
        { value: feePerMint }
      );
    },
    "kind locked"
  );
  invariantLog.push({ key: "kind_locked_before_brick_coverage", pass: true });
  console.log("[sim] Verified kind lock before brick coverage.");

  let brickMintCount = 0;
  for (const density of DENSITIES) {
    console.log(`[sim] Minting bricks for density=${density} ...`);
    const bySize = new Map();
    bricksByDensity.set(density, bySize);

    const g = toHash(`brick-genesis-${density}`);
    const tx = await buildNFT.connect(alice).mint(
      g,
      1,
      `ipfs://brick/${density}/1x1`,
      [],
      [],
      0,
      1,
      1,
      density,
      { value: feePerMint, gasLimit: GAS_MINT }
    );
    const rc = await tx.wait();
    const tokenId = parseBuildMinted(buildNFT, rc);
    bySize.set(sizeKey(1, 1), tokenId);
    sizeCoverage.add(sizeKey(1, 1));
    minted.push({ tokenId, kind: 0, width: 1, depth: 1, density, mass: 1, components: [], geometryHash: g, minter: aliceAddr });
    brickMintCount += 1;

    for (let w = 1; w <= MAX_SIDE; w++) {
      for (let d = 1; d <= MAX_SIDE; d++) {
        if (w === 1 && d === 1) continue;
        if (w > d) continue;
        const componentId = bySize.get(sizeKey(1, 1));
        const cnt = w * d;
        const geom = toHash(`brick-${density}-${w}x${d}`);
        const mintTx = await buildNFT.connect(alice).mint(
          geom,
          cnt,
          `ipfs://brick/${density}/${w}x${d}`,
          [componentId],
          [cnt],
          0,
          w,
          d,
          density,
          { value: feePerMint, gasLimit: GAS_MINT }
        );
        const mintRc = await mintTx.wait();
        const brickId = parseBuildMinted(buildNFT, mintRc);

        bySize.set(sizeKey(w, d), brickId);
        sizeCoverage.add(sizeKey(w, d));
        minted.push({ tokenId: brickId, kind: 0, width: w, depth: d, density, mass: cnt, components: [{ componentId, count: cnt }], geometryHash: geom, minter: aliceAddr });
        brickMintCount += 1;
        if (brickMintCount % 100 === 0) {
          console.log(`[sim] Brick mints=${brickMintCount}`);
        }
      }
    }
  }
  console.log(`[sim] Brick minting complete. Total bricks=${brickMintCount}`);

  expect(
    sizeCoverage.size === UNIQUE_BRICK_SIZES,
    `expected ${UNIQUE_BRICK_SIZES} covered brick sizes, got ${sizeCoverage.size}`
  );
  const unlocked = await buildNFT.isKindUnlocked();
  expect(unlocked === true, "kind unlock should be true after full brick size coverage");
  invariantLog.push({ key: "kind_unlocked_after_all_sizes", pass: true });
  console.log("[sim] Kind unlock validated.");

  const density1 = 1;

  const buildAHash = toHash("build-a");
  const buildATx = await buildNFT.connect(bob).mint(
    buildAHash,
    120,
    "ipfs://build/a",
    [],
    [],
    1,
    0,
    0,
    density1,
    { value: feePerMint, gasLimit: GAS_MINT }
  );
  const buildAReceipt = await buildATx.wait();
  const buildA = parseBuildMinted(buildNFT, buildAReceipt);
  minted.push({ tokenId: buildA, kind: 1, density: density1, mass: 120, components: [], geometryHash: buildAHash, minter: bobAddr });
  console.log(`[sim] Minted buildA tokenId=${buildA}`);

  await (await licenseRegistry.connect(bob).registerBuild(buildA, buildAHash)).wait();
  const buildALicenseId = await licenseRegistry.licenseIdForBuild(buildA);

  for (const signer of [bob, carol, dave, eve, alice]) {
    const q = await licenseRegistry.quote(buildA, 5);
    await (await licenseRegistry.connect(signer).mintLicenseForBuild(buildA, 5, { value: q })).wait();
  }

  const selfBefore = await distributor.ethOwed(bobAddr);
  const selfHash = toHash("build-self-pay");
  const selfTx = await buildNFT.connect(bob).mint(
    selfHash,
    30,
    "ipfs://build/self",
    [buildA],
    [1],
    3,
    0,
    0,
    density1,
    { value: feePerMint, gasLimit: GAS_MINT }
  );
  const selfRc = await selfTx.wait();
  const selfBuildId = parseBuildMinted(buildNFT, selfRc);
  const selfAfter = await distributor.ethOwed(bobAddr);
  expect(selfAfter > selfBefore, "self-pay should increase owner accrued ETH");
  minted.push({ tokenId: selfBuildId, kind: 3, density: density1, mass: 30, components: [{ componentId: buildA, count: 1 }], geometryHash: selfHash, minter: bobAddr });
  invariantLog.push({ key: "self_pay_accrual", pass: true });
  console.log(`[sim] Self-pay accrual validated tokenId=${selfBuildId}`);

  const buildBHash = toHash("build-b");
  const buildBTx = await buildNFT.connect(carol).mint(
    buildBHash,
    80,
    "ipfs://build/b",
    [buildA],
    [2],
    1,
    0,
    0,
    density1,
    { value: feePerMint, gasLimit: GAS_MINT }
  );
  const buildBReceipt = await buildBTx.wait();
  const buildB = parseBuildMinted(buildNFT, buildBReceipt);
  minted.push({ tokenId: buildB, kind: 1, density: density1, mass: 80, components: [{ componentId: buildA, count: 2 }], geometryHash: buildBHash, minter: carolAddr });
  console.log(`[sim] Minted buildB tokenId=${buildB}`);

  await (await licenseRegistry.connect(carol).registerBuild(buildB, buildBHash)).wait();
  const buildBLicenseId = await licenseRegistry.licenseIdForBuild(buildB);
  for (const signer of [dave, eve]) {
    const q = await licenseRegistry.quote(buildB, 2);
    await (await licenseRegistry.connect(signer).mintLicenseForBuild(buildB, 2, { value: q })).wait();
  }

  const uniqueBefore = await distributor.uniqueUsers(buildB);
  const daveUseTx = await buildNFT.connect(dave).mint(
    toHash("reuse-dave"),
    25,
    "ipfs://build/reuse-d",
    [buildB],
    [1],
    1,
    0,
    0,
    density1,
    { value: feePerMint, gasLimit: GAS_MINT }
  );
  await daveUseTx.wait();
  const afterDave = await distributor.uniqueUsers(buildB);
  const eveUseTx = await buildNFT.connect(eve).mint(
    toHash("reuse-eve"),
    25,
    "ipfs://build/reuse-e",
    [buildB],
    [1],
    1,
    0,
    0,
    density1,
    { value: feePerMint, gasLimit: GAS_MINT }
  );
  await eveUseTx.wait();
  const afterEve = await distributor.uniqueUsers(buildB);
  expect(afterDave > uniqueBefore && afterEve > afterDave, "unique users should increase across distinct reusers");
  invariantLog.push({ key: "unique_users_increase", pass: true });
  console.log("[sim] Unique user growth validated.");

  const burnTx = await buildNFT.connect(bob).burn(buildA);
  await burnTx.wait();

  await expectRevert(
    async () => {
      const q = await licenseRegistry.quote(buildA, 1);
      await licenseRegistry.connect(alice).mintLicenseForBuild(buildA, 1, { value: q });
    },
    "build burned"
  );
  invariantLog.push({ key: "license_blocked_after_burn", pass: true });
  console.log("[sim] Burn + license block validated.");

  const treasuryBefore = await distributor.ethOwed(deployerAddr);
  const burnedRouteTx = await buildNFT.connect(alice).mint(
    toHash("burned-route"),
    40,
    "ipfs://build/burned-route",
    [buildA],
    [1],
    1,
    0,
    0,
    density1,
    { value: feePerMint, gasLimit: GAS_MINT }
  );
  await burnedRouteTx.wait();
  const treasuryAfter = await distributor.ethOwed(deployerAddr);
  expect(treasuryAfter > treasuryBefore, "burned component share should route to treasury accrual");
  invariantLog.push({ key: "burned_component_routes_to_treasury", pass: true });
  console.log("[sim] Burned component routing validated.");

  const lpBefore = await licenseRegistry.lpBudgetBalance();
  const qOne = await licenseRegistry.quote(buildB, 1);
  await (await licenseRegistry.connect(alice).mintLicenseForBuild(buildB, 1, { value: qOne })).wait();
  const lpAfter = await licenseRegistry.lpBudgetBalance();
  expect(lpAfter - lpBefore === qOne / 2n, "license fee split must allocate 50% to LP budget");
  invariantLog.push({ key: "license_split_50_50", pass: true });
  console.log("[sim] License fee 50/50 split validated.");

  const router = await deployContract(deployer, "LicenseRegistry.t.sol/RebalanceRouterMock.json", []);
  await (await licenseRegistry.setRouterWhitelist(router.target, true)).wait();

  await expectRevert(
    async () => {
      await licenseRegistry.executeRebalance(
        router.target,
        ethers.parseEther("0.00001"),
        100,
        BigInt(Math.floor(Date.now() / 1000) + 60),
        "0x1234"
      );
    },
    "threshold"
  );

  await (await licenseRegistry.setRebalanceGuards(0n, 1n, 1000n, 1800n)).wait();
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
  const iface = new ethers.Interface(["function execute() external payable"]);
  const data = iface.encodeFunctionData("execute", []);
  const rebAmt = lpAfter / 4n > 0n ? lpAfter / 4n : 1n;
  const rebReceipt =
    await (await licenseRegistry.executeRebalance(router.target, rebAmt, 50, deadline, data)).wait();
  expect(parseRebalanceOk(licenseRegistry, rebReceipt) === true, "rebalance execution failed");
  invariantLog.push({ key: "rebalance_executes_under_guards", pass: true });

  const lastRebalanceAt = await licenseRegistry.lastRebalanceAt();
  expect(lastRebalanceAt > 0n, "lastRebalanceAt not set");
  await (await licenseRegistry.setRebalanceGuards(86_400n, 1n, 1000n, 1800n)).wait();
  await provider.send("evm_setNextBlockTimestamp", [Number(lastRebalanceAt + 1n)]);
  await expectRevert(
    async () => {
      return licenseRegistry.executeRebalance(router.target, rebAmt, 50, deadline, data);
    },
    ""
  );
  const lastRebalanceAfter = await licenseRegistry.lastRebalanceAt();
  expect(lastRebalanceAfter === lastRebalanceAt, "interval guard should block state advance");
  invariantLog.push({ key: "rebalance_interval_guard", pass: true });
  console.log("[sim] Rebalance guards validated.");

  const tags = ["voxel", "pet", "artifact", "tower", "abstract", "kinetic"];
  for (const rec of minted.filter((m) => m.kind > 0).slice(0, 10)) {
    const shape = generateShape(rand, randInt(rand, 8, 14), randInt(rand, 8, 14));
    const metadata = {
      tokenId: rec.tokenId,
      name: `ETHBLOX Build #${rec.tokenId}`,
      description: "Protocol simulation artifact",
      kind: rec.kind,
      density: rec.density,
      mass: rec.mass,
      geometryHash: rec.geometryHash,
      tags: [tags[randInt(rand, 0, tags.length - 1)], tags[randInt(rand, 0, tags.length - 1)]],
      components: rec.components,
      shape
    };

    const metadataPath = path.join(metadataDir, `${rec.tokenId}.json`);
    const imagePath = path.join(imagesDir, `${rec.tokenId}.svg`);
    writeJson(metadataPath, metadata);
    fs.writeFileSync(imagePath, renderShapeSvg(shape, 14, 14));
  }

  const contractsOut = {
    blox: blox.target,
    distributor: distributor.target,
    licenseNFT: licenseNFT.target,
    licenseRegistry: licenseRegistry.target,
    buildNFT: buildNFT.target,
    chainId: Number((await provider.getNetwork()).chainId)
  };

  const summary = {
    runId: opts.runId,
    seed: opts.seed,
    startedAt: new Date().toISOString(),
    contracts: contractsOut,
    totals: {
      mintedCount: minted.length,
      bricks: minted.filter((m) => m.kind === 0).length,
      builds: minted.filter((m) => m.kind > 0).length,
      uniqueBrickSizesCovered: sizeCoverage.size,
      densitiesCovered: DENSITIES.length
    },
    invariants: invariantLog
  };

  writeJson(path.join(runDir, "contracts.json"), contractsOut);
  writeJson(path.join(runDir, "tokens.json"), minted);
  writeJson(path.join(runDir, "invariants.json"), invariantLog);
  writeJson(path.join(runDir, "summary.json"), summary);
  writeJson(path.join(runDir, "tx-log.json"), txLog);

  console.log("Simulation complete");
  console.log(`Run: ${opts.runId}`);
  console.log(`Output: ${runDir}`);
  console.log(`Bricks minted: ${summary.totals.bricks}`);
  console.log(`Builds minted: ${summary.totals.builds}`);

  if (anvilProc) {
    anvilProc.kill("SIGTERM");
  }
}

main().catch((err) => {
  console.error("Simulation failed:", err);
  process.exitCode = 1;
});
