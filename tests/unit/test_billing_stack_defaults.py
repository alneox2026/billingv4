from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts" / "billing_stack.sh"


def _bash() -> str:
    git_bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if git_bash.is_file():
        return str(git_bash)
    executable = shutil.which("bash")
    if executable and "\\Windows\\System32\\bash.exe" not in executable:
        return executable
    pytest.skip("bash is required to exercise billing_stack.sh")


def _resolve(root: Path, env: dict[str, str]) -> list[str]:
    command = (
        '. "$1"; resolve_billing_stack "$2" "$3"; '
        'printf "%s\\n" "$BILLING_STACK_NAME" "$BILLING_RESOURCE_PREFIX" '
        '"$DEFAULT_BILLING_SERVICE_NAME" "$DEFAULT_BILLING_SERVICE_ACCOUNT_NAME" '
        '"$DEFAULT_BILLING_RECONCILER_SERVICE_ACCOUNT_NAME" "$DEFAULT_BILLING_IMAGE_NAME" '
        '"$DEFAULT_TF_STATE_PREFIX"'
    )
    result = subprocess.run(
        [_bash(), "-c", command, "billing-stack-test", str(HELPER), str(root), "development"],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, **env},
    )
    return result.stdout.strip().splitlines()


def test_stack_name_from_git_origin_builds_isolated_defaults(tmp_path: Path) -> None:
    subprocess.run(["git", "init", "--quiet", str(tmp_path)], check=True)
    subprocess.run(
        ["git", "-C", str(tmp_path), "config", "remote.origin.url", "https://github.com/example/billing1.git"],
        check=True,
    )

    values = _resolve(tmp_path, {})

    assert values == [
        "billing1",
        "billing1",
        "billing1-api",
        "billing1-sa",
        "billing1-recon-sa",
        "billing1-billing-api",
        "superapp-billing/stacks/billing1/development/terraform/state",
    ]


def test_long_stack_names_use_short_stable_resource_prefix() -> None:
    values = _resolve(ROOT, {"BILLING_STACK_NAME": "very-long-billing-service-name"})

    assert values[0] == "very-long-billing-service-name"
    assert len(values[1]) <= 21
    assert values[2] == f"{values[1]}-api"
    assert values[3] == f"{values[1]}-sa"
    assert len(values[4]) <= 30
    assert values[5] == f"{values[1]}-billing-api"
    assert values[6] == "superapp-billing/stacks/very-long-billing-service-name/development/terraform/state"


def test_deploy_script_uses_stack_isolation_and_terraform_collection_values() -> None:
    script = (ROOT / "scripts" / "cloudshell_deploy_billing.sh").read_text()
    variables = (ROOT / "infra" / "terraform" / "variables.tf").read_text()
    terraform_locals = (ROOT / "infra" / "terraform" / "locals.tf").read_text()

    assert 'source "${SCRIPT_DIR}/billing_stack.sh"' in script or '. "${SCRIPT_DIR}/billing_stack.sh"' in script
    assert 'TF_STATE_PREFIX="${TF_STATE_PREFIX:-${DEFAULT_TF_STATE_PREFIX}}"' in script
    assert '-var="billing_api_service_name=${BILLING_SERVICE_NAME}"' in script
    assert 'if [ -n "${FIRESTORE_CUSTOMER_WALLETS_COLLECTION:-}" ]; then' in script
    assert 'firestore_customer_wallets_collection=${FIRESTORE_CUSTOMER_WALLETS_COLLECTION}' in script
    assert 'SHARE_CENTRAL_BILLING_COLLECTIONS' not in script
    shared_collections = {
        "FIRESTORE_CUSTOMER_WALLETS_COLLECTION": "firestore_customer_wallets_collection",
        "FIRESTORE_WALLET_TRANSACTIONS_COLLECTION": "firestore_wallet_transactions_collection",
        "FIRESTORE_CUSTOMER_BILLING_PERIODS_COLLECTION": "firestore_customer_billing_periods_collection",
        "FIRESTORE_CUSTOMER_BILLING_ACCOUNTS_COLLECTION": "firestore_customer_billing_accounts_collection",
        "FIRESTORE_STRIPE_WEBHOOK_EVENTS_COLLECTION": "firestore_stripe_webhook_events_collection",
        "FIRESTORE_SUBSCRIPTION_CANCELLATION_REQUESTS_COLLECTION": "firestore_subscription_cancellation_requests_collection",
    }
    for environment_name, terraform_name in shared_collections.items():
        assert re.search(
            rf"\b{environment_name}\s*=\s*var\.{terraform_name}\b",
            terraform_locals,
        )
        assert f'if [ -n "${{{environment_name}:-}}" ]; then' in script
        assert f'{terraform_name}=${{{environment_name}}}' in script
        assert f'default     = "{terraform_name.removeprefix("firestore_")[:-len("_collection")]}_v3"' in variables
    assert "ALLOW_SHARED_BILLING_TERRAFORM_STATE" in script


def test_build_script_uses_same_stack_derived_image_name() -> None:
    script = (ROOT / "scripts" / "cloudshell_build_billing.sh").read_text()

    assert '. "${SCRIPT_DIR}/billing_stack.sh"' in script
    assert 'IMAGE_NAME="${IMAGE_NAME:-${DEFAULT_BILLING_IMAGE_NAME}}"' in script
