# Build configuration

The build scripts refer to this path. The guide to the App Store build configuration is the section
"Building the App Store configuration" of [README.md](../README.md): copy
`build-system/zenlygram-appstore.json` to `build-system/zenlygram-appstore.local.json` (git-ignored) and replace
every `FILL_ME` value with your own. Never commit real values: `api_hash` in a public repository gets scraped
and abused, and Telegram then restricts the `api_id`.
