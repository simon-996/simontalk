from fastapi import Request
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker


class Base(DeclarativeBase):
    pass


def create_database(url: str):
    engine = create_engine(
        url,
        pool_pre_ping=True,
        hide_parameters=True,
        connect_args={"connect_timeout": 3},
    )
    return engine, sessionmaker(engine, expire_on_commit=False)


def database_session(request: Request):
    with request.app.state.session_factory() as db:
        yield db
