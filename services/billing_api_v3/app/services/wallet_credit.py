"""Atomic, idempotent wallet-credit allocation shared by credit sources.

Call ``apply_wallet_credit_in_transaction`` from inside the caller's Firestore
transaction. The caller must verify the payment/source and use a stable
``transaction_id`` as the wallet transaction document ID.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Mapping

from common.billing import nonnegative_int
from services.billing_api_v3.app.core.errors import BillingApiError
from services.billing_api_v3.app.services.firestore_client import (
    get_transaction_document_snapshot,
)


@dataclass(frozen=True)
class WalletCreditResult:
    applied: bool
    duplicate: bool
    gross_credit_nanos: int
    usage_debt_repaid_nanos: int
    net_credit_nanos: int
    remaining_usage_debt_nanos: int
    available_credit_after_nanos: int | None


def apply_wallet_credit_in_transaction(
    transaction: Any,
    *,
    wallet_ref: Any,
    wallet_transaction_ref: Any,
    transaction_id: str,
    owner_uid: str,
    gross_credit_nanos: int,
    transaction_fields: Mapping[str, Any],
    processed_at: datetime,
) -> WalletCreditResult:
    """Apply a verified credit, paying known usage debt before increasing funds.

    The transaction document is the idempotency marker. Its existence prevents
    duplicate source events from applying credit twice. A legacy wallet without
    ``usage_debt_nanos`` is treated as having zero usage debt.

    Refund/chargeback debt is intentionally not included in this allocation:
    the existing signed ``available_credit_nanos`` and refund handlers retain
    their own recovery/suspension behavior.
    """

    if (
        isinstance(gross_credit_nanos, bool)
        or not isinstance(gross_credit_nanos, int)
        or gross_credit_nanos <= 0
    ):
        raise BillingApiError(
            500,
            "wallet_credit_invalid",
            "Wallet credit amount must be a positive integer.",
        )
    transaction_type = transaction_fields.get("transaction_type")
    if not isinstance(transaction_type, str) or not transaction_type.strip():
        raise BillingApiError(500, "wallet_credit_invalid", "Wallet credit transaction type is required.")

    existing_transaction = get_transaction_document_snapshot(transaction, wallet_transaction_ref)
    if existing_transaction.exists:
        prior = existing_transaction.to_dict() or {}
        if (
            prior.get("owner_uid") != owner_uid
            or prior.get("billing_subject_id") != owner_uid
            or prior.get("currency") != "USD"
            or prior.get("amount_nanos") != gross_credit_nanos
            or prior.get("transaction_type") != transaction_type
        ):
            raise BillingApiError(
                409,
                "wallet_credit_idempotency_conflict",
                "Wallet credit transaction ID was already used for different credit details.",
            )
        return WalletCreditResult(
            applied=False,
            duplicate=True,
            gross_credit_nanos=_stored_nonnegative_int(
                prior.get("gross_credit_nanos", prior.get("amount_nanos", 0))
            ),
            usage_debt_repaid_nanos=_stored_nonnegative_int(prior.get("usage_debt_repaid_nanos", 0)),
            net_credit_nanos=_stored_nonnegative_int(
                prior.get("net_credit_nanos", prior.get("amount_nanos", 0))
            ),
            remaining_usage_debt_nanos=_stored_nonnegative_int(prior.get("remaining_usage_debt_nanos", 0)),
            available_credit_after_nanos=None,
        )

    wallet_snapshot = get_transaction_document_snapshot(transaction, wallet_ref)
    wallet = wallet_snapshot.to_dict() or {}
    if wallet_snapshot.exists:
        if (
            wallet.get("owner_uid") != owner_uid
            or wallet.get("billing_subject_id") != owner_uid
            or wallet.get("currency") != "USD"
        ):
            raise BillingApiError(400, "wallet_invalid", "Wallet record does not match the billing account.")
        available_credit = _signed_int(
            wallet.get("available_credit_nanos", 0),
            field_name="available_credit_nanos",
        )
        lifetime_credited = _stored_nonnegative_int(wallet.get("lifetime_credited_nanos", 0))
        usage_debt = _stored_nonnegative_int(wallet.get("usage_debt_nanos", 0))
        lifetime_debt_repaid = _stored_nonnegative_int(wallet.get("lifetime_usage_debt_repaid_nanos", 0))
    else:
        available_credit = 0
        lifetime_credited = 0
        usage_debt = 0
        lifetime_debt_repaid = 0

    debt_repaid = min(gross_credit_nanos, usage_debt)
    net_credit = gross_credit_nanos - debt_repaid
    remaining_debt = usage_debt - debt_repaid
    new_available = available_credit + net_credit

    transaction_document = {
        **dict(transaction_fields),
        "schema_version": 1,
        "transaction_id": transaction_id,
        "status": "posted",
        "billing_subject_id": owner_uid,
        "owner_uid": owner_uid,
        "wallet_document_id": _wallet_document_id(wallet_ref),
        "currency": "USD",
        # Keep amount_nanos as the legacy gross purchase amount.
        "amount_nanos": gross_credit_nanos,
        "gross_credit_nanos": gross_credit_nanos,
        "usage_debt_repaid_nanos": debt_repaid,
        "net_credit_nanos": net_credit,
        "remaining_usage_debt_nanos": remaining_debt,
        "created_at": processed_at,
    }

    if wallet_snapshot.exists:
        wallet_updates: dict[str, Any] = {
            "available_credit_nanos": new_available,
            "usage_debt_nanos": remaining_debt,
            "lifetime_credited_nanos": lifetime_credited + gross_credit_nanos,
            "lifetime_usage_debt_repaid_nanos": lifetime_debt_repaid + debt_repaid,
            "updated_at": processed_at,
            "last_credit_at": processed_at,
        }
        if debt_repaid:
            wallet_updates["last_usage_debt_repayment_at"] = processed_at

        # Preserve the existing refund-debt recovery rule independently of
        # usage-debt allocation.
        existing_reasons = list(wallet.get("suspension_reasons") or [])
        existing_reason = wallet.get("suspension_reason")
        if existing_reason and existing_reason not in existing_reasons:
            existing_reasons.append(existing_reason)
        if new_available >= 0:
            if "refund_debt" in existing_reasons:
                existing_reasons.remove("refund_debt")
            wallet_updates["suspension_reasons"] = existing_reasons
            if not existing_reasons:
                wallet_updates["status"] = "active"
                wallet_updates["suspension_reason"] = None
            elif existing_reason == "refund_debt":
                wallet_updates["suspension_reason"] = existing_reasons[0]
        transaction.update(wallet_ref, wallet_updates)
    else:
        transaction.create(
            wallet_ref,
            {
                "schema_version": 1,
                "billing_subject_id": owner_uid,
                "owner_uid": owner_uid,
                "currency": "USD",
                "status": "active",
                "available_credit_nanos": new_available,
                "reserved_credit_nanos": 0,
                "settled_usage_nanos": 0,
                "usage_debt_nanos": remaining_debt,
                "lifetime_credited_nanos": gross_credit_nanos,
                "lifetime_usage_debt_repaid_nanos": debt_repaid,
                "created_at": processed_at,
                "updated_at": processed_at,
                "last_credit_at": processed_at,
                "last_usage_debt_repayment_at": processed_at if debt_repaid else None,
            },
        )

    transaction.create(wallet_transaction_ref, transaction_document)
    return WalletCreditResult(
        applied=True,
        duplicate=False,
        gross_credit_nanos=gross_credit_nanos,
        usage_debt_repaid_nanos=debt_repaid,
        net_credit_nanos=net_credit,
        remaining_usage_debt_nanos=remaining_debt,
        available_credit_after_nanos=new_available,
    )


def _stored_nonnegative_int(value: Any) -> int:
    try:
        return nonnegative_int(value, field_name="wallet credit accounting field")
    except ValueError as exc:
        raise BillingApiError(
            500,
            "wallet_credit_record_invalid",
            "Wallet credit accounting data is invalid.",
        ) from exc


def _signed_int(value: Any, *, field_name: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise BillingApiError(500, "wallet_record_invalid", f"Wallet field {field_name} is invalid.")
    return value


def _wallet_document_id(wallet_ref: Any) -> str:
    document_id = getattr(wallet_ref, "id", None) or getattr(wallet_ref, "document_id", None)
    if not isinstance(document_id, str) or not document_id:
        raise BillingApiError(500, "wallet_reference_invalid", "Wallet reference is invalid.")
    return document_id
