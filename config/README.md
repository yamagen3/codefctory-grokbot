# Factory DSH config

- `factory.patch.yml` — used by `bin/factory-step` (`dsh --patch …`). Path tokens `__FACTORY_ROOT__` and `__FACTORY_DSH_NM__` are rendered at run time from the checkout and `$HOME/.dsh/profiles/headless/node_modules`.
- `headless.package.json` — copy of `~/.dsh/profiles/headless/package.json` (deps; bundles = base+headless only)
- Profile `cordis.patch.yml` is empty; all factory overlays live in `factory.patch.yml`
