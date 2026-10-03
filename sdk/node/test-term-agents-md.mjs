#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import xtermHeadless from "@xterm/headless";
import { createFxTerminal, supportsJspi, xtermAdapter } from "../node.js";

const { Terminal } = xtermHeadless;
const scriptDir = fileURLToPath(new URL(".", import.meta.url));
const wasm = await readFile(resolve(process.argv[2] || resolve(scriptDir, "../../zig-out/bin/fx-term.wasm")));
if (!supportsJspi()) process.exit(2);

const requestDecoder = new TextDecoder();
const catalog = {
  object: "list",
  data: [{ id: "test/agents-model", type: "language", released: 1, tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }],
};
const info = {
  version: 1,
  root: "/workspace",
  cwd: "/workspace",
  home: "/home/visitor",
  gitAvailable: false,
  ephemeral: true,
};

function textResponse(value) {
  return new Response(
    `data: ${JSON.stringify({ type: "text-delta", delta: value })}\n\n` +
      `data: ${JSON.stringify({ type: "finish", finishReason: { unified: "stop", raw: "stop" } })}\n\ndata: [DONE]\n\n`,
    { headers: { "content-type": "text/event-stream" } },
  );
}

function promptText(body) {
  return (body.prompt || [])
    .filter((message) => message.role === "system")
    .map((message) => (typeof message.content === "string" ? message.content : JSON.stringify(message.content)))
    .join("\n");
}

// Runs one prompt in a fresh terminal and returns the first model request's system text.
async function firstRequestWith(workspace, label) {
  const terminal = new Terminal({ cols: 100, rows: 30, allowProposedApi: true, scrollback: 2000 });
  const config = new Map([["model", "test/agents-model"], ["mode", "code"]]);
  const requests = [];
  let stderr = "";
  const stderrDecoder = new TextDecoder();
  const runtime = await createFxTerminal({
    backend: "wasm",
    wasm,
    terminal: xtermAdapter(terminal),
    env: { AI_GATEWAY_API_KEY: "agents-md-key" },
    async fetch(_url, init = {}) {
      if ((init.method || "GET") === "GET") {
        return new Response(JSON.stringify(catalog), { status: 200, headers: { "content-type": "application/json" } });
      }
      requests.push(JSON.parse(requestDecoder.decode(init.body)));
      return textResponse(`${label} answered`);
    },
    configStore: { get(id) { return config.get(id) ?? null; }, set(id, value) { config.set(id, value); } },
    stderr(chunk) { stderr += stderrDecoder.decode(chunk, { stream: true }); },
    workspace,
  });
  const flush = () => new Promise((resolveFlush) => terminal.write("", resolveFlush));
  const grid = () => {
    const lines = [];
    for (let row = 0; row < terminal.buffer.active.length; row += 1) {
      lines.push(terminal.buffer.active.getLine(row)?.translateToString(true) ?? "");
    }
    return lines.join("\n");
  };
  const waitFor = async (predicate, what) => {
    const deadline = performance.now() + 5000;
    while (!predicate()) {
      await flush();
      if (performance.now() >= deadline) throw new Error(`${label}: timed out waiting for ${what}:\n${stderr}\n${grid()}`);
      await new Promise((resolveWait) => setTimeout(resolveWait, 10));
    }
  };
  try {
    await waitFor(() => grid().includes("𝒇x"), "startup");
    runtime.write(`${label} prompt\r`);
    await waitFor(() => grid().includes(`${label} answered`), "turn");
    runtime.write("/exit\r");
    const exitCode = await Promise.race([
      runtime.exited,
      new Promise((_, reject) => setTimeout(() => reject(new Error(`${label}: exit timeout`)), 5000)),
    ]);
    if (exitCode !== 0) throw new Error(`${label}: fx-term exited with ${exitCode}`);
  } finally {
    runtime.abort();
  }
  if (requests.length === 0) throw new Error(`${label}: no model request`);
  return promptText(requests[0]);
}

function expectIncludes(text, expected, label) {
  if (!text.includes(expected)) throw new Error(`${label}: model context omitted ${JSON.stringify(expected)}:\n${text}`);
}

function expectExcludes(text, unexpected, label) {
  if (text.includes(unexpected)) throw new Error(`${label}: model context unexpectedly included ${JSON.stringify(unexpected)}:\n${text}`);
}

const reads = [];
const readable = await firstRequestWith({
  info,
  permission: "allow-sandboxed",
  exec() { throw new Error("workspace.exec must not run while loading AGENTS.md"); },
  readFile({ path, signal }) {
    if (!(signal instanceof AbortSignal)) throw new Error("readFile did not receive an AbortSignal");
    reads.push(path);
    if (path === "/home/visitor/.fx/AGENTS.md") return "GLOBAL_RULE_SENTINEL\n";
    if (path === "/workspace/AGENTS.md") return new TextEncoder().encode("PROJECT_RULE_SENTINEL\n");
    return null;
  },
}, "readable");
expectIncludes(readable, "<project-instructions-guidance>", "readable");
expectIncludes(readable, "<global-rules from=\"/home/visitor/.fx/AGENTS.md\">\nGLOBAL_RULE_SENTINEL\n</global-rules>", "readable");
expectIncludes(readable, "<project-rules from=\"/workspace/AGENTS.md\">\nPROJECT_RULE_SENTINEL\n</project-rules>", "readable");
expectExcludes(readable, "host cannot read instruction files", "readable");
if (reads.join(",") !== "/home/visitor/.fx/AGENTS.md,/workspace/AGENTS.md") {
  throw new Error(`readable: unexpected readFile paths: ${reads.join(",")}`);
}

const unreadable = await firstRequestWith({
  info,
  permission: "allow-sandboxed",
  exec() { throw new Error("workspace.exec must not run while loading AGENTS.md"); },
}, "unreadable");
expectIncludes(unreadable, "<project-rules-omitted from=\"/workspace/AGENTS.md\" reason=\"host cannot read instruction files\" />", "unreadable");
expectExcludes(unreadable, "<project-rules from=", "unreadable");

const failing = await firstRequestWith({
  info,
  permission: "allow-sandboxed",
  exec() { throw new Error("workspace.exec must not run while loading AGENTS.md"); },
  readFile({ path }) {
    if (path === "/home/visitor/.fx/AGENTS.md") throw new Error("host read failed");
    return new Uint8Array([0x72, 0x75, 0xff, 0x6c, 0x65]);
  },
}, "failing");
expectIncludes(failing, "<project-rules-omitted from=\"/home/visitor/.fx/AGENTS.md\" reason=\"unreadable rule file\" />", "failing");
expectIncludes(failing, "<project-rules-omitted from=\"/workspace/AGENTS.md\" reason=\"unreadable rule file\" />", "failing");
expectExcludes(failing, "<global-rules", "failing");

console.log("headless AGENTS.md passed: host readFile delivers global and project rules, and missing access or unreadable files are reported to the model");
