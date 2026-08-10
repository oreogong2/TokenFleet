/*
 * Dependency-free QR encoder used only for local share images.
 * Algorithm follows Project Nayuki's QR Code generator (MIT License):
 * Copyright (c) Project Nayuki. https://www.nayuki.io/page/qr-code-generator-library
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

const CONFIGS = Object.freeze([
  // Version 6-L: 134 byte payload capacity.
  { version: 6, dataCodewords: 136, eccCodewords: 18, blocks: 2, byteCapacity: 134 },
  // Version 15-L: 520 byte payload capacity; covers ordinary filter values.
  { version: 15, dataCodewords: 523, eccCodewords: 22, blocks: 6, byteCapacity: 520 },
  // Version 40-L: 2953 byte payload capacity; covers worst-case percent-encoded
  // 128-character tool/model filters and a 128-character public ID.
  { version: 40, dataCodewords: 2956, eccCodewords: 30, blocks: 25, byteCapacity: 2953 },
]);

function appendBits(target, value, length) {
  for (let shift = length - 1; shift >= 0; shift -= 1) {
    target.push(((value >>> shift) & 1) !== 0);
  }
}

function multiply(x, y) {
  let result = 0;
  for (let index = 7; index >= 0; index -= 1) {
    result = (result << 1) ^ ((result >>> 7) * 0x11d);
    result ^= ((y >>> index) & 1) * x;
  }
  return result;
}

function divisorFor(degree) {
  const result = Array(degree).fill(0);
  result[degree - 1] = 1;
  let root = 1;
  for (let index = 0; index < degree; index += 1) {
    for (let offset = 0; offset < degree; offset += 1) {
      result[offset] = multiply(result[offset], root);
      if (offset + 1 < degree) result[offset] ^= result[offset + 1];
    }
    root = multiply(root, 2);
  }
  return result;
}

function remainderFor(data, divisor) {
  const result = Array(divisor.length).fill(0);
  data.forEach((byte) => {
    const factor = byte ^ result.shift();
    result.push(0);
    for (let index = 0; index < result.length; index += 1) {
      result[index] ^= multiply(divisor[index], factor);
    }
  });
  return result;
}

function rawDataModules(version) {
  let result = (16 * version + 128) * version + 64;
  if (version >= 2) {
    const alignments = Math.floor(version / 7) + 2;
    result -= (25 * alignments - 10) * alignments - 55;
    if (version >= 7) result -= 36;
  }
  return result;
}

function encodeCodewords(text) {
  const bytes = [...new TextEncoder().encode(String(text))];
  const config = CONFIGS.find((item) => bytes.length <= item.byteCapacity);
  if (!config) throw new RangeError("QR 链接过长");

  const bits = [];
  appendBits(bits, 0b0100, 4);
  appendBits(bits, bytes.length, config.version < 10 ? 8 : 16);
  bytes.forEach((byte) => appendBits(bits, byte, 8));
  const capacity = config.dataCodewords * 8;
  appendBits(bits, 0, Math.min(4, capacity - bits.length));
  while (bits.length % 8) bits.push(false);

  const data = [];
  for (let index = 0; index < bits.length; index += 8) {
    let byte = 0;
    for (let offset = 0; offset < 8; offset += 1) {
      byte = (byte << 1) | Number(bits[index + offset]);
    }
    data.push(byte);
  }
  for (let pad = 0; data.length < config.dataCodewords; pad += 1) {
    data.push(pad % 2 === 0 ? 0xec : 0x11);
  }

  const rawCodewords = Math.floor(rawDataModules(config.version) / 8);
  const shortBlocks = config.blocks - rawCodewords % config.blocks;
  const shortBlockLength = Math.floor(rawCodewords / config.blocks);
  const divisor = divisorFor(config.eccCodewords);
  const blocks = [];
  for (let index = 0, offset = 0; index < config.blocks; index += 1) {
    const dataLength = shortBlockLength - config.eccCodewords + (index < shortBlocks ? 0 : 1);
    const blockData = data.slice(offset, offset + dataLength);
    offset += dataLength;
    blocks.push({ data: blockData, ecc: remainderFor(blockData, divisor) });
  }

  const codewords = [];
  const maximumDataLength = Math.max(...blocks.map((block) => block.data.length));
  for (let index = 0; index < maximumDataLength; index += 1) {
    blocks.forEach((block) => {
      if (index < block.data.length) codewords.push(block.data[index]);
    });
  }
  for (let index = 0; index < config.eccCodewords; index += 1) {
    blocks.forEach((block) => codewords.push(block.ecc[index]));
  }
  return { config, codewords };
}

function bit(value, index) {
  return ((value >>> index) & 1) !== 0;
}

function alignmentPositions(version, size) {
  if (version === 1) return [];
  const count = Math.floor(version / 7) + 2;
  const step = Math.floor((version * 8 + count * 3 + 5) / (count * 4 - 4)) * 2;
  const result = [6];
  for (let position = size - 7; result.length < count; position -= step) {
    result.splice(1, 0, position);
  }
  return result;
}

export function createQrMatrix(text) {
  const { config, codewords } = encodeCodewords(text);
  const size = config.version * 4 + 17;
  const modules = Array.from({ length: size }, () => Array(size).fill(false));
  const functions = Array.from({ length: size }, () => Array(size).fill(false));

  const setFunction = (x, y, dark) => {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    modules[y][x] = Boolean(dark);
    functions[y][x] = true;
  };

  for (let index = 0; index < size; index += 1) {
    setFunction(6, index, index % 2 === 0);
    setFunction(index, 6, index % 2 === 0);
  }

  const drawFinder = (centerX, centerY) => {
    for (let dy = -4; dy <= 4; dy += 1) {
      for (let dx = -4; dx <= 4; dx += 1) {
        const distance = Math.max(Math.abs(dx), Math.abs(dy));
        setFunction(centerX + dx, centerY + dy, distance !== 2 && distance !== 4);
      }
    }
  };
  drawFinder(3, 3);
  drawFinder(size - 4, 3);
  drawFinder(3, size - 4);

  const alignments = alignmentPositions(config.version, size);
  alignments.forEach((x, xIndex) => alignments.forEach((y, yIndex) => {
    const last = alignments.length - 1;
    if ((xIndex === 0 && yIndex === 0) ||
        (xIndex === 0 && yIndex === last) ||
        (xIndex === last && yIndex === 0)) return;
    for (let dy = -2; dy <= 2; dy += 1) {
      for (let dx = -2; dx <= 2; dx += 1) {
        setFunction(x + dx, y + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
      }
    }
  }));

  if (config.version >= 7) {
    let remainder = config.version;
    for (let index = 0; index < 12; index += 1) {
      remainder = (remainder << 1) ^ ((remainder >>> 11) * 0x1f25);
    }
    const versionBits = (config.version << 12) | remainder;
    for (let index = 0; index < 18; index += 1) {
      const color = bit(versionBits, index);
      const first = size - 11 + index % 3;
      const second = Math.floor(index / 3);
      setFunction(first, second, color);
      setFunction(second, first, color);
    }
  }

  const formatData = 0b01 << 3; // Error correction L, mask 0.
  let formatRemainder = formatData;
  for (let index = 0; index < 10; index += 1) {
    formatRemainder = (formatRemainder << 1) ^ ((formatRemainder >>> 9) * 0x537);
  }
  const formatBits = ((formatData << 10) | formatRemainder) ^ 0x5412;
  for (let index = 0; index <= 5; index += 1) setFunction(8, index, bit(formatBits, index));
  setFunction(8, 7, bit(formatBits, 6));
  setFunction(8, 8, bit(formatBits, 7));
  setFunction(7, 8, bit(formatBits, 8));
  for (let index = 9; index < 15; index += 1) setFunction(14 - index, 8, bit(formatBits, index));
  for (let index = 0; index < 8; index += 1) setFunction(size - 1 - index, 8, bit(formatBits, index));
  for (let index = 8; index < 15; index += 1) setFunction(8, size - 15 + index, bit(formatBits, index));
  setFunction(8, size - 8, true);

  let dataIndex = 0;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vertical = 0; vertical < size; vertical += 1) {
      const upward = ((right + 1) & 2) === 0;
      const y = upward ? size - 1 - vertical : vertical;
      for (let column = 0; column < 2; column += 1) {
        const x = right - column;
        if (functions[y][x]) continue;
        const raw = dataIndex < codewords.length * 8
          ? bit(codewords[dataIndex >>> 3], 7 - (dataIndex & 7))
          : false;
        modules[y][x] = raw !== ((x + y) % 2 === 0);
        if (dataIndex < codewords.length * 8) dataIndex += 1;
      }
    }
  }
  if (dataIndex !== codewords.length * 8) throw new Error("QR 数据布局失败");
  return modules;
}
