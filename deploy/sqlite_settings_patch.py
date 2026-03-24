"""
SQLite settings patch for Gobii Platform on RunPod.

This module is imported by Django's settings.py (via a sitecustomize hook or
direct patch) to override the database backend from PostgreSQL to SQLite3.

Usage: The entrypoint checks for GOBII_DB_ENGINE=sqlite3 and applies this patch
by modifying Django settings after they load.
"""
import os


def patch_databases(settings_module):
    """Override DATABASES to use SQLite3 on the network volume."""
    sqlite_path = os.environ.get(
        "GOBII_SQLITE_PATH", "/runpod-volume/data/gobii.db"
    )

    settings_module.DATABASES = {
        "default": {
            "ENGINE": "django.db.backends.sqlite3",
            "NAME": sqlite_path,
            "OPTIONS": {
                "timeout": 30,  # Wait up to 30s for locks (concurrent workers)
                "init_command": (
                    "PRAGMA journal_mode=WAL;"
                    "PRAGMA synchronous=NORMAL;"
                    "PRAGMA busy_timeout=30000;"
                    "PRAGMA cache_size=-64000;"  # 64MB cache
                    "PRAGMA foreign_keys=ON;"
                    "PRAGMA temp_store=MEMORY;"
                ),
            },
        }
    }

    # Disable PostgreSQL-specific settings
    settings_module.DATABASES["default"].pop("DISABLE_SERVER_SIDE_CURSORS", None)
    settings_module.DATABASES["default"].pop("CONN_HEALTH_CHECKS", None)

    return settings_module
