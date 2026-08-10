#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from prepare_env import validate_domain


def main() -> None:
    parser = argparse.ArgumentParser(description="Render TokenFleet Nginx configuration")
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--app-port", type=int, required=True)
    args = parser.parse_args()
    domain = validate_domain(args.domain)
    if not 1024 <= args.app_port <= 65535:
        raise SystemExit("app port must be between 1024 and 65535")
    rendered = args.template.read_text(encoding="utf-8").replace(
        "__TOKENFLEET_DOMAIN__", domain
    ).replace("__TOKENFLEET_APP_PORT__", str(args.app_port))
    if "__TOKENFLEET_" in rendered:
        raise SystemExit("unresolved Nginx template placeholder")
    args.output.write_text(rendered, encoding="utf-8")


if __name__ == "__main__":
    main()
