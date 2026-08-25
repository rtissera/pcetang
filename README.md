# pcetang

PC Engine / SuperGrafx / TurboGrafx-CD core for Sipeed Tang FPGA boards, integrated with
[TangCore](https://github.com/nand2mario/tangcore) (BL616-based ROM loading, joypad, and
on-screen display).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the real integration plan — what
TangCore's `iosys_bl616` interface actually provides (read from source, not assumed from
docs), the phased build order (Console 60K, then Primer 25K and Nano 20K), and the CD/CHD
approach reusing TangCore's existing sector-block interface. See
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for provenance of the vendored files.

**Status: research and planning only. Nothing has been synthesized yet.**
