;; Ripo Contract - Complete Commit-Reveal Lottery System

;; Data maps
(define-map commitments principal { commit: (buff 32), revealed: bool, ticket-number: (optional uint) })
(define-map entries uint { participant: principal, ticket: uint })
(define-map winners uint { participant: principal, prize-amount: uint })

;; Phase management variables
(define-data-var commit-phase-end uint u0)
(define-data-var reveal-phase-end uint u0)
(define-data-var contract-owner principal tx-sender)

;; Lottery management variables
(define-data-var entry-counter uint u0)
(define-data-var total-prize-pool uint u0)
(define-data-var entry-fee uint u1000000) ;; 1 STX default
(define-data-var max-participants uint u100)
(define-data-var lottery-finalized bool false)
(define-data-var participant-list (list 100 principal) (list))
(define-data-var revealed-counter uint u0)
(define-data-var reveal-randomness uint u0)
(define-data-var revealed-participants (list 100 principal) (list))

;; Error codes
(define-constant ERR-HASH-MISMATCH (err u1))
(define-constant ERR-NO-COMMITMENT (err u2))
(define-constant ERR-ALREADY-REVEALED (err u3))
(define-constant ERR-COMMIT-PHASE-ENDED (err u4))
(define-constant ERR-NOT-REVEAL-PHASE (err u5))
(define-constant ERR-NOT-AUTHORIZED (err u6))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u7))
(define-constant ERR-MAX-PARTICIPANTS-REACHED (err u8))
(define-constant ERR-LOTTERY-NOT-FINALIZED (err u9))
(define-constant ERR-ALREADY-FINALIZED (err u10))
(define-constant ERR-NO-REVEALS (err u11))
(define-constant ERR-ALREADY-COMMITTED (err u12))
(define-constant ERR-REFUND-UNAVAILABLE (err u13))
(define-constant ERR-NO-REFUNDABLE-ENTRY (err u14))
(define-constant MAX-RANDOM-NUM u4294967296)

;; Helper function to convert single byte to uint
(define-private (byte-to-uint (b (buff 1)))
  (buff-to-uint-le b))

;; Helper function to convert hash to ticket number
(define-private (hash-to-ticket-number (hash (buff 32)))
  (let ((first-byte (unwrap-panic (element-at hash u0)))
        (second-byte (unwrap-panic (element-at hash u1)))
        (third-byte (unwrap-panic (element-at hash u2)))
        (fourth-byte (unwrap-panic (element-at hash u3))))
    (mod (+ (* (byte-to-uint first-byte) u16777216)
            (* (byte-to-uint second-byte) u65536)
            (* (byte-to-uint third-byte) u256)
            (byte-to-uint fourth-byte))
         u1000000)))

;; Helper to derive a broader randomness sample from commitment hashes
(define-private (hash-to-uint32 (hash (buff 32)))
  (let ((first-byte (unwrap-panic (element-at hash u0)))
        (second-byte (unwrap-panic (element-at hash u1)))
        (third-byte (unwrap-panic (element-at hash u2)))
        (fourth-byte (unwrap-panic (element-at hash u3))))
    (+ (* (byte-to-uint first-byte) u16777216)
       (* (byte-to-uint second-byte) u65536)
       (* (byte-to-uint third-byte) u256)
       (byte-to-uint fourth-byte))))

;; Initialize lottery with phases and parameters
(define-public (start-lottery (commit-duration uint) (reveal-duration uint) (fee uint) (max-entries uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (var-get commit-phase-end) u0) ERR-ALREADY-FINALIZED) ;; Ensure not already running
    (var-set commit-phase-end (+ stacks-block-height commit-duration))
    (var-set reveal-phase-end (+ (+ stacks-block-height commit-duration) reveal-duration))
    (var-set entry-fee fee)
    (var-set max-participants max-entries)
    (var-set entry-counter u0)
    (var-set total-prize-pool u0)
    (var-set lottery-finalized false)
    (var-set participant-list (list))
    (var-set revealed-counter u0)
    (var-set reveal-randomness u0)
    (var-set revealed-participants (list))
    (ok true)))

;; Legacy function for backward compatibility
(define-public (start-commit-phase (commit-duration uint) (reveal-duration uint))
  (start-lottery commit-duration reveal-duration (var-get entry-fee) (var-get max-participants)))

