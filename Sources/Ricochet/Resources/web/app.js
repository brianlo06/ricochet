// Ricochet controller.
//
// The pairing handshake and the wire protocol are AirPoint's. What is specific to a
// gamepad: a d-pad that reports the whole set of held directions every time it changes,
// and a trigger. No motion sensors, so no permission prompt — the phone is a pad, not a gun.

'use strict';

const PROTOCOL_VERSION = 1;
const CLIENT_VERSION = '0.1.0';
// How often a held pad state is repeated. The host treats a state it has not heard about
// for a second as released, so a phone that dies mid-press does not leave a tank driving
// into a wall; this keeps a live one well inside that.
const HELD_REPEAT_MS = 250;

const $ = (id) => document.getElementById(id);
const b64url = (v) => {
  const p = v.replace(/-/g, '+').replace(/_/g, '/');
  return Uint8Array.from(atob(p + '='.repeat((4 - (p.length % 4)) % 4)), (c) => c.charCodeAt(0));
};
const toB64 = (bytes) => btoa(String.fromCharCode(...bytes));
const haptic = (p) => { if (navigator.vibrate) { try { navigator.vibrate(p); } catch {} } };

// Feedback for cues the Mac sends back. Tones are synthesised rather than loaded; iOS will
// not start an AudioContext without a user gesture, so it is created lazily on the first tap.
const Cue = {
  context: null,

  unlock() {
    try {
      if (!this.context) {
        const Ctor = window.AudioContext || window.webkitAudioContext;
        if (Ctor) this.context = new Ctor();
      }
      if (this.context && this.context.state === 'suspended') this.context.resume();
    } catch { this.context = null; }
  },

  // kind -> [vibration pattern, frequency Hz, duration s, waveform]
  recipes: {
    success: [[18], 880, 0.07, 'square'],
    failure: [[70, 40, 70], 140, 0.22, 'sawtooth'],
    warning: [[12, 60, 12], 500, 0.06, 'square'],
    start:   [[30, 60, 30, 60, 60], 660, 0.14, 'square'],
    finish:  [[120], 330, 0.30, 'triangle'],
    tick:    [[10], 740, 0.04, 'square'],
    info:    [[10], 520, 0.05, 'sine'],
  },

  play(kind, intensity = 0.6) {
    const recipe = this.recipes[kind] ?? this.recipes.info;
    const [pattern, frequency, duration, waveform] = recipe;
    const strength = Math.min(Math.max(intensity, 0), 1);

    haptic(pattern.map((ms, i) => (i % 2 === 0 ? Math.round(ms * (0.5 + strength)) : ms)));

    if (!this.context || this.context.state !== 'running') return;
    try {
      const now = this.context.currentTime;
      const osc = this.context.createOscillator();
      const gain = this.context.createGain();
      osc.type = waveform;
      osc.frequency.setValueAtTime(frequency * (kind === 'success' ? 1 + strength * 0.5 : 1), now);
      gain.gain.setValueAtTime(0.0001, now);
      gain.gain.exponentialRampToValueAtTime(0.02 + 0.10 * strength, now + 0.008);
      gain.gain.exponentialRampToValueAtTime(0.0001, now + duration);
      osc.connect(gain).connect(this.context.destination);
      osc.start(now);
      osc.stop(now + duration + 0.02);
    } catch { /* audio is a bonus, never a requirement */ }
  },
};

function showError(message) {
  const el = $('connect-error');
  el.textContent = message;
  el.classList.remove('is-hidden');
}

function deviceId() {
  let id = localStorage.getItem('ricochet.deviceId');
  if (!id || !/^[0-9a-f-]{1,64}$/.test(id)) {
    id = Array.from(crypto.getRandomValues(new Uint8Array(16)),
                    (b) => b.toString(16).padStart(2, '0')).join('');
    localStorage.setItem('ricochet.deviceId', id);
  }
  return id;
}

function playerName() {
  const ua = navigator.userAgent;
  if (/iPad/.test(ua)) return 'iPad';
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/Android/.test(ua)) return 'Android';
  return 'Player';
}

