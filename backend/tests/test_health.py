from fastapi.testclient import TestClient

from app.main import app


def test_health() -> None:
    client = TestClient(app, base_url="http://localhost")
    response = client.get("/api/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
