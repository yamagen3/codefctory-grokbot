/** Step timeout budget shared by the orchestrator plugin and its tests. */

export const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000
export const TIMEOUT_EXIT_CODE = 124

function positiveNumber(value) {
  if (value === undefined || value === null || value === '') return null
  const number = Number(value)
  return Number.isFinite(number) && number > 0 ? number : null
}

/**
 * Resolve the per-step timeout. An explicit step timeout wins, then the stall
 * budget (leaving room for the stall retry wrapper), then the configured value.
 *
 * @param {number|undefined} configMs
 * @param {NodeJS.ProcessEnv|Record<string, string|undefined>} env
 * @returns {number}
 */
export function resolveTimeoutMs(configMs, env = {}) {
  const stepMs = positiveNumber(env?.FACTORY_STEP_TIMEOUT_MS)
  if (stepMs !== null) return stepMs

  const stallSec = positiveNumber(env?.FACTORY_STALL_TIMEOUT_SEC)
  if (stallSec !== null) {
    const ms = stallSec * 1000
    const margin = Math.max(60000, Math.floor(ms / 10))
    return Math.max(ms - margin, Math.floor(ms / 2))
  }

  const configuredMs = positiveNumber(configMs)
  return configuredMs !== null ? configuredMs : DEFAULT_TIMEOUT_MS
}

/**
 * Map an activation stop reason to the process exit code.
 *
 * @param {string|undefined} stopReason
 * @param {boolean} timedOut
 * @returns {number}
 */
export function exitCodeFor(stopReason, timedOut) {
  if (stopReason === 'completed') return 0
  if (timedOut) return TIMEOUT_EXIT_CODE
  return 1
}