;; Enhanced commit function with lottery entry and fee payment
(define-public (commit (c (buff 32)))
  (begin
    (asserts! (< stacks-block-height (var-get commit-phase-end)) ERR-COMMIT-PHASE-ENDED)
    (asserts! (< (var-get entry-counter) (var-get max-participants)) ERR-MAX-PARTICIPANTS-REACHED)
    (asserts! (is-none (map-get? commitments tx-sender)) ERR-ALREADY-COMMITTED)
    
    ;; Transfer entry fee to contract
    (try! (stx-transfer? (var-get entry-fee) tx-sender (as-contract tx-sender)))
    
    ;; Add participant to tracking list
    (var-set participant-list (unwrap! (as-max-len? (append (var-get participant-list) tx-sender) u100) ERR-MAX-PARTICIPANTS-REACHED))
    
    ;; Generate ticket number from commitment hash (using helper function)
    (let ((hash (sha256 c))
          (ticket-num (hash-to-ticket-number hash)))
      (var-set entry-counter (+ (var-get entry-counter) u1))
      (var-set total-prize-pool (+ (var-get total-prize-pool) (var-get entry-fee)))
      (map-set commitments tx-sender { commit: c, revealed: false, ticket-number: (some ticket-num) })
      (map-set entries (var-get entry-counter) { participant: tx-sender, ticket: ticket-num })
      (ok ticket-num))))

;; Enhanced reveal function with ticket validation
(define-public (reveal (nonce (buff 32)))
  (begin
    (asserts! (>= stacks-block-height (var-get commit-phase-end)) ERR-NOT-REVEAL-PHASE)
    (asserts! (< stacks-block-height (var-get reveal-phase-end)) ERR-NOT-REVEAL-PHASE)
    (let ((c (map-get? commitments tx-sender)))
      (match c
        val
          (let ((nonce-hash (sha256 nonce)))
            (begin
              (asserts! (not (get revealed val)) ERR-ALREADY-REVEALED)
              (asserts! (is-eq (get commit val) nonce-hash) ERR-HASH-MISMATCH)
              (map-set commitments tx-sender { 
                commit: (get commit val), 
                revealed: true, 
                ticket-number: (get ticket-number val) 
              })
              (var-set revealed-counter (+ (var-get revealed-counter) u1))
              (var-set reveal-randomness (mod (+ (var-get reveal-randomness) (hash-to-uint32 nonce-hash)) MAX-RANDOM-NUM))
              (var-set revealed-participants (unwrap! (as-max-len? (append (var-get revealed-participants) tx-sender) u100) ERR-MAX-PARTICIPANTS-REACHED))
              (ok true)))
        ERR-NO-COMMITMENT))))

;; Finalize lottery and select winner
(define-public (finalize-lottery)
  (begin
    (asserts! (>= stacks-block-height (var-get reveal-phase-end)) ERR-NOT-REVEAL-PHASE)
    (asserts! (not (var-get lottery-finalized)) ERR-ALREADY-FINALIZED)
    (asserts! (> (var-get revealed-counter) u0) ERR-NO-REVEALS)
    
    ;; Winner is selected from revealed participants using accumulated randomness plus block height
    (let ((revealed-count (var-get revealed-counter))
          (random-base (mod (+ (var-get reveal-randomness) stacks-block-height) revealed-count)))
      (let ((winner (unwrap-panic (element-at (var-get revealed-participants) random-base)))
            (prize (/ (* (var-get total-prize-pool) u90) u100))) ;; 90% of pool to winner
        (map-set winners u1 { participant: winner, prize-amount: prize })
        (try! (as-contract (stx-transfer? prize tx-sender winner)))
        (var-set lottery-finalized true)
        (ok winner)))))

;; Owner can withdraw remaining funds after finalization
(define-public (withdraw-remaining)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (var-get lottery-finalized) ERR-LOTTERY-NOT-FINALIZED)
    (let ((remaining (stx-get-balance (as-contract tx-sender))))
      (and (> remaining u0)
           (try! (as-contract (stx-transfer? remaining tx-sender (var-get contract-owner)))))
      (ok remaining))))

