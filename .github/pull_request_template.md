**What changes for the person using Broski**

**How it's tested**
- [ ] Tests written first, and they fail without the change
- [ ] `scripts/ci.sh` passes (`--ios` if the iPhone app changed)
- [ ] Screenshots from `--snapshot` or a device run, if it changes a screen

**Privacy and safety**
- [ ] Nothing new leaves the device, or the new path has a privacy test (local-only projects, private mode, secrets)
- [ ] Nothing writes into a project's repo or runs its code
- [ ] No personal data in code, tests or fixtures (names, real notes, paths, keys)
