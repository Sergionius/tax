#!/usr/bin/env node
'use strict';

// Private Orca terminal protocol bridge. Its stdout is NDJSON consumed only by
// tax-agent; terminal bytes are base64 and are never written to diagnostics.

const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const CONTROL_STREAM_ID = 0;
const TERMINAL_STREAM_ID = 1;

function fatal(message) {
  process.stdout.write(`${JSON.stringify({ type: 'error', message })}\n`);
  process.exit(1);
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === '--terminal' && value) result.terminal = value;
    else if (flag === '--pairing-code-file' && value) result.pairingCodeFile = value;
    else fatal(`unknown or incomplete argument: ${flag}`);
    index += 1;
  }
  if (!result.terminal || !result.pairingCodeFile) fatal('terminal and pairing code file are required');
  return result;
}

function loadModules() {
  const app = process.env.ORCA_APP_PATH || '/Applications/Orca.app';
  const root = path.join(app, 'Contents', 'Resources', 'app.asar.unpacked', 'out');
  const load = (relative) => {
    const target = path.join(root, relative);
    if (!fs.existsSync(target)) fatal(`Orca protocol helper is unavailable: ${relative}`);
    return require(target);
  };
  return {
    pairing: load('shared/pairing.js'),
    client: load('shared/remote-runtime-client.js'),
    protocol: load('shared/terminal-stream-protocol.js'),
  };
}

function readPairing(file) {
  const stat = fs.statSync(file);
  if ((stat.mode & 0o077) !== 0) fatal('pairing code file must have mode 0600');
  return fs.readFileSync(file, 'utf8').trim();
}

function emit(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const modules = loadModules();
  const pairing = modules.pairing.parsePairingCode(readPairing(args.pairingCodeFile));
  if (!pairing) fatal('invalid Orca pairing code');

  const protocol = modules.protocol;
  const opcodes = protocol.TerminalStreamOpcode;
  let subscription;
  let closed = false;
  let subscribed = false;
  let generation;
  let snapshotInfo = {};
  let snapshotChunks = [];

  const send = (streamId, opcode, payload = new Uint8Array()) => Boolean(subscription?.sendBinary(
    protocol.encodeTerminalStreamFrame({ opcode, streamId, seq: 0, payload }),
  ));
  const finish = () => {
    if (closed) return;
    closed = true;
    if (subscribed) send(TERMINAL_STREAM_ID, opcodes.Unsubscribe);
    subscription?.close();
    emit({ type: 'closed' });
    setImmediate(() => process.exit(0));
  };

  subscription = await modules.client.subscribeRemoteRuntimeRequest(
    pairing,
    'terminal.multiplex',
    {},
    15_000,
    {
      onResponse(response) {
        if (response?.ok !== true) {
          emit({ type: 'error', message: response?.error?.message || 'terminal stream failed' });
          finish();
          return;
        }
        const event = response.result;
        if (event?.type === 'ready') {
          send(CONTROL_STREAM_ID, opcodes.Subscribe, protocol.encodeTerminalStreamJson({
            streamId: TERMINAL_STREAM_ID,
            terminal: args.terminal,
            client: { id: 'tax-agent', type: 'desktop' },
            capabilities: { ackOutput: 1, outputPause: 1, writeUnavailable: 1, desktopViewportClaims: 1 },
          }));
        } else if (event?.type === 'subscribed') {
          subscribed = true;
          generation = event.streamGeneration;
        } else if (event?.type === 'error') {
          emit({ type: 'error', message: event.message || 'terminal stream failed' });
        } else if (event?.type === 'end') finish();
      },
      onBinary(bytes) {
        const frame = protocol.decodeTerminalStreamFrame(bytes);
        if (!frame || frame.streamId !== TERMINAL_STREAM_ID) return;
        if (frame.opcode === opcodes.SnapshotStart) {
          snapshotInfo = protocol.decodeTerminalStreamJson(frame.payload) || {};
          snapshotChunks = [];
        } else if (frame.opcode === opcodes.SnapshotChunk) {
          snapshotChunks.push(Buffer.from(frame.payload));
        } else if (frame.opcode === opcodes.SnapshotEnd) {
          emit({
            type: 'snapshot',
            data_b64: Buffer.concat(snapshotChunks).toString('base64'),
            generation,
            sequence: snapshotInfo.seq,
            columns: snapshotInfo.cols,
            rows: snapshotInfo.rows,
          });
          snapshotChunks = [];
        } else if (frame.opcode === opcodes.Output || frame.opcode === opcodes.OutputSpan) {
          const span = frame.opcode === opcodes.OutputSpan ? protocol.decodeTerminalStreamJson(frame.payload) : null;
          const output = frame.opcode === opcodes.OutputSpan ? span?.data : protocol.decodeTerminalStreamText(frame.payload);
          if (typeof output !== 'string') {
            send(TERMINAL_STREAM_ID, opcodes.SnapshotRequest, protocol.encodeTerminalStreamJson({}));
            return;
          }
          emit({
            type: 'output',
            data_b64: Buffer.from(output, 'utf8').toString('base64'),
            generation,
            sequence: frame.seq || undefined,
          });
          send(TERMINAL_STREAM_ID, opcodes.Ack, protocol.encodeTerminalStreamJson({ bytes: frame.payload.byteLength }));
        } else if (frame.opcode === opcodes.Resized) {
          const size = protocol.decodeTerminalStreamJson(frame.payload) || {};
          emit({ type: 'resized', columns: size.cols, rows: size.rows });
        } else if (frame.opcode === opcodes.WriteUnavailable) {
          emit({ type: 'write_unavailable', message: 'Orca rejected terminal input' });
        } else if (frame.opcode === opcodes.Error) {
          emit({ type: 'error', message: protocol.decodeTerminalStreamText(frame.payload) });
        }
      },
      onError(error) {
        emit({ type: 'error', message: error.message || 'terminal stream failed' });
        finish();
      },
      onClose: finish,
    },
  );

  const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  input.on('line', (line) => {
    let command;
    try { command = JSON.parse(line); } catch { emit({ type: 'error', message: 'invalid bridge command' }); return; }
    if (command.type === 'close') finish();
    else if (command.type === 'snapshot') {
      send(TERMINAL_STREAM_ID, opcodes.SnapshotRequest, protocol.encodeTerminalStreamJson({}));
    } else if (command.type === 'resize') {
      const columns = Number(command.columns);
      const rows = Number(command.rows);
      if (!Number.isInteger(columns) || !Number.isInteger(rows) || columns < 1 || rows < 1 || columns > 1000 || rows > 1000) {
        emit({ type: 'error', message: 'invalid terminal dimensions' });
        return;
      }
      send(TERMINAL_STREAM_ID, opcodes.ClaimViewport, protocol.encodeTerminalStreamJson({ cols: columns, rows }));
      send(TERMINAL_STREAM_ID, opcodes.Resize, protocol.encodeTerminalStreamJson({ cols: columns, rows }));
    } else if (command.type === 'input') {
      let data;
      try { data = Buffer.from(String(command.data_b64 || ''), 'base64'); } catch { return; }
      const text = data.toString('utf8');
      if (Buffer.from(text, 'utf8').compare(data) !== 0) {
        emit({ type: 'error', message: 'terminal input must be valid UTF-8' });
        return;
      }
      if (text) send(TERMINAL_STREAM_ID, opcodes.Input, protocol.encodeTerminalStreamText(text));
    } else emit({ type: 'error', message: 'unknown bridge command' });
  });
  input.on('close', finish);
}

main().catch((error) => fatal(error instanceof Error ? error.message : String(error)));
