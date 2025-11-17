# Automated Git Monitor

This script automatically monitors files for changes and commits them to GitHub.

## Setup
1. Configure `config.cfg` with your repository paths
2. Make script executable: `chmod +x monitor_and_push.sh`
3. Run: `./monitor_and_push.sh`

## Features
- Monitors files/directories for changes using SHA-256 checksums
- Automatically commits and pushes changes
- Logs notifications in NOTIFICATIONS.md
- Handles errors with retry logic

## Notification System
Changes are logged in NOTIFICATIONS.md instead of email notifications.
