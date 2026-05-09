import os
import pytest
import jwt
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch
from fastapi import HTTPException

os.environ.setdefault("JWT_SECRET", "test-secret-key-minimum-32-bytes!!")

from fastapi.testclient import TestClient
from main import app, JWT_SECRET, JWT_ALGORITHM, JWT_AUDIENCE, JWT_ISSUER, create_access_token

client = TestClient(app)

MOCK_GEOCODE_RESPONSE = {
    "results": [{"name": "Singapore", "latitude": 1.2897, "longitude": 103.8501}]
}

MOCK_FORECAST_RESPONSE = {
    "current_weather": {
        "temperature": 30.2,
        "windspeed": 15.0,
        "weathercode": 1,
        "is_day": 1,
        "time": "2024-01-01T12:00",
    },
    "daily": {
        "time": ["2024-01-01", "2024-01-02"],
        "temperature_2m_max": [32.0, 31.5],
        "temperature_2m_min": [26.0, 25.8],
        "precipitation_sum": [0.0, 2.3],
        "weathercode": [1, 61],
    },
}


def _valid_token(client_id: str = "max-weather-client") -> str:
    return create_access_token(client_id)


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

def test_health():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


# ---------------------------------------------------------------------------
# Token endpoint
# ---------------------------------------------------------------------------

def test_token_success():
    resp = client.post(
        "/token",
        data={"username": "max-weather-client", "password": "super-secret-key"},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert "access_token" in body
    assert body["token_type"] == "bearer"
    decoded = jwt.decode(body["access_token"], JWT_SECRET, algorithms=[JWT_ALGORITHM], audience=JWT_AUDIENCE, issuer=JWT_ISSUER)
    assert decoded["sub"] == "max-weather-client"


def test_token_wrong_password():
    resp = client.post(
        "/token",
        data={"username": "max-weather-client", "password": "wrong"},
    )
    assert resp.status_code == 401


def test_token_unknown_client():
    resp = client.post(
        "/token",
        data={"username": "unknown", "password": "anything"},
    )
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Auth enforcement
# ---------------------------------------------------------------------------

def test_weather_current_no_token():
    resp = client.get("/weather/current?city=Singapore")
    assert resp.status_code == 401


def test_weather_forecast_no_token():
    resp = client.get("/weather/forecast?city=London")
    assert resp.status_code == 401


def test_weather_current_expired_token():
    payload = {
        "sub": "max-weather-client",
        "iss": JWT_ISSUER,
        "aud": JWT_AUDIENCE,
        "iat": datetime.now(timezone.utc) - timedelta(hours=2),
        "exp": datetime.now(timezone.utc) - timedelta(hours=1),
    }
    expired_token = jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)
    resp = client.get("/weather/current?city=Singapore", headers={"Authorization": f"Bearer {expired_token}"})
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Weather endpoints (mocked HTTP calls)
# ---------------------------------------------------------------------------

@patch("main.geocode", new_callable=AsyncMock)
@patch("main.fetch_forecast", new_callable=AsyncMock)
def test_weather_current(mock_forecast, mock_geocode):
    mock_geocode.return_value = (1.2897, 103.8501, "Singapore")
    mock_forecast.return_value = MOCK_FORECAST_RESPONSE
    token = _valid_token()
    resp = client.get("/weather/current?city=Singapore", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["city"] == "Singapore"
    assert body["temperature_celsius"] == 30.2
    assert body["windspeed_kmh"] == 15.0


@patch("main.geocode", new_callable=AsyncMock)
@patch("main.fetch_forecast", new_callable=AsyncMock)
def test_weather_forecast(mock_forecast, mock_geocode):
    mock_geocode.return_value = (51.5074, -0.1278, "London")
    mock_forecast.return_value = MOCK_FORECAST_RESPONSE
    token = _valid_token()
    resp = client.get("/weather/forecast?city=London&days=2", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["city"] == "London"
    assert len(body["forecast"]) == 2
    assert body["forecast"][0]["temp_max_celsius"] == 32.0


@patch("main.fetch_forecast", new_callable=AsyncMock)
def test_weather_coordinates(mock_forecast):
    mock_forecast.return_value = MOCK_FORECAST_RESPONSE
    token = _valid_token()
    resp = client.get("/weather/coordinates?lat=1.3521&lon=103.8198", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200
    body = resp.json()
    assert body["latitude"] == 1.3521
    assert "current" in body


def test_weather_forecast_invalid_days():
    token = _valid_token()
    resp = client.get("/weather/forecast?city=London&days=20", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 400


@patch("main.geocode", new_callable=AsyncMock)
def test_weather_city_not_found(mock_geocode):
    mock_geocode.side_effect = HTTPException(status_code=404, detail="City 'FakeCity12345' not found")
    token = _valid_token()
    resp = client.get("/weather/current?city=FakeCity12345", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 404
