"""Shared test setup.

The tests run against a real PostgreSQL (dev/prod parity): locally the Phase 1
docker-compose database, in CI a `postgres:16` service container.
DATABASE_URL must be set before the app is imported, because the app connects
and creates its tables at import time.
"""
import os

os.environ.setdefault("DATABASE_URL", "postgresql://shortify:shortify@localhost:5432/shortify")

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.database import engine  # noqa: E402
from app.main import app  # noqa: E402


@pytest.fixture
def client():
    return TestClient(app)


@pytest.fixture(autouse=True)
def empty_links_table():
    """Every test starts with an empty table, so tests can't affect each other."""
    with engine.begin() as conn:
        conn.execute(text("TRUNCATE TABLE links"))
    yield
