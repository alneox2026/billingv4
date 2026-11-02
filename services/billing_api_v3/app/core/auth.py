"""Firebase authentication for FlutterFlow-facing Billing API routes."""

from __future__ import annotations

import asyncio
import hashlib
import threading
import time
from typing import Any, Callable

from fastapi import Request

from services.billing_api_v3.app.core.errors import BillingApiError


_firebase_ready = False
_firebase_lock = threading.Lock()
_token_cache: dict[str, tuple[str, float]] = {}
_token_cache_lock = threading.Lock()
MAX_TOKEN_CACHE_SIZE = 5000


def _extract_bearer_token(authorization_header: str | None) -> str:
    if not authorization_header:
        raise BillingApiError(
            401,
            "missing_bearer_token",
            "A Firebase ID token is required in the Authorization header.",
        )
    scheme, _, token = authorization_header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise BillingApiError(
            401,
            "invalid_authorization_header",
            "Authorization must be a Bearer token.",
        )
    return token.strip()


def _ensure_firebase_initialized() -> None:
    import firebase_admin

    global _firebase_ready
    if _firebase_ready:
        return
    with _firebase_lock:
        if not _firebase_ready:
            firebase_admin.initialize_app()
            _firebase_ready = True


async def authenticate_request(request: Request) -> str:
    """Return the verified Firebase UID; never accept a UID from the request body."""

    token = _extract_bearer_token(request.headers.get("Authorization"))
    token_hash = hashlib.sha256(token.encode("utf-8")).hexdigest()
    now = time.time()

    with _token_cache_lock:
        cached = _token_cache.get(token_hash)
        if cached is not None and cached[1] > now:
            return cached[0]

    try:
        from firebase_admin import auth as firebase_auth

        if not _firebase_ready:
            await asyncio.to_thread(_ensure_firebase_initialized)
        decoded_token = await asyncio.to_thread(firebase_auth.verify_id_token, token)
    except BillingApiError:
        raise
    except ModuleNotFoundError as exc:
        raise BillingApiError(
            500,
            "firebase_admin_missing",
            "firebase-admin is not installed in the Billing API runtime.",
        ) from exc
    except Exception as exc:
        raise BillingApiError(
            401,
            "invalid_firebase_token",
            "The Firebase ID token could not be verified.",
        ) from exc

    user_id = str(decoded_token.get("uid", "")).strip()
    if not user_id:
        raise BillingApiError(
            401,
            "invalid_firebase_token",
            "The Firebase ID token did not include a valid user id.",
        )

    exp = decoded_token.get("exp")
    ttl = min(60.0, max(0.0, float(exp) - now - 30.0)) if exp else 60.0
    if ttl > 0:
        with _token_cache_lock:
            if len(_token_cache) >= MAX_TOKEN_CACHE_SIZE:
                _token_cache.clear()
            _token_cache[token_hash] = (user_id, now + ttl)

    return user_id


_reconciliation_token_verifier: Callable[[str, str], dict[str, Any]] | None = None
RECONCILIATION_OIDC_CERT_FETCH_TIMEOUT_SECONDS = 5


def _limit_reconciliation_auth_request_timeout(
    auth_request: Callable[..., Any],
) -> Callable[..., Any]:
    """Keep Google OIDC certificate fetches shorter than the Cloud Run request limit."""

    def bounded_request(url: str, *args: Any, **kwargs: Any) -> Any:
        # google-auth's Requests transport defaults to 120 seconds, which exceeds
        # this service's 60-second Cloud Run timeout and can strand cold Scheduler
        # invocations until Cloud Run terminates them.
        kwargs["timeout"] = RECONCILIATION_OIDC_CERT_FETCH_TIMEOUT_SECONDS
        return auth_request(url, *args, **kwargs)

    return bounded_request


def set_reconciliation_token_verifier(
    verifier: Callable[[str, str], dict[str, Any]] | None,
) -> None:
    """Override OIDC token verifier for testing."""
    global _reconciliation_token_verifier
    _reconciliation_token_verifier = verifier


async def authenticate_reconciliation_request(request: Request) -> dict[str, Any]:
    """Verify Cloud Scheduler Google OIDC token protecting internal reconciliation."""
    from services.billing_api_v3.app.core.config import get_settings

    settings = get_settings()
    if not settings.reconciliation_auth_required:
        return {"sub": "anonymous", "email": "anonymous"}

    expected_audience = (settings.reconciliation_audience or "").strip()
    expected_service_account = (settings.reconciliation_allowed_service_account or "").strip()

    if not expected_audience or not expected_service_account:
        raise BillingApiError(
            500,
            "reconciliation_auth_misconfigured",
            "Reconciliation OIDC audience and allowed service account must be configured when reconciliation auth is enabled.",
        )

    auth_header = request.headers.get("Authorization")
    if not auth_header:
        raise BillingApiError(
            401,
            "missing_reconciliation_token",
            "A Google OIDC token is required in the Authorization header.",
        )

    scheme, _, token = auth_header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise BillingApiError(
            401,
            "invalid_authorization_header",
            "Authorization must be a Bearer token.",
        )

    try:
        if _reconciliation_token_verifier is not None:
            claims = _reconciliation_token_verifier(token.strip(), expected_audience)
        else:
            from google.auth.transport.requests import Request as GoogleAuthRequest
            from google.oauth2 import id_token

            bounded_auth_request = _limit_reconciliation_auth_request_timeout(
                GoogleAuthRequest()
            )
            claims = await asyncio.to_thread(
                id_token.verify_oauth2_token,
                token.strip(),
                bounded_auth_request,
                audience=expected_audience,
            )
    except BillingApiError:
        raise
    except Exception as exc:
        from google.auth.exceptions import TransportError

        if isinstance(exc, TransportError):
            raise BillingApiError(
                503,
                "reconciliation_token_verification_unavailable",
                "Google OIDC token verification is temporarily unavailable.",
            ) from exc
        raise BillingApiError(
            401,
            "invalid_reconciliation_token",
            f"The Google OIDC token could not be verified: {exc}",
        ) from exc

    token_audience = str(claims.get("aud", "")).strip()
    if token_audience != expected_audience:
        raise BillingApiError(
            401,
            "invalid_reconciliation_audience",
            f"Scheduler OIDC token audience mismatch (expected {expected_audience}).",
        )

    token_email = str(claims.get("email", "")).strip()
    if token_email != expected_service_account:
        raise BillingApiError(
            403,
            "forbidden_service_account",
            f"Scheduler OIDC token service account mismatch (expected {expected_service_account}).",
        )

    return claims
