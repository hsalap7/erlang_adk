import assert from "node:assert/strict"
import test from "node:test"

import {LiveVoice} from "./live_voice.js"

class FakeSocket {
  static CONNECTING = 0
  static OPEN = 1
  static CLOSING = 2
  static CLOSED = 3

  constructor() {
    this.readyState = FakeSocket.CONNECTING
    this.bufferedAmount = 0
    this.listeners = new Map()
    this.sent = []
  }

  addEventListener(name, callback) {
    const callbacks = this.listeners.get(name) || new Set()
    callbacks.add(callback)
    this.listeners.set(name, callbacks)
  }

  removeEventListener(name, callback) {
    this.listeners.get(name)?.delete(callback)
  }

  dispatch(name) {
    for (const callback of this.listeners.get(name) || []) callback()
    if (name === "close") this.onclose?.()
    if (name === "error") this.onerror?.()
  }

  send(frame) {
    this.sent.push(frame)
  }

  close() {
    if (this.readyState >= FakeSocket.CLOSING) return
    this.readyState = FakeSocket.CLOSED
    this.dispatch("close")
  }
}

class FakeAudioContext {
  constructor() {
    this.state = "suspended"
    this.currentTime = 0
    this.audioWorklet = {addModule: async () => {}}
  }

  async resume() {
    this.state = "running"
  }

  async close() {
    this.state = "closed"
  }
}

function element() {
  return {
    disabled: false,
    textContent: "",
    style: {},
    setAttribute(name, value) {
      this[name] = value
    },
  }
}

function hook() {
  return Object.assign(Object.create(LiveVoice), {
    el: {
      dataset: {
        sessionId: "live-test",
        voicePath: "/live/voice",
        workletUrl: "/assets/js/live_voice_worklet.js",
      },
    },
    sessionId: "live-test",
    generation: 0,
    running: false,
    starting: false,
    muted: false,
    inputSequence: 0n,
    lastServerSequence: 0n,
    transcripts: {input: "", output: ""},
    transcriptFinal: {input: true, output: true},
    resetTranscriptOnInput: false,
    playbackCursor: 0,
    playbackSources: new Set(),
    scheduledAudioSeconds: 0,
    pendingAudioFrames: [],
    pendingAudioBytes: 0,
    socket: null,
    audioContext: null,
    stream: null,
    sourceNode: null,
    captureNode: null,
    silentGain: null,
    startButton: element(),
    muteButton: element(),
    stopButton: element(),
    status: element(),
    transcript: element(),
    transcriptAnnouncement: element(),
    level: element(),
  })
}

function installBrowser(socketFactory, getUserMedia) {
  globalThis.WebSocket = class extends FakeSocket {
    constructor() {
      super()
      socketFactory(this)
    }
  }
  Object.assign(globalThis.WebSocket, {
    CONNECTING: FakeSocket.CONNECTING,
    OPEN: FakeSocket.OPEN,
    CLOSING: FakeSocket.CLOSING,
    CLOSED: FakeSocket.CLOSED,
  })

  globalThis.window = {
    location: {protocol: "http:", host: "127.0.0.1:4000"},
    AudioContext: FakeAudioContext,
    AudioWorkletNode: class {},
    setTimeout,
    clearTimeout,
    queueMicrotask,
  }
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {mediaDevices: {getUserMedia}},
  })
}

function lifecycleFrame(sequence, state) {
  const frame = new ArrayBuffer(11)
  const view = new DataView(frame)
  view.setUint8(0, 1)
  view.setUint8(1, 131)
  view.setBigUint64(2, BigInt(sequence))
  view.setUint8(10, state)
  return frame
}

function audioFrame(sequence, samples = 320, sampleRate = 24_000, channels = 1) {
  const frame = new ArrayBuffer(15 + samples * channels * 2)
  const view = new DataView(frame)
  view.setUint8(0, 1)
  view.setUint8(1, 129)
  view.setBigUint64(2, BigInt(sequence))
  view.setUint32(10, sampleRate)
  view.setUint8(14, channels)
  return frame
}

