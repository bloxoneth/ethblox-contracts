#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const path = require("path");

function parseArgs() {
  const args = process.argv.slice(2);
  const out = {
    ids: [],
    outDir: "metadata",
    base: "ipfs://CID",
    imageBase: "ipns://IMAGES_IPNS",
    dataPath: ""
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
    image: `${imageBase}/images/${id}.png`,
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

function main() {
  const { ids, outDir, base, imageBase, dataPath } = parseArgs();
  if (!ids.length) {
    console.error("Usage: node scripts/generate-metadata.js --ids 1,2,3 [--out metadata] [--base ipfs://CID] [--image-base ipns://IMAGES_IPNS] [--data data.json]");
    process.exit(1);
  }

  const data = loadData(dataPath);
  fs.mkdirSync(outDir, { recursive: true });

  for (const id of ids) {
    const json = buildMetadata(id, base, imageBase, data);
    const outPath = path.join(outDir, `${id}.json`);
    fs.writeFileSync(outPath, JSON.stringify(json, null, 2));
    console.log(`Wrote ${outPath}`);
  }
}

main();
