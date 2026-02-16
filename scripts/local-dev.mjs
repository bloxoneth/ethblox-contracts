import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";

const cmd = (process.argv[2] || "up").toLowerCase();
const RPC_URL = process.env.LOCAL_RPC_URL || "http://127.0.0.1:8545";
const CHAIN_ID = 31337;
const ANVIL_HOST = "127.0.0.1";
const ANVIL_PORT = "8545";
const ANVIL_STATE_PATH = path.resolve(process.cwd(), ".anvil/state.json");
const ANVIL_PID_PATH = path.resolve(process.cwd(), ".anvil/anvil.pid");
const ANVIL_LOG_PATH = path.resolve(process.cwd(), ".anvil/anvil.log");
const MANIFEST_PATH = path.resolve(process.cwd(), "deployments/anvil.contracts.json");
const BROADCAST_PATH = path.resolve(process.cwd(), "broadcast/Deploy.s.sol/31337/run-latest.json");
const ANVIL_PK = process.env.ANVIL_PRIVATE_KEY
  || "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const ANVIL_DEPLOYER = process.env.ANVIL_DEPLOYER
  || "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

function ensureDirs() {
  fs.mkdirSync(path.dirname(ANVIL_STATE_PATH), { recursive: true });
  fs.mkdirSync(path.dirname(MANIFEST_PATH), { recursive: true });
}

async function rpc(method, params = []) {
  const res = await fetch(RPC_URL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  if (!res.ok) throw new Error(`RPC HTTP ${res.status}`);
  const json = await res.json();
  if (json.error) throw new Error(`RPC ${method} error: ${json.error.message}`);
  return json.result;
}

async function isNodeUp() {
  try {
    const id = await rpc("eth_chainId");
    return Number.parseInt(id, 16) === CHAIN_ID;
  } catch {
    return false;
  }
}

async function waitForNode(timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await isNodeUp()) return;
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error("Anvil did not become ready in time");
}

function startAnvil() {
  ensureDirs();
  const shell = [
    "nohup anvil",
    `--host ${ANVIL_HOST}`,
    `--port ${ANVIL_PORT}`,
    `--chain-id ${CHAIN_ID}`,
    `--state ${ANVIL_STATE_PATH}`,
    "--state-interval 5",
    `>${ANVIL_LOG_PATH} 2>&1 &`,
    "echo $!",
  ].join(" ");
  const out = run("/bin/zsh", ["-lc", shell], { cwd: process.cwd() }).trim();
  const pid = Number.parseInt(out.split(/\s+/).at(-1) || "", 10);
  if (!Number.isFinite(pid)) {
    throw new Error(`Failed to parse Anvil PID from output: ${out}`);
  }
  fs.writeFileSync(ANVIL_PID_PATH, `${pid}\n`);
}

function stopAnvil() {
  if (!fs.existsSync(ANVIL_PID_PATH)) {
    console.log("No Anvil PID file found.");
    return;
  }
  const pid = Number.parseInt(fs.readFileSync(ANVIL_PID_PATH, "utf8").trim(), 10);
  if (!Number.isFinite(pid)) {
    fs.unlinkSync(ANVIL_PID_PATH);
    console.log("Invalid PID file removed.");
    return;
  }
  try {
    process.kill(pid, "SIGTERM");
    fs.unlinkSync(ANVIL_PID_PATH);
    console.log(`Stopped Anvil pid=${pid}`);
  } catch (err) {
    console.error(`Failed to stop pid=${pid}: ${err.message}`);
  }
}

function readManifest() {
  if (!fs.existsSync(MANIFEST_PATH)) return null;
  try {
    return JSON.parse(fs.readFileSync(MANIFEST_PATH, "utf8"));
  } catch {
    return null;
  }
}

async function codeExists(address) {
  if (!address) return false;
  const code = await rpc("eth_getCode", [address, "latest"]);
  return typeof code === "string" && code !== "0x";
}

async function isManifestLive(manifest) {
  if (!manifest) return false;
  return (
    (await codeExists(manifest.blox))
    && (await codeExists(manifest.buildNFT))
    && (await codeExists(manifest.distributor))
    && (await codeExists(manifest.licenseNFT))
    && (await codeExists(manifest.licenseRegistry))
  );
}

