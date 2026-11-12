# Security

This public repository contains sanitized iOS source only. Do not commit API keys, OAuth credentials, passwords, private certificates, provisioning profiles, signing identities, device data, or production configuration.

The checked-in `.env.xcconfig.example` is a template. Keep real configuration in an ignored local `.env.xcconfig` file or an approved secret manager. The companion proxy and any Google Places or AI provider keys must be configured outside Git.

Before publishing a release, inspect the Xcode project, plist files, build settings, asset catalogs, and reachable Git history for credentials and private data. Rotate any value that enters a commit, issue, pull request, build log, or chat message.

This repository is source code and does not grant access to the companion service, Apple signing account, Google APIs, or other external systems.
