# Staged patches

Patches that are written and build but have not run on the phone, or ran without proving what they are for. They
are kept out of the default build: `scripts/03-apply-patches.sh` applies them and `scripts/04-build-kernel.sh` adds
their config fragments only for the topics named in `STAGING` (in `scripts/local.sh` or the environment):

```sh
STAGING="camera" scripts/03-apply-patches.sh   # the default patches, then the camera topic's
STAGING="camera" scripts/04-build-kernel.sh    # the kernel with the topic's config fragment too
```

A topic directory has the layout of `patches/`: `kernel/` (patches and `*.config` fragments) and
`oh/<project path>/`. A staged patch comes after its project's default patches, and its number continues their
series; numbers are unique across the default set and every topic. Promoting a patch, once it has run on the phone
and done what it is for: `git mv` it into `patches/kernel/` or `patches/oh/<project path>/` (config lines into
`patches/kernel/oneplus6.config`), a row in the README's patch table, and the topic's README updated.

A source tree keeps staged patches once they are applied: 03-apply-patches.sh without `STAGING` does not take them
out. Undo them, last first, with `git -C <project> apply -R <patch>` before going back to the default build.

| topic | what | state |
|---|---|---|
| [`hang`](hang) | kernel `0005`-`0007`: the access-token device's terminal probes without a log line, fastrpc session 0, UFS interconnect votes; a config fragment and `log_buf_len=4M` for crash-dump captures; the storage stress that hangs the phone | `0007` ran on the phone and did not stop the hang; the others are not evaluated |
| [`camera`](camera) | kernel `0008`-`0010`: SDM845 camera subsystem, the three sensors and lenses, their device tree (all modules); OH: the camera HDI for the rear IMX376K | built (kernel modules and DTB, the OH camera targets), not run on the phone |
