# Fixed labels and hover captions

NVX uses Pie's fixed-label mode and configurable stationary-hover captions. The
release app has been rebuilt and its signature verified. Its exact binary passed
19 real-pointer window/tab checks in the dedicated macOS guest. The shared
presentation fixture passed 11 real-pointer checks, and the focused native
presentation/window-guard suites passed 10 tests.

The [complete verification record](../../../Documents/Pie/validation/tab-presentation/README.md)
contains binary hashes, logs, captures, browser results and configuration examples.
Source and vendor hashes are in `Tabs/Pie-source.json`; only NVX's existing
refresh/accessibility/compressed-title adapter differs from native Pie.
