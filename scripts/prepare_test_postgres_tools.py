"""Create test-only PostgreSQL clients backed by an existing Docker container."""

import argparse
import re
import shutil
import sys
from pathlib import Path


def prepare_tools(container, output):
    output = Path(output)
    if not re.fullmatch(r"[a-f0-9]{12,64}", container) or not output.is_absolute():
        raise ValueError("A container ID and new absolute output directory are required")
    docker = shutil.which("docker")
    if docker is None:
        raise ValueError("Docker CLI is required")
    output.mkdir(mode=0o700)
    for tool in ("pg_dump", "pg_restore"):
        source = (
            f"#!{sys.executable}\n"
            "import os, sys\n"
            "env = dict(os.environ)\n"
            "if not env.get('PGDATABASE', '').endswith('_test'):\n"
            "    sys.exit('An explicitly configured test database is required')\n"
            f"env.update(PGHOST='127.0.0.1', PGPORT='5432', HOME={str(Path.home())!r})\n"
            f"args = [{docker!r}, 'exec', '-i']\n"
            "for key in ('PGHOST', 'PGPORT', 'PGUSER', 'PGPASSWORD', 'PGDATABASE',\n"
            "            'PGCONNECT_TIMEOUT', 'PGPASSFILE', 'PGSSLMODE',\n"
            "            'PGSSLROOTCERT', 'PGSSLCERT', 'PGSSLKEY', 'PGCHANNELBINDING'):\n"
            "    if key in env:\n"
            "        args.extend(['-e', key])\n"
            f"args.extend([{container!r}, {tool!r}, *sys.argv[1:]])\n"
            f"os.execve({docker!r}, args, env)\n"
        )
        path = output / tool
        with path.open("x") as stream:
            stream.write(source)
        path.chmod(0o700)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    try:
        prepare_tools(args.container, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Test PostgreSQL tool preparation failed ({type(error).__name__}).\n")


if __name__ == "__main__":
    main()
