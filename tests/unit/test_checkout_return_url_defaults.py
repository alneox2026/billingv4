from pathlib import Path
import re


def test_terraform_checkout_return_defaults_match_flutterflow_routes():
    variables = Path("infra/terraform/variables.tf").read_text(encoding="utf-8")

    expected = {
        "billing_api_checkout_success_url": (
            "https://ceoappdev.flutterflow.app/billing-complete"
            "?session_id={CHECKOUT_SESSION_ID}"
        ),
        "billing_api_checkout_cancel_url": (
            "https://ceoappdev.flutterflow.app/billing/cancel"
        ),
    }
    for variable, url in expected.items():
        block = re.search(
            rf'variable "{re.escape(variable)}"\s*\{{(?P<body>.*?)\n\}}',
            variables,
            re.DOTALL,
        )
        assert block is not None, f"Terraform variable {variable} is missing"
        assert f'default     = "{url}"' in block.group("body")
