#!/usr/bin/env node
'use strict';

/**
 * Read-only compatibility probe for Orca's private Runtime protocol.
 *
 * This intentionally lives outside the tax protocol implementation. It loads the
 * version-matched wire helpers shipped inside Orca.app so private protocol changes
 * are isolated to the future OrcaRuntimeAdapter.
 */

const fs = require('node:fs');
const path = require('node:path');

const DEFAULT_APP = '/Applications/Orca.app';
const DEFAULT_DURATION_MS = 5_000;
const CONTROL_STREAM_ID = 0;
const PROBE_STREAM_ID = 1;

function fail(message, code = 1) {
  process.stderr.write(`[tax-orca-probe] ${message}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const result = { command: argv[0] ?? 'inventory', durationMs: DEFAULT_DURATION_MS };
  for (let index = 1; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === '--terminal' && value) {
      result.terminal = value;
      index += 1;
    } else if (flag === '--pairing-code-file' && value) {
      result.pairingCodeFile = value;
      index += 1;
    } else if (flag === '--duration-ms' && value) {
      result.durationMs = Number(value);
      index += 1;
    } else if (flag === '--help' || flag === '-h') {
      result.help = true;
    } else {
      fail(`unknown or incomplete argument: ${flag}`, 2);
    }
  }
  if (!Number.isInteger(result.durationMs) || result.durationMs < 100 || result.durationMs > 300_000) {
    fail('--duration-ms must be an integer between 100 and 300000', 2);
  }
  return result;
}

function usage() {
  return `Usage:
  scripts/orca-runtime-probe.cjs inventory
  TAX_ORCA_PAIRING_CODE='<orca://pair?...>' scripts/orca-runtime-probe.cjs stream --terminal <handle> [--duration-ms 5000]
  scripts/orca-runtime-probe.cjs stream --terminal <handle> --pairing-code-file <0600-file>

Environment:
  ORCA_APP_PATH          Orca application path (default: /Applications/Orca.app)
  ORCA_USER_DATA_PATH    Runtime metadata directory (default: ~/Library/Application Support/Orca)
  TAX_ORCA_PAIRING_CODE  Pairing credential; prefer a protected file for persistent use
`;
}

function resolveOrcaModules() {
  const appPath = process.env.ORCA_APP_PATH || DEFAULT_APP;
  const root = path.join(appPath, 'Contents', 'Resources', 'app.asar.unpacked', 'out');
  const requireFrom = (relativePath) => {
    const modulePath = path.join(root, relativePath);
    if (!fs.existsSync(modulePath)) {
      fail(`Orca ${relativePath} is unavailable in ${appPath}; runtime is incompatible`);
    }
    return require(modulePath);
  };
  return {
    pairing: requireFrom('shared/pairing.js'),
    remoteClient: requireFrom('shared/remote-runtime-client.js'),
    streamProtocol: requireFrom('shared/terminal-stream-protocol.js'),
  };
}

function pairingCode(args) {
  if (args.pairingCodeFile) {
    const stat = fs.statSync(args.pairingCodeFile);
    if ((stat.mode & 0o077) !== 0) {
      fail('pairing code file must not be accessible by group or other users');
    }
    return fs.readFileSync(args.pairingCodeFile, 'utf8').trim();
  }
  return (process.env.TAX_ORCA_PAIRING_CODE || '').trim();
}

async function remoteCall(modules, pairing, method, params = {}) {
  const response = await modules.remoteClient.sendRemoteRuntimeRequest(pairing, method, params, 15_000);
  if (!response || response.ok !== true) {
    const detail = response?.error?.message || `${method} failed`;
    throw new Error(detail);
  }
  return response.result;
}

async function inventory(args, modules) {
  const code = pairingCode(args);
  if (code) {
    const pairing = modules.pairing.parsePairingCode(code);
    if (!pairing) fail('invalid Orca pairing code', 2);
    const [status, worktrees, terminals] = await Promise.all([
      remoteCall(modules, pairing, 'status.get'),
      remoteCall(modules, pairing, 'worktree.ps'),
      remoteCall(modules, pairing, 'terminal.list', { includeVisualLayouts: false }),
    ]);
    process.stdout.write(`${JSON.stringify({ status, worktrees, terminals }, null, 2)}\n`);
    return;
  }

  // The public CLI uses the same authenticated local Runtime RPC. Keeping this
  // fallback credential-free is useful for discovery, but live streaming below
  // deliberately requires Orca's E2EE WebSocket pairing transport.
  const { spawnSync } = require('node:child_process');
  const executable = process.env.ORCA_CLI_COMMAND || 'orca';
  const invoke = (command) => {
    const result = spawnSync(executable, [...command, '--json'], { encoding: 'utf8' });
    if (result.status !== 0) fail(result.stderr.trim() || `${command.join(' ')} failed`);
    try { return JSON.parse(result.stdout); } catch { fail(`invalid JSON from ${command.join(' ')}`); }
  };
  process.stdout.write(`${JSON.stringify({
    status: invoke(['status']),
    worktrees: invoke(['worktree', 'ps']),
    terminals: invoke(['terminal', 'list']),
  }, null, 2)}\n`);
}

async function stream(args, modules) {
  if (!args.terminal) fail('stream requires --terminal <handle>', 2);
  const code = pairingCode(args);
  if (!code) fail('stream requires TAX_ORCA_PAIRING_CODE or --pairing-code-file', 2);
  const pairing = modules.pairing.parsePairingCode(code);
  if (!pairing) fail('invalid Orca pairing code', 2);

  const protocol = modules.streamProtocol;
  const opcodes = protocol.TerminalStreamOpcode;
  let subscription;
  let snapshotChunks = [];
  let snapshotInfo = null;
  let ended = false;

  const send = (streamId, opcode, payload = new Uint8Array()) => subscription?.sendBinary(
    protocol.encodeTerminalStreamFrame({ opcode, streamId, seq: 0, payload }),
  );

  const close = () => {
    if (ended) return;
    ended = true;
    send(PROBE_STREAM_ID, opcodes.Unsubscribe);
    subscription?.close();
  };

  subscription = await modules.remoteClient.subscribeRemoteRuntimeRequest(
    pairing,
    'terminal.multiplex',
    {},
    15_000,
    {
      onResponse(response) {
        if (response?.ok !== true) {
          process.stderr.write(`[tax-orca-probe] stream RPC failed: ${response?.error?.message || 'unknown error'}\n`);
          close();
          return;
        }
        const event = response.result;
        if (event?.type === 'ready') {
          send(CONTROL_STREAM_ID, opcodes.Subscribe, protocol.encodeTerminalStreamJson({
            streamId: PROBE_STREAM_ID,
            terminal: args.terminal,
            client: { id: 'tax-orca-probe', type: 'desktop' },
            capabilities: { ackOutput: 1 },
          }));
        } else if (event?.type === 'error') {
          process.stderr.write(`[tax-orca-probe] ${event.message}\n`);
        } else if (event?.type === 'end' && event.streamId === PROBE_STREAM_ID) {
          close();
        }
      },
      onBinary(bytes) {
        const frame = protocol.decodeTerminalStreamFrame(bytes);
        if (!frame || frame.streamId !== PROBE_STREAM_ID) return;
        if (frame.opcode === opcodes.SnapshotStart) {
          snapshotInfo = protocol.decodeTerminalStreamJson(frame.payload) || {};
          snapshotChunks = [];
        } else if (frame.opcode === opcodes.SnapshotChunk) {
          snapshotChunks.push(Buffer.from(frame.payload));
        } else if (frame.opcode === opcodes.SnapshotEnd) {
          process.stderr.write(`[tax-orca-probe] snapshot ${snapshotInfo?.cols || 80}x${snapshotInfo?.rows || 24}\n`);
          process.stdout.write(Buffer.concat(snapshotChunks));
          snapshotChunks = [];
        } else if (frame.opcode === opcodes.Output || frame.opcode === opcodes.OutputSpan) {
          const output = frame.opcode === opcodes.OutputSpan
            ? protocol.decodeTerminalStreamJson(frame.payload)?.data || ''
            : protocol.decodeTerminalStreamText(frame.payload);
          process.stdout.write(output);
          send(PROBE_STREAM_ID, opcodes.Ack, protocol.encodeTerminalStreamJson({ bytes: frame.payload.byteLength }));
        } else if (frame.opcode === opcodes.Error) {
          process.stderr.write(`[tax-orca-probe] ${protocol.decodeTerminalStreamText(frame.payload)}\n`);
        }
      },
      onError(error) {
        process.stderr.write(`[tax-orca-probe] ${error.message}\n`);
        close();
      },
      onClose: close,
    },
  );

  await new Promise((resolve) => setTimeout(resolve, args.durationMs));
  close();
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(usage());
    return;
  }
  if (!['inventory', 'stream'].includes(args.command)) fail(`unknown command: ${args.command}`, 2);
  const modules = resolveOrcaModules();
  if (args.command === 'inventory') await inventory(args, modules);
  else await stream(args, modules);
}

main().catch((error) => fail(error instanceof Error ? error.message : String(error)));
