#!/bin/zsh
set -euo pipefail

APP_NAME="Printer Bridge"
APP_PATH="/Applications/Printer Bridge.app"
PACKAGE_ID="com.danielraffel.printerbridge"
AGENT_LABEL="com.danielraffel.printerbridge.agent"
LEGACY_AGENT_LABEL="com.danielraffel.printerbridge.daemon"
PRODUCT_SUPPORT_DIR="$HOME/Library/Application Support/PrinterBridge"
LEGACY_AGENT_PLIST="$HOME/Library/LaunchAgents/${LEGACY_AGENT_LABEL}.plist"
PREFERENCES_FILE="$HOME/Library/Preferences/com.danielraffel.printerbridge.plist"
SAVED_STATE_DIR="$HOME/Library/Saved Application State/com.danielraffel.printerbridge.savedState"
CACHE_DIR="$HOME/Library/Caches/com.danielraffel.printerbridge"
USER_DOMAIN="gui/$(id -u)"

print_section() {
  printf '\n%s\n' "$1"
}

confirm_uninstall() {
  print_section "This will remove ${APP_NAME}, stop its background service, and delete its local settings for $(whoami)."
  printf 'Continue? [y/N] '
  read -r reply

  case "${reply:-}" in
    y|Y|yes|YES)
      ;;
    *)
      print_section "Uninstall cancelled."
      exit 0
      ;;
  esac
}

stop_background_services() {
  killall "PrinterBridge" >/dev/null 2>&1 || true
  killall "Printer Bridge Daemon" >/dev/null 2>&1 || true

  /bin/launchctl bootout "${USER_DOMAIN}/${AGENT_LABEL}" >/dev/null 2>&1 || true
  /bin/launchctl bootout "${USER_DOMAIN}/${LEGACY_AGENT_LABEL}" >/dev/null 2>&1 || true
}

remove_user_data() {
  rm -rf "$PRODUCT_SUPPORT_DIR"
  rm -rf "$SAVED_STATE_DIR"
  rm -rf "$CACHE_DIR"
  rm -f "$PREFERENCES_FILE"
  rm -f "$LEGACY_AGENT_PLIST"
}

remove_app_and_receipt() {
  /usr/bin/osascript - "$APP_PATH" "$PACKAGE_ID" <<'APPLESCRIPT'
on run argv
  set appPath to item 1 of argv
  set packageID to item 2 of argv

  try
    do shell script "if [ -d " & quoted form of appPath & " ]; then rm -rf " & quoted form of appPath & "; fi" with administrator privileges
  on error errMsg number errNum
    if errNum is not -128 then error errMsg number errNum
  end try

  try
    do shell script "/usr/sbin/pkgutil --forget " & quoted form of packageID & " >/dev/null 2>&1 || true" with administrator privileges
  on error errMsg number errNum
    if errNum is not -128 then error errMsg number errNum
  end try
end run
APPLESCRIPT
}

finish() {
  print_section "${APP_NAME} has been removed for $(whoami)."
  printf 'Press Return to close this window.'
  read -r _
}

confirm_uninstall
stop_background_services
remove_user_data
remove_app_and_receipt
finish
