# Security Policy

## Supported versions

Security fixes are provided for the latest release.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for sensitive reports:

https://github.com/Sol-momma/capsled/security/advisories/new

For non-sensitive bugs, open a regular GitHub Issue. Please do not include
passwords, access tokens, private logs, or other confidential data.

## Privilege and API scope

`capsled` does not require root privileges or Accessibility permission. The
`on`, `off`, `auto`, and `run` commands do not read keyboard input and do not
require Input Monitoring permission. The experimental `watch` command requires
Input Monitoring access and accepts only raw Caps Lock HID input values. It
opens keyboards non-exclusively and does not alter or suppress input.

LED control uses an unsupported macOS HID event-system property, so API
compatibility cannot be guaranteed across macOS releases or keyboard models.
