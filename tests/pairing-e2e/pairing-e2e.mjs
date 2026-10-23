// Pairs with a running backend the way TodeX Desktop does (device pairing v3,
// TodeX_protocol's implementation), approves the request with
// `todex-agentd pair approve`, then checks what a paired device sees in
// /v2/version.
//
//   node pairing-e2e.mjs --server http://127.0.0.1:7345 --container NAME \
//     [--expect-mapping HOST=BACKEND]
//
// --approve-command replaces the docker exec approval (for a backend run on
// the host): the verification code is appended as the last argument.
//
// --ipc-socket PATH talks to the backend's local socket instead, the way
// Desktop on the same host does: every request goes over the socket, and the
// request is approved through the local-admin API with the verification code.
import { execFileSync } from 'node:child_process';
import http from 'node:http';
import { createRequire } from 'node:module';
import { parseArgs } from 'node:util';
import { xchacha20poly1305 } from '@noble/ciphers/chacha.js';
import { x25519 } from '@noble/curves/ed25519.js';

const require = createRequire(import.meta.url);
const secureChannel = require('./dist/protocol/secureChannel.js');
const deviceAuth = require('./dist/protocol/deviceAuth.js');

const { values: args } = parseArgs({
  options: {
    server: { type: 'string', default: 'http://127.0.0.1:7345' },
    container: { type: 'string' },
    'approve-command': { type: 'string' },
    'ipc-socket': { type: 'string' },
    'expect-mapping': { type: 'string', multiple: true, default: [] },
  },
});

function fail(message) {
  console.error(`pairing-e2e: FAIL: ${message}`);
  process.exit(1);
}
const pass = (message) => console.log(`pairing-e2e: ok: ${message}`);
const encode = (bytes) => deviceAuth.encodeBase64Url(bytes);

const ipcSocket = args['ipc-socket'];
// The pairing transport checks only look at the URL for plaintext servers.
const serverUrl = ipcSocket ? 'http://localhost' : args.server;

// Returns { status, text }; over the socket with node:http (fetch cannot use
// a Unix socket), otherwise with fetch.
function request(method, path, { body, headers = {} } = {}) {
  const payload = body === undefined ? undefined : JSON.stringify(body);
  const allHeaders = payload === undefined ? { ...headers } : { 'Content-Type': 'application/json', ...headers };
  if (!ipcSocket) {
    return fetch(new URL(path, args.server), { method, headers: allHeaders, body: payload })
      .then(async (response) => ({ status: response.status, text: await response.text() }));
  }
  return new Promise((resolve, reject) => {
    const req = http.request(
      { socketPath: ipcSocket, path, method, headers: { Host: 'localhost', ...allHeaders }, timeout: 15000 },
      (response) => {
        let text = '';
        response.setEncoding('utf8');
        response.on('data', (chunk) => { text += chunk; });
        response.on('end', () => resolve({ status: response.statusCode, text }));
        response.on('error', reject);
      },
    );
    req.on('timeout', () => req.destroy(new Error(`${method} ${path} timed out`)));
    req.on('error', reject);
    req.end(payload);
  });
}

async function requestJson(method, path, options) {
  const { status, text } = await request(method, path, options);
  if (status < 200 || status >= 300) fail(`${method} ${path} returned HTTP ${status}: ${text}`);
  return JSON.parse(text);
}

const post = (action, body) => requestJson('POST', `/v2/device-pairing/${action}`, { body });

async function approveOverIpc(requestId, code) {
  const pending = await requestJson('GET', '/v2/local-admin/pairing-requests');
  const entry = pending.find((r) => r.requestId === requestId);
  if (!entry) fail(`local-admin does not list request ${requestId}: ${JSON.stringify(pending)}`);
  if (entry.peerAddress !== 'ipc') fail(`request made over the socket has peerAddress ${entry.peerAddress}`);
  if (entry.deviceName !== deviceName) fail(`local-admin lists device name ${entry.deviceName}`);
  const decision = `/v2/local-admin/pairing-requests/${encodeURIComponent(requestId)}/decision`;
  const wrong = await request('POST', decision, { body: { approved: true, verificationCode: 'AAAAA-AAAAA' } });
  if (wrong.status !== 409) fail(`a wrong verification code returned HTTP ${wrong.status}, not 409: ${wrong.text}`);
  const result = await requestJson('POST', decision, { body: { approved: true, verificationCode: code } });
  if (result.ok !== true) fail(`decision returned ${JSON.stringify(result)}`);
}

