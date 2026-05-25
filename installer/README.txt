Enshittifier Installer
======================

This DMG contains two apps:

  Enshittifier Installer.app — patches your installed fonts so the
      standalone word "ai" (any case: ai / AI / Ai / aI) is displayed
      as 💩 wherever that font is used. All four case variants trigger
      the substitution. "ai" inside a word (painter, rain, said, email)
      is left untouched.

  Unshittifier.app — restores your original fonts from the backup
      folder created during installation.


HOW IT WORKS
------------
The installer scans three font locations:

  ~/Library/Fonts/         User fonts. Patched in-place; original saved
                           to ~/Desktop/Fonts (Backup)/.

  /Library/Fonts/          Shared fonts (admin password required).
                           Patched in-place; original saved to backup.

  /System/Library/Fonts/   System fonts. macOS SIP makes these read-only,
                           so the installer copies each chosen font into
                           ~/Library/Fonts/ and patches that copy. macOS
                           CoreText prefers ~/Library/Fonts/ over
                           /System/Library/Fonts/ for virtually all
                           user-space apps (browsers, text editors, etc.).
                           The original system file is NEVER modified.


IMPORTANT LIMITATION — UI CHROME FONTS
---------------------------------------
SF Pro, SF Compact, and .AppleSystemUIFont are intentionally excluded
from the font list. macOS WindowServer and the system UI load these fonts
via private internal paths — not by PostScript name lookup — so placing a
shadowed copy in ~/Library/Fonts/ has no effect on menus, the Dock, or
system dialogs. The exclusion is a feature, not a bug.


AFTER INSTALLATION
------------------
Font changes take effect after:
  1. Flushing the font cache (the installer does this automatically), and
  2. Logging out and back in, or restarting the apps that use the font.

Some apps cache fonts at launch and must be restarted individually.


UNINSTALLING
------------
1. Open ~/Desktop/Fonts (Backup)/.
2. Double-click Unshittifier.app.
3. Select the fonts you want to restore and click "Restore Selected".
4. Log out and back in.

For system fonts that were shadowed: the uninstaller deletes the copy
in ~/Library/Fonts/; macOS automatically reverts to the untouched
/System/Library/Fonts/ original after a cache flush + log out.


REQUIREMENTS
------------
macOS 10.15 (Catalina) or later. No SIP changes required.
