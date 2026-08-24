import { execFileSync, spawn } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { createInterface } from 'node:readline'
import {
  CompanionMessageKind,
  createMessage,
  encodeMessage,
} from './protocol.js'

const here = dirname(fileURLToPath(import.meta.url))
const defaultHelperPath = resolve(here, '..', 'runtime', 'helper.py')
const bundledHelperPath = resolve(here, '..', 'runtime', 'bin', 'win32-x64', 'dsh-dafeiyu-helper.exe')
// Apple Silicon macOS helper (Swift/AppKit). Built locally via `npm run build:helper:mac`.
// Preferred: the packaged .app (Contents/MacOS/dsh-dafeiyu-helper) so
// Bundle.main resolves a real bundle identifier — required by
// UNUserNotificationCenter for system notification banners. Dev installs keep
// the plain binary as a fallback (no bundle id ⇒ notifications skipped).
const bundledDarwinArm64HelperAppPath = resolve(here, '..', 'runtime', 'bin', 'darwin-arm64', 'DafeiyuHelper.app')
const bundledDarwinArm64HelperPath = resolve(here, '..', 'runtime', 'bin', 'darwin-arm64', 'dsh-dafeiyu-helper')

function resolveDarwinArm64HelperPath() {
  // Node cannot exec a .app directory (EACCES), so when the packaged bundle
  // exists we point at the binary INSIDE it: running from Contents/MacOS makes
  // Bundle.main resolve the bundle identity (needed for notification banners).
  if (existsSync(bundledDarwinArm64HelperAppPath)) {
    const inBundle = resolve(bundledDarwinArm64HelperAppPath, 'Contents', 'MacOS', 'dsh-dafeiyu-helper')
    if (existsSync(inBundle)) return inBundle
  }
  return bundledDarwinArm64HelperPath
}

function isWsl() {
  if (process.platform !== 'linux') return false
  try {
    return readFileSync('/proc/sys/fs/binfmt_misc/WSLInterop', 'utf8').includes('enabled')
  } catch {
    try {
      return /microsoft/i.test(readFileSync('/proc/version', 'utf8'))
    } catch {
      return false
    }
  }
}

function shouldUseBundledHelper() {
  return (process.platform === 'win32' || isWsl()) && existsSync(bundledHelperPath)
}

// Apple Silicon macOS only: the Swift helper is bundled at runtime/bin/darwin-arm64.
// Intel macOS (darwin-x64) and Rosetta are explicitly unsupported.
function shouldUseBundledDarwinArm64Helper() {
  return (
    process.platform === 'darwin' &&
    process.arch === 'arm64' &&
    existsSync(bundledDarwinArm64HelperPath)
  )
}

function toWindowsPath(path) {
  return execFileSync('wslpath', ['-w', path], { encoding: 'utf8' }).trim()
}

function defaultCmdExe({ wslpath = defaultWslPath, fileExists = existsSync } = {}) {
  // WSL visual mode launches the bundled EXE through Windows cmd.exe. cmd.exe
  // is usually NOT on the WSL PATH (System32 is not appended by default), so
  // never rely on `cmd.exe` being resolvable: convert the Windows absolute path
  // with wslpath and only fall back to the bare name as a last resort.
  try {
    const candidate = wslpath('C:\\Windows\\System32\\cmd.exe')
    if (candidate && fileExists(candidate)) return candidate
  } catch {
    // Fall through to the bare-name fallback below.
  }
  return 'cmd.exe'
}

function defaultWslPath(...args) {
  return execFileSync('wslpath', args, { encoding: 'utf8' }).trim()
}

