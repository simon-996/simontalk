import re
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, SecretStr, StrictBool, field_validator


class InputModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LoginInput(InputModel):
    username: str = Field(min_length=3, max_length=32)
    password: SecretStr = Field(min_length=12, max_length=128)
    platform: Literal["web", "mobile"]

    @field_validator("username", mode="before")
    @classmethod
    def normalize_username(cls, value):
        if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{2,31}", value):
            raise ValueError("Invalid username")
        return value.lower()


class RegisterInput(LoginInput):
    invite_code: SecretStr = Field(min_length=20, max_length=256)
    display_name: str = Field(min_length=1, max_length=60)

    @field_validator("display_name")
    @classmethod
    def display_name_not_blank(cls, value):
        if not value.strip():
            raise ValueError("Display name is required")
        return value.strip()


class ResetInput(InputModel):
    reset_token: SecretStr = Field(min_length=20, max_length=256)
    new_password: SecretStr = Field(min_length=12, max_length=128)


class PreferencesPatch(InputModel):
    version: int = Field(ge=1, strict=True)
    difficulty: Literal["beginner", "intermediate", "advanced"] | None = None
    speech_pace: Literal["normal", "slow"] | None = None
    subtitle_default: StrictBool | None = None
    chinese_hints_enabled: StrictBool | None = None
    translation_mode: Literal["on_demand"] | None = None

    @field_validator(
        "speech_pace",
        "subtitle_default",
        "chinese_hints_enabled",
        "translation_mode",
        mode="before",
    )
    @classmethod
    def non_nullable_preferences(cls, value):
        if value is None:
            raise ValueError("Preference cannot be null")
        return value


class UserOutput(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: UUID
    username: str
    display_name: str


class PreferencesOutput(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    difficulty: Literal["beginner", "intermediate", "advanced"] | None
    speech_pace: Literal["normal", "slow"]
    subtitle_default: bool
    chinese_hints_enabled: bool
    translation_mode: Literal["on_demand"]
    version: int
