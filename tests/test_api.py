"""Behaviour tests for the four Shortify endpoints."""


def shorten(client, url="https://example.com/campaign?utm_source=email"):
    response = client.post("/shorten", json={"url": url})
    assert response.status_code == 200, response.text
    return response.json()


def test_health_returns_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_shorten_returns_a_six_character_code(client):
    body = shorten(client)
    assert len(body["short_code"]) == 6
    assert body["short_code"].isalnum()
    assert body["original_url"] == "https://example.com/campaign?utm_source=email"


def test_shorten_rejects_invalid_url(client):
    response = client.post("/shorten", json={"url": "not-a-url"})
    assert response.status_code == 422


def test_shorten_generates_unique_codes(client):
    codes = {shorten(client)["short_code"] for _ in range(20)}
    assert len(codes) == 20


def test_redirect_returns_302_to_original_url(client):
    body = shorten(client)
    response = client.get(f"/{body['short_code']}", follow_redirects=False)
    assert response.status_code == 302
    assert response.headers["location"] == body["original_url"]


def test_redirect_counts_clicks(client):
    code = shorten(client)["short_code"]
    for _ in range(3):
        client.get(f"/{code}", follow_redirects=False)

    from sqlalchemy import text

    from app.database import engine

    with engine.connect() as conn:
        clicks = conn.execute(text("SELECT clicks FROM links WHERE short_code = :c"), {"c": code}).scalar_one()
    assert clicks == 3


def test_unknown_code_returns_404(client):
    response = client.get("/doesnotexist", follow_redirects=False)
    assert response.status_code == 404


def test_metrics_counts_links(client):
    assert client.get("/metrics").json()["total_links"] == 0
    shorten(client)
    shorten(client)
    assert client.get("/metrics").json()["total_links"] == 2


def test_version_is_dev_without_a_release_file(client):
    # Running from source (no app/VERSION written by a build), the app reports "dev".
    assert client.get("/version").json() == {"version": "dev"}


def test_read_version_uses_the_release_file(tmp_path):
    from app.main import read_version

    version_file = tmp_path / "VERSION"
    version_file.write_text("3d3c42e5aac5ba805825da76410c181273ba90b1\n")
    assert read_version(version_file) == "3d3c42e5aac5ba805825da76410c181273ba90b1"
    assert read_version(tmp_path / "missing") == "dev"


def test_short_url_uses_base_url(client, monkeypatch):
    import app.main

    monkeypatch.setattr(app.main, "BASE_URL", "https://go.brand.com")
    body = shorten(client)
    assert body["short_url"] == f"https://go.brand.com/{body['short_code']}"
