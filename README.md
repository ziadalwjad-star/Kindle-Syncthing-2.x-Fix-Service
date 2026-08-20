# Kindle Syncthing 2.x Fix Service — Reliable, Always-On Syncthing Synchronisation

A Kindle-focused service wrapper that turns the File Managers Syncthing installation into a reliable background synchronisation service with an optional temporary web-management mode.

The programme is designed to:

* keep Syncthing running automatically in the background on the Kindle;
* start and recover correctly after reboot, delayed Wi-Fi availability and network changes;
* synchronise files continuously with any configured Syncthing peer, including Linux servers, desktops, NAS devices and other supported platforms;
* provide a temporary Manual GUI mode for securely managing Syncthing from another device on the local network;
* keep the permanent Syncthing web interface restricted to the Kindle itself;
* manage the required firewall rules automatically;
* detect and recover from Syncthing crashes and connectivity problems;
* provide clear Kindle notifications and persistent diagnostic/health files when something succeeds, fails or requires attention;
* preserve the Kindle's existing Syncthing identity, folders, certificates, credentials and configuration rather than replacing them;

In normal use, Always-On mode is installed once and then runs automatically with the Kindle. Manual GUI mode can be launched when administrative access to the Syncthing web interface is required.

# v1.1

Major reliability, security, recovery and diagnostics update.

Changes

* Added clear Kindle-side notifications for startup, success, failure, busy states and runtime recovery.
* Added persistent Always-On health reporting through `SYNCTHING-ALWAYS-ON-HEALTH.txt`.
* Fixed silent-failure cases where Syncthing could appear active while networking or firewall state was not actually ready.
* Fixed post-reboot recovery when Syncthing starts before Wi-Fi becomes available.
* Added faster recovery after Wi-Fi reconnects or the active network interface changes.
* Added automatic recovery when the managed Syncthing process exits unexpectedly.
* Added bounded restart backoff to prevent rapid restart loops.
* Reworked firewall handling around a dedicated service-owned `KST_SYNCTHING` chain.
* Firewall rules are now derived from the actual Syncthing configuration instead of assuming default ports.
* Added support for configured TCP, QUIC and local-discovery ports.
* Added safe rollback when firewall configuration fails part-way through.
* Hardened PID handling against stale files and PID reuse.
* Added process identity and process-start-time checks before termination.
* Prevented unrelated Syncthing instances using the same binary from being mistaken for the managed service.
* Hardened launcher locking against stale, recycled and legacy PID-only locks.
* Added safer graceful termination and SIGKILL escalation handling.
* Strengthened installer rollback so previous supervisors and Upstart jobs are restored after a failed installation.
* Added internal service-generation tracking so newer v1.1 supervisors reliably replace older installed revisions.
* Manual GUI now uses authenticated HTTPS for temporary LAN access.
* Manual GUI HTTPS exposure no longer requires permanently modifying the stored Syncthing TLS setting.
* Added clearer handling of the expected self-signed HTTPS certificate warning.
* Existing Syncthing credentials, certificates, identity and configuration remain preserved.
* Removed the Syncthing device ID from user-facing status output.
* Improved network-interface detection instead of relying only on `wlan0`.
* Added installed Syncthing version, network state, firewall state and service-generation information to diagnostics.
* Corrected offline status handling so `RUNNING_OFFLINE` is not reported as fully healthy.
* Added one-shot failure and recovery notifications to avoid both silent failures and repeated alert spam.
* Expanded regression and stress testing for reboot recovery, offline startup, interface changes, custom ports, firewall failures, stale PIDs, process isolation, concurrent launches, failed installs and rollback.
* Improved shell portability and BusyBox compatibility.
* General cleanup and simplification of service logic, with stronger error checking and fewer ambiguous or silent failure paths.
* Removed hard-coded assumptions about the remote peer's IP address, device identity or operating system. Note permanent Always-On GUI access remains restricted to `127.0.0.1:8384`. 

# v1.0

Initial release of the Kindle Syncthing service wrapper.

Features

* Provides Always-On and Manual GUI operating modes.
* Runs the File Managers Syncthing binary using the existing Kindle Syncthing configuration.
* Supports automatic Syncthing startup through Kindle Upstart integration.
* Keeps Syncthing running in the background for continuous file synchronisation.
* Opens the required Syncthing synchronisation and discovery firewall ports.
* Provides a Manual GUI mode for accessing the Syncthing web interface from another device on the local network.
* Uses the existing Syncthing device identity, certificates and configuration.
* Stores runtime state and logs separately from the Syncthing configuration.
* Stops conflicting legacy File Managers Syncthing services before taking control.
* Supports switching between background synchronisation and temporary GUI-access modes.
* Produces status files under `/mnt/us/documents/` for troubleshooting.
* Designed around the Kindle File Managers Syncthing installation while remaining independent of the remote peer's operating system.
