"""
py2app setup for Unshittifier.app

Build with:
    cd installer
    pip install py2app
    python setup_unshittifier.py py2app
"""

from setuptools import setup

APP = ["unshittifier.py"]
DATA_FILES = []
OPTIONS = {
    "argv_emulation": False,
    "packages": ["fontTools", "svgpathtools", "cu2qu"],
    "resources": ["../enshittifier.py"],
    "iconfile": None,
    "plist": {
        "CFBundleName": "Unshittifier",
        "CFBundleDisplayName": "Unshittifier",
        "CFBundleIdentifier": "com.enshittifier.unshittifier",
        "CFBundleVersion": "1.0.0",
        "CFBundleShortVersionString": "1.0",
        "NSHumanReadableCopyright": "Copyright © 2024",
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
