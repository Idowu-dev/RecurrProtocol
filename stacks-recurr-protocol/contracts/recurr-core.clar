;; Subscription Service Contract
;; A decentralized subscription management system with automatic billing and service access control
;; Competition Project - 100 Lines Clarity Smart Contract

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-SUBSCRIPTION-NOT-FOUND (err u101))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u102))
(define-constant ERR-SUBSCRIPTION-EXPIRED (err u103))
(define-constant ERR-SUBSCRIPTION-ALREADY-ACTIVE (err u104))
(define-constant ERR-INVALID-TIER (err u105))
(define-constant ERR-REFUND-NOT-ALLOWED (err u106))

;; Contract constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant BASIC-TIER-PRICE u50000)    ;; 50k microSTX per month
(define-constant PREMIUM-TIER-PRICE u100000) ;; 100k microSTX per month
(define-constant PRO-TIER-PRICE u200000)     ;; 200k microSTX per month
(define-constant BLOCKS-PER-MONTH u4320)     ;; Approximately 30 days
(define-constant REFUND-GRACE-PERIOD u144)   ;; 1 day in blocks

;; Subscription tiers
(define-constant TIER-BASIC u1)
(define-constant TIER-PREMIUM u2)
(define-constant TIER-PRO u3)

;; Data variables
(define-data-var next-subscription-id uint u1)
(define-data-var total-revenue uint u0)

;; Subscription structure
(define-map subscriptions uint {
  subscriber: principal,
  tier: uint,
  start-block: uint,
  end-block: uint,
  auto-renew: bool,
  total-paid: uint,
  is-active: bool
})

;; User subscription tracking (one active subscription per user)
(define-map user-subscriptions principal uint)

;; Service provider revenue tracking
(define-map provider-earnings principal uint)

;; Get tier price
(define-private (get-tier-price (tier uint))
  (if (is-eq tier TIER-BASIC) BASIC-TIER-PRICE
    (if (is-eq tier TIER-PREMIUM) PREMIUM-TIER-PRICE
      (if (is-eq tier TIER-PRO) PRO-TIER-PRICE u0))))

;; Validate subscription tier
(define-private (is-valid-tier (tier uint))
  (or (is-eq tier TIER-BASIC) (or (is-eq tier TIER-PREMIUM) (is-eq tier TIER-PRO))))

;; Create new subscription
(define-public (create-subscription (tier uint) (auto-renew bool))
  (let (
    (subscription-id (var-get next-subscription-id))
    (tier-price (get-tier-price tier))
    (current-subscription (map-get? user-subscriptions tx-sender))
  )
    (asserts! (is-valid-tier tier) ERR-INVALID-TIER)
    (asserts! (> tier-price u0) ERR-INVALID-TIER)
    (asserts! (is-none current-subscription) ERR-SUBSCRIPTION-ALREADY-ACTIVE)
    
    ;; Process payment
    (try! (stx-transfer? tier-price tx-sender (as-contract tx-sender)))
    
    ;; Create subscription record
    (map-set subscriptions subscription-id {
      subscriber: tx-sender,
      tier: tier,
      start-block: block-height,
      end-block: (+ block-height BLOCKS-PER-MONTH),
      auto-renew: auto-renew,
      total-paid: tier-price,
      is-active: true
    })
    
    ;; Link user to subscription
    (map-set user-subscriptions tx-sender subscription-id)
    
    ;; Update revenue tracking
    (var-set total-revenue (+ (var-get total-revenue) tier-price))
    (var-set next-subscription-id (+ subscription-id u1))
    
    (ok subscription-id)
  )
)

;; Renew existing subscription
(define-public (renew-subscription)
  (let (
    (subscription-id (unwrap! (map-get? user-subscriptions tx-sender) ERR-SUBSCRIPTION-NOT-FOUND))
    (subscription (unwrap! (map-get? subscriptions subscription-id) ERR-SUBSCRIPTION-NOT-FOUND))
    (tier-price (get-tier-price (get tier subscription)))
  )
    (asserts! (get is-active subscription) ERR-SUBSCRIPTION-EXPIRED)
    
    ;; Process payment
    (try! (stx-transfer? tier-price tx-sender (as-contract tx-sender)))
    
    ;; Extend subscription
    (map-set subscriptions subscription-id
      (merge subscription {
        end-block: (+ (get end-block subscription) BLOCKS-PER-MONTH),
        total-paid: (+ (get total-paid subscription) tier-price)
      })
    )
    
    ;; Update revenue
    (var-set total-revenue (+ (var-get total-revenue) tier-price))
    
    (ok true)
  )
)

