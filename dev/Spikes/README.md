# libtmux Swift bakeoffs

This SwiftPM package is disposable experiment infrastructure for libtmux's
Swift architecture bakeoffs. It pins the Swift toolchain and shared support
contracts used by the individual contenders.

Run the harness checks from the repository root:

```console
$ mise exec -C swift -- bash dev/Spikes/Scripts/check-toolchain.sh
```

Run the spike support tests:

```console
$ mise exec -C swift -- swift test --package-path dev/Spikes --filter SpikeSupportTests
```
