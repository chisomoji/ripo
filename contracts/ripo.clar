;; Ripo Contract - Improved Commit-Reveal Scheme

;; Data maps
(define-map commitments principal { commit: (buff 32), revealed: bool })
(define-map entries uint { participant: principal, ticket: uint })

;; Phase management variables
(define-data-var commit-phase-end uint u0)
(define-data-var reveal-phase-end uint u0)
(define-data-var contract-owner principal tx-sender)

;; Error codes
(define-constant ERR-HASH-MISMATCH (err u1))
(define-constant ERR-NO-COMMITMENT (err u2))
(define-constant ERR-ALREADY-REVEALED (err u3))
(define-constant ERR-COMMIT-PHASE-ENDED (err u4))
(define-constant ERR-NOT-REVEAL-PHASE (err u5))
(define-constant ERR-NOT-AUTHORIZED (err u6))

;; Initialize phases (only contract owner can call this)
(define-public (start-commit-phase (commit-duration uint) (reveal-duration uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (var-set commit-phase-end (+ stacks-block-height commit-duration))
    (var-set reveal-phase-end (+ (+ stacks-block-height commit-duration) reveal-duration))
    (ok true)))

;; Commit function with phase checking
(define-public (commit (c (buff 32)))
  (begin
    (asserts! (< stacks-block-height (var-get commit-phase-end)) ERR-COMMIT-PHASE-ENDED)
    (map-set commitments tx-sender { commit: c, revealed: false })
    (ok true)))

;; Reveal function with phase checking and double-reveal prevention
(define-public (reveal (nonce (buff 32)))
  (begin
    (asserts! (>= stacks-block-height (var-get commit-phase-end)) ERR-NOT-REVEAL-PHASE)
    (asserts! (< stacks-block-height (var-get reveal-phase-end)) ERR-NOT-REVEAL-PHASE)
    (let ((c (map-get? commitments tx-sender)))
      (match c
        val
          (begin
            (asserts! (not (get revealed val)) ERR-ALREADY-REVEALED)
            (asserts! (is-eq (get commit val) (sha256 nonce)) ERR-HASH-MISMATCH)
            (map-set commitments tx-sender { commit: (get commit val), revealed: true })
            (ok true))
        ERR-NO-COMMITMENT))))

;; Clear state function (only owner can call when phase has ended)
(define-public (reset-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (>= stacks-block-height (var-get reveal-phase-end)) ERR-NOT-REVEAL-PHASE)
    (var-set commit-phase-end u0)
    (var-set reveal-phase-end u0)
    (ok true)))

;; Read-only functions
(define-read-only (get-current-phase)
  (if (< stacks-block-height (var-get commit-phase-end))
    "commit"
    (if (< stacks-block-height (var-get reveal-phase-end))
      "reveal" 
      "ended")))

(define-read-only (get-commitment (user principal))
  (map-get? commitments user))

(define-read-only (get-phase-info)
  {
    commit-end: (var-get commit-phase-end),
    reveal-end: (var-get reveal-phase-end),
    current-block: stacks-block-height
  })