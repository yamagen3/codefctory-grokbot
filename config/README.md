# Factory DSH config

- `factory.patch.yml` — used by `/workspace/factory/bin/factory-step` (`dsh --patch …`)
- `headless.package.json` — copy of `~/.dsh/profiles/headless/package.json` (deps; bundles = base+headless only)
- Profile `cordis.patch.yml` is empty; all factory overlays live in `factory.patch.yml`
