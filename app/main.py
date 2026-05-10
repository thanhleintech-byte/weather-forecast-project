import os
import time
import logging
from datetime import datetime, timedelta, timezone

import httpx
import jwt
from fastapi import Depends, FastAPI, HTTPException, status
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pythonjsonlogger import jsonlogger

# ---------------------------------------------------------------------------
# Logging — JSON to stdout so Fluent Bit can forward to CloudWatch
# ---------------------------------------------------------------------------

logger = logging.getLogger("max-weather")
handler = logging.StreamHandler()
handler.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
logger.addHandler(handler)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

JWT_SECRET = os.environ.get("JWT_SECRET", "change-me-in-production")
JWT_ALGORITHM = "HS256"
JWT_EXPIRY_MINUTES = 60
JWT_ISSUER = "max-weather"
JWT_AUDIENCE = "max-weather-api"

# OAuth2 client_credentials — values come from the max-weather-secrets
# Kubernetes Secret (created by the argocd terraform stage). Defaults are
# only for local dev / unit tests.
VALID_CLIENTS = {
    os.environ.get("OAUTH_CLIENT_ID", "max-weather-client"):
        os.environ.get("OAUTH_CLIENT_SECRET", "super-secret-key"),
}

GEOCODING_URL = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Max Weather API",
    description="Weather forecasting platform powered by Open-Meteo",
    version="1.0.0",
)

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/token")


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

def create_access_token(client_id: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": client_id,
        "iss": JWT_ISSUER,
        "aud": JWT_AUDIENCE,
        "iat": now,
        "exp": now + timedelta(minutes=JWT_EXPIRY_MINUTES),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALGORITHM)


def verify_token(token: str = Depends(oauth2_scheme)) -> dict:
    try:
        payload = jwt.decode(
            token,
            JWT_SECRET,
            algorithms=[JWT_ALGORITHM],
            audience=JWT_AUDIENCE,
            issuer=JWT_ISSUER,
        )
        return payload
    except jwt.ExpiredSignatureError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Token has expired")
    except jwt.InvalidTokenError as exc:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail=f"Invalid token: {exc}")


# ---------------------------------------------------------------------------
# Open-Meteo helpers
# ---------------------------------------------------------------------------

async def geocode(city: str) -> tuple[float, float, str]:
    """Return (latitude, longitude, resolved_name) for a city name."""
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(GEOCODING_URL, params={"name": city, "count": 1, "language": "en", "format": "json"})
    resp.raise_for_status()
    results = resp.json().get("results")
    if not results:
        raise HTTPException(status_code=404, detail=f"City '{city}' not found")
    r = results[0]
    return r["latitude"], r["longitude"], r.get("name", city)


async def fetch_forecast(lat: float, lon: float, days: int = 1) -> dict:
    params = {
        "latitude": lat,
        "longitude": lon,
        "current_weather": "true",
        "hourly": "temperature_2m,precipitation,weathercode,windspeed_10m",
        "daily": "temperature_2m_max,temperature_2m_min,precipitation_sum,weathercode",
        "forecast_days": days,
        "timezone": "auto",
    }
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(FORECAST_URL, params=params)
    resp.raise_for_status()
    return resp.json()


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.post("/token", summary="Issue OAuth2 access token (client_credentials)")
async def token(form: OAuth2PasswordRequestForm = Depends()):
    """
    OAuth2 client_credentials grant.
    Use client_id as username and client_secret as password.
    """
    secret = VALID_CLIENTS.get(form.username)
    if not secret or secret != form.password:
        logger.warning("token_rejected", extra={"client_id": form.username})
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid client credentials")
    access_token = create_access_token(form.username)
    logger.info("token_issued", extra={"client_id": form.username})
    return {"access_token": access_token, "token_type": "bearer", "expires_in": JWT_EXPIRY_MINUTES * 60}


@app.get("/health", summary="Health / readiness check")
async def health():
    return {"status": "ok", "timestamp": datetime.now(timezone.utc).isoformat()}


@app.get("/weather/current", summary="Current weather by city name")
async def weather_current(city: str, _: dict = Depends(verify_token)):
    lat, lon, resolved = await geocode(city)
    data = await fetch_forecast(lat, lon, days=1)
    cw = data.get("current_weather", {})
    logger.info("weather_current", extra={"city": resolved, "lat": lat, "lon": lon})
    return {
        "city": resolved,
        "latitude": lat,
        "longitude": lon,
        "temperature_celsius": cw.get("temperature"),
        "windspeed_kmh": cw.get("windspeed"),
        "weathercode": cw.get("weathercode"),
        "is_day": bool(cw.get("is_day")),
        "time": cw.get("time"),
    }


@app.get("/weather/forecast", summary="Multi-day forecast by city name")
async def weather_forecast(city: str, days: int = 7, _: dict = Depends(verify_token)):
    if not 1 <= days <= 16:
        raise HTTPException(status_code=400, detail="days must be between 1 and 16")
    lat, lon, resolved = await geocode(city)
    data = await fetch_forecast(lat, lon, days=days)
    daily = data.get("daily", {})
    dates = daily.get("time", [])
    logger.info("weather_forecast", extra={"city": resolved, "days": days})
    forecast = [
        {
            "date": dates[i],
            "temp_max_celsius": daily.get("temperature_2m_max", [])[i] if i < len(daily.get("temperature_2m_max", [])) else None,
            "temp_min_celsius": daily.get("temperature_2m_min", [])[i] if i < len(daily.get("temperature_2m_min", [])) else None,
            "precipitation_mm": daily.get("precipitation_sum", [])[i] if i < len(daily.get("precipitation_sum", [])) else None,
            "weathercode": daily.get("weathercode", [])[i] if i < len(daily.get("weathercode", [])) else None,
        }
        for i in range(len(dates))
    ]
    return {"city": resolved, "latitude": lat, "longitude": lon, "forecast": forecast}


@app.get("/weather/coordinates", summary="Current weather by latitude/longitude")
async def weather_coordinates(lat: float, lon: float, days: int = 1, _: dict = Depends(verify_token)):
    if not 1 <= days <= 16:
        raise HTTPException(status_code=400, detail="days must be between 1 and 16")
    data = await fetch_forecast(lat, lon, days=days)
    cw = data.get("current_weather", {})
    daily = data.get("daily", {})
    dates = daily.get("time", [])
    logger.info("weather_coordinates", extra={"lat": lat, "lon": lon})
    forecast = [
        {
            "date": dates[i],
            "temp_max_celsius": daily.get("temperature_2m_max", [])[i] if i < len(daily.get("temperature_2m_max", [])) else None,
            "temp_min_celsius": daily.get("temperature_2m_min", [])[i] if i < len(daily.get("temperature_2m_min", [])) else None,
            "precipitation_mm": daily.get("precipitation_sum", [])[i] if i < len(daily.get("precipitation_sum", [])) else None,
        }
        for i in range(len(dates))
    ]
    return {
        "latitude": lat,
        "longitude": lon,
        "current": {
            "temperature_celsius": cw.get("temperature"),
            "windspeed_kmh": cw.get("windspeed"),
            "weathercode": cw.get("weathercode"),
            "is_day": bool(cw.get("is_day")),
            "time": cw.get("time"),
        },
        "forecast": forecast,
    }
