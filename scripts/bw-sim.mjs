import fs from "node:fs";
import path from "node:path";
import { ethers } from "ethers";

const DEFAULT_CSV = path.resolve(process.cwd(), "..", "BW_converted.csv");
const DEFAULT_CONTRACTS = path.resolve(
  process.cwd(),
  "..",
  "ethblox-app",
  "data",
  "sim-runs",
  "local-reseed-8545",
  "contracts.json",
);

const MINT_FEE = ethers.parseEther("0.01");
const BLOX_UNIT = 10n ** 18n;
const GAS_LIMIT = 5_000_000n;

const BUILD_NFT_ABI = [
  "function nextTokenId() view returns (uint256)",
  "function mint(bytes32,uint256,string,uint256[],uint256[],uint8,uint8,uint8,uint16) payable returns (uint256)",
  "function exists(uint256) view returns (bool)",
  "function kindOf(uint256) view returns (uint8)",
  "function geometryOf(uint256) view returns (bytes32)",
  "event BuildMinted(uint256 indexed tokenId,address indexed creator,uint256 mass,bytes32 indexed geometryHash,string tokenURI)",
];

const BLOX_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address,uint256) returns (bool)",
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
];

const LICENSE_REGISTRY_ABI = [
  "function licenseIdForBuild(uint256) view returns (uint256)",
  "function quote(uint256,uint256) view returns (uint256)",
  "function mintLicenseForBuild(uint256,uint256) payable",
  "function registerBuild(uint256,bytes32)",
];

const LICENSE_NFT_ABI = [
  "function setApprovalForAll(address,bool)",
  "function isApprovedForAll(address,address) view returns (bool)",
];

const DISTRIBUTOR_ABI = [
  "function ethOwed(address) view returns (uint256)",
  "function bwScore(uint256) view returns (int256)",
  "function uniqueUsers(uint256) view returns (uint256)",
  "function uses(uint256) view returns (uint256)",
];

function parseArgs() {
  const args = process.argv.slice(2);
  const opts = {
    rpc: process.env.RPC_URL || "http://127.0.0.1:8545",
    csv: process.env.BW_CSV || DEFAULT_CSV,
    contracts: process.env.CONTRACTS_JSON || DEFAULT_CONTRACTS,
    outDir: process.env.OUT_DIR || path.resolve(process.cwd(), "data", "bw-runs"),
    runId: process.env.RUN_ID || `bw-${Date.now()}`,
    rewardsMints: Number(process.env.REWARD_MINTS || "10"),
  };

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--rpc") opts.rpc = args[++i];
    else if (a === "--csv") opts.csv = args[++i];
    else if (a === "--contracts") opts.contracts = args[++i];
    else if (a === "--out") opts.outDir = args[++i];
    else if (a === "--run-id") opts.runId = args[++i];
    else if (a === "--rewards-mints") opts.rewardsMints = Number(args[++i]);
  }
  return opts;
}

function readCsv(filePath) {
  const text = fs.readFileSync(filePath, "utf8").replace(/\r/g, "").trim();
  const lines = text.split("\n");
  const header = lines[0].split(",").map((s) => s.trim());
  return lines.slice(1).map((line) => {
    const cols = line.split(",").map((s) => s.trim());
    const row = Object.fromEntries(header.map((h, i) => [h, cols[i] ?? ""]));
    return {
      scenarioId: Number(row.scenario_id),
      bloxUsed: Number(row.blox_used),
      uniqueComponents: Math.max(1, Math.min(20, Math.floor(Number(row.unique_components) || 1))),
      daysSinceMint: Number(row.days_since_mint),
      bwTarget: Number(row.bw_0_100),
    };
  });
}

function toHash(label) {
  return ethers.keccak256(ethers.toUtf8Bytes(label));
}

function parseBuildMinted(receipt, buildNft) {
  for (const log of receipt.logs) {
    try {
      const parsed = buildNft.interface.parseLog(log);
      if (parsed?.name === "BuildMinted") return Number(parsed.args.tokenId);
    } catch {
      // ignore
    }
  }
  throw new Error("BuildMinted event not found");
}

