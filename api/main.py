import os
import time
import secrets
import hashlib
import logging
from contextlib import asynccontextmanager
from collections import defaultdict

from fastapi import FastAPI, HTTPException, Depends, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import (
    Counter, Histogram, Gauge, generate_latest,
    CONTENT_TYPE_LATEST, CollectorRegistry, multiprocess
)
import uvicorn

# LOGGING
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

# PROMETHEUS METRICS
REQUEST_COUNT = Counter(
    "api_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status_code"],
)
REQUEST_LATENCY = Histogram(
    "api_request_duration_seconds",
    "HTTP request latency",
    ["method", "endpoint"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
)
ACTIVE_REQUESTS = Gauge("api_active_requests", "Active HTTP requests")
ERROR_COUNT = Counter(
    "api_errors_total",
    "Total API errors",
    ["method", "endpoint", "error_type"],
)
AUTH_FAILURES = Counter("api_auth_failures_total", "Authentication failures")
RATE_LIMIT_HITS = Counter("api_rate_limit_hits_total", "Rate limit hits", ["client_ip"])

# RATE LIMITER
class RateLimiter:
    """Token-bucket rate limiter (per IP, in-memory)."""
 
    def __init__(self, requests_per_minute: int = 60, burst: int = 20):
        self.rpm = requests_per_minute
        self.burst = burst
        self._buckets: dict[str, dict] = defaultdict(
            lambda: {"tokens": burst, "last": time.monotonic()}
        )
 
    def is_allowed(self, ip: str) -> bool:
        bucket = self._buckets[ip]
        now = time.monotonic()
        elapsed = now - bucket["last"]
        bucket["tokens"] = min(
            self.burst,
            bucket["tokens"] + elapsed * (self.rpm / 60),
        )
        bucket["last"] = now
        if bucket["tokens"] >= 1:
            bucket["tokens"] -= 1
            return True
        return False
 
 
rate_limiter = RateLimiter(requests_per_minute=60, burst=20)

# API-KEY AUTH

security = HTTPBearer()
 
def _load_api_key() -> str:
    key = os.getenv("API_KEY", "")
    if not key:
        raise RuntimeError("API_KEY env var not set")
    return key
 
def verify_api_key(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    expected = _load_api_key()
    provided = credentials.credentials
    # Constant-time comparison
    if not secrets.compare_digest(
        hashlib.sha256(provided.encode()).digest(),
        hashlib.sha256(expected.encode()).digest(),
    ):
        AUTH_FAILURES.inc()
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid API key",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return provided

# API
@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("API starting up...")
    yield
    logger.info("API shutting down...")

app = FastAPI(
    title="Monitoring API",
    description="Secure FastAPI",
    version="1.0.0",
    lifespan=lifespan,
    # docs_url="/docs",
    # redoc_url="/redoc",
)
 
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# MIDDLEWARE
@app.middleware("http")
async def metrics_and_ratelimit_middleware(request: Request, call_next):
    client_ip = request.client.host if request.client else "unknown"
    path = request.url.path
 
    if path not in ("/metrics", "/health"):
        if not rate_limiter.is_allowed(client_ip):
            RATE_LIMIT_HITS.labels(client_ip=client_ip).inc()
            return JSONResponse(
                status_code=429,
                content={"detail": "Too Many Requests."},
                headers={"Retry-After": "10"},
            )
 
    ACTIVE_REQUESTS.inc()
    start = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception as exc:
        ERROR_COUNT.labels(method=request.method, endpoint=path, error_type=type(exc).__name__).inc()
        raise
    finally:
        duration = time.perf_counter() - start
        ACTIVE_REQUESTS.dec()
        status_code = getattr(response, "status_code", 500)
        REQUEST_COUNT.labels(method=request.method, endpoint=path, status_code=status_code).inc()
        REQUEST_LATENCY.labels(method=request.method, endpoint=path).observe(duration)
 
    return response

# HEADERS
@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-XSS-Protection"] = "1; mode=block"
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
    return response

# ROUTES
@app.get("/health", tags=["System"])
async def health():
    """Public health check endpoint."""
    return {"status": "ok", "timestamp": time.time()}
 
@app.get("/metrics", response_class=PlainTextResponse, tags=["System"])
async def metrics():
    """Prometheus scrape endpoint (internal use)."""
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)
 
@app.get("/api/v1/status", tags=["API"], dependencies=[Depends(verify_api_key)])
async def api_status():
    """Secured status endpoint."""
    return {
        "status": "operational",
        "timestamp": time.time(),
        "version": "1.0.0",
    }
 
@app.get("/api/v1/stats", tags=["API"], dependencies=[Depends(verify_api_key)])
async def api_stats(request: Request):
    """Return basic runtime stats."""
    return {
        "active_requests": ACTIVE_REQUESTS._value.get(),
        "client_ip": request.client.host if request.client else "unknown",
        "timestamp": time.time(),
    }
 
@app.post("/api/v1/echo", tags=["API"], dependencies=[Depends(verify_api_key)])
async def echo(request: Request):
    """Echo request body back (demo endpoint)."""
    try:
        body = await request.json()
    except Exception:
        body = {}
    return {"echo": body, "timestamp": time.time()}
 
if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)