"""
py2app setup for Enshittifier Installer.app

Build with:
    cd installer
    pip install py2app
    python setup_installer.py py2app
"""

from setuptools import setup

APP = ["enshittifier_installer.py"]
DATA_FILES = []
OPTIONS = {
    "argv_emulation": False,
    "packages": ["fontTools", "svgpathtools", "cu2qu"],
    "resources": ["../enshittifier.py"],
    "iconfile": None,
    "plist": {
        "CFBundleName": "Enshittifier Installer",
        "CFBundleDisplayName": "Enshittifier Installer",
        "CFBundleIdentifier": "com.enshittifier.installer",
        "CFBundleVersion": "1.0.0",
        "CFBundleShortVersionString": "1.0",
        "NSHumanReadableCopyright": "Copyright © 2024",
        "LSMinimumSystemVersion": "10.15",
        "NSHighResolutionCapable": True,
    },
}

setup(
    name="Enshittifier Installer",
    app=APP,
    data_files=DATA_FILES,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
