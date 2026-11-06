"""
data_contracts.py — Canonical Python Data Models and State Machines for Gate G1 (S04)
Mirrors Swift DataContracts.swift for 100% interoperable serialization and validation.
"""

from enum import Enum
from typing import Optional, Dict, Any
from dataclasses import dataclass, field
import datetime
import uuid

class Origin(str, Enum):
    USER = "user"
    VISUAL_MODEL = "visual_model"
    ASR = "asr"
    AUDIO_DETECTOR = "audio_detector"
    OCR = "ocr"
    METADATA = "metadata"
    DERIVED = "derived"

class EpistemicStatus(str, Enum):
    OBSERVED = "observed"
    REPORTED = "reported"
    INFERRED = "inferred"
    UNKNOWN = "unknown"

class ReviewStatus(str, Enum):
    UNREVIEWED = "unreviewed"
    AUTO_CHECKED = "auto_checked"
    NEEDS_REVIEW = "needs_review"
    CONFIRMED = "confirmed"
    REJECTED = "rejected"
    SUPERSEDED = "superseded"

class SupportStatus(str, Enum):
    SUPPORTED = "supported"
    CONTRADICTED = "contradicted"
    INSUFFICIENT = "insufficient"
    DISPUTED = "disputed"

class AllowedUse(str, Enum):
    DIRECT_CLAIM = "direct_claim"
    ATTRIBUTED_OR_QUALIFIED = "attributed_or_qualified"
    ILLUSTRATIVE_ONLY = "illustrative_only"
    EXCLUDE = "exclude"

class ArtifactPublicationState(str, Enum):
    PREPARED = "PREPARED"
    MATERIALIZED = "MATERIALIZED"
    VERIFIED = "VERIFIED"
    COMMITTED = "COMMITTED"

    def can_transition_to(self, next_state: 'ArtifactPublicationState') -> bool:
        allowed = {
            ArtifactPublicationState.PREPARED: {ArtifactPublicationState.MATERIALIZED},
            ArtifactPublicationState.MATERIALIZED: {ArtifactPublicationState.VERIFIED},
            ArtifactPublicationState.VERIFIED: {ArtifactPublicationState.COMMITTED},
            ArtifactPublicationState.COMMITTED: set()
        }
        return next_state in allowed.get(self, set())

class JobStatus(str, Enum):
    QUEUED = "QUEUED"
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"

    def can_transition_to(self, next_state: 'JobStatus') -> bool:
        allowed = {
            JobStatus.QUEUED: {JobStatus.RUNNING, JobStatus.CANCELLED},
            JobStatus.RUNNING: {JobStatus.SUCCEEDED, JobStatus.FAILED, JobStatus.CANCELLED},
            JobStatus.SUCCEEDED: set(),
            JobStatus.FAILED: set(),
            JobStatus.CANCELLED: set()
        }
        return next_state in allowed.get(self, set())

class ContractError(Exception):
    """Raised when an illegal state transition or contract violation occurs."""
    pass

@dataclass
class ClaimRecord:
    workday_id: str
    text: str
    origin: Origin
    epistemic_status: EpistemicStatus
    review_status: ReviewStatus = ReviewStatus.UNREVIEWED
    support_status: SupportStatus = SupportStatus.INSUFFICIENT
    allowed_use: AllowedUse = AllowedUse.EXCLUDE
    claim_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    revision_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    source_revision_id: Optional[str] = None
    time_range: Optional[Dict[str, int]] = None
    confirmation_id: Optional[str] = None
    confidence_raw: Optional[float] = None
    created_at: str = field(default_factory=lambda: datetime.datetime.now(datetime.timezone.utc).isoformat())

    def confirm_user_fact(self, confirmation_id: Optional[str] = None) -> 'ClaimRecord':
        """
        Invariant S04.T2: user_confirmed does NOT change origin to observed.
        Origin stays user, epistemic stays reported.
        """
        return ClaimRecord(
            claim_id=self.claim_id,
            revision_id=str(uuid.uuid4()),
            workday_id=self.workday_id,
            text=self.text,
            origin=self.origin,  # Invariant: does not become visual_model
            epistemic_status=self.epistemic_status,  # Invariant: does not become observed
            review_status=ReviewStatus.CONFIRMED,
            support_status=self.support_status,
            allowed_use=self.allowed_use,
            source_revision_id=self.source_revision_id,
            time_range=self.time_range,
            confirmation_id=confirmation_id or str(uuid.uuid4()),
            confidence_raw=self.confidence_raw
        )

@dataclass
class ArtifactPublicationRecord:
    project_id: str
    job_id: str
    attempt_id: str
    fencing_token: int
    artifact_type: str
    state: ArtifactPublicationState = ArtifactPublicationState.PREPARED
    publication_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    temp_path: Optional[str] = None
    canonical_path: Optional[str] = None
    sha256_hash: Optional[str] = None
    byte_size: Optional[int] = None
    created_at: str = field(default_factory=lambda: datetime.datetime.now(datetime.timezone.utc).isoformat())
    updated_at: str = field(default_factory=lambda: datetime.datetime.now(datetime.timezone.utc).isoformat())

    def transition_to_materialized(self, temp_path: str):
        if not self.state.can_transition_to(ArtifactPublicationState.MATERIALIZED):
            raise ContractError(f"Illegal transition from {self.state} to MATERIALIZED")
        self.temp_path = temp_path
        self.state = ArtifactPublicationState.MATERIALIZED
        self.updated_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

    def transition_to_verified(self, sha256_hash: str, byte_size: int):
        if not self.state.can_transition_to(ArtifactPublicationState.VERIFIED):
            raise ContractError(f"Illegal transition from {self.state} to VERIFIED")
        if len(sha256_hash) != 64:
            raise ContractError("SHA-256 hash must be 64 characters")
        self.sha256_hash = sha256_hash
        self.byte_size = byte_size
        self.state = ArtifactPublicationState.VERIFIED
        self.updated_at = datetime.datetime.now(datetime.timezone.utc).isoformat()

    def transition_to_committed(self, canonical_path: str):
        if not self.state.can_transition_to(ArtifactPublicationState.COMMITTED):
            raise ContractError(f"Illegal transition from {self.state} to COMMITTED")
        self.canonical_path = canonical_path
        self.state = ArtifactPublicationState.COMMITTED
        self.updated_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
