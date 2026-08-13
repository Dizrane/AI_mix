# Security

Accessibility is sensitive. The app requests no permission automatically, opens System Settings only at user request, and treats scanning as read-only. Credentials must be stored in Keychain by a future provider configuration screen, never in session artefacts. Raw snapshots can contain project metadata and must stay on the local machine unless the user chooses to send a normalized context to an LLM.

Closed shell: the folder around the `.app` is the program's entire footprint — all data lives in `Data/` beside the bundle, storage refuses to initialize when the `.app` sits directly in a shared folder (Downloads, Desktop, home…), and uninstalling deletes that one folder plus the few `~/Library` files macOS created for the app's exact bundle identifier. The only trace the app cannot remove is the Accessibility permission entry, which macOS owns.
