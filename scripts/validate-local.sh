#!/usr/bin/env bash
set -euo pipefail

command -v terraform >/dev/null 2>&1 || { echo "terraform is required" >&2; exit 1; }

terraform fmt -check -recursive
terraform init -backend=false -input=false
terraform validate

python3 -m py_compile validate_infra.py modules/monitoring/lambda/*.py tests/*.py
python3 -m unittest discover -s tests -v

echo "Local Terraform and Python validation passed."

python -m py_compile modules/monitoring/lambda/*.py
