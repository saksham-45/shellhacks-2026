"""Demo endpoints for the ShellHacks table cut (FM-MYAD-DEMO-DESK): Fee Check, Warm Handoff Sheet, the Desk
Copilot's non-Live fallback, and Live ephemeral tokens. Every live path is optional: with MYAD_OFFLINE=1 or
no GEMINI_API_KEY, Fee Check and the Handoff Sheet run on deterministic local code and the two voice
routes answer a stable 503 code so the phone shows its labelled cached replay."""