function playbackContext() {
  const starts = []
  const sources = []
  const context = {
    state: "running",
    currentTime: 0,
    destination: {},
    async close() {
      this.state = "closed"
    },
    createBuffer(channels, frameCount, sampleRate) {
      const channelData = Array.from({length: channels}, () => new Float32Array(frameCount))
      return {
        duration: frameCount / sampleRate,
        getChannelData: (channel) => channelData[channel],
      }
    },
    createBufferSource() {
      let ended = null
      const source = {
        stopped: false,
        connect() {},
        disconnect() {},
        addEventListener(name, callback) {
          if (name === "ended") ended = callback
        },
        start(at) {
          starts.push(at)
        },
        stop() {
          this.stopped = true
        },
        finish() {
          const callback = ended
          ended = null
          callback?.()
        },
      }
      sources.push(source)
      return source
    },
  }
  return {context, starts, sources}
}

test("a microphone granted after Stop is immediately released", async () => {
  let resolvePermission
  let socket
  let stopped = 0
  const permission = new Promise((resolve) => { resolvePermission = resolve })
  installBrowser((created) => { socket = created }, () => permission)

  const voice = hook()
  voice.playbackCursor = 123
  const startup = voice.startVoice()
  assert.equal(voice.starting, true)
  assert.equal(voice.playbackCursor, 0)

  voice.stopVoice()
  assert.equal(voice.starting, false)
  assert.equal(socket.readyState, FakeSocket.CLOSED)

  const track = {stop: () => { stopped += 1 }, addEventListener: () => {}}
  resolvePermission({
    getTracks: () => [track],
    getAudioTracks: () => [track],
  })
  await startup

  assert.equal(stopped, 1)
  assert.equal(voice.stream, null)
  assert.equal(voice.running, false)
})

for (const [state, expected] of [
  [5, "reconnecting"],
  [8, "session closed"],
  [9, "session error"],
]) {
  test(`lifecycle ${state} is acknowledged before capture is terminated`, async () => {
    installBrowser(() => {}, async () => { throw new Error("unused") })
    const voice = hook()
    const socket = new FakeSocket()
    socket.readyState = FakeSocket.OPEN
    voice.socket = socket
    voice.audioContext = new FakeAudioContext()
    voice.audioContext.state = "running"
    voice.running = true
    voice.generation = 1

    voice.handleServerMessage(lifecycleFrame(1, state))
    assert.equal(socket.sent.length, 1)
    assert.equal(new DataView(socket.sent[0]).getUint8(1), 3)

    await Promise.resolve()
    assert.equal(voice.running, false)
    assert.equal(socket.readyState, FakeSocket.CLOSED)
    assert.match(voice.status.textContent, new RegExp(expected, "i"))
  })
}

test("transcripts are separated by direction and bounded", () => {
  const voice = hook()
  voice.appendTranscript("input", "hello", false)
  voice.appendTranscript("input", "hello world", true)
  voice.appendTranscript("output", "x".repeat(5_000), true)

  assert.equal(voice.transcripts.input, "hello world")
  assert.equal(voice.transcripts.output.length, 4_096)
  assert.match(voice.transcript.textContent, /^You: hello world\nModel: /)
  assert.equal(voice.transcriptAnnouncement.textContent, `Model: ${"x".repeat(4_096)}`)
})

test("corrected input hypotheses replace the complete previous hypothesis", () => {
  const voice = hook()
  voice.appendTranscript("input", "I scream", false)
  voice.appendTranscript("input", "ice cream", true)

  assert.equal(voice.transcripts.input, "ice cream")
  assert.equal(voice.transcript.textContent, "You: ice cream")
  assert.equal(voice.transcriptAnnouncement.textContent, "You: ice cream")
})

