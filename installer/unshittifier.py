#!/usr/bin/env python3
"""
Unshittifier — restores fonts previously backed up by Enshittifier Installer.

Reads ~/Desktop/Fonts (Backup)/, lets the user choose which fonts to restore,
then:
  - System fonts (originally from /System/Library/Fonts/): deletes the shadow
    copy from ~/Library/Fonts/ so macOS falls back to the untouched system copy.
  - User fonts (originally from ~/Library/Fonts/): copies the backup back to
    its original path.
"""

import json
import shutil
import subprocess
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
USER_FONT_DIR   = Path.home() / "Library" / "Fonts"
SYSTEM_FONT_DIR = Path("/System/Library/Fonts")
BACKUP_DIR      = Path.home() / "Desktop" / "Fonts (Backup)"
ORIGINS_FILE    = BACKUP_DIR / "origins.json"

PATCHABLE_EXTS = {".ttf", ".otf"}


# ---------------------------------------------------------------------------
# Backup discovery
# ---------------------------------------------------------------------------

def _load_origins() -> dict:
    if ORIGINS_FILE.exists():
        try:
            return json.loads(ORIGINS_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {}


def discover_backups() -> list[dict]:
    """
    Return font descriptors from the backup folder.
    Each dict has:
      backup_path    – Path inside ~/Desktop/Fonts (Backup)/
      original_path  – Path the font should be restored to
      location       – 'user' or 'system'
    """
    if not BACKUP_DIR.is_dir():
        return []

    origins = _load_origins()
    results = []
    for p in sorted(BACKUP_DIR.iterdir()):
        if not (p.is_file() and p.suffix.lower() in PATCHABLE_EXTS):
            continue

        entry = origins.get(p.name)
        if entry:
            location = entry["location"]
            original_path = Path(entry["original_path"])
        else:
            # Older backup without a manifest entry: fall back to a
            # filesystem-based guess. Prefer user over system, since user
            # files were always patched in-place (manifest absent shouldn't
            # happen for new installs).
            if (USER_FONT_DIR / p.name).exists():
                location, original_path = "user", USER_FONT_DIR / p.name
            elif (SYSTEM_FONT_DIR / p.name).exists():
                location, original_path = "system", SYSTEM_FONT_DIR / p.name
            else:
                location, original_path = "user", USER_FONT_DIR / p.name

        results.append({
            "backup_path": p,
            "original_path": original_path,
            "location": location,
        })

    return results


# ---------------------------------------------------------------------------
# Restore logic
# ---------------------------------------------------------------------------

def flush_font_cache():
    subprocess.run(["atsutil", "databases", "-removeUser"], capture_output=True)
    script = (
        'do shell script "atsutil databases -remove" '
        'with administrator privileges'
    )
    subprocess.run(["osascript", "-e", script], capture_output=True)


def _prune_manifest(removed_names: list[str]) -> None:
    """Drop restored entries from the origins manifest."""
    if not ORIGINS_FILE.exists():
        return
    origins = _load_origins()
    for name in removed_names:
        origins.pop(name, None)
    if origins:
        ORIGINS_FILE.write_text(json.dumps(origins, indent=2, sort_keys=True))
    else:
        ORIGINS_FILE.unlink()


def restore_fonts(selected: list[dict], progress_cb=None) -> list[str]:
    """
    Restore each selected backed-up font. Returns list of error strings.
    """
    errors = []
    restored = []
    total = len(selected)
    for i, desc in enumerate(selected):
        bp = desc["backup_path"]
        loc = desc["location"]

        if progress_cb:
            progress_cb(i, total, bp.name)

        try:
            if loc == "system":
                # Remove shadow copy; system original is untouched
                shadow = USER_FONT_DIR / bp.name
                if shadow.exists():
                    shadow.unlink()
            else:
                # Copy backup back to its original location
                shutil.copy2(str(bp), str(desc["original_path"]))

            # Remove the backup entry
            bp.unlink()
            restored.append(bp.name)

        except Exception as e:
            errors.append(f"{bp.name}: {e}")

    _prune_manifest(restored)
    if progress_cb:
        progress_cb(total, total, "")
    flush_font_cache()
    return errors


# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------

class UnshittifierApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Unshittifier")
        self.resizable(False, False)
        self._build_ui()
        self._load_backups()

    def _build_ui(self):
        pad = {"padx": 12, "pady": 6}

        header = tk.Label(self, text="Unshittifier", font=("", 18, "bold"))
        header.pack(**pad, anchor="w")

        note = tk.Label(
            self,
            text=(
                "Select fonts to restore from ~/Desktop/Fonts (Backup)/.\n"
                "System-font shadow copies will be removed; "
                "user/shared fonts will be replaced with the backed-up originals."
            ),
            justify="left",
            wraplength=520,
            fg="#555",
        )
        note.pack(padx=12, pady=(0, 6), anchor="w")

        toolbar = tk.Frame(self)
        toolbar.pack(padx=12, fill="x")
        tk.Button(toolbar, text="Select All", command=self._select_all).pack(side="left")
        tk.Button(toolbar, text="Select None", command=self._select_none).pack(side="left", padx=(4, 0))

        list_frame = tk.Frame(self, relief="sunken", bd=1)
        list_frame.pack(padx=12, pady=6, fill="both", expand=True)

        canvas = tk.Canvas(list_frame, width=540, height=300)
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

        self._vars: list[tk.BooleanVar] = []
        self._backups: list[dict] = []
        self._rows: list[tk.Frame] = []

        self._progress_var = tk.DoubleVar()
        self._progress = ttk.Progressbar(self, variable=self._progress_var, maximum=100)

        btn_frame = tk.Frame(self)
        btn_frame.pack(padx=12, pady=(0, 12), anchor="e")
        self._restore_btn = tk.Button(
            btn_frame, text="Restore Selected",
            font=("", 13, "bold"),
            command=self._on_restore,
            bg="#e84a1a", fg="white", relief="flat",
            padx=16, pady=8,
        )
        self._restore_btn.pack()

    def _load_backups(self):
        for row in self._rows:
            row.destroy()
        self._vars.clear()
        self._backups.clear()
        self._rows.clear()

        backups = discover_backups()
        self._backups = backups

        if not backups:
            lbl = tk.Label(
                self._inner,
                text="No backed-up fonts found in ~/Desktop/Fonts (Backup)/.",
                fg="#888",
            )
            lbl.pack(padx=8, pady=8)
            return

        for desc in backups:
            var = tk.BooleanVar(value=True)
            self._vars.append(var)

            frame = tk.Frame(self._inner)
            frame.pack(fill="x", padx=4, pady=1)

            cb = tk.Checkbutton(frame, variable=var, anchor="w")
            cb.pack(side="left")

            loc_labels = {
                "user": "~/Library/Fonts",
                "system": "/System/Library/Fonts (removes shadow copy)",
            }
            label_text = f"{desc['backup_path'].name}  [{loc_labels[desc['location']]}]"
            fg = "#c05000" if desc["location"] == "system" else "#333"

            lbl = tk.Label(frame, text=label_text, anchor="w", fg=fg, font=("", 11))
            lbl.pack(side="left")
            lbl.bind("<Button-1>", lambda e, v=var: v.set(not v.get()))

            self._rows.append(frame)

    def _select_all(self):
        for v in self._vars:
            v.set(True)

    def _select_none(self):
        for v in self._vars:
            v.set(False)

    def _on_restore(self):
        selected = [desc for desc, var in zip(self._backups, self._vars) if var.get()]
        if not selected:
            messagebox.showinfo("Nothing selected", "Please select at least one font to restore.")
            return

        if not messagebox.askyesno("Confirm", f"Restore {len(selected)} font(s)?"):
            return

        self._restore_btn.config(state="disabled")
        self._progress.pack(padx=12, pady=(0, 6), fill="x")
        self._progress_var.set(0)
        self.update()

        def progress_cb(i, total, name):
            self._progress_var.set((i / total) * 100)
            self.title(f"Restoring… {name}")
            self.update()

        errors = restore_fonts(selected, progress_cb=progress_cb)

        self._progress.pack_forget()
        self._restore_btn.config(state="normal")
        self.title("Unshittifier")

        if errors:
            err_text = "\n".join(errors)
            messagebox.showerror(
                "Some fonts failed",
                f"The following could not be restored:\n\n{err_text}",
            )
        else:
            messagebox.showinfo(
                "Done",
                "Fonts restored.\n\n"
                "Please log out and back in (or restart apps) to see changes.",
            )
            self._load_backups()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app = UnshittifierApp()
    app.mainloop()
