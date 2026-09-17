#!/bin/bash
# Copyright (c) 2026 Dr Daniel Mompel Riera
# Licensed under the GNU Affero General Public License v3.0.
# Free to use and change; if you pass on a changed version, or let anyone
# use it over a network, you must publish your source under the same licence.
# Commercial use needs my permission: dmompelriera@nlcsjeju.kr
# Double-click to switch the reminder off. Your files are left alone.
LABEL="uk.dmr.birthdayreminder"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null
rm -f "$PLIST"
pkill -f "Contents/Resources/serve[.]py" 2>/dev/null && echo "Stopped the calendar's local server."
rm -f "$HOME/Library/Application Support/BirthdayReminder/server.url"
for A in "Birthday Reminder.app" "Student Birthdays.app"; do
  [ -L "$HOME/Desktop/$A" ] && rm -f "$HOME/Desktop/$A" && echo "Removed Desktop icon: $A"
done
echo "Reminder switched off. Delete this folder too if you want it fully gone."
echo "(Its memory of what it has already shown lives in"
echo " ~/Library/Application Support/BirthdayReminder — delete that to reset it.)"