function resolveHelperLaunch({
  platform,
  arch = process.arch,
  isWslEnv,
  bundledPath,
  darwinArm64Path = resolveDarwinArm64HelperPath(),
  helperPath,
  pythonEnv,
  headless = false,
  fileExists = existsSync,
  windowsPath = toWindowsPath,
  cmdExe = defaultCmdExe,
}) {
  // Apple Silicon macOS: launch the bundled Swift helper directly. This is the
  // top-priority branch. Intel macOS (darwin-x64) or an unbuilt arm64 helper
  // refuse to start with a clear error — there is no Python/Intel fallback.
  if (platform === 'darwin') {
    if (arch === 'arm64') {
      // Return the resolved path even when the artifact is not built yet (a dev
      // checkout or a pre-build test run): spawn will fail with a clear ENOENT/
      // EACCES error either way, and launch-time probing must not throw so
      // platform-exposure tests (defaultCommand) stay deterministic.
      return { command: darwinArm64Path, args: headless ? ['--headless'] : [] }
    }
    throw new Error(
      'dsh-dafeiyu mac helper only supports Apple Silicon (darwin-arm64)',
    )
  }
  if (platform === 'win32' && fileExists(bundledPath)) {
    return { command: bundledPath, args: [] }
  }
  if (platform === 'linux' && isWslEnv && !headless && fileExists(bundledPath)) {
    // npm archives created on Windows store ordinary files as 0644. Launching
    // the EXE directly from WSL can therefore fail with EACCES. cmd.exe opens
    // the Windows path without relying on the Linux executable bit and keeps
    // stdin/stdout attached for the companion protocol.
    return {
      command: cmdExe(),
      args: ['/d', '/c', windowsPath(bundledPath)],
    }
  }
  const command = pythonEnv || (platform === 'win32' ? 'py' : 'python3')
  return { command, args: defaultArgs(command, helperPath) }
}

function defaultLaunch(headless = false) {
  return resolveHelperLaunch({
    platform: process.platform,
    arch: process.arch,
    isWslEnv: isWsl(),
    bundledPath: bundledHelperPath,
    // No explicit darwinArm64Path: the default arg resolves the packaged .app
    // (Contents/MacOS binary) when present, falling back to the bare dev binary.
    helperPath: defaultHelperPath,
    pythonEnv: process.env.DSH_DAFEIYU_PYTHON,
    headless,
  })
}

function defaultCommand(headless = false) {
  return defaultLaunch(headless).command
}

function defaultArgs(command, helperPath) {
  if (command === bundledHelperPath) return []
  // Explicit override to the bundled Swift helper: never append the Python path.
  if (command === bundledDarwinArm64HelperAppPath || command === bundledDarwinArm64HelperPath) return []
  if (process.platform === 'win32' && /(^|[\\/])py(?:\.exe)?$/i.test(command)) {
    return ['-3', helperPath]
  }
  return [helperPath]
}

export class HelperProcess {
  constructor(options = {}, logger = console) {
    this.options = options
    this.logger = logger
    this.child = undefined
    this.queue = []
    this.snapshot = new Map()
    this.spawned = false
    this.hasEverSpawned = false
    this.stopping = false
    this.restartSuppressed = false
    this.startFailures = 0
    this.restartTimer = undefined
    this.heartbeatTimer = undefined
    this.startupTimer = undefined
    this.lastPongAt = 0
  }

