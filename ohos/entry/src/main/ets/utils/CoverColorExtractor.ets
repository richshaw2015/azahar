import { image } from '@kit.ImageKit';

interface ColorBin {
  r: number;
  g: number;
  b: number;
  count: number;
}

export async function extractDominantColor(pixelMap: image.PixelMap): Promise<string | null> {
  try {
    const info = pixelMap.getImageInfoSync();
    const width = info.size.width;
    const height = info.size.height;
    const format = info.pixelFormat;

    if (width <= 0 || height <= 0) {
      return null;
    }

    const buffer = new ArrayBuffer(pixelMap.getPixelBytesNumber());
    await pixelMap.readPixelsToBuffer(buffer);
    const view = new Uint8Array(buffer);

    const isBgra = (format === image.PixelMapFormat.BGRA_8888);
    const rOffset = isBgra ? 2 : 0;
    const gOffset = 1;
    const bOffset = isBgra ? 0 : 2;
    const aOffset = 3;
    const bytesPerPixel = 4;

    const bins = new Map<string, ColorBin>();
    const step = (width > 64 || height > 64) ? 4 : 1;

    for (let y = 0; y < height; y += step) {
      for (let x = 0; x < width; x += step) {
        const idx = (y * width + x) * bytesPerPixel;
        const r = view[idx + rOffset];
        const g = view[idx + gOffset];
        const b = view[idx + bOffset];
        const a = view[idx + aOffset];

        if (a < 128) {
          continue;
        }

        const brightness = Math.sqrt(0.299 * r * r + 0.587 * g * g + 0.114 * b * b);
        if (brightness < 35 || brightness > 235) {
          continue;
        }

        const max = Math.max(r, g, b);
        const min = Math.min(r, g, b);
        if (max - min < 24) {
          continue;
        }

        const qr = Math.floor(r / 43) * 43;
        const qg = Math.floor(g / 43) * 43;
        const qb = Math.floor(b / 43) * 43;
        const key = `${qr},${qg},${qb}`;

        const bin = bins.get(key);
        if (bin) {
          bin.r += r;
          bin.g += g;
          bin.b += b;
          bin.count++;
        } else {
          bins.set(key, { r, g, b, count: 1 });
        }
      }
    }

    let bestCount = 0;
    let bestSumR = 0;
    let bestSumG = 0;
    let bestSumB = 0;

    bins.forEach((bin) => {
      if (bin.count > bestCount) {
        bestCount = bin.count;
        bestSumR = bin.r;
        bestSumG = bin.g;
        bestSumB = bin.b;
      }
    });

    if (bestCount === 0) {
      return null;
    }

    const avgR = Math.round(bestSumR / bestCount);
    const avgG = Math.round(bestSumG / bestCount);
    const avgB = Math.round(bestSumB / bestCount);

    return `#${avgR.toString(16).padStart(2, '0')}${avgG.toString(16).padStart(2, '0')}${avgB.toString(16).padStart(2, '0')}`;
  } catch (_err) {
    return null;
  }
}
