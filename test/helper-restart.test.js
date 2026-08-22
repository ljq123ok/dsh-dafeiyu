import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'
import { HelperProcess, defaultHelperPath } from '../src/helper-process.js'
import { CompanionMessageKind, CompanionState, createMessage } from '../src/protocol.js'

const fixture = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'restart-helper.js')
const closedFixture = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'closed-helper.js')
const crashBeforeReadyFixture = join(dirname(fileURLToPath(import.meta.url)), 'fixtures', 'crash-before-ready.js')

// The bundled Apple-Silicon Swift helper is only present after `npm run build:helper:mac`.
// CI without a Mac build skips this real-binary integration test instead of failing.
const swiftHelperPath = join(dirname(defaultHelperPath), 'bin', 'darwin-arm64', 'dsh-dafeiyu-helper')
const swiftHelperExists = existsSync(swiftHelperPath)

async function waitFor(predicate, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 25))
  }
  throw new Error('timed out waiting for helper restart')
}

test('unexpected helper exit restarts and replays the latest state snapshot', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'dsh-dafeiyu-restart-'))
  const marker = join(directory, 'crashed-once')
  const eventLog = join(directory, 'events.jsonl')
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const bridge = new HelperProcess({
    command: process.execPath,
    args: [fixture, marker, eventLog],
    headless: false,
    heartbeatMs: 0,
    restartDelayMs: 50,
  }, logger)
  bridge.start()
  bridge.send(createMessage(CompanionMessageKind.STATE, {
    state: CompanionState.WORKING,
    activity: 'testing',
    message: 'replay me',
  }))
  bridge.send(createMessage(CompanionMessageKind.CONFIG, {
    scale: 0.9,
    bubbleScale: 0.7,
    activityLevel: 'quiet',
    reducedMotion: true,
  }))

  await waitFor(async () => {
    try {
      return (await readFile(eventLog, 'utf8')).includes('replay me')
    } catch {
      return false
    }
  })
  bridge.stop('restart-test-complete')
  await waitFor(async () => {
    try {
      return (await readFile(eventLog, 'utf8')).includes('"kind":"shutdown"')
    } catch {
      return false
    }
  })

  const messages = (await readFile(eventLog, 'utf8')).trim().split(/\r?\n/).map(JSON.parse)
  assert.equal(messages.some((message) => message.state === CompanionState.WORKING), true)
  assert.equal(messages.some((message) => message.kind === CompanionMessageKind.CONFIG && message.bubbleScale === 0.7), true)
  assert.equal(messages.at(-1).kind, CompanionMessageKind.SHUTDOWN)
  await rm(directory, { recursive: true, force: true })
})

test('startup failure clears the failed process and gives up after the retry limit', async () => {
  let failures = 0
  const logger = {
    debug() {},
    info() {},
    warn() {},
    error() { failures += 1 },
  }
  const bridge = new HelperProcess({
    command: 'dsh-dafeiyu-helper-does-not-exist',
    headless: true,
    heartbeatMs: 0,
    restartDelayMs: 20,
    maxStartFailures: 2,
  }, logger)
  bridge.start()
  // The first spawn fails; the scheduler should retry once, then give up.
  await waitFor(() => failures >= 2)
  await waitFor(() => bridge.restartSuppressed === true)
  await waitFor(() => bridge.child === undefined)

  const failuresAfterGiveUp = failures
  await new Promise((resolve) => setTimeout(resolve, 100))
  assert.equal(failures, failuresAfterGiveUp)
  assert.equal(bridge.child, undefined)
  bridge.stop('startup-failure-test-complete')
})

test('explicit user close suppresses automatic restart until the next DSH boot', async () => {
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const bridge = new HelperProcess({
    command: process.execPath,
    args: [closedFixture],
    headless: false,
    heartbeatMs: 0,
    restartDelayMs: 25,
  }, logger)
  bridge.start()
  bridge.send(createMessage(CompanionMessageKind.STATE, {
    state: CompanionState.IDLE,
    message: 'close me',
  }))
  await waitFor(() => bridge.restartSuppressed === true)
  await waitFor(() => bridge.child === undefined)
  await new Promise((resolve) => setTimeout(resolve, 100))
  assert.equal(bridge.child, undefined)
  bridge.stop('closed-test-complete')
})

test('helper that spawns but crashes before READY is bounded by the retry limit', async () => {
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const bridge = new HelperProcess({
    command: process.execPath,
    args: [crashBeforeReadyFixture],
    headless: false,
    heartbeatMs: 0,
    restartDelayMs: 15,
    maxStartFailures: 3,
  }, logger)
  bridge.start()
  // The process can spawn fine but never becomes ready; the restart must be
  // bounded instead of looping forever.
  await waitFor(() => bridge.restartSuppressed === true)
  await waitFor(() => bridge.child === undefined)
  await waitFor(() => bridge.startFailures >= 3)

  const failuresAfterGiveUp = bridge.startFailures
  await new Promise((resolve) => setTimeout(resolve, 120))
  assert.equal(bridge.startFailures, failuresAfterGiveUp)
  assert.equal(bridge.child, undefined)
  assert.equal(bridge.restartSuppressed, true)
  bridge.stop('crash-before-ready-test-complete')
})

test('a launch that throws synchronously cannot crash the host and is bounded', async () => {
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const bridge = new HelperProcess({
    command: 123, // spawn() rejects this with a synchronous TypeError
    headless: false,
    heartbeatMs: 0,
    restartDelayMs: 10,
    maxStartFailures: 2,
  }, logger)
  assert.doesNotThrow(() => bridge.start())
  await waitFor(() => bridge.restartSuppressed === true)
  await waitFor(() => bridge.child === undefined)
  await waitFor(() => bridge.startFailures >= 2)

  const afterGiveUp = bridge.startFailures
  await new Promise((resolve) => setTimeout(resolve, 120))
  assert.equal(bridge.startFailures, afterGiveUp)
  assert.equal(bridge.child, undefined)
  bridge.stop('launch-throw-test-complete')
})

test('killing the real Swift helper triggers a bounded automatic restart', { skip: !swiftHelperExists }, async () => {
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const bridge = new HelperProcess({
    command: swiftHelperPath,
    headless: true,
    heartbeatMs: 0,
    restartDelayMs: 30,
  }, logger)
  const first = bridge.start()
  // The Swift helper becomes ready (first spawn); wait for the READY handshake.
  await waitFor(() => bridge.spawned === true, 5000)

  // Simulate an unexpected crash: kill the child. The bridge must respawn a new
  // process (different child reference) and become ready again, without flipping
  // restartSuppressed before the retry limit.
  first.kill()
  await waitFor(() => bridge.child && bridge.child !== first, 5000)
  await waitFor(() => bridge.spawned === true, 5000)
  assert.equal(bridge.restartSuppressed, false)

  bridge.stop('swift-restart-test-complete')
  await waitFor(() => bridge.child === undefined, 5000)
})
