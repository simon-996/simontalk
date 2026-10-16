import argparse
import sys

from sqlalchemy.exc import SQLAlchemyError

from simontalk_api.config import Settings
from simontalk_api.db import create_database
from simontalk_api.maintenance import disable_user, issue_invite, issue_reset


def main():
    parser = argparse.ArgumentParser(description="Local SimonTalk account maintenance")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("invite", help="Issue a single-use 72-hour invitation")
    commands.add_parser("reset", help="Issue a 15-minute reset grant").add_argument("username")
    commands.add_parser("disable", help="Disable an account and revoke sessions").add_argument(
        "username"
    )
    args = parser.parse_args()
    engine, factory = create_database(Settings().database_url)
    try:
        with factory.begin() as db:
            if args.command == "invite":
                result = issue_invite(db)
            elif args.command == "reset":
                result = issue_reset(db, args.username)
            else:
                disable_user(db, args.username)
                result = "Account disabled."
        # Single-use credentials are printed once, only after a successful commit.
        print(result)
    except (ValueError, SQLAlchemyError):
        print("Maintenance failed; check account and database availability.", file=sys.stderr)
        raise SystemExit(1) from None
    finally:
        engine.dispose()
