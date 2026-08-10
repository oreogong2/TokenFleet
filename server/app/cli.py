from __future__ import annotations

import argparse
import getpass
import json
import os
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from alembic import command
from alembic.config import Config
from sqlalchemy import delete, func, select

from .config import Settings
from .database import build_engine, build_session_factory
from .models import DailyUsage, Organization, User, UserRole
from .security import hash_password


def init_db(settings: Settings) -> None:
    config_path = Path(__file__).resolve().parents[1] / "alembic.ini"
    migration_config = Config(str(config_path))
    migration_config.attributes["database_url"] = settings.database_url
    command.upgrade(migration_config, "head")


def create_admin(settings: Settings, *, org_slug: str, org_name: str, email: str) -> None:
    password = os.getenv("BOOTSTRAP_ADMIN_PASSWORD") or getpass.getpass(
        "Initial administrator password: "
    )
    if len(password) < 12:
        raise SystemExit("administrator password must contain at least 12 characters")
    init_db(settings)
    engine = build_engine(settings.database_url)
    factory = build_session_factory(engine)
    with factory() as session:
        organization = session.scalar(select(Organization).where(Organization.slug == org_slug))
        if organization is None:
            organization = Organization(slug=org_slug, name=org_name)
            session.add(organization)
            session.flush()
        existing = session.scalar(
            select(User).where(User.org_id == organization.id, User.email == email.lower())
        )
        if existing is not None:
            raise SystemExit("administrator email already exists in this organization")
        session.add(
            User(
                org_id=organization.id,
                email=email.lower(),
                role=UserRole.ADMIN,
                password_hash=hash_password(password, settings.pbkdf2_iterations),
            )
        )
        session.commit()


def purge_retention(settings: Settings, *, apply: bool) -> dict[str, object]:
    """Preview or enforce each organization's daily-usage retention policy.

    Scheduling is deliberately external so operators can use their platform's
    auditable cron/job runner. The command is a dry run unless ``--apply`` is
    explicit.
    """

    engine = build_engine(settings.database_url)
    factory = build_session_factory(engine)
    organizations_result: dict[str, dict[str, object]] = {}
    with factory() as session:
        organizations = list(
            session.scalars(select(Organization).order_by(Organization.slug))
        )
        for organization in organizations:
            local_today = datetime.now(ZoneInfo(organization.default_timezone)).date()
            cutoff = local_today - timedelta(days=organization.retention_days)
            predicate = (
                DailyUsage.org_id == organization.id,
                DailyUsage.usage_date < cutoff,
            )
            rows = session.scalar(
                select(func.count()).select_from(DailyUsage).where(*predicate)
            ) or 0
            if apply and rows:
                session.execute(delete(DailyUsage).where(*predicate))
                organization.ledger_version += 1
            organizations_result[organization.slug] = {
                "cutoff_exclusive": cutoff.isoformat(),
                "matched_rows": rows,
                "deleted_rows": rows if apply else 0,
            }
        if apply:
            session.commit()
        else:
            session.rollback()
    return {
        "mode": "apply" if apply else "dry-run",
        "organizations": organizations_result,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="TokenFleet database utilities")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("init-db", help="create all tables (development/bootstrap)")
    admin_parser = subparsers.add_parser("create-admin", help="create an organization admin")
    admin_parser.add_argument("--org-slug", required=True)
    admin_parser.add_argument("--org-name", required=True)
    admin_parser.add_argument("--email", required=True)
    retention_parser = subparsers.add_parser(
        "purge-retention",
        help="preview retention deletions; pass --apply to execute",
    )
    retention_parser.add_argument(
        "--apply",
        action="store_true",
        help="delete matched daily usage (otherwise dry-run only)",
    )
    args = parser.parse_args()
    settings = Settings.from_env()
    if args.command == "init-db":
        init_db(settings)
    elif args.command == "create-admin":
        create_admin(
            settings,
            org_slug=args.org_slug,
            org_name=args.org_name,
            email=args.email,
        )
    elif args.command == "purge-retention":
        print(json.dumps(purge_retention(settings, apply=args.apply), sort_keys=True))


if __name__ == "__main__":
    main()
