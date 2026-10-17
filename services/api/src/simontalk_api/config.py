from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SIMONTALK_", env_file=".env", extra="ignore")

    database_url: str = "postgresql+psycopg://simontalk:simontalk@127.0.0.1:54329/simontalk"
    environment: str = "development"
    cookie_secure: bool = False
    allowed_origins: list[str] = ["http://localhost:7357", "http://127.0.0.1:7357"]
    rate_limit_enabled: bool = True
    rate_limit_max_buckets: int = Field(default=10000, ge=1, le=100000)
    login_ip_limit: int = Field(default=30, ge=1)
    login_account_limit: int = Field(default=10, ge=1)
    register_ip_limit: int = Field(default=10, ge=1)
    reset_ip_limit: int = Field(default=10, ge=1)
    rate_limit_window_seconds: int = Field(default=600, ge=1)
    practice_maintenance_interval_seconds: float = Field(
        default=15, ge=1, le=300, allow_inf_nan=False
    )

    @model_validator(mode="after")
    def validate_security(self):
        if not self.database_url.startswith("postgresql+psycopg://"):
            raise ValueError("PostgreSQL with psycopg is required")
        if self.environment not in {"development", "test", "production"}:
            raise ValueError("Invalid environment")
        if self.environment == "production":
            self.cookie_secure = True
        for origin in self.allowed_origins:
            from urllib.parse import urlsplit

            parts = urlsplit(origin)
            if (
                parts.scheme not in {"http", "https"}
                or not parts.netloc
                or parts.path
                or parts.query
                or parts.fragment
                or parts.username
                or "*" in origin
            ):
                raise ValueError("Allowed origins must be exact origins")
            if self.environment == "production" and parts.scheme != "https":
                raise ValueError("Production origins require HTTPS")
            if self.environment == "development" and parts.hostname not in {
                "localhost",
                "127.0.0.1",
            }:
                raise ValueError("Development origins require an explicit loopback host")
        return self