async function ensureBloxAndApprovals({
  blox,
  licenseNft,
  buildNftAddress,
  ownerSigner,
  ownerAddress,
  funderSigner,
  requiredBlox,
}) {
  const allowance = await blox.allowance(ownerAddress, buildNftAddress);
  if (allowance < requiredBlox) {
    const tx = await blox.connect(ownerSigner).approve(buildNftAddress, ethers.MaxUint256);
    await tx.wait();
  }

  const approved = await licenseNft.isApprovedForAll(ownerAddress, buildNftAddress);
  if (!approved) {
    const tx = await licenseNft.connect(ownerSigner).setApprovalForAll(buildNftAddress, true);
    await tx.wait();
  }

  const bal = await blox.balanceOf(ownerAddress);
  if (bal < requiredBlox) {
    const needed = requiredBlox - bal + 1_000n * BLOX_UNIT;
    const tx = await blox.connect(funderSigner).transfer(ownerAddress, needed);
    await tx.wait();
  }
}

async function ensureLicenseBalance(registry, ownerSigner, buildId, qty) {
  const price = await registry.quote(buildId, qty);
  const tx = await registry.connect(ownerSigner).mintLicenseForBuild(buildId, qty, { value: price });
  await tx.wait();
  return price;
}

async function ensureRegistered(registry, buildNft, signer, buildId) {
  const existing = await registry.licenseIdForBuild(buildId);
  if (existing > 0n) return existing;
  const gh = await buildNft.geometryOf(buildId);
  const tx = await registry.connect(signer).registerBuild(buildId, gh);
  await tx.wait();
  return await registry.licenseIdForBuild(buildId);
}

async function findComponentPool(buildNft, registry, target = 24) {
  const nextId = Number(await buildNft.nextTokenId());
  const ids = [];
  for (let id = 1; id < nextId && ids.length < target; id++) {
    const exists = await buildNft.exists(id).catch(() => false);
    if (!exists) continue;
    const licenseId = await registry.licenseIdForBuild(id);
    if (licenseId > 0n) ids.push(id);
  }
  if (ids.length === 0) {
    throw new Error("No registered component builds found. Register at least one component first.");
  }
  return ids;
}

function formatEth(wei) {
  return Number(ethers.formatEther(wei));
}

