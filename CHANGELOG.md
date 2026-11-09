# Changelog

All notable changes to lain5g-manager are documented here.

## [1.1.8] - 2026-11-09

### Added
- Dynamic discovery of official OpenLain5G profiles (`PUBLIC_PROFILE_IDS` and `DEPLOYMENTS`)
- Dynamic discovery of Compose project names and running containers
- Educational section explaining the 6 containers that comprise OpenLain5G Web App & Observability
- Integration with `./lain5g scenario start` and `./lain5g scenario stop`
- Full compatibility with OpenLain5G v1.1.8 and backwards compatibility with earlier releases
- Guided start for Real IMS Service (4G / 5G) via OpenLain5G Web App with operations mode

### Fixed
- Fixed stopping Real IMS 4G and 5G services (`cmd_stop`) using direct Docker Compose project-level down (`-p`) instead of blocked internal Makefile targets
- Fixed stopping VoLTE and VoNR scenarios using Compose project-level down fallback
- Thorough Docker Compose project cleanup during uninstall step 1 covering all discovered Compose stacks and Real IMS/VoLTE manifests

## [1.1.7] - 2026-11-05

### Added
- Initial release compatible with OpenLain5G 1.1.7
- Interactive menu with 8 options
- `cmd_about()`: embedded educational guide
  - What is OpenLain5G?
  - What is 4G and 5G? (from scratch)
  - What are frequency bands?
  - What is Docker?
  - What is simulation? (no hardware needed)
  - What is USRP / SDR?
  - Antenna RF safety (VSWR, frequency table, checklist)
  - Getting Started guide
- `cmd_start()`: launch simulations (5G SA, 4G LTE, 5G VoNR) and the web app
  - App web mode: `--operations` (full control) or observation-only
  - RF profiles shown as informational-only with antenna safety panel
- `cmd_stop()`: detect running components and stop them selectively
  - Shows numbered list of active components
  - `todo` option to stop everything at once
- Commands printed to terminal before execution (non-black-box design)
- Status line in menu header showing running components
- `--status` flag: non-interactive status output
- `--help` flag
- One-liner installation via curl

### Compatibility
- OpenLain5G: 1.1.7
