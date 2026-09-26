#!/usr/bin/env python3
"""Local API-only helper for weekly prices; credentials never enter stdout/argv.

Official research is performed separately. This helper does not guess prices,
execute remote shell commands, clean data or reprice existing priced rows.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

MAX_BYTES = 2 * 1024 * 1024


class MaintenanceError(Exception):
    """Only constant categories and HTTP status may be included in errors."""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def outside_git(path: Path) -> None:
    result = subprocess.run(['git', '-C', str(path.parent.resolve()), 'rev-parse', '--show-toplevel'],
                            capture_output=True)
    if result.returncode == 0:
        raise MaintenanceError('private files must be outside source repositories')


def read_credential(path: Path) -> str:
    outside_git(path)
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'r') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                raise MaintenanceError('credential file must be a private regular file')
            if hasattr(os, 'getuid') and info.st_uid != os.getuid():
                raise MaintenanceError('credential file must belong to the current user')
            token = stream.read(1024).strip()
    except OSError:
        raise MaintenanceError('credential file could not be read safely') from None
    if not re.fullmatch(r'tfprice_[A-Za-z0-9_-]{43}', token):
        raise MaintenanceError('a dedicated price-only credential is required')
    return token


def write_private(path: Path, body: dict) -> None:
    outside_git(path)
    temp = None
    try:
        fd, temp = tempfile.mkstemp(prefix='.price-maintenance-', dir=path.parent)
        with os.fdopen(fd, 'w') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(body, stream, ensure_ascii=False, indent=2)
            stream.write('\n')
        os.replace(temp, path)
    except OSError:
        raise MaintenanceError('private receipt could not be saved') from None
    finally:
        if temp and os.path.exists(temp):
            os.unlink(temp)


class PriceAdminClient:
    def __init__(self, origin: str, token: str, opener=None):
        try:
            parts = urlsplit(origin)
            valid = (parts.scheme == 'https' and parts.hostname and not parts.username
                     and not parts.password and not parts.query and not parts.fragment
                     and parts.path in ('', '/') and parts.port in (None, 443))
        except ValueError:
            valid = False
        if not valid:
            raise MaintenanceError('an HTTPS server origin without credentials or a path is required')
        self._origin, self._token = origin.rstrip('/'), token
        # Never forward a Bearer credential through a redirect, even to another
        # path on the same host. TLS validation remains the standard default.
        self._opener = opener if opener is not None else build_opener(NoRedirect())

    def request(self, endpoint: str, payload: dict | None = None) -> dict:
        allowed = {'missing': '/api/v1/price-management/missing',
                   'versions': '/api/v1/price-management/versions'}
        if endpoint not in allowed:
            raise MaintenanceError('endpoint is outside the price-only workflow')
        data = json.dumps(payload, separators=(',', ':')).encode() if payload is not None else None
        req = Request(self._origin + allowed[endpoint], data=data,
                      headers={'Authorization': 'Bearer ' + self._token, 'Accept': 'application/json',
                               'Content-Type': 'application/json'}, method='POST' if data is not None else 'GET')
        try:
            with self._opener.open(req, timeout=30) as response:
                raw = response.read(MAX_BYTES + 1)
        except HTTPError as exc:
            raise MaintenanceError('price API returned HTTP ' + str(exc.code)) from None
        except (URLError, OSError):
            raise MaintenanceError('price API transport failed') from None
        if len(raw) > MAX_BYTES:
            raise MaintenanceError('price API response exceeded the size bound')
        try:
            body = json.loads(raw)
        except (ValueError, UnicodeError):
            raise MaintenanceError('price API returned invalid JSON') from None
        if not isinstance(body, dict):
            raise MaintenanceError('price API returned an invalid object')
        return body


def import_versions(client: PriceAdminClient, prices: list[dict]) -> dict:
    receipts = []
    for price in prices:
        receipt = client.request('versions', price)
        # Persist only the known receipt fields, never an unexpected server
        # response field that could contain a reflected credential.
        keys = ('price_version_id', 'created', 'effective_from', 'effective_basis', 'backfill', 'catalog_version')
        if any(key not in receipt for key in keys) or set(receipt) != set(keys):
            raise MaintenanceError('price API returned an unexpected import receipt')
        if receipt['backfill'].get('unpriced_only') is not True:
            raise MaintenanceError('price API receipt is outside missing-only scope')
        receipts.append(receipt)
    return {'imported_models': len(receipts), 'created_versions': sum(r['created'] for r in receipts),
            'backfilled_exact_rows': sum(r['backfill']['changed_rows'] for r in receipts), 'receipts': receipts}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', required=True)
    parser.add_argument('--credential-file', type=Path, required=True)
    sub = parser.add_subparsers(dest='action', required=True)
    inventory = sub.add_parser('inventory')
    inventory.add_argument('--output', type=Path, required=True)
    add = sub.add_parser('import')
    add.add_argument('--prices-file', type=Path, required=True)
    add.add_argument('--receipt', type=Path, required=True)
    add.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    try:
        client = PriceAdminClient(args.server, read_credential(args.credential_file))
        if args.action == 'inventory':
            body = client.request('missing')
            if set(body) != {'models', 'retention_cutoff'}:
                raise MaintenanceError('price API returned an unexpected inventory')
            write_private(args.output, body)
            print(json.dumps({'missing_models': len(body['models']), 'inventory_saved': True}))
        else:
            # Validate the destination before any mutation. A receipt failure
            # after successful writes can be retried: imports are idempotent.
            outside_git(args.receipt)
            try:
                raw = args.prices_file.read_bytes()
                if len(raw) > MAX_BYTES:
                    raise ValueError()
                prices = json.loads(raw)
                if not isinstance(prices, list) or not 1 <= len(prices) <= 500 or not all(isinstance(p, dict) for p in prices):
                    raise ValueError()
            except (ValueError, OSError):
                raise MaintenanceError('official price input must be a bounded JSON array') from None
            if not args.apply:
                print(json.dumps({'mode': 'dry-run', 'input_prices': len(prices), 'writes': 0}))
                return 0
            result = import_versions(client, prices)
            write_private(args.receipt, result)
            print(json.dumps({k: v for k, v in result.items() if k != 'receipts'}))
        return 0
    except MaintenanceError as exc:
        print('Price maintenance stopped: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
