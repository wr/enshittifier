"""
py2app setup for Unshittifier.app

Build with:
    cd installer
    pip3 install py2app
    python3 setup_unshittifier.py py2app
"""

from setuptools import setup

APP = ["unshittifier.py"]
DATA_FILES = []
OPTIONS = {
    "argv_emulation": False,
    "packages": [],
    "resources": [],
    "iconfile": None,
    "plist": {
        "CFBundleName": "Unshittifier",
        "CFBundleDisplayName": "Unshittifier",
        "CFBundleIdentifier": "com.enshittifier.unshittifier",
        "CFBundleVersion": "1.0.0",
        "CFBundleShortVersionString": "1.0",
        "NSHumanReadableCopyright": "Copyright © 2026",
        "LSMinimumSystemVersion": "10.15",
        "NSHighResolutionCapable": True,
    },
}

setup(
    name="Unshittifier",
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
