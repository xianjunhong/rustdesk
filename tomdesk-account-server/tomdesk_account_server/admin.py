import argparse
import getpass
import json
from pathlib import Path
import secrets
import sqlite3
import sys
import warnings

from .config import Settings
from .service import AccountError, AccountService
from .provision import create_pairs


def read_password() -> str:
    if not sys.stdin.isatty():
        raise ValueError("Use an interactive terminal to enter the password securely.")
    with warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        password = getpass.getpass("Password (12-1024 characters): ")
        repeated = getpass.getpass("Repeat password: ")
    if not secrets.compare_digest(password.encode("utf-8"), repeated.encode("utf-8")):
        raise ValueError("Passwords do not match.")
    return password


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage TomDesk accounts locally; no public registration.")
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create", help="Create an account using a hidden password prompt")
    create.add_argument("username")
    create.add_argument("--display-name", default="")
    create.add_argument("--admin", action="store_true")
    create.add_argument("--role", choices=("controller", "receiver"), default="receiver")
    for name in ("disable", "set-password"):
        commands.add_parser(name).add_argument("username")
    set_role = commands.add_parser("set-role", help="Change an account role and revoke its sessions")
    set_role.add_argument("username")
    set_role.add_argument("role", choices=("controller", "receiver"))
    batch = commands.add_parser("create-pairs", help="Create paired accounts and write a private credentials CSV")
    batch.add_argument("--count", type=int, required=True)
    batch.add_argument("--output", type=Path, required=True)
    commands.add_parser("pairs", help="List account pairs without passwords")
    for name in ("disable-pair", "logout-pair"):
        commands.add_parser(name).add_argument("pair_id")
    commands.add_parser("list", help="List accounts without credentials")
    commands.add_parser("devices", help="List bound device IDs and UUIDs")
    commands.add_parser("unbind", help="Unbind a device and revoke its sessions/tickets").add_argument("id")
    commands.add_parser("create-web-admin", help="Create a separate web administrator").add_argument("username")
    commands.add_parser("disable-web-admin", help="Disable a web administrator and revoke their sessions").add_argument("username")
    args = parser.parse_args()
    try:
        service = AccountService(Settings.from_env())
        if args.command == "create-pairs":
            count = create_pairs(service, args.count, args.output)
            print(f"Created {count} pairs. Credentials saved to {args.output}.")
            return 0
        elif args.command == "pairs":
            print(json.dumps(service.list_pairs(), ensure_ascii=False, indent=2))
            return 0
        elif args.command in ("disable-pair", "logout-pair"):
            service.revoke_pair(args.pair_id, disable=args.command == "disable-pair")
        elif args.command == "create":
            service.create_user(args.username, read_password(), args.display_name, args.admin, args.role)
        elif args.command == "disable":
            service.disable_user(args.username)
        elif args.command == "set-password":
            service.set_password(args.username, read_password())
        elif args.command == "set-role":
            service.set_role(args.username, args.role)
        elif args.command == "unbind":
            service.unbind_device(args.id)
        elif args.command == "create-web-admin":
            from .admin_web import create_web_admin

            create_web_admin(service, args.username, read_password())
        elif args.command == "disable-web-admin":
            from .admin_web import disable_web_admin

            disable_web_admin(service, args.username)
        else:
            rows = service.list_users() if args.command == "list" else service.list_devices()
            print(json.dumps(rows, ensure_ascii=False, indent=2))
            return 0
        print("Done.")
        return 0
    except (AccountError, ValueError, getpass.GetPassWarning) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except sqlite3.Error:
        print("Database operation failed. Check the database and any completed export before retrying.", file=sys.stderr)
        return 1
    except OSError:
        print("Output operation failed. Check the absolute path, permissions, and any completed export.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
