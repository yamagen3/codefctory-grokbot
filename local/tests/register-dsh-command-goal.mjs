import { register } from 'node:module'

register('./dsh-command-goal-loader.mjs', {
  parentURL: import.meta.url,
})
