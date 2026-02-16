#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    ids: [],
    outDir: "metadata",
    base: "ipfs://CID",
    imageBase: "ipns://IMAGES_IPNS",
    dataPath: "",
    onchain: false,
    rpcUrl: process.env.BASE_SEPOLIA_RPC_URL || "",
    buildNft: process.env.BUILDNFT_ADDRESS || ""
  };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--ids") {
      out.ids = args[++i]
        .split(",")
        .map((v) => Number(v.trim()))
        .filter((v) => Number.isFinite(v) && v >= 0);
    } else if (a === "--out") {
      out.outDir = args[++i];
    } else if (a === "--base") {
      out.base = args[++i];
    } else if (a === "--image-base") {
      out.imageBase = args[++i];
    } else if (a === "--data") {
      out.dataPath = args[++i];
    } else if (a === "--onchain") {
      out.onchain = true;
    } else if (a === "--rpc") {
      out.rpcUrl = args[++i];
    } else if (a === "--buildnft") {
      out.buildNft = args[++i];
    }
  }
  return out;
}

function loadData(dataPath) {
  if (!dataPath) return {};
  const raw = fs.readFileSync(dataPath, "utf8");
  return JSON.parse(raw);
}

function buildMetadata(id, base, imageBase, data) {
  const defaults = {
    name: `ETHBLOX #${id}`,
    description: "ETHBLOX build/brick",
    image: `${imageBase}/${id}.png`,
    external_url: "https://ethblox.art",
    geometryHash: "0x",
    kind: 1,
    mass: 1,
    density: 1,
    specKey: "",
    componentsHash: ""
  };
  const merged = { ...defaults, ...(data[id] || {}) };
  return {
    name: merged.name,
    description: merged.description,
    image: merged.image,
    external_url: merged.external_url,
    attributes: [
      { trait_type: "kind", value: merged.kind },
      { trait_type: "mass", value: merged.mass },
      { trait_type: "density", value: merged.density },
      { trait_type: "geometryHash", value: merged.geometryHash },
      { trait_type: "specKey", value: merged.specKey },
      { trait_type: "componentsHash", value: merged.componentsHash }
    ]
  };
}

function castCall(buildNft, rpcUrl, sig, arg) {
  const cmd = [
    "cast",
    "call",
    buildNft,
    `"${sig}"`,
    String(arg),
    "--rpc-url",
    rpcUrl
  ].join(" ");
  try {
    const out = execSync(cmd, { encoding: "utf8" }).trim();
    return out.replace(/^\"|\"$/g, "");
  } catch {
    return null;
  }
}

function loadOnchainData(ids, buildNft, rpcUrl) {
  if (!buildNft || !rpcUrl) return {};
  const data = {};
  for (const id of ids) {
    const kind = castCall(buildNft, rpcUrl, "kindOf(uint256)(uint8)", id);
    const mass = castCall(buildNft, rpcUrl, "massOf(uint256)(uint256)", id);
    const density = castCall(buildNft, rpcUrl, "densityOf(uint256)(uint16)", id);
    const geometryHash = castCall(buildNft, rpcUrl, "geometryOf(uint256)(bytes32)", id);
    const specKey = castCall(buildNft, rpcUrl, "brickSpecKeyOf(uint256)(bytes32)", id);
    data[id] = {
      ...(kind !== null ? { kind: Number(kind) } : {}),
      ...(mass !== null ? { mass: Number(mass) } : {}),
      ...(density !== null ? { density: Number(density) } : {}),
      ...(geometryHash !== null ? { geometryHash } : {}),
      ...(specKey !== null ? { specKey } : {})
    };
  }
  return data;
}

function main() {
  const { ids, outDir, base, imageBase, dataPath, onchain, rpcUrl, buildNft } = parseArgs();
  if (!ids.length) {
    console.error("Usage: node scripts/generate-metadata.js --ids 1,2,3 [--out metadata] [--base ipfs://CID] [--image-base ipns://IMAGES_IPNS] [--data data.json] [--onchain] [--rpc RPC_URL] [--buildnft ADDRESS]");
    process.exit(1);
  }

  const data = loadData(dataPath);
  const chainData = onchain ? loadOnchainData(ids, buildNft, rpcUrl) : {};
  const mergedData = { ...data, ...chainData };
  fs.mkdirSync(outDir, { recursive: true });

  for (const id of ids) {
    const json = buildMetadata(id, base, imageBase, mergedData);
    const outPath = path.join(outDir, `${id}.json`);
    fs.writeFileSync(outPath, JSON.stringify(json, null, 2));
    console.log(`Wrote ${outPath}`);
  }
}

main();
