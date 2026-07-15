import assert from "node:assert/strict"
import test from "node:test"

import {StreamingPcmDownsampler, encodePcm16Le} from "./pcm_downsampler.mjs"

const TARGET_RATE = 16_000
const CHUNK_SAMPLES = 320

function sine(sampleRate, frequency, seconds = 1) {
  const result = new Float32Array(sampleRate * seconds)
  for (let index = 0; index < result.length; index += 1) {
    result[index] = Math.sin((2 * Math.PI * frequency * index) / sampleRate)
  }
  return result
}

function stream(sourceSampleRate, samples, blockSizes) {
  const downsampler = new StreamingPcmDownsampler({
    sourceSampleRate,
    targetSampleRate: TARGET_RATE,
    chunkSamples: CHUNK_SAMPLES,
  })
  const chunks = []
  let offset = 0
  let blockIndex = 0

  while (offset < samples.length) {
    const blockSize = blockSizes[blockIndex % blockSizes.length]
    const end = Math.min(samples.length, offset + blockSize)
    downsampler.push(samples.slice(offset, end), (chunk) => chunks.push(chunk))
    offset = end
    blockIndex += 1
  }

  const output = new Float32Array(chunks.length * CHUNK_SAMPLES)
  chunks.forEach((chunk, index) => output.set(chunk, index * CHUNK_SAMPLES))
  return {chunks, output}
}

function rms(samples, start = 0) {
  let sumSquares = 0
  for (let index = start; index < samples.length; index += 1) {
    sumSquares += samples[index] * samples[index]
  }
  return Math.sqrt(sumSquares / (samples.length - start))
}

for (const sourceSampleRate of [48_000, 44_100]) {
  test(`${sourceSampleRate} Hz produces exactly one second of 16 kHz 20 ms chunks`, () => {
    const input = new Float32Array(sourceSampleRate)
    const {chunks, output} = stream(sourceSampleRate, input, [128])

    assert.equal(chunks.length, 50)
    assert.equal(output.length, TARGET_RATE)
    chunks.forEach((chunk) => assert.equal(chunk.length, CHUNK_SAMPLES))
  })
}

test("fractional resampling is identical across arbitrary render-block boundaries", () => {
  const input = sine(44_100, 1_137)
  const contiguous = stream(44_100, input, [input.length]).output
  const fragmented = stream(44_100, input, [1, 127, 19, 256, 3, 64]).output

  assert.equal(fragmented.length, contiguous.length)
  for (let index = 0; index < contiguous.length; index += 1) {
    assert.equal(fragmented[index], contiguous[index], `sample ${index}`)
  }
})

test("the anti-alias filter strongly attenuates content above the 16 kHz Nyquist limit", () => {
  const passband = stream(48_000, sine(48_000, 1_000), [128]).output
  const stopband = stream(48_000, sine(48_000, 12_000), [128]).output
  const transientSamples = 1_000
  const passbandRms = rms(passband, transientSamples)
  const stopbandRms = rms(stopband, transientSamples)

  assert.ok(passbandRms > 0.6, `unexpected passband RMS ${passbandRms}`)
  assert.ok(
    stopbandRms < passbandRms * 0.02,
    `stopband RMS ${stopbandRms} was not sufficiently below ${passbandRms}`,
  )
})

for (const sourceSampleRate of [44_100, 48_000, 96_000]) {
  test(`${sourceSampleRate} Hz rejects tones immediately above the output Nyquist limit`, () => {
    const passband = stream(sourceSampleRate, sine(sourceSampleRate, 1_000), [128]).output
    const stopband = stream(sourceSampleRate, sine(sourceSampleRate, 8_100), [128]).output
    const transientSamples = 2_000
    const passbandRms = rms(passband, transientSamples)
    const stopbandRms = rms(stopband, transientSamples)

    assert.ok(
      stopbandRms < passbandRms * 0.01,
      `8.1 kHz RMS ${stopbandRms} was not sufficiently below ${passbandRms}`,
    )
  })
}

test("PCM serialization is signed 16-bit little-endian and clamps safely", () => {
  const encoded = encodePcm16Le(new Float32Array([-1, -0.5, 0, 0.5, 1, 2, Number.NaN]))

  assert.deepEqual(
    Array.from(new Uint8Array(encoded)),
    [0x00, 0x80, 0x00, 0xc0, 0x00, 0x00, 0x00, 0x40, 0xff, 0x7f, 0xff, 0x7f, 0x00, 0x00],
  )
})

test("source sample rates above the supported 96 kHz ceiling are rejected", () => {
  assert.throws(
    () => new StreamingPcmDownsampler({sourceSampleRate: 192_000}),
    {
      name: "RangeError",
      message: "sourceSampleRate must be less than or equal to 96000",
    },
  )
})
