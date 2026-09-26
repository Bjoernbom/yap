# yap

talk. it types.

yap 1.0 is being rebuilt from scratch as a native Mac app: dictation and
meeting notes, fully on-device. The plan lives in [docs/PLAN.md](docs/PLAN.md).

Looking for the current release? yap 0.4 is on the
[releases page](https://github.com/Bjoernbom/yap/releases/tag/v0.4.0) and its
source is under the [`v0.4.0`](https://github.com/Bjoernbom/yap/tree/v0.4.0) tag.

## Build

Requires macOS 26+, Apple Silicon, Xcode 26 and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
swift test   # core logic
make run     # build the app and launch it
```

## License

[MIT](LICENSE) — made by [bjornbom](https://github.com/Bjoernbom).
