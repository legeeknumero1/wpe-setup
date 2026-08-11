## What this changes

<!-- And why the obvious approach was not the right one, if relevant. -->

## Checklist

- [ ] `./tests/run.sh` passes
- [ ] `shellcheck -s bash -S style wpe-setup.sh lib/wpe plugins/*.sh tests/run.sh` is clean
- [ ] No hardcoded paths — anything machine-specific is discovered at runtime
- [ ] If it writes files: they are in `backup_targets`, or removed by a plugin's `cleanup`
- [ ] A test covers the bug this fixes
