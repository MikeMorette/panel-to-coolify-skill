#!/usr/bin/env node
/**
 * Advisory port check for migrated Node.js/API containers. The port is released
 * before the child starts, so this cannot itself prevent a race or split-brain.
 * Cross-process exclusion requires an independently verified shared lock used by
 * every old and new writer; different network/filesystem namespaces matter.
 *
 * Usage:
 *   node start-guard.js --port 3000 [--host 127.0.0.1] [--timeout-ms 3000] -- node dist/main.js
 */

'use strict';

const net = require('net');
const { spawn } = require('child_process');

function parseArgs(argv) {
  const sepIndex = argv.indexOf('--');
  if (sepIndex === -1 || sepIndex === argv.length - 1) {
    console.error('Usage: start-guard.js --port <port> [--host 127.0.0.1] [--timeout-ms 3000] -- <cmd> [args...]');
    process.exit(2);
  }

  const guardArgs = argv.slice(0, sepIndex);
  const cmdArgs = argv.slice(sepIndex + 1);
  let port = Number(process.env.PORT || 0);
  let host = '0.0.0.0';
  let timeoutMs = 3000;

  for (let i = 0; i < guardArgs.length; i++) {
    const arg = guardArgs[i];
    if (arg === '--port' && guardArgs[i + 1]) {
      port = Number(guardArgs[++i]);
    } else if (arg === '--host' && guardArgs[i + 1]) {
      host = guardArgs[++i];
    } else if (arg === '--timeout-ms' && guardArgs[i + 1]) {
      timeoutMs = Number(guardArgs[++i]);
    } else if (arg === '--help' || arg === '-h') {
      console.log('Usage: start-guard.js --port <port> [--host 0.0.0.0] [--timeout-ms 3000] -- <cmd> [args...]');
      process.exit(0);
    } else {
      console.error(`[start-guard] Unknown or incomplete option: ${arg}`);
      process.exit(2);
    }
  }

  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error(`[start-guard] Invalid or missing --port (${port}).`);
    process.exit(2);
  }

  return { port, host, timeoutMs, cmd: cmdArgs[0], args: cmdArgs.slice(1) };
}

function checkPortFree(host, port, timeoutMs) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    const timer = setTimeout(() => {
      server.close();
      reject(new Error(`Timeout checking port ${host}:${port}`));
    }, timeoutMs);

    server.once('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });

    server.listen(port, host, () => {
      clearTimeout(timer);
      server.close((closeErr) => {
        if (closeErr) reject(closeErr);
        else resolve();
      });
    });
  });
}

async function main() {
  const { port, host, timeoutMs, cmd, args } = parseArgs(process.argv.slice(2));

  try {
    await checkPortFree(host, port, timeoutMs);
  } catch (err) {
    console.error(`[start-guard] REFUSING START: ${host}:${port} is already in use or unreachable (${err.code || err.message}).`);
    process.exit(1);
  }

  console.log(`[start-guard] Port ${host}:${port} was free at the time of the check. Starting child.`);
  const child = spawn(cmd, args, { stdio: 'inherit' });

  child.on('error', (err) => {
    console.error(`[start-guard] Unable to start child (${err.code || 'spawn error'}).`);
    process.exitCode = 1;
  });

  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => {
      if (!child.killed) child.kill(sig);
    });
  }

  child.on('exit', (code, signal) => {
    if (signal) {
      process.removeAllListeners(signal);
      process.kill(process.pid, signal);
    } else {
      process.exit(code === null ? 1 : code);
    }
  });
}

main();
