"""Tests for the shared Firestore transaction boundary."""

from __future__ import annotations

import sys
from types import ModuleType
from typing import Any

from services.billing_api_v3.app.services.firestore_client import run_firestore_transaction


class FakeTransaction:
    def __init__(self) -> None:
        self.committed = False

    def commit(self) -> None:
        self.committed = True


class FakeFirestoreClient:
    def __init__(self) -> None:
        self.created_transaction = FakeTransaction()

    def transaction(self) -> FakeTransaction:
        return self.created_transaction


def test_shared_runner_commits_operation_with_firestore_transactional(
    monkeypatch: Any,
) -> None:
    fake_firestore = ModuleType("google.cloud.firestore")

    def transactional(operation: Any) -> Any:
        def run(transaction: FakeTransaction) -> Any:
            result = operation(transaction)
            transaction.commit()
            return result

        return run

    fake_firestore.transactional = transactional  # type: ignore[attr-defined]
    monkeypatch.setitem(sys.modules, "google.cloud.firestore", fake_firestore)

    client = FakeFirestoreClient()
    result = run_firestore_transaction(
        client,
        lambda transaction: ("executed", transaction is client.created_transaction),
    )

    assert result == ("executed", True)
    assert client.created_transaction.committed is True
