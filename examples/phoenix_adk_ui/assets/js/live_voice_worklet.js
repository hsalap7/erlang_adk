import {StreamingPcmDownsampler, encodePcm16Le} from "./pcm_downsampler.mjs"

class AdkPcmCaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super()
    const processorOptions = options.processorOptions || {}
    this.targetSampleRate = processorOptions.targetSampleRate || 16_000
    this.chunkSamples = processorOptions.chunkSamples || 320
    const requestedCredit = Number(processorOptions.maxInFlightChunks)
    this.maxInFlightChunks =
      Number.isInteger(requestedCredit) && requestedCredit >= 1 && requestedCredit <= 50
        ? requestedCredit
        : 16
    this.downsampler = new StreamingPcmDownsampler({
      sourceSampleRate: sampleRate,
      targetSampleRate: this.targetSampleRate,
      chunkSamples: this.chunkSamples,
    })
    this.active = true
    this.downmixBuffer = new Float32Array(0)
    this.pcmCredit = this.maxInFlightChunks
    this.overflowNotified = false
    this.latestLevel = null
    this.levelFrames = 0
    this.levelSumSquares = 0
    this.emitChunk = (chunk) => {
      if (this.pcmCredit > 0) {
        this.pcmCredit -= 1
        const buffer = encodePcm16Le(chunk)
        this.port.postMessage({type: "pcm", buffer, level: this.latestLevel}, [buffer])
        this.latestLevel = null
      } else if (!this.overflowNotified) {
        this.overflowNotified = true
        this.port.postMessage({type: "overflow"})
      }
    }

    this.port.onmessage = (event) => {
      if (event.data?.type === "active") {
        this.active = Boolean(event.data.value)
        if (!this.active) this.reset()
      } else if (event.data?.type === "credit") {
        const count = Number(event.data.count)
        if (Number.isInteger(count) && count > 0) {
          this.pcmCredit = Math.min(this.maxInFlightChunks, this.pcmCredit + count)
          this.overflowNotified = false
        }
      }
    }
  }

  reset() {
    this.downsampler.reset()
    this.levelFrames = 0
    this.levelSumSquares = 0
    this.pcmCredit = this.maxInFlightChunks
    this.overflowNotified = false
    this.latestLevel = null
    this.port.postMessage({type: "level", value: 0})
  }

  process(inputs, outputs) {
    const outputChannel = outputs[0]?.[0]
    if (outputChannel) outputChannel.fill(0)

    const inputChannels = inputs[0]
    const frameCount = inputChannels?.[0]?.length || 0
    if (!this.active || !inputChannels || inputChannels.length === 0 || frameCount === 0) {
      return true
    }

    let input = inputChannels[0]
    if (inputChannels.length > 1) {
      if (this.downmixBuffer.length !== frameCount) {
        this.downmixBuffer = new Float32Array(frameCount)
      }
      input = this.downmixBuffer
      input.fill(0)

      for (const channel of inputChannels) {
        if (!channel || channel.length !== frameCount) continue
        for (let index = 0; index < frameCount; index += 1) input[index] += channel[index]
      }
      for (let index = 0; index < frameCount; index += 1) input[index] /= inputChannels.length
    }

    for (let index = 0; index < input.length; index += 1) {
      const value = input[index]
      this.levelSumSquares += value * value
    }

    this.levelFrames += input.length
    if (this.levelFrames >= sampleRate / 20) {
      const rms = Math.sqrt(this.levelSumSquares / this.levelFrames)
      this.latestLevel = Math.min(1, rms * 4)
      this.levelFrames = 0
      this.levelSumSquares = 0
    }

    this.downsampler.push(input, this.emitChunk)

    return true
  }
}

registerProcessor("adk-pcm-capture", AdkPcmCaptureProcessor)
