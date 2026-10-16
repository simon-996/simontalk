from sqlalchemy import create_engine, pool

from alembic import context
from simontalk_api import models  # noqa: F401
from simontalk_api.config import Settings
from simontalk_api.db import Base

config = context.config
target_metadata = Base.metadata
url = config.attributes.get("database_url") or Settings().database_url

if context.is_offline_mode():
    context.configure(url=url, target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = create_engine(url, poolclass=pool.NullPool, hide_parameters=True)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()