test("ordered output transcription deltas append to the current model utterance", () => {
  const voice = hook()
  voice.appendTranscript("output", "Hello", false)
  voice.appendTranscript("output", ", world", false)
  voice.appendTranscript("output", "!", true)

  assert.equal(voice.transcripts.output, "Hello, world!")
  assert.equal(voice.transcript.textContent, "Model: Hello, world!")
  assert.equal(voice.transcriptAnnouncement.textContent, "Model: Hello, world!")
})

test("duplicate server sequences cannot apply transcript side effects", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  voice.socket = socket
  voice.running = true

  const transcriptionFrame = (sequence, text) => {
    const encoded = new TextEncoder().encode(text)
    const frame = new ArrayBuffer(12 + encoded.byteLength)
    const view = new DataView(frame)
    view.setUint8(0, 1)
    view.setUint8(1, 130)
    view.setBigUint64(2, BigInt(sequence))
    view.setUint8(10, 2)
    view.setUint8(11, 1)
    new Uint8Array(frame, 12).set(encoded)
    return frame
  }

  voice.handleServerMessage(transcriptionFrame(1, "first"))
  assert.equal(voice.transcripts.output, "first")
  assert.equal(socket.sent.length, 1)

  voice.handleServerMessage(transcriptionFrame(1, "duplicate"))
  assert.equal(voice.transcripts.output, "first")
  assert.equal(socket.sent.length, 1)
  assert.equal(socket.readyState, FakeSocket.CLOSED)
})

test("an AudioWorklet processor failure closes the active voice generation", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  const captureNode = {port: {onmessage: null, postMessage() {}, close() {}}, disconnect() {}}
  voice.socket = socket
  voice.captureNode = captureNode
  voice.audioContext = new FakeAudioContext()
  voice.running = true
  voice.generation = 7

  captureNode.onprocessorerror = () => {
    if (voice.currentCapture(7, captureNode)) {
      voice.protocolFailure("Microphone audio processing failed. Restart voice to try again.")
    }
  }
  captureNode.onprocessorerror()

  assert.equal(voice.running, false)
  assert.equal(socket.readyState, FakeSocket.CLOSED)
  assert.match(voice.status.textContent, /audio processing failed/i)
})

test("an unexpected AudioContext state change terminates capture and playback", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  const audioContext = new FakeAudioContext()
  audioContext.state = "running"
  voice.socket = socket
  voice.audioContext = audioContext
  voice.running = true
  voice.generation = 3
  audioContext.onstatechange = () => voice.handleAudioContextState(3, audioContext)

  audioContext.state = "suspended"
  audioContext.onstatechange()

  assert.equal(voice.running, false)
  assert.equal(voice.audioContext, null)
  assert.equal(audioContext.state, "closed")
  assert.equal(audioContext.onstatechange, null)
  assert.equal(socket.readyState, FakeSocket.CLOSED)
  assert.match(voice.status.textContent, /audio was interrupted/i)
})

test("audio is not acknowledged when suspension races ahead of statechange delivery", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  const audioContext = new FakeAudioContext()
  audioContext.state = "suspended"
  voice.socket = socket
  voice.audioContext = audioContext
  voice.running = true
  voice.generation = 4

  voice.handleServerMessage(audioFrame(1))

  assert.equal(socket.sent.length, 0)
  assert.equal(voice.running, false)
  assert.equal(socket.readyState, FakeSocket.CLOSED)
  assert.match(voice.status.textContent, /audio was interrupted/i)
})

test("server activity cannot visually unmute a muted microphone", () => {
  const voice = hook()
  voice.muted = true

  voice.handleLifecycleFrame(lifecycleFrame(1, 3), new DataView(lifecycleFrame(1, 3)))

  assert.equal(voice.el.dataset.voiceState, "muted")
  assert.match(voice.status.textContent, /remains muted/i)
  refuteActive(voice.status.textContent)
})

function refuteActive(message) {
  assert.doesNotMatch(message, /microphone is active/i)
}

