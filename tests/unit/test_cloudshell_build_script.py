from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_cloud_shell_build_uses_checked_in_cloud_build_config() -> None:
    script = (ROOT / "scripts" / "cloudshell_build_billing.sh").read_text()
    config = ROOT / "cloudbuild.yaml"

    assert config.is_file()
    assert "--config=\"${BUILD_CONFIG}\"" in script
    assert "--substitutions=\"_IMAGE_TAG=${IMAGE_TAG}\"" in script
    assert "--config=-" not in script


def test_cloud_build_config_builds_billing_api_dockerfile() -> None:
    config = (ROOT / "cloudbuild.yaml").read_text()

    assert (ROOT / "services" / "billing_api_v3" / "Dockerfile").is_file()
    assert "${_IMAGE_TAG}" in config
    assert "services/billing_api_v3/Dockerfile" in config
