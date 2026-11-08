/**
 * Run the published @deepseek-ai/dsh-command-goal@0.2.2-rc.1 handler, then the
 * factory function that supplies that objective to the spec prompt.
 * No model call and no API key. Requires FACTORY_DSH_COMMAND_GOAL (the package root).
 */
import assert from 'node:assert/strict'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { configureDshGoal } from '../../plugin/dsh-goal.js'

const root = process.env.FACTORY_DSH_COMMAND_GOAL
if (!root) throw new Error('FACTORY_DSH_COMMAND_GOAL is required')
const commandUrl = pathToFileURL(path.join(root, 'lib/index.js')).href
const { apply } = await import(commandUrl)

const OBJECTIVE = 'DeepSeek max setting persists after reprovision, and factory /goal entry is established and verified.'
const LINE = `/goal ${OBJECTIVE}`
const specPrompt = `You are the factory SPEC step.\nBrief: ${OBJECTIVE}\n`
const transcript = []
const registered = []
const store = { current: undefined }
const agent = { id: 'factory-agent' }
const goals = {
  create(received, request) {
    assert.equal(received, agent)
    store.current = {
      id: 'goal-1',
      revision: 1,
      phase: 'active',
      activation: 'armed',
      objective: request.objective,
      roundsStarted: 0,
      maxGoalRounds: 256,
    }
    transcript.push({ event: 'goals.create', objective: request.objective, activation: 'armed' })
    return { ...store.current }
  },
  get() {
    return store.current ? { ...store.current } : undefined
  },
  disarm(received) {
    assert.equal(received, agent)
    assert.equal(store.current.phase, 'active')
    store.current = { ...store.current, activation: 'disarmed' }
    transcript.push({ event: 'goals.disarm', phase: store.current.phase, activation: 'disarmed' })
    return { ...store.current }
  },
}
apply({ commands: { register: (definition) => registered.push(definition) }, goals })
assert.equal(registered.length, 1)
assert.equal(registered[0].name, 'goal')
const handler = registered[0].handler

const commands = {
  async execute(received, line, attachments, signal) {
    const match = /^\/([a-z][a-z0-9_-]*)(?=$|[\t\n\r ])/u.exec(line)
    if (match === null) return undefined
    const definition = registered.find((item) => item.name === match[1])
    if (!definition) return undefined
    const result = await definition.handler({
      commandId: 'cmd-1',
      agent: received,
      rawInput: line.slice(match[0].length),
      attachments,
      signal,
    })
    transcript.push({ event: 'command/done', name: match[1], kind: result.kind, text: result.text })
    return { commandId: 'cmd-1', result }
  },
}

const configured = await configureDshGoal({
  commands,
  goals,
  agent,
  line: LINE,
  signal: new AbortController().signal,
  prompt: specPrompt,
})
assert.equal(configured.objective, OBJECTIVE)
assert.equal(configured.phase, 'active')
assert.equal(configured.activation, 'disarmed')
assert.equal(specPrompt.includes(configured.objective), true)
assert.match(configured.commandText, /^Goal created/)
assert.match(configured.commandText, /Objective: DeepSeek max setting persists/)
assert.equal(store.current.activation, 'disarmed')
assert.equal(transcript.some((row) => row.event === 'goals.create' && row.objective === OBJECTIVE), true)

const shown = await handler({
  commandId: 'cmd-2',
  agent,
  rawInput: '',
  attachments: [],
  signal: new AbortController().signal,
})
transcript.push({ event: 'command/done', name: 'goal', kind: shown.kind, text: shown.text })
assert.equal(shown.kind, 'success')
assert.match(shown.text, /^Goal\n/)

for (const row of transcript) console.log(JSON.stringify(row))
console.log('test_dsh_goal_command: PASS')
