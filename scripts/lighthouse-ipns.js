#!/usr/bin/env node
/* eslint-disable no-console */
const fs = require("fs");
const path = require("path");

async function main() {
  const apiKey = process.env.IPNS_KEY;
  const ipnsNameEnv = process.env.IPNS_NAME || "";
  const targetDir = process.env.METADATA_DIR || "metadata";

  if (!apiKey) {
    console.error("Missing IPNS_KEY in environment.");
    process.exit(1);
  }

  const fullPath = path.resolve(process.cwd(), targetDir);
  if (!fs.existsSync(fullPath)) {
    console.error(`Metadata folder not found: ${fullPath}`);
    process.exit(1);
  }

  const lighthouse = (await import("@lighthouse-web3/sdk")).default;

  console.log(`Uploading ${fullPath} to Lighthouse...`);
  const uploadRes = await lighthouse.upload(fullPath, apiKey);
  const cid = uploadRes?.data?.Hash;
  if (!cid) {
    console.error("Upload failed: missing CID in response.");
    process.exit(1);
  }

  let ipnsName = ipnsNameEnv;
  if (!ipnsName) {
    const keyRes = await lighthouse.generateKey(apiKey);
    ipnsName = keyRes?.data?.ipnsName;
    if (!ipnsName) {
      console.error("Failed to generate IPNS key.");
      process.exit(1);
    }
    fs.writeFileSync(
      "ipns.json",
      JSON.stringify({ ipnsName }, null, 2)
    );
    console.log("Generated IPNS key. Saved ipns.json with ipnsName.");
  }

  console.log(`Publishing CID ${cid} to IPNS ${ipnsName}...`);
  await lighthouse.publishRecord(cid, ipnsName, apiKey);

  console.log("Done.");
  console.log(`CID: ${cid}`);
  console.log(`Base URI: ipns://${ipnsName}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