  start() {
    if (this.child || this.stopping || this.restartSuppressed) return this.child
    // Resolving the launch command can throw synchronously (e.g. WSL interop
    // probing). Never let that escape: it would crash the host when it happens
    // inside the restart timer. Treat it like any other start failure instead.
    let child
    try {
      const headless = this.options.headless ?? process.env.DSH_DAFEIYU_HEADLESS === '1'
      const helperPath = this.options.helperPath || defaultHelperPath
      const launch = this.options.command
        ? { command: this.options.command, args: defaultArgs(this.options.command, helperPath) }
        : defaultLaunch(headless)
      const command = launch.command
      const args = this.options.args || launch.args
      const extraArgs = []
      const eventLog = this.options.eventLog || process.env.DSH_DAFEIYU_EVENT_LOG
      const snapshot = this.options.snapshot || process.env.DSH_DAFEIYU_SNAPSHOT
      if (headless) extraArgs.push('--headless')
      if (eventLog) extraArgs.push('--event-log', eventLog)
      if (snapshot) extraArgs.push('--snapshot', snapshot)

      child = spawn(command, [...args, ...extraArgs], {
        cwd: this.options.cwd || resolve(here, '..'),
        env: { ...process.env, ...this.options.env },
        stdio: ['pipe', 'pipe', 'pipe'],
        windowsHide: true,
      })
    } catch (error) {
      this.child = undefined
      this.spawned = false
      this.logger.error?.(`dsh-dafeiyu helper failed to start: ${error.message}`)
      if (!this.stopping && !this.restartSuppressed) {
        this.#countStartFailure(`launch error: ${error.message}`)
      }
      return undefined
    }
    this.child = child
    // A broken pipe on any child channel must never crash the DSH host.
    // EPIPE on stdin is expected after the helper dies before we flush.
    child.stdin.on('error', () => {})
    child.stdout.on('error', () => {})
    child.stderr.on('error', () => {})
    child.once('spawn', () => {
      const startupTimeoutMs = this.options.startupTimeoutMs ?? 60000
      this.startupTimer = setTimeout(() => {
        if (this.child === child && !this.spawned) {
          this.logger.warn?.('dsh-dafeiyu helper readiness timed out')
          child.kill()
        }
      }, startupTimeoutMs)
      this.startupTimer.unref?.()
    })
    child.once('error', (error) => {
      this.logger.error?.(`dsh-dafeiyu helper failed to start: ${error.message}`)
      if (this.child !== child) return
      this.child = undefined
      this.spawned = false
      this.#clearHeartbeat()
      this.#clearStartupTimer()
      if (!this.stopping && !this.restartSuppressed) {
        this.#countStartFailure(`spawn error: ${error.message}`)
      }
    })
    child.once('exit', (code, signal) => {
      if (this.child !== child) return
      this.child = undefined
      const wasReady = this.spawned
      this.spawned = false
      this.#clearHeartbeat()
      this.#clearStartupTimer()
      if (!this.stopping && !this.restartSuppressed) {
        if (!wasReady) {
          // The helper never became ready during this attempt (crashed before
          // READY or timed out). Count it as a failed start so a broken
          // helper cannot restart forever.
          this.#countStartFailure(`exited before ready (code=${String(code)}, signal=${String(signal)})`)
          return
        }
        this.logger.warn?.(`dsh-dafeiyu helper exited (code=${String(code)}, signal=${String(signal)}); restarting`)
        this.#scheduleRestart()
      }
    })
    createInterface({ input: child.stdout }).on('line', (line) => this.#handleReply(line))
    createInterface({ input: child.stderr }).on('line', (line) => {
      if (line.trim()) this.logger.warn?.(`dsh-dafeiyu helper: ${line}`)
    })
    return child
  }

  send(message) {
    this.#remember(message)
    const line = encodeMessage(message)
    if (!this.child || !this.spawned || !this.child.stdin.writable || this.child.stdin.destroyed) {
      if (!this.hasEverSpawned
        || ![CompanionMessageKind.HELLO, CompanionMessageKind.STATE, CompanionMessageKind.TASK, CompanionMessageKind.TASKS, CompanionMessageKind.PULSE, CompanionMessageKind.CONFIG].includes(message.kind)) {
        this.queue.push(line)
      }
      return
    }
    this.child.stdin.write(line)
  }

  stop(reason = 'plugin-disposed') {
    this.stopping = true
    this.#clearHeartbeat()
    if (this.restartTimer) clearTimeout(this.restartTimer)
    this.restartTimer = undefined
    const child = this.child
    if (!child) return
    this.queue.push(encodeMessage(createMessage(CompanionMessageKind.SHUTDOWN, { reason })))
    if (this.spawned) {
      this.#flushQueue()
      this.#endInput(child)
    }
    const timer = setTimeout(() => {
      if (this.child === child) child.kill()
    }, this.options.shutdownTimeoutMs ?? 10000)
    timer.unref?.()
  }

  #remember(message) {
    if (message.kind === CompanionMessageKind.HELLO) this.snapshot.set('hello', encodeMessage(message))
    if (message.kind === CompanionMessageKind.STATE) this.snapshot.set('state', encodeMessage(message))
    if (message.kind === CompanionMessageKind.TASK) this.snapshot.set('task', encodeMessage(message))
    if (message.kind === CompanionMessageKind.TASKS) this.snapshot.set('tasks', encodeMessage(message))
    if (message.kind === CompanionMessageKind.CONFIG) this.snapshot.set('config', encodeMessage(message))
  }

