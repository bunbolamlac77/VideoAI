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
class TimeRange:
    start_frame: int
    end_frame: int
    time_base_num: int = 1
    time_base_den: int = 24

    def to_dict(self) -> Dict[str, int]:
        return {
            "start_frame": self.start_frame,
            "end_frame": self.end_frame,
            "time_base_num": self.time_base_num,
            "time_base_den": self.time_base_den
        }

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> 'TimeRange':
        return cls(
            start_frame=int(d["start_frame"]),
            end_frame=int(d["end_frame"]),
            time_base_num=int(d.get("time_base_num", 1)),
            time_base_den=int(d.get("time_base_den", 24))
        )

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
    time_range: Optional[Any] = None
    confirmation_id: Optional[str] = None
    confidence_raw: Optional[float] = None
    created_at: str = field(default_factory=lambda: datetime.datetime.now(datetime.timezone.utc).isoformat())

    def to_dict(self) -> Dict[str, Any]:
        tr_dict = None
        if self.time_range is not None:
            if hasattr(self.time_range, "to_dict"):
                tr_dict = self.time_range.to_dict()
            elif isinstance(self.time_range, dict):
                tr_dict = self.time_range

        return {
            "claim_id": self.claim_id,
            "revision_id": self.revision_id,
            "workday_id": self.workday_id,
            "text": self.text,
            "origin": self.origin.value if hasattr(self.origin, "value") else str(self.origin),
            "epistemic_status": self.epistemic_status.value if hasattr(self.epistemic_status, "value") else str(self.epistemic_status),
            "review_status": self.review_status.value if hasattr(self.review_status, "value") else str(self.review_status),
            "support_status": self.support_status.value if hasattr(self.support_status, "value") else str(self.support_status),
            "allowed_use": self.allowed_use.value if hasattr(self.allowed_use, "value") else str(self.allowed_use),
            "source_revision_id": self.source_revision_id,
            "time_range": tr_dict,
            "confirmation_id": self.confirmation_id,
            "confidence_raw": self.confidence_raw,
            "created_at": self.created_at
        }

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> 'ClaimRecord':
        tr = d.get("time_range")
        if isinstance(tr, dict):
            tr = TimeRange.from_dict(tr)
        return cls(
            claim_id=d["claim_id"],
            revision_id=d["revision_id"],
            workday_id=d["workday_id"],
            text=d["text"],
            origin=Origin(d["origin"]),
            epistemic_status=EpistemicStatus(d["epistemic_status"]),
            review_status=ReviewStatus(d.get("review_status", "unreviewed")),
            support_status=SupportStatus(d.get("support_status", "insufficient")),
            allowed_use=AllowedUse(d.get("allowed_use", "exclude")),
            source_revision_id=d.get("source_revision_id"),
            time_range=tr,
            confirmation_id=d.get("confirmation_id"),
            confidence_raw=d.get("confidence_raw"),
            created_at=d["created_at"]
        )

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

    def to_dict(self) -> Dict[str, Any]:
        return {
            "publication_id": self.publication_id,
            "project_id": self.project_id,
            "job_id": self.job_id,
            "attempt_id": self.attempt_id,
            "fencing_token": self.fencing_token,
            "artifact_type": self.artifact_type,
            "state": self.state.value if hasattr(self.state, "value") else str(self.state),
            "temp_path": self.temp_path,
            "canonical_path": self.canonical_path,
            "sha256_hash": self.sha256_hash,
            "byte_size": self.byte_size,
            "created_at": self.created_at,
            "updated_at": self.updated_at
        }

    @classmethod
    def from_dict(cls, d: Dict[str, Any]) -> 'ArtifactPublicationRecord':
        return cls(
            publication_id=d["publication_id"],
            project_id=d["project_id"],
            job_id=d["job_id"],
            attempt_id=d["attempt_id"],
            fencing_token=int(d["fencing_token"]),
            artifact_type=d["artifact_type"],
            state=ArtifactPublicationState(d["state"]),
            temp_path=d.get("temp_path"),
            canonical_path=d.get("canonical_path"),
            sha256_hash=d.get("sha256_hash"),
            byte_size=d.get("byte_size"),
            created_at=d["created_at"],
            updated_at=d["updated_at"]
        )

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
