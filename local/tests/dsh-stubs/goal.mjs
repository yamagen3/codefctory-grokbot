/** Test stub for symbols the pinned command file imports. Not the goal service. */
export class GoalError extends Error {
  constructor(message, code) {
    super(message)
    this.code = code
  }
}
