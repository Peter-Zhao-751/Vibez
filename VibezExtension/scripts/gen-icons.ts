// Generates the extension's PNG icons (16/48/128) with no image deps — a
// Claude-orange tile with a cream pixel "z". PNG is hand-encoded; node:zlib
// supplies the zlib-wrapped DEFLATE stream PNG requires.

import { deflateSync } from "node:zlib";
import { mkdir, writeFile } from "node:fs/promises";

const ORANGE: RGB = [0xd9, 0x77, 0x57];
const CREAM: RGB = [0xf5, 0xf1, 0xec];
type RGB = [number, number, number];

function crc32(buf: Uint8Array): number {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, data.length);
  out.set(new TextEncoder().encode(type), 4);
  out.set(data, 8);
  dv.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

function encodePng(size: number, rgba: Uint8Array): Uint8Array {
  const stride = 1 + size * 4;
  const raw = new Uint8Array(size * stride);
  for (let y = 0; y < size; y++) {
    raw[y * stride] = 0; // filter: none
    raw.set(rgba.subarray(y * size * 4, (y + 1) * size * 4), y * stride + 1);
  }
  const ihdr = new Uint8Array(13);
  const dv = new DataView(ihdr.buffer);
  dv.setUint32(0, size);
  dv.setUint32(4, size);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // color type RGBA
  const idat = new Uint8Array(deflateSync(raw));
  const sig = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
  const parts = [sig, chunk("IHDR", ihdr), chunk("IDAT", idat), chunk("IEND", new Uint8Array(0))];
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

function draw(size: number): Uint8Array {
  const px = new Uint8Array(size * size * 4);
  const set = (x: number, y: number, [r, g, b]: RGB) => {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    const i = (y * size + x) * 4;
    px[i] = r;
    px[i + 1] = g;
    px[i + 2] = b;
    px[i + 3] = 255;
  };
  for (let y = 0; y < size; y++) for (let x = 0; x < size; x++) set(x, y, ORANGE);

  const pattern = ["11111", "00010", "00100", "01000", "11111"];
  const cell = Math.max(1, Math.floor(size / 7));
  const ox = Math.floor((size - cell * 5) / 2);
  const oy = ox;
  for (let r = 0; r < 5; r++) {
    for (let c = 0; c < 5; c++) {
      if (pattern[r][c] !== "1") continue;
      for (let dy = 0; dy < cell; dy++)
        for (let dx = 0; dx < cell; dx++) set(ox + c * cell + dx, oy + r * cell + dy, CREAM);
    }
  }
  return px;
}

const dir = `${import.meta.dir}/../icons`;
await mkdir(dir, { recursive: true });
for (const size of [16, 48, 128]) {
  await writeFile(`${dir}/icon-${size}.png`, encodePng(size, draw(size)));
}
console.log("✓ wrote icons/icon-{16,48,128}.png");
