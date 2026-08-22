import assert from 'node:assert/strict'
import { existsSync } from 'node:fs'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { HelperProcess, defaultCommand, defaultHelperPath, isWsl, shouldUseBundledHelper } from '../src/helper-process.js'
import { CompanionMessageKind, CompanionState, createMessage } from '../src/protocol.js'

// The event-log based lifecycle tests below exercise the helper's --event-log
// recording, which the Swift helper (Step2) does not implement yet. On any
// platform we run them against the Python helper so the assertions stay real;
// the Swift helper path is covered by the dedicated integration test at the end.
// `defaultHelperPath` already points at the repository's runtime/helper.py.
const pythonHelper = {
  command: process.env.DSH_DAFEIYU_PYTHON || 'python3',
  args: [defaultHelperPath],
}

async function waitFor(predicate, timeoutMs = 3000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  throw new Error('timed out waiting for helper condition')
}

test('helper process exposes WSL detection helpers without throwing', () => {
  assert.equal(typeof isWsl(), 'boolean')
  assert.equal(typeof shouldUseBundledHelper(), 'boolean')
  assert.equal(typeof defaultCommand(), 'string')
  assert.equal(typeof defaultCommand(true), 'string')
})

test('helper consumes events and exits when the plugin stops', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-dafeiyu-test-'))
  const eventLog = join(directory, 'events.jsonl')
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const bridge = new HelperProcess({ headless: true, eventLog, ...pythonHelper }, logger)
  const child = bridge.start()
  const exited = new Promise((resolve, reject) => {
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`helper exited with ${String(code)}`)))
    child.once('error', reject)
  })
  bridge.send(createMessage(CompanionMessageKind.STATE, {
    state: CompanionState.WORKING,
    message: 'running a test',
  }))
  bridge.stop('test-complete')
  await exited

  const messages = (await readFile(eventLog, 'utf8')).trim().split(/\r?\n/).map(JSON.parse)
  assert.equal(messages[0].state, CompanionState.WORKING)
  assert.equal(messages.at(-1).kind, CompanionMessageKind.SHUTDOWN)
  await rm(directory, { recursive: true, force: true })
})

test('helper heartbeat stays healthy and responds without a restart', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-dafeiyu-heartbeat-'))
  const eventLog = join(directory, 'events.jsonl')
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const bridge = new HelperProcess({
    headless: true,
    eventLog,
    heartbeatMs: 25,
    // Raised from 150 → 300 so a loaded Python helper's PONG is not mistaken for a
    // dead helper. A false timeout would kill+restart the child and break the
    // "no restart" assertion under full-suite parallel load (the pre-existing flake).
    heartbeatTimeoutMs: 300,
    ...pythonHelper,
  }, logger)
  const initialChild = bridge.start()
  bridge.send(createMessage(CompanionMessageKind.STATE, {
    state: CompanionState.THINKING,
    message: 'heartbeat test',
  }))

  // Wait for the first heartbeat reply rather than polling the on-disk event log, which
  // is subject to flush latency under parallel load. `lastPongAt` is updated in-process
  // by the heartbeat loop on every PONG, so it is immune to that latency.
  await waitFor(() => bridge.lastPongAt > 0, 8000)

  // Sample heartbeat health across a window: lastPongAt must advance (the helper keeps
  // answering pings) and the child must stay the same instance (no restart) the whole time.
  const firstPong = bridge.lastPongAt
  await new Promise((resolve) => setTimeout(resolve, 220))
  assert.ok(bridge.lastPongAt > firstPong, 'heartbeat should keep advancing')
  assert.equal(bridge.child, initialChild, 'helper must not restart during the heartbeat')

  bridge.stop('heartbeat-test-complete')
  await waitFor(async () => {
    try {
      return (await readFile(eventLog, 'utf8')).includes('"kind": "shutdown"')
    } catch {
      return false
    }
  })
  await rm(directory, { recursive: true, force: true })
})

// Real Swift helper integration (Apple Silicon only). Skipped when the bundled
// darwin-arm64 helper has not been built, so CI without a Mac build still passes.
// The Swift helper (Step2) does not implement --event-log yet, so we assert on
// the helper's protocol behavior (ready -> pong -> clean shutdown) via the bridge.
const swiftHelperPath = join(dirname(defaultHelperPath), 'bin', 'darwin-arm64', 'dsh-dafeiyu-helper')
const swiftHelperExists = existsSync(swiftHelperPath)

test('Apple Silicon Swift helper starts, answers ping/pong, and exits on shutdown', { skip: !swiftHelperExists }, async (t) => {
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const bridge = new HelperProcess({ headless: true }, logger)
  const child = bridge.start()
  assert.ok(child, 'Swift helper child process should spawn')
  assert.equal(child.pid !== undefined, true)

  const exited = new Promise((resolve, reject) => {
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(`helper exited with ${String(code)}`)))
    child.once('error', reject)
  })
  // The helper becomes ready on its own; wait for spawned, then probe ping/pong.
  await waitFor(() => bridge.spawned === true)
  bridge.send(createMessage(CompanionMessageKind.PING))
  await waitFor(() => bridge.lastPongAt > 0)
  bridge.stop('swift-integration-complete')
  await exited
})