test("outbound buffering is capped and closes the voice generation", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  socket.bufferedAmount = 262_140
  voice.socket = socket
  voice.running = true

  assert.equal(voice.sendFrame(new ArrayBuffer(8)), false)
  assert.equal(socket.readyState, FakeSocket.CLOSED)
  assert.equal(voice.running, false)
  assert.match(voice.status.textContent, /fell behind/)
})

test("a failed microphone send terminates without returning worklet credit", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.CLOSING
  const portMessages = []
  voice.socket = socket
  voice.running = true
  voice.audioContext = new FakeAudioContext()
  voice.audioContext.state = "running"
  voice.captureNode = {
    onprocessorerror: null,
    port: {
      onmessage: null,
      postMessage: (message) => portMessages.push(message),
      close() {},
    },
    disconnect() {},
  }

  voice.handleCapture({type: "pcm", buffer: new ArrayBuffer(640), level: 0.25})

  assert.equal(voice.running, false)
  assert.equal(portMessages.some((message) => message.type === "credit"), false)
  assert.deepEqual(portMessages, [{type: "active", value: false}])
  assert.match(voice.status.textContent, /no longer writable/i)
})

test("one long server audio frame is segmented without dropping its unscheduled tail", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  const {context, starts, sources} = playbackContext()
  voice.socket = socket
  voice.audioContext = context
  voice.running = true

  voice.handleServerMessage(audioFrame(1, 60_000))

  assert.equal(starts.length, 20)
  assert.equal(voice.pendingAudioFrames.length, 1)
  assert.equal(voice.pendingAudioFrames[0].offset, 96_000)
  assert.equal(socket.sent.length, 0, "the partial frame must retain exact ACK credit")

  for (let index = 0; index < 5; index += 1) {
    context.currentTime = starts[index] + 0.1
    sources[index].finish()
  }

  assert.equal(starts.length, 25)
  assert.equal(voice.pendingAudioFrames.length, 0)
  assert.equal(socket.sent.length, 1)
  assert.equal(new DataView(socket.sent[0]).getBigUint64(2), 1n)
})

test("jittered PCM frame arrivals remain sample-contiguous while playback is buffered", () => {
  const voice = hook()
  const {context, starts} = playbackContext()
  const pcm20ms = new ArrayBuffer(480 * 2)
  voice.audioContext = context

  voice.scheduleAudioSegment(pcm20ms, 24_000, 1)
  context.currentTime = 0.027
  voice.scheduleAudioSegment(pcm20ms, 24_000, 1)
  context.currentTime = 0.053
  voice.scheduleAudioSegment(pcm20ms, 24_000, 1)

  assert.equal(starts.length, 3)
  assert.ok(starts[0] >= 0.05, `initial jitter buffer was only ${starts[0]} seconds`)
  assert.ok(Math.abs(starts[1] - (starts[0] + 0.02)) < 1e-9)
  assert.ok(Math.abs(starts[2] - (starts[1] + 0.02)) < 1e-9)
})

test("bursty long replies remain continuous and bounded by deferred exact ACK credit", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  const {context, starts, sources} = playbackContext()
  voice.socket = socket
  voice.audioContext = context
  voice.running = true

  for (let sequence = 1; sequence <= 28; sequence += 1) {
    voice.handleServerMessage(audioFrame(sequence, 2_400))
  }

  assert.equal(voice.playbackSources.size, 20)
  assert.ok(voice.scheduledAudioSeconds <= 2 + 1e-9)
  assert.equal(voice.pendingAudioFrames.length, 8)
  assert.ok(voice.pendingAudioBytes <= 262_144)
  assert.deepEqual(
    socket.sent.map((frame) => new DataView(frame).getBigUint64(2)),
    Array.from({length: 20}, (_value, index) => BigInt(index + 1)),
  )

  for (let index = 0; index < 8; index += 1) {
    context.currentTime = starts[index] + 0.1
    sources[index].finish()
  }

  assert.equal(voice.playbackSources.size, 20)
  assert.ok(voice.scheduledAudioSeconds <= 2 + 1e-9)
  assert.equal(voice.pendingAudioFrames.length, 0)
  assert.equal(starts.length, 28)
  for (let index = 1; index < starts.length; index += 1) {
    assert.ok(Math.abs(starts[index] - (starts[index - 1] + 0.1)) < 1e-9)
  }
  assert.deepEqual(
    socket.sent.map((frame) => new DataView(frame).getBigUint64(2)),
    Array.from({length: 28}, (_value, index) => BigInt(index + 1)),
  )
})

