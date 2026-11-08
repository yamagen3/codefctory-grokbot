/**
 * Load the published command-goal file while stubbing packages that pull the
 * whole DSH host. The command implementation itself is not stubbed.
 */
const stubs = new Map([
  ['@deepseek-ai/dsh-goal', new URL('./dsh-stubs/goal.mjs', import.meta.url).href],
  ['@deepseek-ai/dsh-llm', new URL('./dsh-stubs/llm.mjs', import.meta.url).href],
])

export async function resolve(specifier, context, nextResolve) {
  const stub = stubs.get(specifier)
  if (stub) return { url: stub, shortCircuit: true }
  return nextResolve(specifier, context)
}
