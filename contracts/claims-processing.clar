;; Marine Insurance - Claims Processing Contract
;; Handles claim submission, validation, and settlement

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-CLAIM-NOT-FOUND (err u301))
(define-constant ERR-INVALID-INPUT (err u302))
(define-constant ERR-CLAIM-ALREADY-PROCESSED (err u303))
(define-constant ERR-INSUFFICIENT-FUNDS (err u304))

;; Data Variables
(define-data-var next-claim-id uint u1)
(define-data-var claims-adjuster principal CONTRACT-OWNER)
(define-data-var settlement-fund uint u0)

;; Data Maps
(define-map insurance-claims
  { claim-id: uint }
  {
    vessel-id: uint,
    claimant: principal,
    incident-type: (string-ascii 50),
    incident-date: uint,
    incident-location: (string-ascii 100),
    description: (string-ascii 500),
    claimed-amount: uint,
    assessed-amount: uint,
    adjuster: (optional principal),
    evidence-hash: (string-ascii 64),
    status: (string-ascii 20),
    submitted-at: uint,
    processed-at: uint,
    settlement-date: uint
  }
)

(define-map claim-evidence
  { claim-id: uint, evidence-id: uint }
  {
    evidence-type: (string-ascii 50),
    description: (string-ascii 200),
    hash: (string-ascii 64),
    submitted-by: principal,
    submitted-at: uint
  }
)

(define-map claim-assessments
  { claim-id: uint }
  {
    adjuster: principal,
    damage-assessment: (string-ascii 500),
    liability-assessment: (string-ascii 500),
    recommended-amount: uint,
    assessment-date: uint,
    notes: (string-ascii 500)
  }
)

(define-map authorized-adjusters
  { adjuster: principal }
  { authorized: bool, certification: (string-ascii 100) }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (is-claims-adjuster)
  (is-eq tx-sender (var-get claims-adjuster))
)

(define-private (is-authorized-adjuster)
  (default-to false (get authorized (map-get? authorized-adjusters { adjuster: tx-sender })))
)

(define-private (is-claimant (claim-id uint))
  (match (map-get? insurance-claims { claim-id: claim-id })
    claim (is-eq tx-sender (get claimant claim))
    false
  )
)

;; Validation Functions
(define-private (is-valid-incident-type (incident-type (string-ascii 50)))
  (or
    (is-eq incident-type "collision")
    (or (is-eq incident-type "grounding")
    (or (is-eq incident-type "fire")
    (or (is-eq incident-type "theft")
    (or (is-eq incident-type "weather-damage")
    (or (is-eq incident-type "mechanical-failure")
    (is-eq incident-type "other"))))))
  )
)

;; Public Functions

;; Submit insurance claim
(define-public (submit-claim
  (vessel-id uint)
  (incident-type (string-ascii 50))
  (incident-date uint)
  (incident-location (string-ascii 100))
  (description (string-ascii 500))
  (claimed-amount uint)
  (evidence-hash (string-ascii 64))
)
  (let ((claim-id (var-get next-claim-id)))
    (asserts! (is-valid-incident-type incident-type) ERR-INVALID-INPUT)
    (asserts! (> claimed-amount u0) ERR-INVALID-INPUT)
    (asserts! (<= incident-date block-height) ERR-INVALID-INPUT)
    (asserts! (> (len description) u0) ERR-INVALID-INPUT)
    (asserts! (> (len incident-location) u0) ERR-INVALID-INPUT)

    (map-set insurance-claims
      { claim-id: claim-id }
      {
        vessel-id: vessel-id,
        claimant: tx-sender,
        incident-type: incident-type,
        incident-date: incident-date,
        incident-location: incident-location,
        description: description,
        claimed-amount: claimed-amount,
        assessed-amount: u0,
        adjuster: none,
        evidence-hash: evidence-hash,
        status: "submitted",
        submitted-at: block-height,
        processed-at: u0,
        settlement-date: u0
      }
    )

    (var-set next-claim-id (+ claim-id u1))
    (ok claim-id)
  )
)

;; Assign claim to adjuster
(define-public (assign-claim
  (claim-id uint)
  (adjuster principal)
)
  (let ((claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND)))
    (asserts! (or (is-claims-adjuster) (is-contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim) "submitted") ERR-CLAIM-ALREADY-PROCESSED)
    (asserts! (default-to false (get authorized (map-get? authorized-adjusters { adjuster: adjuster }))) ERR-NOT-AUTHORIZED)

    (map-set insurance-claims
      { claim-id: claim-id }
      (merge claim {
        adjuster: (some adjuster),
        status: "under-review"
      })
    )
    (ok true)
  )
)

