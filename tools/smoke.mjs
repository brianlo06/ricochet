#!/usr/bin/env node
// Puts several simulated gamepads into one round against a running game.
//
// The rules are unit-tested without a phone; this is the other half — the real TLS
// listener, the real pairing, the real `pad_state` event through AirPoint's validation
// and rate limiting, and cues coming back to the right phones.
//
//   node tools/smoke.mjs --code 123456 [--port 8445] [--players 3]

import crypto from 'node:crypto';

process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, arg, i, all) => {
    if (arg.startsWith('--')) pairs.push([arg.slice(2), all[i + 1]]);
    return pairs;
  }, [])
);
const host = args.host ?? '127.0.0.1';
const port = args.port ?? '8445';
const code = args.code;
const playerCount = Number(args.players ?? 3);
if (!code) {
  console.error('usage: node tools/smoke.mjs --code <6 digits> [--port n] [--players n]');
  process.exit(2);
}

let passed = 0;
let failed = 0;
function check(name, condition, detail = '') {
  if (condition) { passed += 1; console.log(`  ok    ${name}`); }
  else { failed += 1; console.log(`  FAIL  ${name}${detail ? ' — ' + detail : ''}`); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// One simulated phone.
class Player {
  constructor(index) {
    this.index = index;
    this.deviceId = crypto.randomBytes(8).toString('hex');
    this.name = `Sim${index + 1}`;
    this.seq = 0;
    this.received = [];
    this.cues = [];
    this.welcome = null;
    this.closed = null;
  }

  connect() {
    return new Promise((resolve, reject) => {
      this.socket = new WebSocket(`wss://${host}:${port}/`);
      this.socket.addEventListener('message', async (event) => {
        const message = JSON.parse(event.data);
        this.received.push(message);
        if (message.t === 'cue') this.cues.push(message.d);
        if (message.t === 'welcome') { this.welcome = message.d; resolve(this); }
        if (message.t === 'challenge') await this._hello(message.d.nonce);
        if (message.t === 'error' && message.d.fatal) resolve(this);
      });
      this.socket.addEventListener('close', (event) => { this.closed = event; });
      this.socket.addEventListener('error', () => reject(new Error('socket error')));
      setTimeout(() => resolve(this), 8000);
    });
  }

  async _hello(nonceB64) {
    const nonce = Buffer.from(nonceB64.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
    const message = Buffer.concat([nonce, Buffer.from(this.deviceId, 'utf8')]);
    const proof = crypto.createHmac('sha256', Buffer.from(code, 'utf8'))
      .update(message).digest('base64');
    this.send('hello', {
      deviceId: this.deviceId,
      deviceName: this.name,
      platform: 'node',
      clientVersion: '0.1.0',
      auth: { mode: 'code', proof, channel: 'typed' },
    });
  }

  send(type, payload) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.seq += 1;
    const frame = { v: 1, t: type, seq: this.seq, ts: Date.now() };
    if (payload !== undefined) frame.d = payload;
    this.socket.send(JSON.stringify(frame));
  }

  get errorCodes() {
    return this.received.filter((m) => m.t === 'error').map((m) => m.d.code);
  }

  close() {
    if (this.socket && this.socket.readyState === WebSocket.OPEN) this.socket.close(1000);
  }
}

console.log(`Ricochet smoke check — ${playerCount} simultaneous gamepads\n`);

const players = [];
try {
  for (let i = 0; i < playerCount; i += 1) {
    players.push(await new Player(i).connect());
    await sleep(150);
  }

  const seated = players.filter((p) => p.welcome);
  check('every player got a seat', seated.length === playerCount,
    `${seated.length} of ${playerCount} seated`);
  check('the host advertises a pad, not a pointer',
    seated.every((p) => p.welcome.features.includes('pad') && !p.welcome.features.includes('pointer')));

  // One bot, asked for from a phone, so the seat arithmetic and the key path are exercised.
  const cuesBeforeBot = seated[0].cues.length;
  seated[0].send('key_press', { key: 'b' });
  await sleep(300);
  check('a Bots press from a phone is acknowledged to everyone',
    seated.every((p) => p.cues.some((c) => /bot/i.test(c.text ?? ''))),
    seated[0].cues.slice(cuesBeforeBot).map((c) => c.text).join(','));

  // Everyone readies at once. The round should start exactly once, for all of them.
  for (const player of seated) player.send('left_click', { clicks: 1 });
  await sleep(400);
  check('every player was told they readied up',
    seated.every((p) => p.cues.some((c) => c.text === 'Ready')));

  await sleep(3800);
  check('every player felt the round start',
    seated.every((p) => p.cues.some((c) => c.kind === 'start')),
    seated.map((p) => p.cues.filter((c) => c.kind === 'start').length).join(','));

  // Everybody drives and fires for a couple of seconds, with the pad state repeated the
  // way the real controller repeats it.
  const before = seated.map((p) => p.cues.length);
  for (let frame = 0; frame < 10; frame += 1) {
    for (const [index, player] of seated.entries()) {
      player.send('pad_state', { held: index % 2 ? ['up', 'left'] : ['up', 'right'] });
      if (frame % 2 === 0) player.send('left_click', { clicks: 1 });
    }
    await sleep(250);
  }
  for (const player of seated) player.send('pad_state', { held: [] });
  await sleep(300);

  check('every player felt their own shots',
    seated.every((p, i) => p.cues.slice(before[i]).some((c) => c.kind === 'tick')),
    seated.map((p, i) => `${p.name}:+${p.cues.length - before[i]}`).join(' '));
  check('no player was disconnected by driving and firing',
    seated.every((p) => p.closed === null));
  check('nobody hit a rate limit at a human rate',
    seated.every((p) => !p.errorCodes.includes('rate_limited')));

  // A misspelt button is rejected and explained, not silently taken as "nothing held".
  const first = seated[0];
  const errorsBefore = first.errorCodes.length;
  first.send('pad_state', { held: ['fire'] });
  await sleep(300);
  check('an unknown pad button is refused with an explanation',
    first.errorCodes.slice(errorsBefore).includes('invalid_payload'),
    first.errorCodes.slice(errorsBefore).join(',') || 'no error');
  check('and the refusal does not cost the session', first.closed === null);

  for (const player of players) player.close();
  await sleep(200);
} catch (error) {
  console.log(`  FAIL  harness error — ${error.message}`);
  failed += 1;
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
