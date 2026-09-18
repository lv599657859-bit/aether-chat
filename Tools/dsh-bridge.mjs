#!/usr/bin/env node
/**
 * 灵犀 · DSH 远程桥接（方案 C）
 * ================================================================
 * 跑在电脑上的一个小 HTTP 服务。手机上的灵犀通过局域网连过来，
 * 就能把任务交给这台电脑上完整的 DSH —— 联网、读写文件、跑命令、
 * 开子代理、用技能，全都拿得到。
 *
 * 它同时也是一个**安全边界**：能力是白名单的，默认只开最温和的三项。
 *
 * 用法：
 *   node Tools/dsh-bridge.mjs
 *   node Tools/dsh-bridge.mjs --port 8787 --allow ask,read,ls
 *
 * 零依赖，只需要 Node 18+（用到了 fetch 之外的东西都来自标准库）。
 */

import http from "node:http";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";

// ── 参数 ────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
function flag(name, fallback) {
  const i = argv.indexOf("--" + name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
}

const PORT = Number(flag("port", "8787"));
/** 默认只开这三项。exec 与 write 必须显式打开 —— 它们能让手机操作你的电脑。 */
const DEFAULT_CAPABILITIES = ["ask", "read", "ls"];
const ALL_CAPABILITIES = ["ask", "read", "ls", "exec", "write"];
const CAPABILITIES = (flag("allow", DEFAULT_CAPABILITIES.join(",")))
  .split(",")
  .map((s) => s.trim())
  .filter((s) => ALL_CAPABILITIES.includes(s));

/** 读写能碰的目录。默认是当前工作目录，以及 DSH 的家目录。 */
const ROOTS = (flag("roots", [process.cwd(), process.env.DSH_HOME || ""].filter(Boolean).join(path.delimiter)))
  .split(path.delimiter)
  .map((p) => path.resolve(p))
  .filter(Boolean);

const DSH_COMMAND = flag("dsh", "dsh");
const TOKEN_FILE = path.join(os.homedir(), ".aether-dsh-bridge.json");

// ── 配对令牌 ────────────────────────────────────────────────────
// 默认持久化，免得每次重启都要在手机上重填一遍。

let token = flag("token", "");
if (!token) {
  try {
    const saved = JSON.parse(fs.readFileSync(TOKEN_FILE, "utf8"));
    if (saved.token) token = saved.token;
  } catch {
    /* 第一次跑，没有文件 */
  }
}
if (!token) {
  token = crypto.randomBytes(16).toString("hex");
  try {
    fs.writeFileSync(TOKEN_FILE, JSON.stringify({ token, port: PORT }, null, 2), { mode: 0o600 });
  } catch {
    /* 写不了就算了，令牌只在本次运行有效 */
  }
}

// ── 工具函数 ────────────────────────────────────────────────────

function lanAddresses() {
  const result = [];
  for (const [name, list] of Object.entries(os.networkInterfaces())) {
    for (const entry of list || []) {
      if (entry.family === "IPv4" && !entry.internal) {
        result.push({ name, address: entry.address });
      }
    }
  }
  return result;
}

function insideRoots(target) {
  const resolved = path.resolve(target);
  return ROOTS.some((root) => resolved === root || resolved.startsWith(root + path.sep));
}

function run(command, args, { cwd, timeout = 180000, shell = false } = {}) {
  return new Promise((resolve) => {
    const started = Date.now();
    let stdout = "";
    let stderr = "";
    let finished = false;

    const child = spawn(command, args, {
      cwd: cwd && fs.existsSync(cwd) ? cwd : process.cwd(),
      shell,
      windowsHide: true,
    });

    const timer = setTimeout(() => {
      if (!finished) {
        finished = true;
        try { child.kill("SIGKILL"); } catch { /* ignore */ }
        resolve({ ok: false, stdout, stderr: stderr + "\n[超时被终止]", code: -1, ms: Date.now() - started });
      }
    }, timeout);

    child.stdout.on("data", (d) => { if (stdout.length < 400000) stdout += d.toString(); });
    child.stderr.on("data", (d) => { if (stderr.length < 100000) stderr += d.toString(); });
    child.on("error", (error) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolve({ ok: false, stdout, stderr: String(error.message || error), code: -1, ms: Date.now() - started });
    });
    child.on("close", (code) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      resolve({ ok: code === 0, stdout, stderr, code, ms: Date.now() - started });
    });
  });
}

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(payload),
  });
  res.end(payload);
}

function readBody(req) {
  return new Promise((resolve) => {
    let raw = "";
    req.on("data", (chunk) => {
      raw += chunk;
      if (raw.length > 8_000_000) req.destroy();
    });
    req.on("end", () => {
      try { resolve(JSON.parse(raw || "{}")); } catch { resolve({}); }
    });
  });
}

// ── 路由 ────────────────────────────────────────────────────────

