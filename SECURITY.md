# Security Policy

## Supported versions

Security fixes are provided for the latest release.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for sensitive reports:

https://github.com/Sol-momma/capsled/security/advisories/new

For non-sensitive bugs, open a regular GitHub Issue. Please do not include
passwords, access tokens, private logs, or other confidential data.

## Privilege and API scope

`capsled` does not require root privileges, Accessibility permission, or Input
Monitoring permission. It does not read keyboard events. It does use an
unsupported macOS HID event-system property, so API compatibility cannot be
guaranteed across macOS releases or keyboard models.
