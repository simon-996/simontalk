import argparse
import json
import sys

from sqlalchemy.exc import SQLAlchemyError

from simontalk_api.backup_bundle import BackupError, check_backup, create_backup
from simontalk_api.config import Settings
from simontalk_api.connections import expire_connection_leases
from simontalk_api.db import create_database
from simontalk_api.deletion_archive import (
    DeletionArchiveError,
    export_deletions,
    read_archive,
    write_archive,
)
from simontalk_api.deletion_restore import replay_deletions
from simontalk_api.maintenance import disable_user, issue_invite, issue_reset
from simontalk_api.practice_maintenance import run_maintenance_batch


def main():
    parser = argparse.ArgumentParser(description="Local SimonTalk maintenance")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("invite", help="Issue a single-use 72-hour invitation")
    commands.add_parser("reset", help="Issue a 15-minute reset grant").add_argument("username")
    commands.add_parser("disable", help="Disable an account and revoke sessions").add_argument(
        "username"
    )
    scan = commands.add_parser(
        "expire-connections", help="Expire business leases without claiming upstream termination"
    )
    scan.add_argument("--limit", type=int, default=100, choices=range(1, 1001), metavar="1..1000")
    cleanup = commands.add_parser(
        "cleanup-preparations", help="Run bounded connection and unused preparation cleanup"
    )
    cleanup.add_argument(
        "--limit", type=int, default=100, choices=range(1, 1001), metavar="1..1000"
    )
    export = commands.add_parser(
        "export-deletions", help="Save a private deletion snapshot separately from the older backup"
    )
    export.add_argument("--output", required=True)
    replay = commands.add_parser(
        "replay-deletions",
        help="Preflight a trusted deletion snapshot; stop API and workers before applying",
    )
    replay.add_argument("--input", required=True)
    replay.add_argument("--apply", action="store_true")
    replay.add_argument("--confirm-database")
    backup = commands.add_parser("backup-create", help="Create a private database snapshot bundle")
    backup.add_argument("--output", required=True)
    backup.add_argument("--pg-dump", default="pg_dump")
    backup.add_argument(
        "--timeout-seconds", type=int, default=30, choices=range(1, 121), metavar="1..120"
    )
    check = commands.add_parser(
        "backup-check", help="Check local integrity only; no database or restore"
    )
    check.add_argument("--input", required=True)
    args = parser.parse_args()
    engine = None
    try:
        if args.command == "backup-check":
            print(json.dumps(check_backup(args.input)))
            return
        engine, factory = create_database(Settings().database_url)
        if args.command == "backup-create":
            print(
                json.dumps(
                    create_backup(
                        factory,
                        args.output,
                        pg_dump=args.pg_dump,
                        timeout_seconds=args.timeout_seconds,
                    )
                )
            )
            return
        if args.command == "export-deletions":
            archive = export_deletions(factory)
            write_archive(args.output, archive)
            print(
                json.dumps(
                    {
                        "archive_hash": archive.content_hash,
                        "receipt_count": len(archive.receipts),
                        "member_count": sum(len(r.members) for r in archive.receipts),
                    }
                )
            )
            return
        if args.command == "replay-deletions":
            archive = read_archive(args.input)
            print(
                json.dumps(
                    replay_deletions(
                        factory, archive, apply=args.apply, confirm_database=args.confirm_database
                    )
                )
            )
            return
        if args.command == "cleanup-preparations":
            counts = run_maintenance_batch(factory, limit=args.limit)
            print(
                f"Expired connection leases: {counts.connections_expired}; "
                f"expired preparations: {counts.preparations_expired}."
            )
            return
        with factory.begin() as db:
            if args.command == "invite":
                result = issue_invite(db)
            elif args.command == "reset":
                result = issue_reset(db, args.username)
            elif args.command == "disable":
                disable_user(db, args.username)
                result = "Account disabled."
            else:
                result = (
                    f"Expired connection leases: {expire_connection_leases(db, limit=args.limit)}."
                )
        # Single-use credentials are printed once, only after a successful commit.
        print(result)
    except BackupError as error:
        print(
            f"Backup maintenance refused ({error.code}); "
            "check the private bundle and tool configuration.",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
    except DeletionArchiveError as error:
        print(
            f"Deletion maintenance refused ({error.code}); "
            "check the trusted archive and target database.",
            file=sys.stderr,
        )
        raise SystemExit(1) from None
    except (ValueError, SQLAlchemyError):
        print("Maintenance failed; check account and database availability.", file=sys.stderr)
        raise SystemExit(1) from None
    finally:
        if engine is not None:
            engine.dispose()
