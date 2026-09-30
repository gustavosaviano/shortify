"""database_url(): where the app connects, tested without AWS or Floci."""
import json

import pytest
from sqlalchemy.engine import make_url

from app.database import database_url

ARN = "arn:aws:secretsmanager:us-east-1:000000000000:secret:rds!db-test"
PASSWORD = "p#ss%w?rd:x"  # URL-special characters an RDS-generated password can contain


class FakeSecretsManager:
    def __init__(self):
        self.requested = []

    def get_secret_value(self, **kwargs):
        self.requested.append(kwargs["SecretId"])
        return {"SecretString": json.dumps({"username": "shortify", "password": PASSWORD})}


@pytest.fixture
def fake_boto3(monkeypatch):
    fake, clients = FakeSecretsManager(), []

    def client(service, region_name=None):
        clients.append((service, region_name))
        return fake

    monkeypatch.setattr("boto3.client", client)
    return fake, clients


@pytest.fixture
def secret_env(monkeypatch):
    monkeypatch.setenv("DATABASE_SECRET_ARN", ARN)
    monkeypatch.setenv("DATABASE_HOST", "db.internal")
    monkeypatch.setenv("DATABASE_PORT", "5432")
    monkeypatch.setenv("DATABASE_NAME", "shortify")


def test_without_secret_uses_database_url(monkeypatch):
    monkeypatch.delenv("DATABASE_SECRET_ARN", raising=False)
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@example:5432/d")
    assert database_url() == "postgresql://u:p@example:5432/d"


def test_with_secret_reads_it_and_builds_the_url(secret_env, fake_boto3):
    fake, clients = fake_boto3
    url = database_url()
    assert clients == [("secretsmanager", "us-east-1")]  # region taken from the ARN
    assert fake.requested == [ARN]
    parsed = make_url(url.render_as_string(hide_password=False))  # survives the round trip
    assert (parsed.username, parsed.password, parsed.host, parsed.port, parsed.database) == (
        "shortify", PASSWORD, "db.internal", 5432, "shortify"
    )


def test_with_secret_missing_host_fails_before_calling_aws(secret_env, fake_boto3, monkeypatch):
    fake, clients = fake_boto3
    monkeypatch.delenv("DATABASE_HOST")
    with pytest.raises(RuntimeError, match="DATABASE_HOST must be set"):
        database_url()
    assert clients == []  # nothing was sent to AWS
