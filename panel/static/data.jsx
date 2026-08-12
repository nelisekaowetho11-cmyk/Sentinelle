// Utility constants and helpers — real data loaded from API

const fakeRand = (seed) => {
  let s = typeof seed === 'string' ? seed.split('').reduce((a, c) => a + c.charCodeAt(0), 0) : seed;
  return () => { s = (s * 9301 + 49297) % 233280; return s / 233280; };
};

// Protocols for user management (UUID-based)
const PROTOCOLS = ['VLESS', 'VMess', 'Trojan', 'Shadowsocks'];
// All protocols available as inbound listeners
const INBOUND_PROTOCOLS = ['VLESS', 'VMess', 'Trojan', 'Shadowsocks', 'SOCKS', 'HTTP'];

const AVATAR_GRADIENTS = [
  ['oklch(72% 0.14 175)', 'oklch(60% 0.13 240)'],
  ['oklch(72% 0.16 80)',  'oklch(68% 0.18 30)'],
  ['oklch(70% 0.14 320)', 'oklch(72% 0.14 175)'],
  ['oklch(72% 0.14 240)', 'oklch(70% 0.14 280)'],
  ['oklch(74% 0.13 130)', 'oklch(72% 0.16 80)'],
  ['oklch(72% 0.14 200)', 'oklch(60% 0.14 320)'],
];
const gradFor = (i) => AVATAR_GRADIENTS[i % AVATAR_GRADIENTS.length];

const PROTOCOL_COLORS = {
  VLESS:       'oklch(75% 0.14 175)',
  VMess:       'oklch(72% 0.14 240)',
  Trojan:      'oklch(70% 0.18 30)',
  Shadowsocks: 'oklch(72% 0.16 80)',
  SOCKS:       'oklch(72% 0.14 320)',
  HTTP:        'oklch(70% 0.12 60)',
  WireGuard:   'oklch(74% 0.10 140)',
};

const buildTraffic = () => {
  const r = fakeRand(7);
  const pts = 40;
  const down = [], up = [];
  for (let i = 0; i < pts; i++) {
    const base = 40 + 20 * Math.sin(i / 4) + 15 * Math.sin(i / 7);
    down.push(Math.max(8, base + r() * 30));
    up.push(Math.max(4, base * 0.45 + r() * 14));
  }
  return { down, up };
};

const TRAFFIC = buildTraffic();

Object.assign(window, { PROTOCOLS, INBOUND_PROTOCOLS, gradFor, fakeRand, PROTOCOL_COLORS, TRAFFIC });
