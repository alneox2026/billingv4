import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VARIABLES = (ROOT / "infra" / "terraform" / "variables.tf").read_text()


def test_service_account_variables_validate_gcp_id_constraints() -> None:
    for variable_name in (
        "billing_api_service_account_name",
        "billing_reconciler_service_account_name",
    ):
        declaration = VARIABLES.split(f'variable "{variable_name}"', 1)[1].split("\nvariable ", 1)[0]
        assert f"length(var.{variable_name}) >= 6" in declaration
        assert f"length(var.{variable_name}) <= 30" in declaration
        assert "can(regex(\"^[a-z]([-a-z0-9]*[a-z0-9])$\"" in declaration


def test_documented_billing31_reconciler_id_is_valid_and_shorter() -> None:
    too_long = "billing31-billing-reconciler-sa"
    recommended = "billing31-recon-sa"

    assert len(too_long) == 31
    assert 6 <= len(recommended) <= 30
    assert re.fullmatch(r"[a-z]([-a-z0-9]*[a-z0-9])", recommended)
