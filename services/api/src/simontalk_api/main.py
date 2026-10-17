import logging
import uuid

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from starlette.exceptions import HTTPException

from simontalk_api.config import Settings
from simontalk_api.connection_routes import router as connection_router
from simontalk_api.db import create_database
from simontalk_api.errors import APIError
from simontalk_api.practice import UnavailableAdmission
from simontalk_api.practice_routes import router as practice_router
from simontalk_api.routes import router

logger = logging.getLogger(__name__)


def error_response(request, status, code, message):
    response = JSONResponse(
        status_code=status,
        content={
            "code": code,
            "message": message,
            "request_id": request.state.request_id,
        },
    )
    if status == 429:
        response.headers["Retry-After"] = str(request.app.state.settings.rate_limit_window_seconds)
    origin = request.headers.get("origin")
    if origin and origin in request.app.state.settings.allowed_origins:
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Allow-Credentials"] = "true"
        response.headers["Access-Control-Expose-Headers"] = "X-Request-ID"
        response.headers["Vary"] = "Origin"
    return response


def create_app(settings: Settings | None = None):
    app = FastAPI(title="SimonTalk API", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings or Settings()
    app.state.practice_admission = UnavailableAdmission()
    app.state.engine, app.state.session_factory = create_database(app.state.settings.database_url)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=app.state.settings.allowed_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PATCH", "OPTIONS"],
        allow_headers=[
            "Content-Type",
            "Authorization",
            "X-CSRF-Token",
            "X-Account-ID",
            "Idempotency-Key",
        ],
        expose_headers=["X-Request-ID"],
    )

    @app.middleware("http")
    async def request_context(request: Request, call_next):
        # Generate locally; never reflect an attacker-supplied ID or credential into errors/logs.
        request.state.request_id = str(uuid.uuid4())
        origin = request.headers.get("origin")
        if origin and origin not in app.state.settings.allowed_origins:
            response = error_response(request, 403, "origin_forbidden", "此来源不受允许。")
        else:
            try:
                response = await call_next(request)
                if (
                    request.method == "OPTIONS"
                    and request.headers.get("access-control-request-method")
                    and response.status_code == 400
                ):
                    response = error_response(request, 400, "request_error", "请求无法处理。")
            except Exception:
                # Exception messages/tracebacks may contain credentials from driver or input errors.
                logger.error("Unhandled request failure request_id=%s", request.state.request_id)
                response = error_response(
                    request,
                    503,
                    "service_unavailable",
                    "服务暂时不可用，请稍后重试。",
                )
        response.headers["X-Request-ID"] = request.state.request_id
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.exception_handler(APIError)
    async def handle_api_error(request: Request, error: APIError):
        return error_response(request, error.status, error.code, error.message)

    @app.exception_handler(RequestValidationError)
    async def handle_validation(request: Request, error: RequestValidationError):
        return error_response(request, 422, "validation_error", "输入格式不正确，请检查后重试。")

    @app.exception_handler(SQLAlchemyError)
    async def handle_database(request: Request, error: SQLAlchemyError):
        return error_response(request, 503, "service_unavailable", "服务暂时不可用，请稍后重试。")

    @app.exception_handler(HTTPException)
    async def handle_http(request: Request, error: HTTPException):
        return error_response(request, error.status_code, "request_error", "请求无法处理。")

    @app.get("/health/live")
    def live():
        return {"status": "ok"}

    @app.get("/health/ready")
    def ready():
        with app.state.engine.connect() as connection:
            connection.execute(text("SELECT 1"))
        return {"status": "ok"}

    app.include_router(router)
    app.include_router(practice_router)
    app.include_router(connection_router)
    return app
