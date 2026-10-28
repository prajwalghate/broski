**What changes for the person using Broski**

**How it's tested**
- [ ] Tests written first, and they fail without the change
- [ ] `scripts/ci.sh` is green (`--ios` if the iPhone app or shared code changed); the pre-commit hook checks it
- [ ] Screenshots from `--snapshot` or a device run, if it changes a screen
- [ ] The `reviewer` agent or a person read the diff

**Privacy and safety**
- [ ] Nothing new leaves the device, or the new path has a privacy test (local-only projects, private mode, secrets)
- [ ] Nothing writes into a project's repo or runs its code
- [ ] No personal data in code, tests, fixtures or docs (names, real notes, paths, keys)
