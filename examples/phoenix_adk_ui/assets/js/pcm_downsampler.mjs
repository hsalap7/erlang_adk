const DEFAULT_TARGET_SAMPLE_RATE = 16_000
const DEFAULT_CHUNK_SAMPLES = 320
const MINIMUM_FILTER_TAPS = 127
const FILTER_REFERENCE_SAMPLE_RATE = 48_000
const MAXIMUM_SOURCE_SAMPLE_RATE = 96_000
const CUTOFF_FRACTION_OF_TARGET_RATE = 0.45
const POSITION_EPSILON = 1e-9

function sinc(value) {
  if (value === 0) return 1
  const radians = Math.PI * value
  return Math.sin(radians) / radians
}

function lowPassCoefficients(sourceSampleRate, targetSampleRate, taps) {
  const midpoint = (taps - 1) / 2
  const normalizedCutoff =
    (Math.min(sourceSampleRate, targetSampleRate) * CUTOFF_FRACTION_OF_TARGET_RATE) /
    sourceSampleRate
  const coefficients = new Float64Array(taps)
  let total = 0

  for (let index = 0; index < taps; index += 1) {
    const distance = index - midpoint
    const blackman =
      0.42 -
      0.5 * Math.cos((2 * Math.PI * index) / (taps - 1)) +
      0.08 * Math.cos((4 * Math.PI * index) / (taps - 1))
    const coefficient =
      2 * normalizedCutoff * sinc(2 * normalizedCutoff * distance) * blackman
    coefficients[index] = coefficient
    total += coefficient
  }

  for (let index = 0; index < taps; index += 1) {
    coefficients[index] /= total
  }

  return coefficients
}

function checkedInteger(value, name, minimum) {
  if (!Number.isInteger(value) || value < minimum) {
    throw new RangeError(`${name} must be an integer greater than or equal to ${minimum}`)
  }
  return value
}

function defaultFilterTaps(sourceSampleRate) {
  const scaled = Math.ceil(
    (MINIMUM_FILTER_TAPS * sourceSampleRate) / FILTER_REFERENCE_SAMPLE_RATE,
  )
  const odd = scaled % 2 === 0 ? scaled + 1 : scaled
  return Math.max(MINIMUM_FILTER_TAPS, odd)
}

export function encodePcm16Le(samples) {
  if (!(samples instanceof Float32Array)) {
    throw new TypeError("samples must be a Float32Array")
  }

  const buffer = new ArrayBuffer(samples.length * 2)
  const view = new DataView(buffer)

  for (let index = 0; index < samples.length; index += 1) {
    const finite = Number.isFinite(samples[index]) ? samples[index] : 0
    const clamped = Math.max(-1, Math.min(1, finite))
    const integer = Math.round(clamped < 0 ? clamped * 32_768 : clamped * 32_767)
    view.setInt16(index * 2, integer, true)
  }

  return buffer
}

export class StreamingPcmDownsampler {
  constructor({
    sourceSampleRate,
    targetSampleRate = DEFAULT_TARGET_SAMPLE_RATE,
    chunkSamples = DEFAULT_CHUNK_SAMPLES,
    filterTaps,
  }) {
    this.sourceSampleRate = checkedInteger(sourceSampleRate, "sourceSampleRate", 1)
    this.targetSampleRate = checkedInteger(targetSampleRate, "targetSampleRate", 1)
    this.chunkSamples = checkedInteger(chunkSamples, "chunkSamples", 1)

    if (this.sourceSampleRate > MAXIMUM_SOURCE_SAMPLE_RATE) {
      throw new RangeError(
        `sourceSampleRate must be less than or equal to ${MAXIMUM_SOURCE_SAMPLE_RATE}`,
      )
    }
    this.filterTaps = checkedInteger(
      filterTaps ?? defaultFilterTaps(this.sourceSampleRate),
      "filterTaps",
      3,
    )
    if (this.filterTaps % 2 === 0) {
      throw new RangeError("filterTaps must be odd")
    }

    this.step = this.sourceSampleRate / this.targetSampleRate
    this.coefficients = lowPassCoefficients(
      this.sourceSampleRate,
      this.targetSampleRate,
      this.filterTaps,
    )
    this.history = new Float64Array(this.filterTaps)
    this.output = new Float32Array(this.chunkSamples)
    this.reset()
  }

  reset() {
    this.history.fill(0)
    this.historyCursor = 0
    this.inputIndex = -1
    this.outputIndex = 0
    this.previousFiltered = 0
    this.outputLength = 0
    this.output.fill(0)
  }

  push(samples, onChunk) {
    if (!(samples instanceof Float32Array)) {
      throw new TypeError("samples must be a Float32Array")
    }
    if (typeof onChunk !== "function") {
      throw new TypeError("onChunk must be a function")
    }

    for (let index = 0; index < samples.length; index += 1) {
      const filtered = this.filter(Number.isFinite(samples[index]) ? samples[index] : 0)
      this.inputIndex += 1

      if (this.inputIndex === 0) {
        this.emit(filtered, onChunk)
        this.outputIndex += 1
        this.previousFiltered = filtered
        continue
      }

      let outputPosition = this.outputIndex * this.step
      while (outputPosition <= this.inputIndex + POSITION_EPSILON) {
        const fraction = Math.max(0, Math.min(1, outputPosition - (this.inputIndex - 1)))
        const interpolated =
          this.previousFiltered + (filtered - this.previousFiltered) * fraction
        this.emit(interpolated, onChunk)
        this.outputIndex += 1
        outputPosition = this.outputIndex * this.step
      }

      this.previousFiltered = filtered
    }
  }

  filter(sample) {
    this.history[this.historyCursor] = sample
    let value = 0
    let historyIndex = this.historyCursor

    for (let tap = 0; tap < this.filterTaps; tap += 1) {
      value += this.coefficients[tap] * this.history[historyIndex]
      historyIndex -= 1
      if (historyIndex < 0) historyIndex = this.filterTaps - 1
    }

    this.historyCursor += 1
    if (this.historyCursor === this.filterTaps) this.historyCursor = 0
    return value
  }

  emit(sample, onChunk) {
    this.output[this.outputLength] = sample
    this.outputLength += 1

    if (this.outputLength === this.chunkSamples) {
      const chunk = this.output
      this.output = new Float32Array(this.chunkSamples)
      this.outputLength = 0
      onChunk(chunk)
    }
  }
}