;; Participants can reclaim their entry fee if no reveals occurred and the lottery never finalized
(define-public (claim-refund)
  (let ((participant tx-sender))
    (begin
      (asserts! (>= stacks-block-height (var-get reveal-phase-end)) ERR-NOT-REVEAL-PHASE)
      (asserts! (is-eq (var-get revealed-counter) u0) ERR-REFUND-UNAVAILABLE)
      (asserts! (not (var-get lottery-finalized)) ERR-ALREADY-FINALIZED)
      (let ((c (map-get? commitments participant)))
        (match c
          val
            (begin
              (asserts! (not (get revealed val)) ERR-ALREADY-REVEALED)
              (asserts! (>= (var-get total-prize-pool) (var-get entry-fee)) ERR-INSUFFICIENT-PAYMENT)
              (map-delete commitments participant)
              (var-set total-prize-pool (to-uint (- (to-int (var-get total-prize-pool)) (to-int (var-get entry-fee)))))
              (try! (as-contract (stx-transfer? (var-get entry-fee) tx-sender participant)))
              (ok true))
          ERR-NO-REFUNDABLE-ENTRY)))))

;; Helper function to clear participant commitment
(define-private (clear-participant-commitment (participant principal))
  (begin
    (map-delete commitments participant)
    true))

;; Helper function for fold - clears entry and returns accumulator
(define-private (clear-entry-fold (index uint) (acc bool))
  (begin
    (map-delete entries index)
    acc))

;; Secure reset function with complete data cleanup
(define-public (reset-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (>= stacks-block-height (var-get reveal-phase-end)) ERR-NOT-REVEAL-PHASE)
    
    ;; Clear all participant commitments
    (map clear-participant-commitment (var-get participant-list))
    
    ;; Clear entries up to entry counter using proper fold syntax
    (let ((total-entries (var-get entry-counter)))
      (and (> total-entries u0)
           (fold clear-entry-fold 
                 (list u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11 u12 u13 u14 u15 u16 u17 u18 u19 u20 
                       u21 u22 u23 u24 u25 u26 u27 u28 u29 u30 u31 u32 u33 u34 u35 u36 u37 u38 u39 u40
                       u41 u42 u43 u44 u45 u46 u47 u48 u49 u50 u51 u52 u53 u54 u55 u56 u57 u58 u59 u60
                       u61 u62 u63 u64 u65 u66 u67 u68 u69 u70 u71 u72 u73 u74 u75 u76 u77 u78 u79 u80
                       u81 u82 u83 u84 u85 u86 u87 u88 u89 u90 u91 u92 u93 u94 u95 u96 u97 u98 u99 u100) 
                 true)))
    
    ;; Clear winners
    (map-delete winners u1)
    
    ;; Reset all state variables
    (var-set commit-phase-end u0)
    (var-set reveal-phase-end u0)
    (var-set entry-counter u0)
    (var-set total-prize-pool u0)
    (var-set lottery-finalized false)
    (var-set participant-list (list))
    (var-set revealed-counter u0)
    (var-set reveal-randomness u0)
    (var-set revealed-participants (list))
    
    (ok true)))

;; Emergency cleanup for specific participant (owner only)
(define-public (emergency-clear-participant (participant principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (map-delete commitments participant)
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

(define-read-only (get-lottery-info)
  {
    commit-end: (var-get commit-phase-end),
    reveal-end: (var-get reveal-phase-end),
    current-block: stacks-block-height,
    entry-fee: (var-get entry-fee),
    total-entries: (var-get entry-counter),
    prize-pool: (var-get total-prize-pool),
    max-participants: (var-get max-participants),
    finalized: (var-get lottery-finalized),
    current-phase: (get-current-phase)
  })

(define-read-only (get-winner (winner-id uint))
  (map-get? winners winner-id))

(define-read-only (get-entry (entry-id uint))
  (map-get? entries entry-id))

(define-read-only (get-participant-count)
  (var-get entry-counter))

(define-read-only (verify-reset-complete)
  {
    phases-cleared: (and (is-eq (var-get commit-phase-end) u0) (is-eq (var-get reveal-phase-end) u0)),
    counters-reset: (and (is-eq (var-get entry-counter) u0) (is-eq (var-get total-prize-pool) u0)),
    lottery-reset: (not (var-get lottery-finalized)),
    participant-list-empty: (is-eq (len (var-get participant-list)) u0),
    reveal-state-reset: (and (is-eq (var-get revealed-counter) u0) (is-eq (var-get reveal-randomness) u0)),
    revealed-participants-empty: (is-eq (len (var-get revealed-participants)) u0)
  })
