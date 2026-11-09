/**
 * Configure the session goal through DSH's registered `/goal` command.
 *
 * `@deepseek-ai/dsh-command-goal@0.2.2-rc.1` registers `name: "goal"` on
 * `ctx.commands`. `CommandRuntime.execute(agent, line, attachments, signal)`
 * is the supported invocation: it does not send the slash line to a model.
 * The headless runner never calls that method; this factory step does.
 *
 * `dsh-goal-round-driver` continues only an active armed goal and would send
 * that round to the parent model. After the command creates the goal, disarm
 * continuation so the dummy parent stays unused. The durable objective remains.
 */
export async function configureDshGoal({ commands, goals, agent, line, signal, prompt }) {
  if (typeof line !== 'string' || !line.startsWith('/goal')) {
    throw new Error('factory: DSH goal line must be the /goal command')
  }
  if (typeof commands?.execute !== 'function') {
    throw new Error('factory: DSH /goal requires ctx.commands.execute (dsh-commands)')
  }
  if (typeof goals?.get !== 'function' || typeof goals?.disarm !== 'function') {
    throw new Error('factory: DSH /goal requires ctx.goals.get and ctx.goals.disarm')
  }
  const execution = await commands.execute(agent, line, [], signal)
  if (execution === undefined) {
    throw new Error('factory: DSH did not recognize the /goal command')
  }
  const result = execution.result
  if (!result || result.kind !== 'success') {
    throw new Error(`factory: DSH /goal failed: ${result?.text || 'unknown'}`)
  }
  const created = goals.get(agent)
  const objective = created?.objective
  if (typeof objective !== 'string' || objective.length === 0) {
    throw new Error('factory: DSH /goal did not set an objective')
  }
  if (typeof prompt !== 'string' || !prompt.includes(objective)) {
    throw new Error('factory: DSH goal objective is not in the step prompt')
  }
  const disarmed = goals.disarm(agent)
  return {
    objective,
    commandText: result.text || '',
    phase: disarmed?.phase ?? created.phase,
    activation: disarmed?.activation ?? created.activation,
  }
}