async function handle(action, body) {
  switch (action) {
    case "status":
      return {
        ok: true,
        name: "Aether DSH Bridge",
        version: "1.0.0",
        host: os.hostname(),
        platform: process.platform,
        capabilities: CAPABILITIES,
        roots: ROOTS,
        dsh: DSH_COMMAND,
      };

    case "ask": {
      const prompt = String(body.prompt || "").trim();
      if (!prompt) return { ok: false, error: "缺少 prompt" };
      // 一问一答：dsh 跑完就退出，输出就是答案
      const result = await run(DSH_COMMAND, ["--profile", "headless", prompt], {
        timeout: Number(body.timeout) || 300000,
        shell: process.platform === "win32",
      });
      const output = (result.stdout || "").trim() || (result.stderr || "").trim();
      return { ok: result.ok, output, ms: result.ms, code: result.code };
    }

    case "exec": {
      const command = String(body.command || "").trim();
      if (!command) return { ok: false, error: "缺少 command" };
      const result = await run(command, [], {
        cwd: body.cwd ? String(body.cwd) : undefined,
        timeout: Number(body.timeout) || 120000,
        shell: true,
      });
      return { ok: result.ok, stdout: result.stdout, stderr: result.stderr, code: result.code, ms: result.ms };
    }

    case "read": {
      const target = String(body.path || "");
      if (!insideRoots(target)) return { ok: false, error: "这个路径不在允许范围内" };
      try {
        const content = fs.readFileSync(target, "utf8");
        return { ok: true, content: content.slice(0, 200000), truncated: content.length > 200000 };
      } catch (error) {
        return { ok: false, error: String(error.message || error) };
      }
    }

    case "write": {
      const target = String(body.path || "");
      if (!insideRoots(target)) return { ok: false, error: "这个路径不在允许范围内" };
      try {
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, String(body.content ?? ""), "utf8");
        return { ok: true, bytes: Buffer.byteLength(String(body.content ?? "")) };
      } catch (error) {
        return { ok: false, error: String(error.message || error) };
      }
    }

    case "ls": {
      const target = String(body.path || ROOTS[0] || ".");
      if (!insideRoots(target)) return { ok: false, error: "这个路径不在允许范围内" };
      try {
        const entries = fs.readdirSync(target, { withFileTypes: true }).slice(0, 300).map((entry) => ({
          name: entry.name,
          dir: entry.isDirectory(),
          size: entry.isDirectory() ? null : (() => {
            try { return fs.statSync(path.join(target, entry.name)).size; } catch { return null; }
          })(),
        }));
        return { ok: true, path: path.resolve(target), entries };
      } catch (error) {
        return { ok: false, error: String(error.message || error) };
      }
    }

    default:
      return { ok: false, error: "未知操作：" + action };
  }
}

// ── 服务 ────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");

  if (req.method === "GET" && url.pathname === "/") {
    return json(res, 200, { ok: true, hint: "POST /status /ask /exec /read /write /ls，带上 Authorization: Bearer <token>" });
  }

  const header = req.headers["authorization"] || "";
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!presented || presented !== token) {
    return json(res, 401, { ok: false, error: "令牌不对" });
  }

  const action = url.pathname.replace(/^\//, "") || "status";
  if (!ALL_CAPABILITIES.includes(action)) {
    return json(res, 404, { ok: false, error: "没有这个操作" });
  }
  if (!CAPABILITIES.includes(action)) {
    return json(res, 403, { ok: false, error: `操作 ${action} 没有开放。启动时用 --allow 打开它。` });
  }

  const body = req.method === "POST" ? await readBody(req) : {};
  try {
    const result = await handle(action, body);
    json(res, result.ok ? 200 : 500, result);
  } catch (error) {
    json(res, 500, { ok: false, error: String(error.message || error) });
  }
});

server.listen(PORT, "0.0.0.0", () => {
  const addresses = lanAddresses();
  const line = "─".repeat(58);
  console.log(line);
  console.log("  灵犀 · DSH 桥接已启动");
  console.log(line);
  console.log("  在手机上填这些：");
  console.log("");
  for (const item of addresses) {
    console.log(`    主机  ${item.address}`);
  }
  if (addresses.length === 0) console.log("    主机  （没有找到局域网地址）");
  console.log(`    端口  ${PORT}`);
  console.log(`    令牌  ${token}`);
  console.log("");
  console.log(`  已开放的能力：${CAPABILITIES.join("、")}`);
  console.log(`  未开放：${ALL_CAPABILITIES.filter((c) => !CAPABILITIES.includes(c)).join("、") || "（全部开放）"}`);
  console.log(`  可读写的目录：${ROOTS.join("  |  ")}`);
  console.log("");
  console.log("  要开放跑命令和写文件，重启时加：");
  console.log("    node Tools/dsh-bridge.mjs --allow ask,read,ls,exec,write");
  console.log(line);
  console.log("  手机和电脑要在同一个 Wi-Fi 下。Ctrl+C 停止。");
  console.log("");
});
