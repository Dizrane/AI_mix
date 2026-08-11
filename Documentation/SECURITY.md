# Security

Accessibility is sensitive. The app requests no permission automatically, opens System Settings only at user request, and treats scanning as read-only. Credentials must be stored in Keychain by a future provider configuration screen, never in session artefacts. Raw snapshots can contain project metadata and must stay on the local machine unless the user chooses to send a normalized context to an LLM.
