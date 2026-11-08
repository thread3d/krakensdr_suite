# Xavier AGX — building the V2 suite

This branch is the working copy of the V2 suite on the **NVIDIA Jetson Xavier AGX** (`aarch64`,
Ubuntu 20.04 LTS, kernel 5.10.104-tegra). Companion repos: [`thread3d/KrakenSDR`](https://github.com/thread3d/KrakenSDR)
(hardware bring-up), `thread3d/ogn-rf` and `thread3d/heimdall_daq_fw` (the *previous* generation).

## Why this suite replaces the older DAQ work

The V1 stack (`heimdall_daq_fw` + `krakensdr_doa`) is Python for the DSP stages, and that dragged in a
whole dependency chain: `numba` for the calibration hot loops, `skrf` for Touchstone calibration,
`pyargus` for DOA — and `numba` on ARM effectively means conda. Delay synchronisation, phase
calibration and the MUSIC pipeline all lived in `delay_sync.py` / `SignalProcessor`.

The V2 suite has **none of that**:

| V1 (older) | V2 (this) |
|---|---|
| `heimdall_daq_fw` separate repo, Python stages | `heimdall_v2` — all C++, in-tree |
| `delay_sync.py` needs numba + skrf | phase calibration in C++ (`dsp/compensation.cpp`, Eigen) |
| NE10 needed for the ARM decimator | pffft vendored in `external/`, no NE10 |
| `krakensdr_doa` Python UI on Dash 1.x | `kraken_doa_v2` C++ UI |
| librtlsdr linked dynamically, distro copy can shadow it | librtlsdr linked **statically**, cannot be shadowed |

So on this platform the V2 suite removes the numba/skrf/conda problem entirely. The Python that
remains is test-signal generators for the decoder plugins, not runtime code.

## What the Xavier has, and what is missing

`install.sh` wants this apt list. Present already:

```
build-essential  cmake  git  pkg-config  libusb-1.0-0-dev
libeigen3-dev  libssl-dev  zlib1g-dev  libsqlite3-dev  gpsd
bubblewrap
```

Missing (all need `sudo apt install`):

| Package | Needed by | Impact if absent |
|---|---|---|
| `libopus-dev` | `kraken_doa_v2` (`-lopus`) | the UI will not link |
| `libcrypto++-dev` | uWebSockets SSL | may be optional (`WITH_SSL=0` works) |
| `libusb-dev` | librtlsdr fork (legacy libusb 0.1) | not needed, the fork uses libusb-1.0 |
| `tmux` | `run.sh` split dashboards | cosmetic only |
| `socat` | the AI assistant sandbox | optional feature |

`heimdall_v2` needs only what is already installed: Eigen, OpenSSL, zlib, libusb-1.0, plus
uWebSockets (cloned automatically at a pinned commit) and the krakenrf librtlsdr fork.

## What was verified on this host

Built successfully:

- **librtlsdr fork** at `578b43d` — exactly the commit `heimdall_v2/CMakeLists.txt` requires
  (`RTLSDR_FIX_MARK` / `rtlsdr_finish_tune` present), producing `build/src/librtlsdr.a`.
- **uWebSockets** at the pinned commit, including the `uSockets` submodule.
- **All `heimdall_v2` translation units compile** with C++20.

## The blocker: no C++20 compiler in the system toolchain

Ubuntu 20.04 ships **gcc 9.4**, which does not even recognise the flag:

```
g++: error: unrecognized command-line option '-std=c++20'; did you mean '-std=c++2a'?
```

`-std=c++2a` is not a workaround: uWebSockets needs real C++20 (coroutines), which gcc 9 lacks.

A conda-forge **gcc 13.4.0** toolchain exists at `~/toolchains/gcc13` and does compile everything —
but it is a cross-toolchain with its own sysroot, so linking against system libraries fails:

```
undefined reference to `udev_enumerate_add_match_property@LIBUDEV_183'
undefined reference to `__libc_dlerror_result@GLIBC_PRIVATE'
```

Mixing conda's glibc with `/usr/lib/aarch64-linux-gnu/*.so` does not work. Two further pitfalls found
along the way, both specific to that toolchain:

- `USOCKETS_FLAGS` in `heimdall_v2/Makefile` hardcodes `CC=gcc`, so uSockets builds with the *system*
  compiler while heimdall uses gcc 13. The resulting LTO bytecode mismatch is fatal at link time:
  `bytecode stream in file 'uSockets/bsd.o' generated with GCC compiler older than 10.0`.
  Override with `USOCKETS_FLAGS="... CC=<gcc13 C driver>"`.
- uSockets' sources are `.c`. Handing them the **C++** driver compiles them as C++ and fails on
  `void*` conversions. It needs the gcc 13 **C** driver while heimdall needs the **C++** one.

## Three ways forward

1. **Docker — upstream's supported path.** `Dockerfile` + `docker-compose.yml` are in the tree and
   build on `debian:trixie` (gcc 12), so the toolchain problem simply does not arise. Docker 26.1.3
   is installed, but `threaded` is not in the `docker` group, so this needs `sudo docker compose build`.
   Cleanest and least surprising; it is also what upstream tests.
2. **A real gcc 10+ on the host.** `sudo apt install gcc-11 g++-11` is not available on Focal; the
   usual route is `ubuntu-toolchain-r/test`. Then the plain `./install.sh` works, and `libopus-dev`
   plus friends come from the same apt run.
3. **A self-consistent conda toolchain.** Install `libusb`, `eigen`, `openssl`, `zlib` into the
   `gcc13` env so every library comes from one sysroot. No root needed, but it is an unusual
   configuration and the resulting binary is built against conda's glibc rather than the system's.

Option 1 is recommended unless a native build is specifically wanted.

## Patch carried on this branch

`heimdall_v2/src/sdr/kerberos_gpio.cpp` does not compile against Ubuntu 20.04's kernel headers,
which predate the **GPIO v2 uAPI** (kernel 5.10 uapi):

```
error: 'GPIO_V2_GET_LINE_IOCTL' was not declared in this scope
```

The file already has a "this platform cannot drive Pi header GPIOs" stub for non-Linux, and Kerberos
switch control is KerberosSDR-only — a KrakenSDR never calls it. The guard is therefore widened from
`#ifndef __linux__` to also cover a Linux whose headers lack `GPIO_V2_GET_LINE_IOCTL`, so it falls back
to the same stub and says why. It is a two-line change and is needed for *any* native build on a
pre-5.10-uapi distribution, not just this host.