function approve(code) {
  if (args['approve-command']) {
    const [command, ...rest] = args['approve-command'].split(' ').filter(Boolean);
    return execFileSync(command, [...rest, code], { encoding: 'utf8' });
  }
  if (!args.container) fail('pass --container or --approve-command');
  return execFileSync('docker', ['exec', '-u', 'todex', args.container, 'todex-agentd', 'pair', 'approve', code], { encoding: 'utf8' });
}

const device = deviceAuth.generateDeviceIdentity();
const keys = x25519.keygen();
const clientNonce = crypto.getRandomValues(new Uint8Array(secureChannel.DEVICE_PAIRING_V3_NONCE_LENGTH));
const deviceName = secureChannel.normalizeDevicePairingName('TodeX container e2e', 'TodeX');

const created = await post('create', {
  transportBinding: 1,
  deviceNameBinding: 1,
  clientCommitment: encode(secureChannel.devicePairingV3Commitment(keys.publicKey, clientNonce)),
  devicePublicKey: device.publicKey,
  deviceName,
});
const transport = secureChannel.parseDevicePairingTransport(created, serverUrl);
const material = secureChannel.deriveDevicePairingV3Material({
  requestId: created.requestId,
  clientSecretKey: keys.secretKey,
  serverPublic: deviceAuth.decodeBase64Url(created.serverPublicKey),
  devicePublic: deviceAuth.decodeBase64Url(device.publicKey),
  clientNonce,
  transportProtocol: transport.protocol,
  transportPublicKey: transport.publicKeyRaw,
  deviceName,
});
const revealed = await post('reveal', {
  requestId: created.requestId,
  clientPublicKey: encode(keys.publicKey),
  clientNonce: encode(clientNonce),
});
if (revealed.status !== 'pending') fail(`reveal status ${revealed.status}`);
pass(`pairing request created (code ${material.verificationCode})`);

if (ipcSocket) {
  await approveOverIpc(created.requestId, material.verificationCode);
  pass('approved through the local-admin API on the socket (a wrong code was refused)');
} else {
  const approval = approve(material.verificationCode);
  if (!approval.includes(deviceName)) fail(`pair approve did not name the device:\n${approval}`);
  pass('approved with todex-agentd pair approve');
}

let result;
for (let attempt = 0; attempt < 30; attempt += 1) {
  result = await post('poll', { requestId: created.requestId, proof: encode(material.pollProof) });
  if (result.status !== 'pending') break;
  await new Promise((resolve) => setTimeout(resolve, 1000));
}
if (result.status !== 'approved') fail(`poll ended with status ${result.status}`);
const plaintext = xchacha20poly1305(
  material.wrapKey,
  deviceAuth.decodeBase64Url(result.nonce),
  material.transcript,
).decrypt(deviceAuth.decodeBase64Url(result.ciphertext));
const credential = JSON.parse(new TextDecoder().decode(plaintext));
secureChannel.verifyDevicePairingCredential(credential, { deviceId: device.deviceId, transport });
pass(`paired as ${credential.deviceId}; transport key matches the create response`);

async function version(signed) {
  const path = '/v2/version';
  const headers = signed ? deviceAuth.deviceAuthHeaders(device, 'GET', path) : {};
  return requestJson('GET', path, { headers });
}

const anonymous = await version(false);
if (anonymous.deployment !== 'container') fail(`anonymous /v2/version deployment: ${JSON.stringify(anonymous)}`);
if ('pathMappings' in anonymous || 'workspace_roots' in anonymous) fail('anonymous /v2/version exposes paths');
const trusted = await version(true);
if (!Array.isArray(trusted.workspace_roots)) fail(`signed /v2/version has no paths: ${JSON.stringify(trusted)}`);
for (const expected of args['expect-mapping']) {
  const [hostPath, backendPath] = expected.split('=');
  const found = (trusted.pathMappings ?? []).some((m) => m.hostPath === hostPath && m.backendPath === backendPath);
  if (!found) fail(`pathMappings lacks ${expected}: ${JSON.stringify(trusted.pathMappings)}`);
}
pass('paired device sees deployment, workspace roots and path mappings');
