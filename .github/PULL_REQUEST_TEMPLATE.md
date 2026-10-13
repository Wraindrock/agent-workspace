## What changed

<!-- One or two sentences. Link the issue this closes, if any. -->

## How it was verified

<!--
Check what you actually ran. The default verification path is:

  just check          # repository lint, no podman needed
  just verify         # build the image and run the container self test
-->

- [ ] `just check` passes
- [ ] `just verify` passes (or: not applicable, no image-affecting change)
- [ ] docs/ updated when behaviour or module contracts changed

## Declarative surface

<!--
This repository is declarative: modules, agents and build parameters are all
described by files. Tick the rows you touched and update the corresponding
config file so the declaration stays true.
-->

- [ ] `config/modules.conf` / `config/agents.conf` matches the change
- [ ] `image.env` still describes the image identity correctly
- [ ] new modules declare `module.env` with `MODULE_NAME`, `MODULE_DESCRIPTION`, `MODULE_ENABLED_DEFAULT`
- [ ] rollback behaviour is unchanged (or documented in `docs/rollback.md`)