function readFragment() {
  const hash = location.hash.replace(/^#/, '');
  if (!hash) return null;
  const params = new URLSearchParams(hash);
  const secret = params.get('s');
  if (!secret) return null;
  history.replaceState(null, '', location.pathname);
  return { secret };
}

async function proof(keyBytes, nonce, id) {
  const key = await crypto.subtle.importKey('raw', keyBytes,
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const message = new Uint8Array(nonce.length + id.length);
  message.set(nonce, 0);
  message.set(new TextEncoder().encode(id), nonce.length);
  return toB64(new Uint8Array(await crypto.subtle.sign('HMAC', key, message)));
}

/// A round d-pad that a thumb can slide around without lifting.
///
/// Direction is read from the angle of the touch about the pad's centre, in eight
/// sectors, so the diagonals hold two directions at once: forward-and-left is how you
/// steer a tank. Every pointer on the pad contributes, and the union is what is reported,
/// so a second thumb landing does not cancel the first.
class Pad {
  constructor(element, onChange) {
    this.element = element;
    this.onChange = onChange;
    this.pointers = new Map();
    this.held = [];

    const update = (event) => {
      this.pointers.set(event.pointerId, this._directions(event));
      this._emit();
    };
    const release = (event) => {
      if (this.pointers.delete(event.pointerId)) this._emit();
    };
    element.addEventListener('pointerdown', (event) => {
      event.preventDefault();
      Cue.unlock();
      try { element.setPointerCapture(event.pointerId); } catch {}
      update(event);
    }, { passive: false });
    element.addEventListener('pointermove', (event) => {
      if (this.pointers.has(event.pointerId)) update(event);
    });
    element.addEventListener('pointerup', release);
    element.addEventListener('pointercancel', release);
    element.addEventListener('lostpointercapture', release);
  }

  _directions(event) {
    const rect = this.element.getBoundingClientRect();
    // Page coordinates, y downward. When the play screen has been turned on its side
    // for a portrait viewport, the pad's "up" is the page's right, so the touch is
    // turned back the other way before it is read.
    let px = event.clientX - (rect.left + rect.width / 2);
    let py = event.clientY - (rect.top + rect.height / 2);
    if (Pad.isRotated) [px, py] = [py, -px];
    const dx = px;
    const dy = -py;
    // A dead zone in the middle, so resting a thumb is not a direction.
    if (Math.hypot(dx, dy) < rect.width * 0.09) return [];
    const degrees = (Math.atan2(dy, dx) * 180 / Math.PI + 360) % 360;
    const held = [];
    if (degrees > 22.5 && degrees < 157.5) held.push('up');
    if (degrees > 112.5 && degrees < 247.5) held.push('left');
    if (degrees > 202.5 && degrees < 337.5) held.push('down');
    if (degrees < 67.5 || degrees > 292.5) held.push('right');
    return held;
  }

  _emit() {
    const union = new Set();
    for (const directions of this.pointers.values()) for (const d of directions) union.add(d);
    const held = ['up', 'down', 'left', 'right'].filter((d) => union.has(d));
    if (held.join() === this.held.join()) return;
    this.held = held;
    for (const d of ['up', 'down', 'left', 'right']) this.element.classList.toggle(`is-${d}`, union.has(d));
    this.element.classList.toggle('is-active', held.length > 0);
    this.onChange(held);
  }

  /// Whether the stylesheet has turned the play screen on its side. Mirrors the media
  /// query there; the two must agree or the pad steers ninety degrees off.
  static get isRotated() {
    return window.matchMedia('(orientation: portrait)').matches;
  }

  /// Everything let go, whether or not the browser told us. Used when the page hides:
  /// a backgrounded tab gets no pointerup, and the tank would drive on.
  releaseAll() {
    if (this.pointers.size === 0 && this.held.length === 0) return;
    this.pointers.clear();
    this._emit();
  }
}

class Controller {
  constructor() {
    this.credentials = readFragment();
    this.typedCode = null;
    this.seq = 0;
    this.socket = null;
    this.shouldReconnect = true;
    this.reconnectDelay = 250;
    this.sentPadStates = 0;
    this.wakeLock = null;

    this.pad = new Pad($('dpad'), (held) => this._sendPad(held));
    this._wireUI();
  }

  // --- transport -----------------------------------------------------------

  connect() {
    try {
      // The scheme follows the page's, so a plain-HTTP dev proxy in front of the game can
      // serve this to a desktop browser without the certificate interstitial. Phones
      // always arrive over TLS, because that is all the game itself serves.
      const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
      this.socket = new WebSocket(`${scheme}://${location.host}/`);
    } catch (error) {
      showError(`Could not open a connection: ${error.message}`);
      return;
    }
    this.socket.onopen = () => { this.reconnectDelay = 250; };
    this.socket.onmessage = (event) => this._receive(event.data);
    this.socket.onerror = () => showError(
      'Could not reach the game. If you have not accepted this Mac\'s certificate yet, '
      + 'reload and choose "visit this website". Otherwise check you are on the same Wi-Fi.');
    this.socket.onclose = () => {
      if (!this.shouldReconnect) return;
      setTimeout(() => this.connect(), this.reconnectDelay);
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, 4000);
    };
  }

  send(type, payload) {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return;
    this.seq = (this.seq + 1) >>> 0;
    const frame = { v: PROTOCOL_VERSION, t: type, seq: this.seq, ts: Date.now() };
    if (payload !== undefined) frame.d = payload;
    this.socket.send(JSON.stringify(frame));
  }

  _sendPad(held) {
    this.sentPadStates += 1;
    this.send('pad_state', { held });
  }

  async _receive(raw) {
    let message;
    try { message = JSON.parse(raw); } catch { return; }

    if (message.t === 'challenge') {
      const nonce = b64url(message.d.nonce);
      const id = deviceId();
      let key;
      let channel;
      if (this.credentials) { key = b64url(this.credentials.secret); channel = 'qr'; }
      else if (this.typedCode) { key = new TextEncoder().encode(this.typedCode); channel = 'typed'; }
      else {
        $('connect-status').textContent = 'Join the game';
        $('code-entry').classList.remove('is-hidden');
        return;
      }
      this.send('hello', {
        deviceId: id,
        deviceName: playerName(),
        platform: 'web',
        clientVersion: CLIENT_VERSION,
        auth: { mode: 'code', proof: await proof(key, nonce, id), channel },
      });
    } else if (message.t === 'pair_pending') {
      $('connect-status').textContent = message.d.message || 'Approve on the Mac…';
    } else if (message.t === 'welcome') {
      $('screen-connect').classList.remove('is-visible');
      $('screen-play').classList.add('is-visible');
      this._startLoops();
      this._keepAwake();
      // Where the browser allows it, hold landscape. Where it does not — Safari — the
      // stylesheet turns the page on its side instead, so this is a courtesy.
      try { screen.orientation?.lock?.('landscape').catch(() => {}); } catch {}
      // A reconnect mid-press: tell the new session what is still held.
      if (this.pad.held.length) this._sendPad(this.pad.held);
    } else if (message.t === 'cue') {
      Cue.play(message.d?.kind, message.d?.intensity ?? 0.6);
      if (message.d?.text) this._flash(message.d.text, message.d.kind);
    } else if (message.t === 'error') {
      if (message.d.fatal) {
        this.shouldReconnect = false;
        this.credentials = null;
        this.typedCode = null;
        $('screen-play').classList.remove('is-visible');
        $('screen-connect').classList.add('is-visible');
        $('code-entry').classList.remove('is-hidden');
        showError(message.d.message);
      }
    }
  }

  // --- loops ---------------------------------------------------------------

  _startLoops() {
    if (this.loopsStarted) return;
    this.loopsStarted = true;

    // Repeat a held state, so the host can tell a long press from a dead phone.
    setInterval(() => {
      if (this.pad.held.length) this._sendPad(this.pad.held);
    }, HELD_REPEAT_MS);

    setInterval(() => this.send('ping', { id: 1 }), 2000);

    setInterval(() => {
      const el = $('diag');
      const open = this.socket && this.socket.readyState === WebSocket.OPEN;
      el.textContent = open
        ? (this.pad.held.length ? `holding ${this.pad.held.join(' + ')}` : 'connected')
        : 'reconnecting…';
      el.classList.toggle('is-bad', !open);
    }, 300);
  }

  /// A phone that dims mid-round is a tank that stops. Best-effort: not every browser
  /// offers this, and the ones that do drop it when the page hides.
  async _keepAwake() {
    if (!navigator.wakeLock) return;
    try { this.wakeLock = await navigator.wakeLock.request('screen'); } catch {}
  }

  _flash(text, kind) {
    const el = $('flash');
    if (!el) return;
    el.textContent = text;
    el.className = `flash is-${kind ?? 'info'}`;
    clearTimeout(this.flashTimer);
    this.flashTimer = setTimeout(() => { el.className = 'flash is-hidden'; }, 800);
  }

  // --- controls ------------------------------------------------------------

  _wireUI() {
    $('code-submit').addEventListener('click', () => {
      const code = $('code-input').value.trim();
      if (!/^\d{6}$/.test(code)) { showError('The code is six digits.'); return; }
      this.typedCode = code;
      $('connect-error').classList.add('is-hidden');
      $('code-entry').classList.add('is-hidden');
      $('connect-status').textContent = 'Approve on the Mac…';
      this.shouldReconnect = true;
      if (this.socket && this.socket.readyState === WebSocket.OPEN) this.socket.close();
      else this.connect();
    });

    // Fires on press, not on click: a trigger with the browser's tap delay feels broken.
    $('fire').addEventListener('pointerdown', (event) => {
      event.preventDefault();
      Cue.unlock();
      this.send('left_click', { clicks: 1 });
    }, { passive: false });

    // Cycles the game mode. Sends right_click, which the host interprets — the controller
    // deliberately does not know what modes exist.
    $('mode').addEventListener('click', () => {
      Cue.unlock();
      this.send('right_click', { clicks: 1 });
    });

    // Bots and Map are lettered buttons pressed once, so they are key presses: B adds a
    // bot (wrapping to none), N picks another map. Both are lobby-only; the host says so
    // if pressed mid-round. The same letters work on the Mac's keyboard.
    $('bots').addEventListener('click', () => {
      Cue.unlock();
      this.send('key_press', { key: 'b' });
    });
    // D cycles how good the bots are: easy, medium, hard, impossible.
    $('skill').addEventListener('click', () => {
      Cue.unlock();
      this.send('key_press', { key: 'd' });
    });
    $('map').addEventListener('click', () => {
      Cue.unlock();
      this.send('key_press', { key: 'n' });
    });
    // G cycles through the guns this phone's kills have unlocked. Any time, even
    // mid-round: a loadout is the player's business.
    $('gun').addEventListener('click', () => {
      Cue.unlock();
      this.send('key_press', { key: 'g' });
    });
    // P pauses or resumes, E ends the round with the scores as they stand. Both do
    // nothing outside a round, and the host says so.
    $('pause').addEventListener('click', () => {
      Cue.unlock();
      this.send('key_press', { key: 'p' });
    });
    $('end').addEventListener('click', () => {
      Cue.unlock();
      this.pad.releaseAll();
      this.send('key_press', { key: 'e' });
    });

    document.addEventListener('visibilitychange', () => {
      if (document.hidden) this.pad.releaseAll();
      else this._keepAwake();
    });
    window.addEventListener('blur', () => this.pad.releaseAll());
    document.addEventListener('gesturestart', (event) => event.preventDefault());

    // iOS zooms on a double tap, and `user-scalable=no` has been ignored since iOS 10.
    // Two taps inside 300ms is a player firing, not a request to zoom, so the second
    // one's default is refused. Belt and braces with touch-action: manipulation above.
    let lastTouchEndAt = 0;
    document.addEventListener('touchend', (event) => {
      const now = Date.now();
      if (now - lastTouchEndAt < 300) event.preventDefault();
      lastTouchEndAt = now;
    }, { passive: false });
    document.addEventListener('dblclick', (event) => event.preventDefault(), { passive: false });
  }
}

const controller = new Controller();
controller.connect();
