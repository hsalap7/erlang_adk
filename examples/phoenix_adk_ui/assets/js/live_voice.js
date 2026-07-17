const PROTOCOL_VERSION = 1

const CLIENT_AUDIO = 1
const CLIENT_AUDIO_STREAM_END = 2
const CLIENT_ACK = 3

const SERVER_AUDIO = 129
const SERVER_TRANSCRIPTION = 130
const SERVER_LIFECYCLE = 131

const INPUT_SAMPLE_RATE = 16_000
const INPUT_CHANNELS = 1
const MAX_SERVER_FRAME_BYTES = 262_144
const MAX_SOCKET_BUFFER_BYTES = 262_144
const MAX_TRANSCRIPT_CHARS = 4_096
const MAX_SCHEDULED_SECONDS = 2
const MAX_SCHEDULED_SOURCES = 64
const MAX_PENDING_AUDIO_FRAMES = 8
const MAX_PENDING_AUDIO_BYTES = 262_144
const MAX_PLAYBACK_SEGMENT_SECONDS = 0.1
const PLAYBACK_REBUFFER_SECONDS = 0.08
const PLAYBACK_SCHEDULE_EPSILON_SECONDS = 0.005

class HandledVoiceError extends Error {}

const lifecycleNames = new Map([
  [1, "ready"],
  [2, "generation complete"],
  [3, "turn complete"],
  [4, "interrupted"],
  [5, "reconnecting"],
  [6, "session resumed"],
  [7, "server draining"],
  [8, "session closed"],
  [9, "session error"],
])

function websocketUrl(path, sessionId) {
  const scheme = window.location.protocol === "https:" ? "wss:" : "ws:"
  const base = path.endsWith("/") ? path.slice(0, -1) : path
  return `${scheme}//${window.location.host}${base}/${encodeURIComponent(sessionId)}`
}

function waitForSocket(socket, timeoutMs = 10_000) {
  return new Promise((resolve, reject) => {
    if (socket.readyState === WebSocket.OPEN) {
      resolve()
      return
    }
    if (socket.readyState >= WebSocket.CLOSING) {
      reject(new Error("voice socket closed before startup"))
      return
    }

    const cleanup = () => {
      window.clearTimeout(timer)
      socket.removeEventListener("open", opened)
      socket.removeEventListener("error", failed)
      socket.removeEventListener("close", failed)
    }
    const opened = () => {
      cleanup()
      resolve()
    }
    const failed = () => {
      cleanup()
      reject(new Error("voice socket could not connect"))
    }
    const timer = window.setTimeout(() => {
      cleanup()
      reject(new Error("voice socket timed out"))
    }, timeoutMs)

    socket.addEventListener("open", opened, {once: true})
    socket.addEventListener("error", failed, {once: true})
    socket.addEventListener("close", failed, {once: true})
  })
}

function closeReason(error) {
  if (error && error.name === "NotAllowedError") return "Microphone access was denied."
  if (error && error.name === "NotFoundError") return "No microphone is available."
  if (error && error.name === "NotReadableError") return "The microphone is already in use."
  return "Voice could not start. Check the server session and browser permissions."
}

