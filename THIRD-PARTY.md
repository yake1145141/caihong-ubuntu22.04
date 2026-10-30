# Third-party components

This repository contains only port code (scripts, configuration, documentation).
The following components are pulled in at build time or published as release
assets, and keep their own licenses.

| Component | Origin | License / terms |
| --- | --- | --- |
| Linux kernel, device tree, kernel modules | `linux-caihong` package from the upstream release of [`osilvfe/caihong-linux-rootfs`](https://github.com/osilvfe/caihong-linux-rootfs) | GPL-2.0-only |
| Device firmware (Qualcomm ADSP/CDSP/GPU/WLAN, Awinic, Novatek) | upstream `caihong-linux-rootfs` `firmware/` tree, extracted from the stock OnePlus firmware | vendor terms; **not** covered by GPL-2.0 |
| Mesa 24.3.4 (freedreno + turnip) | built from [mesa3d.org](https://archive.mesa3d.org/) 24.3.4 sources | MIT |
| Ubuntu 22.04 packages | `ubuntu-ports` archives | per-package (mostly free software) |
| AudioReach topology | `external/audioreach-topology` (upstream) | BSD-3-Clause |
| qbootctl | [`linux-msm/qbootctl`](https://github.com/linux-msm/qbootctl) | BSD-3-Clause |

The firmware is downloaded by the build from the upstream release; it is not
redistributed here. `firmware/SHA256SUMS` in the upstream repository records
every binary input.
