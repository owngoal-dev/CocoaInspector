<p align="center">
  <a href="README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# Inspector

Inspect running processes on your jailbroken iPhone or iPad. Monitor CPU usage, memory, thread counts, and process owners in a live list, then open a process to inspect its threads, files, ports, and loaded modules.

![Preview](./Documents/screenshots.png)

## Install

Add the OwnGoal Studio repository in Sileo, Zebra, or another package manager:

**[Add to Sileo](sileo://source/https://apt.owngoal.dev)** · [apt.owngoal.dev](https://apt.owngoal.dev/)

Packages are also on [GitHub Releases](https://github.com/owngoal-dev/CocoaInspector/releases). Choose the file that matches your jailbreak.

| Jailbreak | Package |
| --- | --- |
| [roothide](https://github.com/roothide) | `iphoneos-arm64e` |
| Rootless (`/var/jb`) | `iphoneos-arm64` |

Requires iOS 16 or later. Inspector is not for the App Store.

## Features

- **Live process list**: View CPU usage, memory, thread counts, and process owners with updates every second. Pause updates to inspect the current list.
- **Find a process**: Search by name or PID. Sort by CPU usage, memory, PID, or name. Filter to system, user, or app processes.
- **Process details**: Threads, open files and sockets, Mach ports, loaded modules, sandbox status, and disk and network use.
- **Stop a process**: Ask It to Quit or Force Quit from the detail screen. PID 1 cannot be stopped.
- **Export**: Share a snapshot of a process as a file.
- **Command line**: Inspect processes and monitor CPU usage from a terminal with `cocoainspector`.

## Command Line

```sh
sudo cocoainspector list
sudo cocoainspector inspect 1
sudo cocoainspector details 1 all
sudo cocoainspector watch --count 10 --interval-ms 1000
sudo cocoainspector self-test
```

`self-test` is read-only. Add `--signal` only when you want to exercise Ask It to Quit and Force Quit on a child of the CLI — it does not target a system process.

On a rootless jailbreak, the tool is `/var/jb/usr/bin/cocoainspector`.

## Build from Source

Requires macOS with Xcode, `ldid`, and `dpkg-deb`.

```sh
make deb              # roothide
make deb FLAVOR=rootless
make deb-all          # both packages
make harness          # data-layer tests on Mac
```

Contributor notes are in [AGENTS.md](AGENTS.md). Daemon design is in [Documents/Daemon-XPC-Architecture.md](Documents/Daemon-XPC-Architecture.md).

## License

Inspector is available under the [MIT License](LICENSE).

Join the community on [Discord](https://discord.gg/vqhDEep2mN).
