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
import { execFileSync } from 'node:child_process';
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
    'expect-mapping': { type: 'string', multiple: true, default: [] },
  },
});

function fail(message) {
  console.error(`pairing-e2e: FAIL: ${message}`);
  process.exit(1);
}
const pass = (message) => console.log(`pairing-e2e: ok: ${message}`);
const encode = (bytes) => deviceAuth.encodeBase64Url(bytes);

async function post(action, body) {
  const response = await fetch(new URL(`/v2/device-pairing/${action}`, args.server), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!response.ok) fail(`${action} returned HTTP ${response.status}: ${await response.text()}`);
  return response.json();
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
const transport = secureChannel.parseDevicePairingTransport(created, args.server);
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

const approval = approve(material.verificationCode);
if (!approval.includes(deviceName)) fail(`pair approve did not name the device:\n${approval}`);
pass('approved with todex-agentd pair approve');

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
  const response = await fetch(new URL(path, args.server), { headers });
  if (!response.ok) fail(`${path} returned HTTP ${response.status}`);
  return response.json();
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