;; Cancel subscription (with potential refund if within grace period)
(define-public (cancel-subscription)
  (let (
    (subscription-id (unwrap! (map-get? user-subscriptions tx-sender) ERR-SUBSCRIPTION-NOT-FOUND))
    (subscription (unwrap! (map-get? subscriptions subscription-id) ERR-SUBSCRIPTION-NOT-FOUND))
    (blocks-since-start (- block-height (get start-block subscription)))
    (refund-eligible (< blocks-since-start REFUND-GRACE-PERIOD))
  )
    (asserts! (is-eq (get subscriber subscription) tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active subscription) ERR-SUBSCRIPTION-EXPIRED)
    
    ;; Process refund if within grace period
    (if refund-eligible
      (let ((tier-price (get-tier-price (get tier subscription))))
        (try! (as-contract (stx-transfer? tier-price tx-sender (get subscriber subscription))))
        (var-set total-revenue (- (var-get total-revenue) tier-price))
      )
      true
    )
    
    ;; Deactivate subscription
    (map-set subscriptions subscription-id
      (merge subscription { is-active: false })
    )
    
    ;; Remove user subscription link
    (map-delete user-subscriptions tx-sender)
    
    (ok refund-eligible)
  )
)

;; Check if user has active subscription
(define-public (check-access (user principal))
  (match (map-get? user-subscriptions user)
    some-subscription-id (match (map-get? subscriptions some-subscription-id)
      some-subscription (ok (and 
        (get is-active some-subscription)
        (>= (get end-block some-subscription) block-height)
      ))
      ERR-SUBSCRIPTION-NOT-FOUND
    )
    (ok false)
  )
)

;; Auto-renew subscription (callable by anyone, pays subscriber)
(define-public (auto-renew-subscription (user principal))
  (let (
    (subscription-id (unwrap! (map-get? user-subscriptions user) ERR-SUBSCRIPTION-NOT-FOUND))
    (subscription (unwrap! (map-get? subscriptions subscription-id) ERR-SUBSCRIPTION-NOT-FOUND))
    (tier-price (get-tier-price (get tier subscription)))
  )
    (asserts! (get auto-renew subscription) ERR-NOT-AUTHORIZED)
    (asserts! (get is-active subscription) ERR-SUBSCRIPTION-EXPIRED)
    (asserts! (<= (get end-block subscription) block-height) ERR-SUBSCRIPTION-ALREADY-ACTIVE)
    
    ;; Process payment from subscriber
    (try! (stx-transfer? tier-price (get subscriber subscription) (as-contract tx-sender)))
    
    ;; Extend subscription
    (map-set subscriptions subscription-id
      (merge subscription {
        end-block: (+ (get end-block subscription) BLOCKS-PER-MONTH),
        total-paid: (+ (get total-paid subscription) tier-price)
      })
    )
    
    (var-set total-revenue (+ (var-get total-revenue) tier-price))
    (ok true)
  )
)

;; Owner withdraw revenue
(define-public (withdraw-revenue (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= amount (stx-get-balance (as-contract tx-sender))) ERR-INSUFFICIENT-PAYMENT)
    
    (try! (as-contract (stx-transfer? amount tx-sender CONTRACT-OWNER)))
    (ok true)
  )
)

;; Read-only functions
(define-read-only (get-subscription-info (subscription-id uint))
  (map-get? subscriptions subscription-id)
)

(define-read-only (get-user-subscription (user principal))
  (map-get? user-subscriptions user)
)

(define-read-only (get-contract-balance)
  (stx-get-balance (as-contract tx-sender))
)

(define-read-only (get-total-revenue)
  (var-get total-revenue)
)

(define-read-only (get-tier-pricing)
  {
    basic: BASIC-TIER-PRICE,
    premium: PREMIUM-TIER-PRICE,
    pro: PRO-TIER-PRICE
  }
)