async function main() {
  const opts = parseArgs();
  const provider = new ethers.JsonRpcProvider(opts.rpc);
  await provider.getBlockNumber();

  const contracts = JSON.parse(fs.readFileSync(opts.contracts, "utf8"));
  const scenarios = readCsv(opts.csv);
  if (scenarios.length === 0) throw new Error("No BW scenarios found in CSV");

  const funder = await provider.getSigner(0);
  const owners = [await provider.getSigner(1), await provider.getSigner(2), await provider.getSigner(3), await provider.getSigner(4)];
  const consumer = await provider.getSigner(5);

  const blox = new ethers.Contract(contracts.blox, BLOX_ABI, provider);
  const buildNft = new ethers.Contract(contracts.buildNFT, BUILD_NFT_ABI, provider);
  const registry = new ethers.Contract(contracts.licenseRegistry, LICENSE_REGISTRY_ABI, provider);
  const licenseNft = new ethers.Contract(contracts.licenseNFT, LICENSE_NFT_ABI, provider);
  const distributor = new ethers.Contract(contracts.distributor, DISTRIBUTOR_ABI, provider);

  const componentPool = await findComponentPool(buildNft, registry);
  const runDir = path.join(opts.outDir, opts.runId);
  fs.mkdirSync(runDir, { recursive: true });

  const mintedScenarios = [];
  const rewardsMints = [];
  const fees = {
    scenarioLicenseSpendEth: 0,
    scenarioMintFeeEth: 0,
    rewardsLicenseSpendEth: 0,
    rewardsMintFeeEth: 0,
  };

  let cursor = 0;
  for (const scenario of scenarios) {
    const owner = owners[(scenario.scenarioId - 1) % owners.length];
    const ownerAddr = await owner.getAddress();
    const mass = BigInt(Math.max(1, Math.floor(scenario.bloxUsed)));
    const componentCount = Math.min(scenario.uniqueComponents, componentPool.length);
    const componentIds = componentPool.slice(cursor, cursor + componentCount);
    cursor = (cursor + 3) % Math.max(1, componentPool.length - componentCount + 1);
    const counts = componentIds.map(() => 1n);

    await ensureBloxAndApprovals({
      blox,
      licenseNft,
      buildNftAddress: contracts.buildNFT,
      ownerSigner: owner,
      ownerAddress: ownerAddr,
      funderSigner: funder,
      requiredBlox: mass + 5_000n * BLOX_UNIT,
    });

    for (const cId of componentIds) {
      const spend = await ensureLicenseBalance(registry, owner, BigInt(cId), 1n);
      fees.scenarioLicenseSpendEth += formatEth(spend);
    }

    const gh = toHash(`bw-scenario-${opts.runId}-${scenario.scenarioId}-${Date.now()}`);
    const tx = await buildNft.connect(owner).mint(
      gh,
      mass,
      "",
      componentIds.map((v) => BigInt(v)),
      counts,
      1,
      0,
      0,
      1,
      { value: MINT_FEE, gasLimit: GAS_LIMIT },
    );
    const receipt = await tx.wait();
    const tokenId = parseBuildMinted(receipt, buildNft);
    fees.scenarioMintFeeEth += formatEth(MINT_FEE);

    mintedScenarios.push({
      scenarioId: scenario.scenarioId,
      owner: ownerAddr,
      tokenId,
      mass: mass.toString(),
      uniqueComponents: componentCount,
      componentIds: componentIds.join("|"),
      targetBw: scenario.bwTarget,
      gasUsed: receipt.gasUsed.toString(),
      txHash: tx.hash,
    });

    await ensureRegistered(registry, buildNft, owner, BigInt(tokenId));
  }

  await ensureBloxAndApprovals({
    blox,
    licenseNft,
    buildNftAddress: contracts.buildNFT,
    ownerSigner: consumer,
    ownerAddress: await consumer.getAddress(),
    funderSigner: funder,
    requiredBlox: 20_000n * BLOX_UNIT,
  });

  const mintedIds = mintedScenarios.map((s) => s.tokenId);
  for (let i = 0; i < opts.rewardsMints; i++) {
    const selected = [mintedIds[i % mintedIds.length], mintedIds[(i + 7) % mintedIds.length], mintedIds[(i + 13) % mintedIds.length]]
      .sort((a, b) => a - b);
    for (const id of selected) {
      const spend = await ensureLicenseBalance(registry, consumer, BigInt(id), 1n);
      fees.rewardsLicenseSpendEth += formatEth(spend);
    }
    const gh = toHash(`bw-reward-${opts.runId}-${i}-${Date.now()}`);
    const tx = await buildNft.connect(consumer).mint(
      gh,
      500n,
      "",
      selected.map((v) => BigInt(v)),
      [1n, 1n, 1n],
      1,
      0,
      0,
      1,
      { value: MINT_FEE, gasLimit: GAS_LIMIT },
    );
    const receipt = await tx.wait();
    const tokenId = parseBuildMinted(receipt, buildNft);
    fees.rewardsMintFeeEth += formatEth(MINT_FEE);
    rewardsMints.push({
      iteration: i + 1,
      tokenId,
      components: selected.join("|"),
      gasUsed: receipt.gasUsed.toString(),
      txHash: tx.hash,
    });
  }

  const ownerRewards = [];
  for (const owner of owners) {
    const addr = await owner.getAddress();
    const owed = await distributor.ethOwed(addr);
    ownerRewards.push({ owner: addr, ethOwed: ethers.formatEther(owed) });
  }
  const treasuryOwed = await distributor.ethOwed(await (new ethers.Contract(contracts.buildNFT, ["function protocolTreasury() view returns (address)"], provider)).protocolTreasury());

  const summary = {
    runId: opts.runId,
    rpc: opts.rpc,
    contracts,
    scenariosMinted: mintedScenarios.length,
    rewardMints: rewardsMints.length,
    fees,
    ownerRewards,
    protocolTreasuryEthOwed: ethers.formatEther(treasuryOwed),
  };

  fs.writeFileSync(path.join(runDir, "summary.json"), JSON.stringify(summary, null, 2));
  fs.writeFileSync(path.join(runDir, "minted-scenarios.json"), JSON.stringify(mintedScenarios, null, 2));
  fs.writeFileSync(path.join(runDir, "rewards-mints.json"), JSON.stringify(rewardsMints, null, 2));

  const csvRows = [
    "scenario_id,owner,token_id,mass,unique_components,component_ids,target_bw,gas_used,tx_hash",
    ...mintedScenarios.map((r) =>
      [r.scenarioId, r.owner, r.tokenId, r.mass, r.uniqueComponents, r.componentIds, r.targetBw, r.gasUsed, r.txHash].join(","),
    ),
  ];
  fs.writeFileSync(path.join(runDir, "minted-scenarios.csv"), `${csvRows.join("\n")}\n`);

  console.log(JSON.stringify(summary, null, 2));
  console.log(`Outputs written to: ${runDir}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
