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
The installer scans two font locations:

  ~/Library/Fonts/         User fonts. Patched in-place; original saved
                           to ~/Desktop/Fonts (Backup)/.

  /System/Library/Fonts/   System fonts. macOS SIP makes these read-only,
                           so the installer copies each chosen font into
                           ~/Library/Fonts/ and patches that copy. macOS
                           CoreText prefers ~/Library/Fonts/ over
                           /System/Library/Fonts/ for virtually all
                           user-space apps (browsers, text editors, etc.).
                           The original system file is NEVER modified.

/Library/Fonts/ (shared/admin fonts) is not scanned because patching it
would require running the patch subprocess with administrator privileges,
which isn't wired up. If you have a shared font you want patched, copy
it to ~/Library/Fonts/ first and re-run the installer.


IMPORTANT LIMITATIONS
---------------------
1. UI chrome fonts. SF Pro, SF Compact, and .AppleSystemUIFont are
   intentionally excluded. macOS WindowServer loads these via private
   paths — not by PostScript-name lookup — so a shadowed copy in
   ~/Library/Fonts/ has no effect on menus, the Dock, or system dialogs.

2. .ttc (TrueType Collection) fonts. Only .ttf and .otf are patched.
   Most stock macOS system fonts (Helvetica.ttc, Times.ttc, Geneva.ttc,
   …) are .ttc bundles, which the underlying patcher does not yet handle.
   Stock .ttf system fonts (e.g. Skia.ttf, Symbol.ttf) and any .ttf/.otf
   you've installed yourself are fair game.


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
