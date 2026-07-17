import assert from "node:assert/strict"
import test from "node:test"

let Processor

globalThis.sampleRate = 48_000
globalThis.AudioWorkletProcessor = class {
  constructor() {
    this.port = {
      messages: [],
      onmessage: null,
      postMessage: (message) => this.port.messages.push(message),
    }
  }
}
globalThis.registerProcessor = (_name, implementation) => { Processor = implementation }

await import("./live_voice_worklet.js")

test("capture downmixes every input channel before resampling", () => {
  const processor = new Processor({
    processorOptions: {targetSampleRate: 16_000, chunkSamples: 320},
  })
  const silent = new Float32Array(128)
  const right = new Float32Array(128).fill(0.5)
  const output = [[new Float32Array(128)]]

  for (let block = 0; block < 8; block += 1) {
    processor.process([[silent, right]], output)
  }

  const pcm = processor.port.messages.find((message) => message.type === "pcm")
  assert.ok(pcm, "expected a complete 20 ms PCM chunk")
  const samples = new Int16Array(pcm.buffer)
  assert.ok(samples.some((sample) => Math.abs(sample) > 1_000), "right channel was omitted")
  assert.ok(output[0][0].every((sample) => sample === 0), "worklet output must remain silent")
})

test("capture bounds worklet-to-main PCM messages when the main thread stalls", () => {
  const processor = new Processor({
    processorOptions: {
      targetSampleRate: 16_000,
      chunkSamples: 320,
      maxInFlightChunks: 16,
    },
  })
  const input = new Float32Array(128).fill(0.25)
  const output = [[new Float32Array(128)]]

  for (let block = 0; block < 200; block += 1) processor.process([[input]], output)

  const pcm = processor.port.messages.filter((message) => message.type === "pcm")
  const overflow = processor.port.messages.filter((message) => message.type === "overflow")
  assert.equal(pcm.length, 16)
  assert.equal(overflow.length, 1)
  assert.equal(processor.port.messages.filter((message) => message.type === "level").length, 0)
})

test("capture produces 20 ms chunks at the negotiated 24 kHz rate", () => {
  const processor = new Processor({
    processorOptions: {targetSampleRate: 24_000, chunkSamples: 480},
  })
  const input = new Float32Array(128).fill(0.25)
  const output = [[new Float32Array(128)]]

  for (let block = 0; block < 8; block += 1) processor.process([[input]], output)

  const pcm = processor.port.messages.find((message) => message.type === "pcm")
  assert.ok(pcm)
  assert.equal(pcm.buffer.byteLength, 480 * 2)
})

test("capture safely upsamples a 16 kHz device context to negotiated 24 kHz", () => {
  const originalSampleRate = globalThis.sampleRate
  globalThis.sampleRate = 16_000
  try {
    const processor = new Processor({
      processorOptions: {targetSampleRate: 24_000, chunkSamples: 480},
    })
    const input = new Float32Array(128).fill(0.25)
    const output = [[new Float32Array(128)]]

    for (let block = 0; block < 4; block += 1) processor.process([[input]], output)

    const pcm = processor.port.messages.find((message) => message.type === "pcm")
    assert.ok(pcm, "expected an upsampled 20 ms PCM chunk")
    assert.equal(pcm.buffer.byteLength, 480 * 2)
  } finally {
    globalThis.sampleRate = originalSampleRate
  }
})

test("capture rejects rates outside the negotiated protocol allow-list", () => {
  assert.throws(
    () => new Processor({processorOptions: {targetSampleRate: 48_000}}),
    /unsupported voice input sample rate/,
  )
})
