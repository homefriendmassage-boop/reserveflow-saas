import { Buffer } from "node:buffer";
import jpeg from 'npm:jpeg-js@0.4.4';
import { PNG } from 'npm:pngjs@7.0.0';
import jsQR from 'npm:jsqr@1.4.0';

const scanQr = jsQR as unknown as (pixels: Uint8ClampedArray, width: number, height: number) => { data: string } | null;

export function decodeSlipQr(image: string) {
  const format = /^data:image\/(jpeg|png);base64,/.exec(image);
  if (!format) return null;
  try {
    const bytes = Buffer.from(image.slice(format[0].length), 'base64');
    if (format[1] === 'png' && (bytes.length < 24 ||
      bytes.readUInt32BE(16) * bytes.readUInt32BE(20) > 12_000_000)) return null;
    const decoded = format[1] === 'png'
      ? PNG.sync.read(bytes)
      : jpeg.decode(bytes, { maxResolutionInMP: 12, maxMemoryUsageInMB: 96 });
    const scale = Math.max(1, Math.max(decoded.width, decoded.height) / 1400);
    const width = Math.floor(decoded.width / scale);
    const height = Math.floor(decoded.height / scale);
    const rgba = new Uint8ClampedArray(width * height * 4);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const offset = (Math.floor(y * scale) * decoded.width + Math.floor(x * scale)) * 4;
        rgba.set(decoded.data.subarray(offset, offset + 4), (y * width + x) * 4);
      }
    }
    const value = scanQr(rgba, width, height)?.data?.trim();
    return value && /^[\x20-\x7e]{12,2048}$/.test(value) ? value : null;
  } catch {
    return null;
  }
}