test("interruption releases canceled pending credit and cannot drain stale audio later", () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  const {context, sources} = playbackContext()
  voice.socket = socket
  voice.audioContext = context
  voice.running = true

  for (let sequence = 1; sequence <= 27; sequence += 1) {
    voice.handleServerMessage(audioFrame(sequence, 2_400))
  }
  voice.handleServerMessage(lifecycleFrame(28, 4))

  assert.equal(voice.pendingAudioFrames.length, 0)
  assert.equal(voice.pendingAudioBytes, 0)
  assert.equal(voice.playbackSources.size, 0)
  assert.equal(voice.scheduledAudioSeconds, 0)
  assert.ok(sources.slice(0, 20).every((source) => source.stopped))
  assert.deepEqual(
    socket.sent.map((frame) => new DataView(frame).getBigUint64(2)),
    Array.from({length: 28}, (_value, index) => BigInt(index + 1)),
  )

  sources.forEach((source) => source.finish())
  assert.equal(socket.sent.length, 28, "stale ended callbacks must not ACK or reschedule")
})

test("terminal cleanup drops pending audio without stale ACKs before closing", async () => {
  installBrowser(() => {}, async () => { throw new Error("unused") })
  const voice = hook()
  const socket = new FakeSocket()
  socket.readyState = FakeSocket.OPEN
  const {context, sources} = playbackContext()
  voice.socket = socket
  voice.audioContext = context
  voice.running = true
  voice.generation = 6

  for (let sequence = 1; sequence <= 22; sequence += 1) {
    voice.handleServerMessage(audioFrame(sequence, 2_400))
  }
  voice.handleServerMessage(lifecycleFrame(23, 8))
  await Promise.resolve()

  const acknowledged = socket.sent.map((frame) => new DataView(frame).getBigUint64(2))
  assert.deepEqual(acknowledged, [
    ...Array.from({length: 20}, (_value, index) => BigInt(index + 1)),
    23n,
  ])
  assert.equal(voice.pendingAudioFrames.length, 0)
  assert.equal(voice.playbackSources.size, 0)
  assert.equal(socket.readyState, FakeSocket.CLOSED)

  sources.forEach((source) => source.finish())
  assert.equal(socket.sent.length, 21, "terminal cleanup must not ACK stale pending frames")
})

test("retryable WebSocket close codes give actionable session guidance", () => {
  const voice = hook()
  assert.match(voice.socketCloseMessage({code: 1012}), /reconnecting/)
  assert.match(voice.socketCloseMessage({code: 1013, reason: "voice session not active"}), /not active/)
  assert.match(
    voice.socketCloseMessage({code: 1008, reason: "automatic activity detection required"}),
    /automatic activity detection/,
  )
  assert.match(voice.socketCloseMessage({code: 1008, reason: "authentication expired"}), /sign in/i)
  assert.match(
    voice.socketCloseMessage({code: 1013, reason: "voice session already in use"}),
    /other tab/i,
  )
  assert.match(voice.socketCloseMessage({code: 1002}), /desynchronised/i)
  assert.match(voice.socketCloseMessage({code: 1009}), /size limit/i)
  assert.match(
    voice.socketCloseMessage({code: 1011, reason: "voice outcome unknown"}),
    /avoid duplicate audio/i,
  )
})
