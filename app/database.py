import json
import os

from sqlalchemy import create_engine
from sqlalchemy.engine import URL
from sqlalchemy.orm import declarative_base, sessionmaker

LOCAL_DATABASE_URL = "postgresql://shortify:shortify@db:5432/shortify"


def _required(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"{name} must be set when DATABASE_SECRET_ARN is set")
    return value


def database_url() -> str | URL:
    """Where the app connects.

    With DATABASE_SECRET_ARN (the deployed app), the credentials are read at start from the
    RDS-managed secret through the standard AWS credential chain: the instance's IAM role on
    AWS, the same chain plus AWS_ENDPOINT_URL on Floci. Nothing is stored on the host, and a
    restart picks up a rotated password. Without it (local compose, CI), DATABASE_URL is used.
    """
    secret_arn = os.getenv("DATABASE_SECRET_ARN")
    if not secret_arn:
        return os.getenv("DATABASE_URL", LOCAL_DATABASE_URL)

    # The secret holds only username and password; the endpoint comes from the deploy.
    # Checked before calling AWS so a missing setting fails fast and says which one.
    host, port, name = (_required(v) for v in ("DATABASE_HOST", "DATABASE_PORT", "DATABASE_NAME"))

    import boto3  # only the deployed app needs it

    region = secret_arn.split(":")[3]  # arn:aws:secretsmanager:<region>:<account>:secret:<name>
    client = boto3.client("secretsmanager", region_name=region)
    secret = json.loads(client.get_secret_value(SecretId=secret_arn)["SecretString"])
    # URL.create escapes the password: RDS-generated ones can contain #, %, ? or :.
    return URL.create(
        "postgresql",
        username=secret["username"],
        password=secret["password"],
        host=host,
        port=int(port),
        database=name,
    )


engine = create_engine(database_url())
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