export const LiveVoice = {
  mounted() {
    this.sessionId = this.el.dataset.sessionId
    this.generation = 0
    this.running = false
    this.starting = false
    this.muted = false
    this.inputSequence = 0n
    this.lastServerSequence = 0n
    this.playbackCursor = 0
    this.transcripts = {input: "", output: ""}
    this.transcriptFinal = {input: true, output: true}
    this.resetTranscriptOnInput = false
    this.playbackSources = new Set()
    this.scheduledAudioSeconds = 0
    this.pendingAudioFrames = []
    this.pendingAudioBytes = 0
    this.socket = null
    this.audioContext = null
    this.stream = null
    this.sourceNode = null
    this.captureNode = null
    this.silentGain = null

    this.startButton = this.el.querySelector("[data-voice-start]")
    this.muteButton = this.el.querySelector("[data-voice-mute]")
    this.stopButton = this.el.querySelector("[data-voice-stop]")
    this.status = this.el.querySelector("[data-voice-status]")
    this.transcript = this.el.querySelector("[data-voice-transcript]")
    this.transcriptAnnouncement = this.el.querySelector("[data-voice-announcement]")
    this.level = this.el.querySelector("[data-voice-level]")

    this.onStart = () => this.startVoice()
    this.onMute = () => this.toggleMute()
    this.onStop = () => this.stopVoice()
    this.startButton.addEventListener("click", this.onStart)
    this.muteButton.addEventListener("click", this.onMute)
    this.stopButton.addEventListener("click", this.onStop)
    this.renderControls()
  },

  updated() {
    const nextSessionId = this.el.dataset.sessionId
    if (nextSessionId !== this.sessionId) {
      this.stopVoice()
      this.sessionId = nextSessionId
    }
    this.renderControls()
  },

  destroyed() {
    this.generation += 1
    this.running = false
    this.starting = false
    this.releaseVoice(true)
    this.startButton?.removeEventListener("click", this.onStart)
    this.muteButton?.removeEventListener("click", this.onMute)
    this.stopButton?.removeEventListener("click", this.onStop)
  },

  async startVoice() {
    if (this.running || this.starting) return

    const AudioContext = window.AudioContext || window.webkitAudioContext
    if (!navigator.mediaDevices?.getUserMedia || !AudioContext || !window.AudioWorkletNode) {
      this.setStatus("This browser does not provide the required Web Audio APIs.", "error")
      return
    }

    this.starting = true
    this.muted = false
    this.inputSequence = 0n
    this.lastServerSequence = 0n
    this.playbackCursor = 0
    this.scheduledAudioSeconds = 0
    this.pendingAudioFrames = []
    this.pendingAudioBytes = 0
    this.transcripts = {input: "", output: ""}
    this.transcriptFinal = {input: true, output: true}
    this.resetTranscriptOnInput = false
    this.transcript.textContent = ""
    if (this.transcriptAnnouncement) this.transcriptAnnouncement.textContent = ""
    this.setStatus("Connecting the authenticated voice bridge…", "connecting")
    this.renderControls()

    const generation = ++this.generation

    try {
      const audioContext = new AudioContext({latencyHint: "interactive"})
      this.audioContext = audioContext
      audioContext.onstatechange = () => this.handleAudioContextState(generation, audioContext)

      const socket = new WebSocket(websocketUrl(this.el.dataset.voicePath, this.sessionId))
      socket.binaryType = "arraybuffer"
      this.socket = socket

      const socketReady = waitForSocket(socket)
      socket.onmessage = (event) => {
        if (this.currentConnection(generation, socket)) this.handleServerMessage(event.data)
      }
      socket.onerror = () => {
        if (socket.readyState === WebSocket.CLOSED) {
          this.handleSocketClosed(generation, socket)
        }
      }
      socket.onclose = (event) => this.handleSocketClosed(generation, socket, event)

      // Attach rejection handlers before asking for permission. A user can leave the
      // permission sheet open longer than the socket timeout.
      const startupReady = Promise.all([
        audioContext.resume(),
        audioContext.audioWorklet.addModule(this.el.dataset.workletUrl),
        socketReady,
      ]).then(
        () => ({ok: true}),
        (error) => ({ok: false, error}),
      )
      startupReady.then((result) => {
        if (!result.ok && this.currentConnection(generation, socket)) {
          this.failStartup(generation, result.error)
        }
      })

      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: {ideal: 1},
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
        video: false,
      })

      // Stop a late permission result immediately if Stop, destroy, or a socket
      // failure superseded this startup generation while the prompt was open.
      if (!this.currentConnection(generation, socket)) {
        stream.getTracks().forEach((track) => track.stop())
        this.closeStartupResources(socket, audioContext)
        return
      }
      this.stream = stream

      const startup = await startupReady
      if (!startup.ok) throw startup.error

      if (!this.currentConnection(generation, socket)) {
        stream.getTracks().forEach((track) => track.stop())
        this.closeStartupResources(socket, audioContext)
        return
      }

      this.sourceNode = audioContext.createMediaStreamSource(stream)
      this.captureNode = new AudioWorkletNode(audioContext, "adk-pcm-capture", {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: [1],
        processorOptions: {
          targetSampleRate: INPUT_SAMPLE_RATE,
          chunkSamples: 320,
          maxInFlightChunks: 16,
        },
      })
      const captureNode = this.captureNode
      captureNode.onprocessorerror = () => {
        if (this.currentCapture(generation, captureNode)) {
          this.protocolFailure("Microphone audio processing failed. Restart voice to try again.")
        }
      }
      this.silentGain = audioContext.createGain()
      this.silentGain.gain.value = 0
      this.sourceNode.connect(this.captureNode)
      this.captureNode.connect(this.silentGain)
      this.silentGain.connect(audioContext.destination)

      this.captureNode.port.onmessage = (event) => {
        if (this.currentCapture(generation, captureNode)) this.handleCapture(event.data)
      }
      stream.getAudioTracks().forEach((track) => {
        track.addEventListener(
          "ended",
          () => this.handleMicrophoneEnded(generation, stream),
          {once: true},
        )
      })

      this.running = true
      this.starting = false
      this.setStatus("Listening — speak naturally. Model audio will play automatically.", "listening")
      this.renderControls()
    } catch (error) {
      if (generation !== this.generation) return
      this.starting = false
      this.running = false
      this.releaseVoice(false)
      this.setStatus(closeReason(error), "error")
      this.renderControls()
    }
  },

  handleCapture(message) {
    if (message?.type === "level") {
      this.renderInputLevel(message.value)
      return
    }

    if (message?.type === "overflow") {
      this.protocolFailure("The browser could not process microphone audio in real time.")
      return
    }

    if (message?.type !== "pcm" || !this.running) return
    if (message.level !== undefined && message.level !== null) this.renderInputLevel(message.level)
    if (!(message.buffer instanceof ArrayBuffer) || message.buffer.byteLength === 0) {
      this.returnCaptureCredit()
      return
    }
    if (message.buffer.byteLength > 64_000 || message.buffer.byteLength % 2 !== 0) {
      this.protocolFailure("The microphone produced an invalid audio frame.")
      return
    }

    this.inputSequence += 1n
    const frame = new ArrayBuffer(15 + message.buffer.byteLength)
    const view = new DataView(frame)
    view.setUint8(0, PROTOCOL_VERSION)
    view.setUint8(1, CLIENT_AUDIO)
    view.setBigUint64(2, this.inputSequence)
    view.setUint32(10, INPUT_SAMPLE_RATE)
    view.setUint8(14, INPUT_CHANNELS)
    new Uint8Array(frame, 15).set(new Uint8Array(message.buffer))
    const socket = this.socket
    if (this.sendFrame(frame)) {
      this.returnCaptureCredit()
    } else if (this.running && socket === this.socket) {
      this.transportUnavailable(socket)
    }
  },

  handleServerMessage(data) {
    if (!(data instanceof ArrayBuffer) || data.byteLength < 2 || data.byteLength > MAX_SERVER_FRAME_BYTES) {
      this.protocolFailure("The voice server returned an invalid frame.")
      return
    }

    try {
      const view = new DataView(data)
      if (view.getUint8(0) !== PROTOCOL_VERSION) throw new Error("version")
      if (data.byteLength < 10) throw new Error("sequence length")

      const incomingSequence = view.getBigUint64(2)
      if (incomingSequence === 0n || incomingSequence <= this.lastServerSequence) {
        throw new Error("sequence")
      }

      const type = view.getUint8(1)
      let result

      if (type === SERVER_AUDIO) {
        result = this.handleAudioFrame(data, view)
      } else if (type === SERVER_TRANSCRIPTION) {
        result = {sequence: this.handleTranscriptionFrame(data, view)}
      } else if (type === SERVER_LIFECYCLE) {
        result = this.handleLifecycleFrame(data, view)
      } else {
        throw new Error("type")
      }

      if (result.sequence !== incomingSequence) throw new Error("sequence")
      this.lastServerSequence = incomingSequence
      if (result.deferAck) {
        this.drainPendingAudio()
      } else if (!this.sendAck(result.sequence)) {
        const socket = this.socket
        if (this.running && socket === this.socket) this.transportUnavailable(socket)
        return
      }

      // Credit is returned before terminal cleanup closes the socket.
      if (result.closeMessage) {
        const generation = this.generation
        window.queueMicrotask(() => this.finishLifecycle(generation, result.closeMessage))
      }
    } catch (error) {
      if (error instanceof HandledVoiceError) return
      this.protocolFailure("The voice server returned an invalid frame.")
    }
  },

  handleAudioFrame(data, view) {
    if (data.byteLength <= 15) throw new Error("audio length")
    const sequence = view.getBigUint64(2)
    const sampleRate = view.getUint32(10)
    const channels = view.getUint8(14)
    const pcmBytes = data.byteLength - 15
    if (sampleRate < 8_000 || sampleRate > 48_000 || channels < 1 || channels > 2) {
      throw new Error("audio format")
    }
    if (pcmBytes % (2 * channels) !== 0) throw new Error("audio alignment")

    this.enqueueAudioFrame({
      sequence,
      pcm: data.slice(15),
      sampleRate,
      channels,
      offset: 0,
    })
    return {sequence, deferAck: true}
  },

  handleTranscriptionFrame(data, view) {
    if (data.byteLength < 12) throw new Error("transcription length")
    const sequence = view.getBigUint64(2)
    const direction = view.getUint8(10)
    const final = view.getUint8(11)
    if (![1, 2].includes(direction) || ![0, 1].includes(final)) throw new Error("transcription")

    const text = new TextDecoder("utf-8", {fatal: true}).decode(new Uint8Array(data, 12))
    if (text.length > 0) this.appendTranscript(direction === 1 ? "input" : "output", text, final === 1)
    return sequence
  },

  handleLifecycleFrame(data, view) {
    if (data.byteLength !== 11) throw new Error("lifecycle length")
    const sequence = view.getBigUint64(2)
    const state = view.getUint8(10)
    const name = lifecycleNames.get(state)
    if (!name) throw new Error("lifecycle state")

    if (state === 4) {
      if (!this.cancelPlayback(true)) throw new HandledVoiceError("interruption cleanup failed")
      this.transcripts.output = ""
      this.transcriptFinal.output = true
      this.renderTranscript()
      this.setCaptureStatus("Interrupted; waiting for your next turn.")
    } else if (state === 5 || state === 7) {
      return {
        sequence,
        closeMessage:
          state === 5
            ? "The Live session is reconnecting. Restart voice after the session is active."
            : "The Live server is draining. Restart voice after the session reconnects.",
      }
    } else if (state === 8 || state === 9) {
      return {sequence, closeMessage: `Voice ${name}.`}
    } else if (state === 3) {
      this.resetTranscriptOnInput = true
      this.setCaptureStatus("Voice turn complete.")
    } else if (state === 1 || state === 6) {
      this.setCaptureStatus(`Voice ${name}.`)
    }
    return {sequence}
  },

  enqueueAudioFrame(frame) {
    if (
      this.pendingAudioFrames.length >= MAX_PENDING_AUDIO_FRAMES ||
      this.pendingAudioBytes + frame.pcm.byteLength > MAX_PENDING_AUDIO_BYTES
    ) {
      this.protocolFailure("The voice server exceeded the bounded playback queue.")
      throw new HandledVoiceError("bounded playback queue exceeded")
    }

    this.pendingAudioFrames.push(frame)
    this.pendingAudioBytes += frame.pcm.byteLength
  },

  drainPendingAudio() {
    if (!this.running || this.pendingAudioFrames.length === 0) return

    while (this.pendingAudioFrames.length > 0 && this.running) {
      const frame = this.pendingAudioFrames[0]
      const bytesPerFrame = 2 * frame.channels

      while (frame.offset < frame.pcm.byteLength && this.running) {
        if (this.playbackSources.size >= MAX_SCHEDULED_SOURCES) return

        const availableSeconds = MAX_SCHEDULED_SECONDS - this.scheduledAudioSeconds
        if (availableSeconds <= 1e-9) return

        const remainingFrames = (frame.pcm.byteLength - frame.offset) / bytesPerFrame
        const segmentSeconds = Math.min(MAX_PLAYBACK_SEGMENT_SECONDS, availableSeconds)
        const segmentFrames = Math.min(
          remainingFrames,
          Math.floor(segmentSeconds * frame.sampleRate + 1e-6),
        )
        if (segmentFrames < 1) return

        const segmentBytes = segmentFrames * bytesPerFrame
        const end = frame.offset + segmentBytes
        const segment = frame.pcm.slice(frame.offset, end)
        if (!this.scheduleAudioSegment(segment, frame.sampleRate, frame.channels)) return
        frame.offset = end
      }

      if (frame.offset < frame.pcm.byteLength) return

      this.pendingAudioFrames.shift()
      this.pendingAudioBytes = Math.max(0, this.pendingAudioBytes - frame.pcm.byteLength)
      const socket = this.socket
      if (!this.sendAck(frame.sequence)) {
        if (this.running && socket === this.socket) this.transportUnavailable(socket)
        return
      }
    }
  },

  scheduleAudioSegment(pcm, sampleRate, channels) {
    const context = this.audioContext
    if (!context || context.state !== "running") {
      if (context) this.handleAudioContextState(this.generation, context)
      return false
    }

    const frameCount = pcm.byteLength / (2 * channels)
    const duration = frameCount / sampleRate
    if (!Number.isFinite(duration) || duration <= 0 || duration > MAX_PLAYBACK_SEGMENT_SECONDS) {
      throw new Error("invalid playback segment")
    }

    const samples = new DataView(pcm)
    const buffer = context.createBuffer(channels, frameCount, sampleRate)

    for (let channel = 0; channel < channels; channel += 1) {
      const output = buffer.getChannelData(channel)
      for (let frame = 0; frame < frameCount; frame += 1) {
        const offset = (frame * channels + channel) * 2
        output[frame] = samples.getInt16(offset, true) / 32_768
      }
    }

    const source = context.createBufferSource()
    source.buffer = buffer
    source.connect(context.destination)
    // Preserve sample-contiguous timing while queued audio is still ahead of
    // the hardware clock. Reapplying a fixed lead to every WebSocket frame
    // turns ordinary arrival jitter into silence between otherwise adjacent
    // PCM chunks. Only rebuffer after a real (or imminent) underrun.
    const now = context.currentTime
    const startAt =
      this.playbackCursor > now + PLAYBACK_SCHEDULE_EPSILON_SECONDS
        ? this.playbackCursor
        : now + PLAYBACK_REBUFFER_SECONDS
    this.playbackCursor = startAt + buffer.duration
    source.start(startAt)
    this.playbackSources.add(source)
    this.scheduledAudioSeconds += buffer.duration
    source.addEventListener(
      "ended",
      () => {
        if (this.playbackSources.delete(source)) {
          this.scheduledAudioSeconds = Math.max(0, this.scheduledAudioSeconds - buffer.duration)
          this.drainPendingAudio()
        }
      },
      {once: true},
    )
    return true
  },

  sendAck(sequence) {
    const frame = new ArrayBuffer(10)
    const view = new DataView(frame)
    view.setUint8(0, PROTOCOL_VERSION)
    view.setUint8(1, CLIENT_ACK)
    view.setBigUint64(2, sequence)
    return this.sendFrame(frame)
  },

  sendControl(type) {
    this.sendFrame(Uint8Array.of(PROTOCOL_VERSION, type).buffer)
  },

  sendFrame(frame) {
    const socket = this.socket
    if (socket?.readyState !== WebSocket.OPEN) return false

    const bytes = frame?.byteLength
    if (!Number.isSafeInteger(bytes) || bytes < 1) {
      this.protocolFailure("The browser produced an invalid voice frame.")
      return false
    }
    if (socket.bufferedAmount + bytes > MAX_SOCKET_BUFFER_BYTES) {
      this.transportOverloaded(socket)
      return false
    }

    socket.send(frame)
    return true
  },

  toggleMute() {
    if (!this.running) return
    this.muted = !this.muted
    this.stream?.getAudioTracks().forEach((track) => { track.enabled = !this.muted })
    this.setStatus(
      this.muted
        ? "Microphone muted; only silence is sent so automatic turn detection can finish cleanly."
        : "Listening — microphone restored.",
      this.muted ? "muted" : "listening",
    )
    this.renderControls()
  },

  stopVoice() {
    if (!this.running && !this.starting) return
    this.generation += 1
    this.sendControl(CLIENT_AUDIO_STREAM_END)
    this.running = false
    this.starting = false
    this.muted = false
    this.releaseVoice(false)
    this.setStatus("Voice stopped. Start again when you are ready.", "idle")
    this.renderControls()
  },

  releaseVoice(sendEnd) {
    if (sendEnd && this.socket?.readyState === WebSocket.OPEN) {
      this.sendControl(CLIENT_AUDIO_STREAM_END)
    }

    if (this.captureNode?.port) {
      this.captureNode.onprocessorerror = null
      this.captureNode.port.onmessage = null
      this.captureNode.port.postMessage({type: "active", value: false})
      this.captureNode.port.close()
    }
    this.stream?.getTracks().forEach((track) => track.stop())
    this.sourceNode?.disconnect()
    this.captureNode?.disconnect()
    this.silentGain?.disconnect()
    this.cancelPlayback()

    if (this.socket && this.socket.readyState < WebSocket.CLOSING) this.socket.close(1000, "voice stopped")
    if (this.audioContext) this.audioContext.onstatechange = null
    if (this.audioContext && this.audioContext.state !== "closed") this.audioContext.close()

    this.socket = null
    this.audioContext = null
    this.stream = null
    this.sourceNode = null
    this.captureNode = null
    this.silentGain = null
    this.muted = false
    if (this.level) this.level.style.transform = "scaleX(0)"
  },

  cancelPlayback(ackPending = false) {
    const pending = this.pendingAudioFrames
    const sources = Array.from(this.playbackSources)
    this.pendingAudioFrames = []
    this.pendingAudioBytes = 0
    this.playbackSources.clear()
    this.scheduledAudioSeconds = 0

    sources.forEach((source) => {
      try { source.stop() } catch (_error) { /* already stopped */ }
      source.disconnect()
    })
    this.playbackCursor = this.audioContext?.currentTime || 0

    if (ackPending) {
      for (const frame of pending) {
        const socket = this.socket
        if (!this.sendAck(frame.sequence)) {
          if (this.running && socket === this.socket) this.transportUnavailable(socket)
          return false
        }
      }
    }
    return true
  },

  handleMicrophoneEnded(generation, stream) {
    if (!this.running || generation !== this.generation || stream !== this.stream) return
    this.sendControl(CLIENT_AUDIO_STREAM_END)
    this.generation += 1
    this.running = false
    this.releaseVoice(false)
    this.setStatus("The microphone stream ended.", "error")
    this.renderControls()
  },

  handleSocketClosed(generation, socket, event = {}) {
    if (!this.currentConnection(generation, socket)) return
    if (!this.running && !this.starting) return
    this.generation += 1
    this.running = false
    this.starting = false
    this.releaseVoice(false)
    this.setStatus(this.socketCloseMessage(event), "error")
    this.renderControls()
  },

  protocolFailure(message) {
    if (this.socket?.readyState === WebSocket.OPEN) this.socket.close(4002, "invalid voice frame")
    this.generation += 1
    this.running = false
    this.starting = false
    this.releaseVoice(false)
    this.setStatus(message, "error")
    this.renderControls()
  },

  transportOverloaded(socket) {
    if (socket !== this.socket) return
    if (socket.readyState === WebSocket.OPEN) socket.close(4013, "voice transport overloaded")
    this.generation += 1
    this.running = false
    this.starting = false
    this.releaseVoice(false)
    this.setStatus("The browser voice connection fell behind and was closed safely.", "error")
    this.renderControls()
  },

  transportUnavailable(socket) {
    if (socket !== this.socket || (!this.running && !this.starting)) return
    if (socket?.readyState === WebSocket.OPEN) socket.close(4012, "voice transport unavailable")
    this.generation += 1
    this.running = false
    this.starting = false
    this.releaseVoice(false)
    this.setStatus("The browser voice connection was no longer writable. Restart voice to continue.", "error")
    this.renderControls()
  },

  handleAudioContextState(generation, audioContext) {
    if (generation !== this.generation || audioContext !== this.audioContext) return
    if (audioContext.state === "running" || (!this.running && !this.starting)) return

    this.generation += 1
    this.running = false
    this.starting = false
    this.releaseVoice(false)
    this.setStatus("Browser audio was interrupted. Restart voice to resume microphone and playback.", "error")
    this.renderControls()
  },

  currentConnection(generation, socket) {
    return generation === this.generation && socket === this.socket
  },

  currentCapture(generation, captureNode) {
    return generation === this.generation && captureNode === this.captureNode
  },

  returnCaptureCredit() {
    if (this.captureNode?.port && this.running) {
      this.captureNode.port.postMessage({type: "credit", count: 1})
    }
  },

  renderInputLevel(value) {
    const normalized = Math.max(0, Math.min(1, Number(value) || 0))
    if (this.level) this.level.style.transform = `scaleX(${normalized})`
  },

  closeStartupResources(socket, audioContext) {
    if (socket?.readyState < WebSocket.CLOSING) socket.close(1000, "voice startup cancelled")
    if (audioContext?.state !== "closed") audioContext.close()
  },

  finishLifecycle(generation, message) {
    if (generation !== this.generation) return
    this.generation += 1
    this.running = false
    this.starting = false
    this.muted = false
    this.releaseVoice(false)
    this.setStatus(message, "error")
    this.renderControls()
  },

  failStartup(generation, error) {
    if (generation !== this.generation) return
    this.generation += 1
    this.running = false
    this.starting = false
    this.releaseVoice(false)
    this.setStatus(closeReason(error), "error")
    this.renderControls()
  },

  socketCloseMessage(event) {
    if (event.code === 1012 || event.reason === "live session reconnecting") {
      return "The Live session is reconnecting. Refresh and restart voice when it is active."
    }
    if (event.code === 1013 && event.reason === "voice session not active") {
      return "The Live session is not active yet. Refresh before starting voice again."
    }
    if (event.code === 1013 && event.reason === "voice session already in use") {
      return "This Live session already has a voice connection. Stop voice in the other tab first."
    }
    if (event.code === 1013 && event.reason === "voice input overloaded") {
      return "Voice input exceeded the server's bounded capacity. Restart voice and try again."
    }
    if (event.code === 1008 && event.reason === "automatic activity detection required") {
      return "Browser voice requires a Live session with automatic activity detection."
    }
    if (event.code === 1008 && event.reason === "authentication expired") {
      return "Your login expired. Sign in again before restarting voice."
    }
    if (event.code === 1002) {
      return "The voice protocol became desynchronised. Refresh before restarting voice."
    }
    if (event.code === 1009) {
      return "A voice frame exceeded the safe size limit and the connection was closed."
    }
    if (event.code === 1011 && event.reason === "voice outcome unknown") {
      return "The server could not confirm the last voice operation, so it closed safely to avoid duplicate audio."
    }
    return "The authenticated voice connection closed."
  },

  appendTranscript(direction, text, final) {
    if (direction === "input" && this.resetTranscriptOnInput) {
      this.transcripts = {input: "", output: ""}
      this.transcriptFinal = {input: true, output: true}
      this.resetTranscriptOnInput = false
    }

    const previous = this.transcripts[direction]
    // v1 makes transcription framing unambiguous: input is the provider's
    // complete latest hypothesis, while output is an ordered text delta.
    const combined = direction === "input" ? text : `${previous}${text}`
    this.transcripts[direction] = combined.slice(-MAX_TRANSCRIPT_CHARS)
    this.transcriptFinal[direction] = final
    this.renderTranscript()
    if (final && this.transcriptAnnouncement) {
      const speaker = direction === "input" ? "You" : "Model"
      this.transcriptAnnouncement.textContent = `${speaker}: ${this.transcripts[direction]}`
    }
  },

  renderTranscript() {
    const lines = []
    if (this.transcripts.input) {
      lines.push(`You: ${this.transcripts.input}${this.transcriptFinal.input ? "" : " …"}`)
    }
    if (this.transcripts.output) {
      lines.push(`Model: ${this.transcripts.output}${this.transcriptFinal.output ? "" : " …"}`)
    }
    if (this.transcript) this.transcript.textContent = lines.join("\n")
  },

  setStatus(message, state) {
    if (this.status) this.status.textContent = message
    this.el.dataset.voiceState = state
  },

  setCaptureStatus(message) {
    const suffix = this.muted ? "Microphone remains muted." : "Microphone is active."
    this.setStatus(`${message} ${suffix}`, this.muted ? "muted" : "listening")
  },

  renderControls() {
    if (!this.startButton) return
    this.startButton.disabled = this.running || this.starting
    this.startButton.textContent = this.starting ? "Starting…" : "Start voice"
    this.muteButton.disabled = !this.running
    this.muteButton.textContent = this.muted ? "Unmute microphone" : "Mute microphone"
    this.muteButton.setAttribute("aria-pressed", String(this.muted))
    this.stopButton.disabled = !this.running && !this.starting
  },
}