function run(cmdName, args, opts = {}) {
  const out = spawnSync(cmdName, args, {
    stdio: "pipe",
    encoding: "utf8",
    ...opts,
  });
  if (out.status !== 0) {
    const stderr = out.stderr?.trim() || "";
    const stdout = out.stdout?.trim() || "";
    throw new Error(`${cmdName} failed (${out.status})\n${stderr}\n${stdout}`);
  }
  return out.stdout;
}

function deployBlox() {
  const shell = [
    "BYTECODE=$(forge inspect src/BLOX.sol:BLOX bytecode)",
    `ARGS=$(cast abi-encode "constructor(address)" ${ANVIL_DEPLOYER})`,
    'DATA="${BYTECODE}${ARGS#0x}"',
    `cast send --rpc-url ${RPC_URL} --private-key ${ANVIL_PK} --create "$DATA"`,
  ].join("; ");
  const out = run("/bin/zsh", ["-lc", shell], { cwd: process.cwd() });
  const m = out.match(/contractAddress\s+([0-9a-fA-Fx]+)/);
  if (!m) throw new Error(`Could not parse BLOX contract address.\n${out}`);
  return m[1];
}

function deployProtocolStack(bloxAddress) {
  run(
    "forge",
    [
      "script",
      "script/Deploy.s.sol:Deploy",
      "--rpc-url",
      RPC_URL,
      "--broadcast",
      "--private-key",
      ANVIL_PK,
    ],
    {
      cwd: process.cwd(),
      env: {
        ...process.env,
        PRIVATE_KEY: ANVIL_PK,
        BLOX_ADDRESS: bloxAddress,
        LIQUIDITY_RECEIVER: ANVIL_DEPLOYER,
        PROTOCOL_TREASURY: ANVIL_DEPLOYER,
      },
    },
  );

  const runJson = JSON.parse(fs.readFileSync(BROADCAST_PATH, "utf8"));
  const byName = Object.fromEntries(
    (runJson.transactions || [])
      .filter((t) => t.contractName && t.contractAddress)
      .map((t) => [t.contractName, t.contractAddress]),
  );

  if (!byName.BuildNFT || !byName.LicenseRegistry || !byName.LicenseNFT || !byName.Distributor) {
    throw new Error("Failed to parse deployed protocol contracts from broadcast output");
  }

  return {
    distributor: byName.Distributor,
    licenseNFT: byName.LicenseNFT,
    licenseRegistry: byName.LicenseRegistry,
    buildNFT: byName.BuildNFT,
  };
}

function writeManifest({ blox, distributor, licenseNFT, licenseRegistry, buildNFT }) {
  const manifest = {
    rpcUrl: RPC_URL,
    chainId: CHAIN_ID,
    blox,
    distributor,
    licenseNFT,
    licenseRegistry,
    buildNFT,
    updatedAt: new Date().toISOString(),
  };
  fs.writeFileSync(MANIFEST_PATH, `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}

async function bootstrap() {
  const prior = readManifest();
  if (await isManifestLive(prior)) {
    console.log("Reusing existing local deployment:");
    console.log(JSON.stringify(prior, null, 2));
    return prior;
  }

  console.log("Deploying local BLOX + protocol stack...");
  const blox = deployBlox();
  const stack = deployProtocolStack(blox);
  const manifest = writeManifest({ blox, ...stack });
  console.log("Deployment complete:");
  console.log(JSON.stringify(manifest, null, 2));
  return manifest;
}

async function printStatus() {
  const up = await isNodeUp();
  const manifest = readManifest();
  const live = up ? await isManifestLive(manifest) : false;
  console.log(
    JSON.stringify(
      {
        rpcUrl: RPC_URL,
        anvilUp: up,
        chainId: up ? CHAIN_ID : null,
        manifestPath: MANIFEST_PATH,
        manifestExists: Boolean(manifest),
        deploymentLive: live,
      },
      null,
      2,
    ),
  );
}

async function main() {
  if (cmd === "stop") {
    stopAnvil();
    return;
  }

  if (cmd === "status") {
    await printStatus();
    return;
  }

  if (!(await isNodeUp())) {
    console.log(`Starting Anvil with persisted state: ${ANVIL_STATE_PATH}`);
    startAnvil();
    await waitForNode();
  } else {
    console.log("Anvil already running; using existing node.");
  }

  if (cmd === "up" || cmd === "bootstrap") {
    await bootstrap();
    return;
  }

  throw new Error(`Unknown command: ${cmd}. Use up|bootstrap|status|stop`);
}

main().catch((err) => {
  console.error(err.message || err);
  process.exit(1);
});