  #flushSnapshot() {
    const child = this.child
    if (!this.spawned || !child?.stdin.writable || child.stdin.destroyed) return
    const payload = [...this.snapshot.values()].join('')
    if (payload) child.stdin.write(payload)
  }

  #flushQueue() {
    const child = this.child
    if (!this.spawned || !child?.stdin.writable || child.stdin.destroyed) return
    const payload = this.queue.splice(0).join('')
    if (payload) child.stdin.write(payload)
  }

  #handleReply(line) {
    if (!line.trim()) return
    try {
      const reply = JSON.parse(line)
      if (reply?.protocolVersion === 1 && reply.kind === CompanionMessageKind.READY) {
        if (this.spawned) return
        const firstSpawn = !this.hasEverSpawned
        this.hasEverSpawned = true
        this.spawned = true
        this.startFailures = 0
        this.lastPongAt = Date.now()
        this.#clearStartupTimer()
        if (firstSpawn) this.#flushQueue()
        else {
          this.#flushSnapshot()
          this.#flushQueue()
        }
        this.#startHeartbeat()
        if (this.stopping) this.#endInput(this.child)
        return
      }
      if (reply?.protocolVersion === 1 && reply.kind === CompanionMessageKind.PONG) {
        this.lastPongAt = Date.now()
        return
      }
      if (reply?.protocolVersion === 1 && reply.kind === CompanionMessageKind.CLOSED) {
        this.restartSuppressed = true
        return
      }
    } catch {
      // Non-protocol stdout is still useful in development logs.
    }
    this.logger.debug?.(`dsh-dafeiyu helper: ${line}`)
  }

  #startHeartbeat() {
    const heartbeatMs = this.options.heartbeatMs ?? 5000
    if (heartbeatMs <= 0) return
    const timeoutMs = this.options.heartbeatTimeoutMs ?? Math.max(heartbeatMs * 3, 12000)
    this.heartbeatTimer = setInterval(() => {
      const child = this.child
      if (!child || !this.spawned) return
      if (Date.now() - this.lastPongAt > timeoutMs) {
        this.logger.warn?.('dsh-dafeiyu helper heartbeat timed out')
        child.kill()
        return
      }
      this.send(createMessage(CompanionMessageKind.PING))
    }, heartbeatMs)
    this.heartbeatTimer.unref?.()
  }

  #clearHeartbeat() {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer)
    this.heartbeatTimer = undefined
  }

  #clearStartupTimer() {
    if (this.startupTimer) clearTimeout(this.startupTimer)
    this.startupTimer = undefined
  }

  #countStartFailure(reason) {
    this.startFailures += 1
    const maxFailures = this.options.maxStartFailures ?? 5
    if (this.startFailures >= maxFailures) {
      this.restartSuppressed = true
      this.logger.error?.(`dsh-dafeiyu helper failed to start ${this.startFailures} times; giving up (${reason})`)
      return
    }
    this.logger.warn?.(`dsh-dafeiyu helper failed to start; scheduling restart (${this.startFailures}/${maxFailures}) (${reason})`)
    this.#scheduleRestart()
  }

  #scheduleRestart() {
    if (this.restartTimer || this.stopping || this.restartSuppressed) return
    const delay = this.options.restartDelayMs ?? 750
    this.restartTimer = setTimeout(() => {
      this.restartTimer = undefined
      this.start()
    }, delay)
    this.restartTimer.unref?.()
  }

  #endInput(child) {
    if (child.stdin.writable && !child.stdin.destroyed) child.stdin.end()
  }
}

export {
  bundledHelperPath,
  bundledDarwinArm64HelperAppPath,
  bundledDarwinArm64HelperPath,
  resolveDarwinArm64HelperPath,
  defaultHelperPath,
  defaultArgs,
  defaultCmdExe,
  defaultCommand,
  defaultLaunch,
  isWsl,
  resolveHelperLaunch,
  shouldUseBundledHelper,
  shouldUseBundledDarwinArm64Helper,
  toWindowsPath,
}
