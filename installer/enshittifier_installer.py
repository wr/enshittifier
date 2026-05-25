#!/usr/bin/env python3
"""
Enshittifier Installer — macOS GUI for patching installed fonts.

Discovers fonts in:
  ~/Library/Fonts/          (user fonts, no privilege required)
  /Library/Fonts/           (shared fonts, prompts for admin via osascript)
  /System/Library/Fonts/    (system fonts; patched copy installed to ~/Library/Fonts/ to shadow)

SF Pro, SF Compact, and .AppleSystemUIFont variants are excluded because
macOS WindowServer loads those via private paths rather than PostScript-name
lookup — shadowing them via ~/Library/Fonts/ has no effect on system UI chrome.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
USER_FONT_DIR   = Path.home() / "Library" / "Fonts"
LOCAL_FONT_DIR  = Path("/Library/Fonts")
SYSTEM_FONT_DIR = Path("/System/Library/Fonts")
BACKUP_DIR      = Path.home() / "Desktop" / "Fonts (Backup)"

PATCHABLE_EXTS = {".ttf", ".otf"}

# Filename patterns for fonts we must not attempt to shadow
SF_EXCLUDE_RE = re.compile(
    r"(SF.?(Pro|Compact|Mono)|\.AppleSystemUIFont|SFNS)",
    re.IGNORECASE,
)

SHADOW_NOTE = "⚠ installs shadow copy to ~/Library/Fonts"


# ---------------------------------------------------------------------------
# Font discovery
# ---------------------------------------------------------------------------

def _collect_fonts(directory: Path) -> list[Path]:
    """Return sorted list of patchable font files in *directory* (non-recursive)."""
    if not directory.is_dir():
        return []
    return sorted(
        p for p in directory.iterdir()
        if p.is_file() and p.suffix.lower() in PATCHABLE_EXTS
    )


def _is_sf_excluded(path: Path) -> bool:
    return bool(SF_EXCLUDE_RE.search(path.name))


def discover_fonts() -> list[dict]:
    """
    Return a list of font descriptors, each a dict with keys:
      path       – absolute Path of the source font
      location   – 'user', 'local', or 'system'
      shadow     – True for system fonts (will be copied to ~/Library/Fonts/)
    """
    fonts = []

    for p in _collect_fonts(USER_FONT_DIR):
        if not _is_sf_excluded(p):
            fonts.append({"path": p, "location": "user", "shadow": False})

    for p in _collect_fonts(LOCAL_FONT_DIR):
        if not _is_sf_excluded(p):
            fonts.append({"path": p, "location": "local", "shadow": False})

    for p in _collect_fonts(SYSTEM_FONT_DIR):
        if not _is_sf_excluded(p):
            fonts.append({"path": p, "location": "system", "shadow": True})

    return fonts


def prompt_admin_for_local_fonts():
    """Use osascript to ask for admin credentials before listing /Library/Fonts/."""
    script = (
        'do shell script "ls /Library/Fonts" '
        'with administrator privileges'
    )
    result = subprocess.run(["osascript", "-e", script], capture_output=True)
    return result.returncode == 0


# ---------------------------------------------------------------------------
# Patching helpers
# ---------------------------------------------------------------------------

def _enshittifier_path() -> Path:
    """Locate enshittifier.py — next to this script or in Resources/ when bundled."""
    here = Path(__file__).resolve().parent
    candidates = [
        here / "enshittifier.py",
        here.parent / "enshittifier.py",
        here / "Resources" / "enshittifier.py",
    ]
    for c in candidates:
        if c.exists():
            return c
    raise FileNotFoundError("Cannot find enshittifier.py")


def patch_font(source_path: Path, target_path: Path):
    """Patch *target_path* in-place (no backup — caller already made the backup)."""
    script = _enshittifier_path()
    result = subprocess.run(
        [sys.executable, str(script),
         "--no-backup-yes-i-am-an-idiot", str(target_path)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"enshittifier.py failed on {target_path.name}")


def flush_font_cache():
    """Flush macOS font caches; requires admin for the system-wide cache."""
    subprocess.run(["atsutil", "databases", "-removeUser"], capture_output=True)
    script = (
        'do shell script "atsutil databases -remove" '
        'with administrator privileges'
    )
    subprocess.run(["osascript", "-e", script], capture_output=True)


def copy_unshittifier_app(backup_dir: Path):
    """Copy Unshittifier.app into the backup folder if it can be located."""
    here = Path(__file__).resolve().parent
    candidates = [
        here / "Unshittifier.app",
        here.parent / "Unshittifier.app",
    ]
    for c in candidates:
        if c.exists():
            dest = backup_dir / "Unshittifier.app"
            if not dest.exists():
                shutil.copytree(str(c), str(dest))
            return
    # No-op if app is not present (running script directly during testing)


# ---------------------------------------------------------------------------
# Install logic
# ---------------------------------------------------------------------------

def install_fonts(selected: list[dict], progress_cb=None) -> list[str]:
    """
    Back up and patch each selected font descriptor.
    Returns a list of error strings (empty = all succeeded).
    """
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)

    errors = []
    for i, desc in enumerate(selected):
        src = desc["path"]
        shadow = desc["shadow"]

        if progress_cb:
            progress_cb(i, len(selected), src.name)

        try:
            # --- Backup ---
            backup_dest = BACKUP_DIR / src.name
            if not backup_dest.exists():
                shutil.copy2(str(src), str(backup_dest))

            if shadow:
                # System font: copy to ~/Library/Fonts/ and patch the copy.
                user_copy = USER_FONT_DIR / src.name
                if not user_copy.exists():
                    shutil.copy2(str(src), str(user_copy))
                patch_font(src, user_copy)
            else:
                # User/local font: patch original in-place.
                patch_font(src, src)

        except Exception as e:
            errors.append(f"{src.name}: {e}")

    copy_unshittifier_app(BACKUP_DIR)
    flush_font_cache()
    return errors


# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

class InstallerApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Enshittifier Installer")
        self.resizable(False, False)
        self._build_ui()
        self._load_fonts()

    # --- UI construction ---

    def _build_ui(self):
        pad = {"padx": 12, "pady": 6}

        header = tk.Label(
            self,
            text="Enshittifier Installer",
            font=("Helvetica", 18, "bold"),
        )
        header.pack(**pad, anchor="w")

        note = tk.Label(
            self,
            text=(
                "Select fonts to patch. "
                "System fonts (⚠) will be shadowed in ~/Library/Fonts/.\n"
                "SF Pro, SF Compact, and UI chrome fonts are excluded — "
                "macOS loads those via private paths that cannot be overridden."
            ),
            justify="left",
            wraplength=520,
            fg="#555",
        )
        note.pack(padx=12, pady=(0, 6), anchor="w")

        # Toolbar: All / None
        toolbar = tk.Frame(self)
        toolbar.pack(padx=12, fill="x")
        tk.Button(toolbar, text="Select All", command=self._select_all).pack(side="left")
        tk.Button(toolbar, text="Select None", command=self._select_none).pack(side="left", padx=(4, 0))

        # Scrollable font list
        list_frame = tk.Frame(self, relief="sunken", bd=1)
        list_frame.pack(padx=12, pady=6, fill="both", expand=True)

        canvas = tk.Canvas(list_frame, width=540, height=340)
        scrollbar = ttk.Scrollbar(list_frame, orient="vertical", command=canvas.yview)
        self._inner = tk.Frame(canvas)
        self._inner.bind("<Configure>", lambda e: canvas.configure(
            scrollregion=canvas.bbox("all")
        ))
        canvas.create_window((0, 0), window=self._inner, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)
        canvas.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")
        canvas.bind_all("<MouseWheel>", lambda e: canvas.yview_scroll(-1 * (e.delta // 120), "units"))

        self._canvas = canvas
        self._vars: list[tk.BooleanVar] = []
        self._font_rows: list[dict] = []  # parallel to self._fonts

        # Progress bar (hidden until install)
        self._progress_var = tk.DoubleVar()
        self._progress = ttk.Progressbar(self, variable=self._progress_var, maximum=100)

        # Install button
        btn_frame = tk.Frame(self)
        btn_frame.pack(padx=12, pady=(0, 12), anchor="e")
        self._install_btn = tk.Button(
            btn_frame, text="Install Selected",
            font=("Helvetica", 13, "bold"),
            command=self._on_install,
            bg="#1a73e8", fg="white", relief="flat",
            padx=16, pady=8,
        )
        self._install_btn.pack()

    def _load_fonts(self):
        fonts = discover_fonts()
        self._fonts = fonts

        for row in self._font_rows:
            row["frame"].destroy()
        self._vars.clear()
        self._font_rows.clear()

        if not fonts:
            lbl = tk.Label(self._inner, text="No patchable fonts found.", fg="#888")
            lbl.pack(padx=8, pady=8)
            return

        for desc in fonts:
            var = tk.BooleanVar(value=True)
            self._vars.append(var)

            frame = tk.Frame(self._inner)
            frame.pack(fill="x", padx=4, pady=1)

            cb = tk.Checkbutton(frame, variable=var, anchor="w")
            cb.pack(side="left")

            name_text = desc["path"].name
            loc_tag = {"user": "~/Library/Fonts", "local": "/Library/Fonts",
                       "system": "/System/Library/Fonts"}[desc["location"]]
            label_text = f"{name_text}  [{loc_tag}]"
            if desc["shadow"]:
                label_text += f"  {SHADOW_NOTE}"
                fg = "#c05000"
            else:
                fg = "#333"

            lbl = tk.Label(frame, text=label_text, anchor="w", fg=fg, font=("Helvetica", 11))
            lbl.pack(side="left")
            lbl.bind("<Button-1>", lambda e, v=var: v.set(not v.get()))

            self._font_rows.append({"frame": frame})

    # --- Toolbar callbacks ---

    def _select_all(self):
        for v in self._vars:
            v.set(True)

    def _select_none(self):
        for v in self._vars:
            v.set(False)

    # --- Install ---

    def _on_install(self):
        selected = [desc for desc, var in zip(self._fonts, self._vars) if var.get()]
        if not selected:
            messagebox.showinfo("Nothing selected", "Please select at least one font to patch.")
            return

        shadow_count = sum(1 for d in selected if d["shadow"])
        msg = f"Patch {len(selected)} font(s)?"
        if shadow_count:
            msg += (
                f"\n\n{shadow_count} system font(s) will be shadowed "
                "in ~/Library/Fonts/ — the originals in /System/Library/Fonts/ "
                "are untouched."
            )
        msg += "\n\nOriginals will be backed up to ~/Desktop/Fonts (Backup)/ first."

        if not messagebox.askyesno("Confirm", msg):
            return

        self._install_btn.config(state="disabled")
        self._progress.pack(padx=12, pady=(0, 6), fill="x")
        self._progress_var.set(0)
        self.update()

        def progress_cb(i, total, name):
            self._progress_var.set((i / total) * 100)
            self.title(f"Installing… {name}")
            self.update()

        errors = install_fonts(selected, progress_cb=progress_cb)

        self._progress.pack_forget()
        self._install_btn.config(state="normal")
        self.title("Enshittifier Installer")

        if errors:
            err_text = "\n".join(errors)
            messagebox.showerror(
                "Some fonts failed",
                f"The following fonts could not be patched:\n\n{err_text}",
            )
        else:
            messagebox.showinfo(
                "Done",
                "Fonts patched successfully!\n\n"
                "Please log out and back in (or restart apps) to see changes.\n\n"
                "An Unshittifier.app has been placed in ~/Desktop/Fonts (Backup)/ "
                "if you ever want to restore the originals.",
            )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app = InstallerApp()
    app.mainloop()
