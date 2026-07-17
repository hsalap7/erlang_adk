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
