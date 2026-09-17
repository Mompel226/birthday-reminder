#!/bin/bash
# Double-click this to install or update Birthday Reminder.
#
# Unzip it anywhere - Downloads is fine - and double-click. The app copies itself into
# your Applications folder and runs from there, so the reminder does not break later
# when you tidy the download away. Run it again after any update: your classes, photos
# and settings are kept.
set -u
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="uk.dmr.birthdayreminder"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/Library/Application Support/BirthdayReminder"

# ---------------------------------------------------------------- where it should live
# /Applications when we are allowed to write there, otherwise the personal one. Never a
# Downloads or iCloud/OneDrive folder: macOS refuses background jobs access to those,
# which is silent - the job runs every five minutes and fails every five minutes.
choose_target() {
  local sys="/Applications/BirthdayReminder"
  [ -d "$sys" ] && [ -w "$sys" ] && { printf '%s' "$sys"; return; }
  [ ! -e "$sys" ] && [ -w /Applications ] && { printf '%s' "$sys"; return; }
  printf '%s' "$HOME/Applications/BirthdayReminder"
}
TARGET="${BR_TARGET:-$(choose_target)}"

# ---------------------------------------------------------------- copy ourselves there
# Only the program is copied. Profiles, active_profile and config.conf are yours and are
# never overwritten by an update - they are brought across on a first install only.
if [ "$SRC_DIR" != "$TARGET" ]; then
  echo "Installing to: $TARGET"
  mkdir -p "$TARGET" || { echo "Could not create $TARGET"; exit 1; }
  for item in "Birthday Reminder.app" "Student Birthdays.app" "Import Students.app" \
              "Install.command" "Uninstall.command" "READ ME FIRST.html"; do
    [ -e "$SRC_DIR/$item" ] || continue
    rm -rf "$TARGET/$item"
    ditto "$SRC_DIR/$item" "$TARGET/$item" || { echo "Could not copy $item"; exit 1; }
  done
  for mine in Profiles active_profile config.conf "Birthday Calendar.html"; do  # first install only
    [ -e "$SRC_DIR/$mine" ] && [ ! -e "$TARGET/$mine" ] && ditto "$SRC_DIR/$mine" "$TARGET/$mine"
  done
  xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
  echo
  BR_TARGET="$TARGET" exec "$TARGET/Install.command"       # carry on from the copy
fi

DIR="$TARGET"
APP="$DIR/Birthday Reminder.app/Contents/MacOS/BirthdayReminder"
echo "Installing from: $DIR"
[ -x "$APP" ] || chmod +x "$APP" 2>/dev/null
xattr -dr com.apple.quarantine "$DIR" 2>/dev/null      # clear the downloaded-file flag
mkdir -p "$STATE"

# ---------------------------------------------------------------- settings, merged
# An update must never hand back a factory-fresh config.conf: the whole point of the file
# is that it holds a choice somebody made. New settings are appended with their notes;
# anything already set is left exactly as it is.
DEFAULTS="$DIR/Birthday Reminder.app/Contents/Resources/config.default.conf"
CONF="$DIR/config.conf"
if [ -f "$DEFAULTS" ]; then
  if [ ! -f "$CONF" ]; then
    cp "$DEFAULTS" "$CONF" && echo "Settings file created: config.conf"
  else
    added=""
    for key in $(grep -E '^[A-Z_]+=' "$DEFAULTS" | cut -d= -f1); do
      grep -qE "^[[:space:]]*$key=" "$CONF" && continue
      { echo
        awk -v K="$key" '
          /^#/           { buf = buf $0 "\n"; next }
          $0 ~ "^" K "=" { printf "%s%s\n", buf, $0; exit }
                         { buf = "" }' "$DEFAULTS"
      } >> "$CONF"
      added="$added $key"
    done
    [ -n "$added" ] && echo "Settings kept. New ones added to config.conf:$added"
  fi
fi

# ---------------------------------------------------------------- the background job
# AbandonProcessGroup is not optional. Without it launchd kills every process the job
# leaves behind the moment the job exits - which is the popup window itself, and the
# calendar's helper. The log then says "shown" for a window that lived milliseconds.
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP</string><string>--check</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$STATE/launchd.err</string>
</dict>
</plist>
PL

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
if ! launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null; then
  launchctl unload "$PLIST" 2>/dev/null; launchctl load -w "$PLIST" 2>/dev/null
fi

echo
if launchctl list | grep -q "$LABEL"; then
  NA="$(grep -E '^[[:space:]]*NOTIFY_AFTER=' "$CONF" 2>/dev/null | tail -1 | cut -d'"' -f2)"
  echo "Done. It checks at login and every 5 minutes, which is how it catches your"
  echo "laptop waking up, and it waits until ${NA:-07:00} and until you are actually"
  echo "at the Mac before opening the window. Change that in config.conf."
else
  echo "The background job did not register. Open Terminal and run:"
  echo "  launchctl load -w \"$PLIST\""
fi

# --- build the calendar and put the app on the Desktop ---
"$DIR/Birthday Reminder.app/Contents/MacOS/build-calendar" >/dev/null 2>&1

for A in "Birthday Reminder.app" "Student Birthdays.app" "Import Students.app"; do
  [ -d "$DIR/$A" ] || continue
  chmod -R +x "$DIR/$A/Contents/MacOS" 2>/dev/null
  touch "$DIR/$A"                                    # nudges Finder to pick up the icon
done

# One icon on the Desktop. Everything is reachable from inside the calendar,
# so a second shortcut was just clutter - clear it away if an older install left one.
[ -L "$HOME/Desktop/Birthday Reminder.app" ] && rm -f "$HOME/Desktop/Birthday Reminder.app" \
  && echo "Removed the old second Desktop icon."
LINK="$HOME/Desktop/Student Birthdays.app"
if [ -L "$LINK" ] || [ ! -e "$LINK" ]; then
  rm -f "$LINK"; ln -s "$DIR/Student Birthdays.app" "$LINK" && echo "Desktop icon: Student Birthdays"
else
  echo "Left the existing $LINK alone."
fi

echo
echo "Opening today's window so you can see it working..."
"$APP" --force >/dev/null 2>&1
echo
echo "One icon is on your Desktop: Student Birthdays."
echo "Everything lives inside it - the calendar, your classes, preferred names,"
echo "settings, and a button to show today's birthday window on demand."
echo "Drag it to the Dock if you want it there permanently."
echo
if [ ! -s "$DIR/active_profile" ] && [ ! -f "$DIR/students.csv" ]; then
  echo "No class loaded yet. Open \"Import Students\" in $DIR first -"
  echo "it asks for your Student Report and Student ID Badge exports."
else
  echo "To load a different class, or next year's, open \"Import Students\" in $DIR."
fi
# If macOS is still holding files back - after copying to another Mac, say - point the
# way through rather than leaving a dead icon behind.
if xattr -pr com.apple.quarantine "$DIR" 2>/dev/null | grep -q .; then
  echo
  echo "Some files are still blocked by macOS. Opening the settings page for you."
  A="$(osascript -e 'button returned of (display dialog "macOS is still holding some of these files back.\n\nIn System Settings, scroll to the bottom of Privacy & Security and click Open Anyway." buttons {"Not now","Open Settings"} default button "Open Settings" with title "Birthday Reminder")' 2>/dev/null)"
  [ "$A" = "Open Settings" ] && open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
fi

echo "You can close this Terminal window."