;; Submit claim assessment
(define-public (submit-assessment
  (claim-id uint)
  (damage-assessment (string-ascii 500))
  (liability-assessment (string-ascii 500))
  (recommended-amount uint)
  (notes (string-ascii 500))
)
  (let ((claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND)))
    (asserts! (is-authorized-adjuster) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim) "under-review") ERR-CLAIM-ALREADY-PROCESSED)
    (asserts! (<= recommended-amount (get claimed-amount claim)) ERR-INVALID-INPUT)

    (map-set claim-assessments
      { claim-id: claim-id }
      {
        adjuster: tx-sender,
        damage-assessment: damage-assessment,
        liability-assessment: liability-assessment,
        recommended-amount: recommended-amount,
        assessment-date: block-height,
        notes: notes
      }
    )

    (map-set insurance-claims
      { claim-id: claim-id }
      (merge claim {
        assessed-amount: recommended-amount,
        status: "assessed",
        processed-at: block-height
      })
    )
    (ok true)
  )
)

;; Approve claim settlement
(define-public (approve-settlement (claim-id uint))
  (let ((claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND)))
    (asserts! (or (is-claims-adjuster) (is-contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status claim) "assessed") ERR-CLAIM-ALREADY-PROCESSED)
    (asserts! (>= (var-get settlement-fund) (get assessed-amount claim)) ERR-INSUFFICIENT-FUNDS)

    ;; Deduct from settlement fund
    (var-set settlement-fund (- (var-get settlement-fund) (get assessed-amount claim)))

    (map-set insurance-claims
      { claim-id: claim-id }
      (merge claim {
        status: "approved",
        settlement-date: block-height
      })
    )
    (ok (get assessed-amount claim))
  )
)

;; Reject claim
(define-public (reject-claim
  (claim-id uint)
  (reason (string-ascii 200))
)
  (let ((claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND)))
    (asserts! (or (is-claims-adjuster) (is-contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (or (is-eq (get status claim) "submitted") (is-eq (get status claim) "under-review")) ERR-CLAIM-ALREADY-PROCESSED)
    (asserts! (> (len reason) u0) ERR-INVALID-INPUT)

    (map-set insurance-claims
      { claim-id: claim-id }
      (merge claim {
        status: "rejected",
        processed-at: block-height
      })
    )
    (ok true)
  )
)

;; Add evidence to claim
(define-public (add-evidence
  (claim-id uint)
  (evidence-id uint)
  (evidence-type (string-ascii 50))
  (description (string-ascii 200))
  (hash (string-ascii 64))
)
  (let ((claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-CLAIM-NOT-FOUND)))
    (asserts! (or (is-claimant claim-id) (is-authorized-adjuster)) ERR-NOT-AUTHORIZED)
    (asserts! (> (len evidence-type) u0) ERR-INVALID-INPUT)
    (asserts! (> (len hash) u0) ERR-INVALID-INPUT)

    (map-set claim-evidence
      { claim-id: claim-id, evidence-id: evidence-id }
      {
        evidence-type: evidence-type,
        description: description,
        hash: hash,
        submitted-by: tx-sender,
        submitted-at: block-height
      }
    )
    (ok true)
  )
)

;; Authorize adjuster
(define-public (authorize-adjuster
  (adjuster principal)
  (certification (string-ascii 100))
)
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (map-set authorized-adjusters
      { adjuster: adjuster }
      { authorized: true, certification: certification }
    )
    (ok true)
  )
)

;; Fund settlement pool
(define-public (fund-settlement-pool (amount uint))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (var-set settlement-fund (+ (var-get settlement-fund) amount))
    (ok (var-get settlement-fund))
  )
)

;; Read-only Functions

(define-read-only (get-claim (claim-id uint))
  (map-get? insurance-claims { claim-id: claim-id })
)

(define-read-only (get-claim-assessment (claim-id uint))
  (map-get? claim-assessments { claim-id: claim-id })
)

(define-read-only (get-claim-evidence (claim-id uint) (evidence-id uint))
  (map-get? claim-evidence { claim-id: claim-id, evidence-id: evidence-id })
)

(define-read-only (is-adjuster-authorized (adjuster principal))
  (default-to false (get authorized (map-get? authorized-adjusters { adjuster: adjuster })))
)

(define-read-only (get-settlement-fund-balance)
  (var-get settlement-fund)
)

(define-read-only (get-next-claim-id)
  (var-get next-claim-id)
)

(define-read-only (get-current-adjuster)
  (var-get claims-adjuster)
)
