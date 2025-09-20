;; Agricultural Insurance Payout Smart Contract
;; Automated insurance claim processing and payouts based on weather data

;; Error codes
(define-constant ERR_UNAUTHORIZED (err u200))
(define-constant ERR_POLICY_NOT_FOUND (err u201))
(define-constant ERR_POLICY_EXPIRED (err u202))
(define-constant ERR_INSUFFICIENT_FUNDS (err u203))
(define-constant ERR_INVALID_PREMIUM (err u204))
(define-constant ERR_PAYOUT_ALREADY_CLAIMED (err u205))
(define-constant ERR_CONDITIONS_NOT_MET (err u206))
(define-constant ERR_INVALID_COVERAGE (err u207))
(define-constant ERR_POLICY_ALREADY_EXISTS (err u208))
(define-constant ERR_INVALID_DATES (err u209))
(define-constant ERR_WEATHER_DATA_UNAVAILABLE (err u210))

;; Constants
(define-constant MIN_PREMIUM u100000) ;; 0.1 STX in microSTX
(define-constant MAX_COVERAGE u100000000) ;; 100 STX maximum coverage
(define-constant POLICY_DURATION u52560) ;; ~365 days in blocks
(define-constant GRACE_PERIOD u1440) ;; 10 days in blocks
(define-constant DROUGHT_THRESHOLD u500) ;; 5mm rainfall threshold
(define-constant EXCESS_RAIN_THRESHOLD u10000) ;; 100mm threshold
(define-constant EXTREME_TEMP_HIGH 4500) ;; 45 degrees C * 100
(define-constant EXTREME_TEMP_LOW -1000) ;; -10 degrees C * 100
(define-constant PAYOUT_PERCENTAGE u80) ;; 80% of coverage amount

;; Data variables
(define-data-var contract-owner principal tx-sender)
(define-data-var total-policies uint u0)
(define-data-var total-claims uint u0)
(define-data-var total-payouts uint u0)
(define-data-var contract-balance uint u0)

;; Crop types enum (represented as uint)
;; 1: Wheat, 2: Corn, 3: Rice, 4: Soybean, 5: Cotton, 6: Other

;; Policy structure
(define-map insurance-policies
  { policy-id: uint }
  {
    farmer: principal,
    coverage-amount: uint,
    premium-paid: uint,
    crop-type: uint,
    coverage-area: { latitude: int, longitude: int, radius: uint },
    start-date: uint,
    end-date: uint,
    is-active: bool,
    payout-claimed: bool,
    creation-block: uint
  }
)

;; Claim records
(define-map insurance-claims
  { claim-id: uint }
  {
    policy-id: uint,
    farmer: principal,
    claim-amount: uint,
    weather-condition: (string-ascii 50),
    trigger-date: uint,
    processed-date: uint,
    approved: bool,
    payout-amount: uint
  }
)

;; Premium calculations based on risk factors
(define-map risk-factors
  { crop-type: uint, location-zone: uint }
  {
    base-rate: uint, ;; Base premium rate per 1000 STX coverage
    drought-risk: uint, ;; Risk multiplier for drought
    flood-risk: uint, ;; Risk multiplier for flooding
    temperature-risk: uint ;; Risk multiplier for extreme temperatures
  }
)

;; Farmer policy tracking
(define-map farmer-policies
  { farmer: principal }
  {
    active-policies: (list 10 uint),
    total-premiums-paid: uint,
    total-payouts-received: uint,
    claims-history: (list 20 uint)
  }
)

;; Weather trigger events
(define-map weather-triggers
  { policy-id: uint, trigger-date: uint }
  {
    event-type: (string-ascii 20), ;; "drought", "flood", "frost", "hail"
    severity: uint, ;; 1-10 scale
    duration: uint, ;; Duration in days
    eligible-for-payout: bool
  }
)

;; Read-only functions

(define-read-only (get-policy (policy-id uint))
  (map-get? insurance-policies { policy-id: policy-id })
)

(define-read-only (get-claim (claim-id uint))
  (map-get? insurance-claims { claim-id: claim-id })
)

(define-read-only (get-farmer-policies (farmer principal))
  (default-to 
    { active-policies: (list), total-premiums-paid: u0, total-payouts-received: u0, claims-history: (list) }
    (map-get? farmer-policies { farmer: farmer })
  )
)

(define-read-only (get-contract-stats)
  {
    total-policies: (var-get total-policies),
    total-claims: (var-get total-claims),
    total-payouts: (var-get total-payouts),
    contract-balance: (var-get contract-balance),
    owner: (var-get contract-owner)
  }
)

(define-read-only (calculate-premium (coverage-amount uint) (crop-type uint) (risk-zone uint))
  (let (
    (risk-data (default-to 
      { base-rate: u50, drought-risk: u120, flood-risk: u110, temperature-risk: u100 }
      (map-get? risk-factors { crop-type: crop-type, location-zone: risk-zone })
    ))
    (base-premium (/ (* coverage-amount (get base-rate risk-data)) u1000))
    (total-risk (+ (+ (get drought-risk risk-data) (get flood-risk risk-data)) (get temperature-risk risk-data)))
    (risk-adjusted-premium (/ (* base-premium total-risk) u300))
  )
    risk-adjusted-premium
  )
)

(define-read-only (is-policy-active (policy-id uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data (and 
      (get is-active policy-data)
      (<= (get start-date policy-data) block-height)
      (>= (get end-date policy-data) block-height)
    )
    false
  )
)

(define-read-only (check-weather-conditions (policy-id uint) (rainfall uint) (temperature int))
  (let (
    (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) (err u404)))
    (is-drought (< rainfall DROUGHT_THRESHOLD))
    (is-flood (> rainfall EXCESS_RAIN_THRESHOLD))
    (is-extreme-heat (> temperature EXTREME_TEMP_HIGH))
    (is-frost (< temperature EXTREME_TEMP_LOW))
  )
    (ok {
      drought-risk: is-drought,
      flood-risk: is-flood,
      heat-risk: is-extreme-heat,
      frost-risk: is-frost,
      payout-eligible: (or (or is-drought is-flood) (or is-extreme-heat is-frost))
    })
  )
)

(define-read-only (estimate-payout (policy-id uint) (severity uint))
  (match (map-get? insurance-policies { policy-id: policy-id })
    policy-data 
      (let (
        (base-payout (/ (* (get coverage-amount policy-data) PAYOUT_PERCENTAGE) u100))
        (severity-multiplier (if (<= severity u5) u50 u100))
        (final-payout (/ (* base-payout severity-multiplier) u100))
      )
        (ok final-payout)
      )
    (err ERR_POLICY_NOT_FOUND)
  )
)

;; Public functions

(define-public (create-policy 
  (coverage-amount uint)
  (crop-type uint)
  (coverage-area { latitude: int, longitude: int, radius: uint })
  (risk-zone uint)
)
  (let (
    (farmer tx-sender)
    (policy-id (+ (var-get total-policies) u1))
    (premium-amount (calculate-premium coverage-amount crop-type risk-zone))
    (start-date block-height)
    (end-date (+ block-height POLICY_DURATION))
  )
    (asserts! (>= coverage-amount MIN_PREMIUM) ERR_INVALID_COVERAGE)
    (asserts! (<= coverage-amount MAX_COVERAGE) ERR_INVALID_COVERAGE)
    (asserts! (<= crop-type u6) ERR_INVALID_COVERAGE)
    (asserts! (>= premium-amount MIN_PREMIUM) ERR_INVALID_PREMIUM)
    
    ;; Transfer premium to contract
    (try! (stx-transfer? premium-amount farmer (as-contract tx-sender)))
    
    ;; Create policy
    (map-set insurance-policies
      { policy-id: policy-id }
      {
        farmer: farmer,
        coverage-amount: coverage-amount,
        premium-paid: premium-amount,
        crop-type: crop-type,
        coverage-area: coverage-area,
        start-date: start-date,
        end-date: end-date,
        is-active: true,
        payout-claimed: false,
        creation-block: block-height
      }
    )
    
    ;; Update farmer tracking
    (let (
      (farmer-data (get-farmer-policies farmer))
      (updated-policies (unwrap-panic (as-max-len? 
        (append (get active-policies farmer-data) policy-id) u10)))
    )
      (map-set farmer-policies
        { farmer: farmer }
        {
          active-policies: updated-policies,
          total-premiums-paid: (+ (get total-premiums-paid farmer-data) premium-amount),
          total-payouts-received: (get total-payouts-received farmer-data),
          claims-history: (get claims-history farmer-data)
        }
      )
    )
    
    ;; Update contract stats
    (var-set total-policies policy-id)
    (var-set contract-balance (+ (var-get contract-balance) premium-amount))
    
    (ok policy-id)
  )
)

(define-public (submit-claim 
  (policy-id uint)
  (weather-condition (string-ascii 50))
  (rainfall uint)
  (temperature int)
  (severity uint)
)
  (let (
    (farmer tx-sender)
    (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    (claim-id (+ (var-get total-claims) u1))
    (weather-check (unwrap! (check-weather-conditions policy-id rainfall temperature) ERR_CONDITIONS_NOT_MET))
  )
    (asserts! (is-eq farmer (get farmer policy)) ERR_UNAUTHORIZED)
    (asserts! (is-policy-active policy-id) ERR_POLICY_EXPIRED)
    (asserts! (not (get payout-claimed policy)) ERR_PAYOUT_ALREADY_CLAIMED)
    (asserts! (get payout-eligible weather-check) ERR_CONDITIONS_NOT_MET)
    (asserts! (and (>= severity u1) (<= severity u10)) ERR_INVALID_COVERAGE)
    
    ;; Calculate payout amount
    (let (
      (payout-amount (unwrap! (estimate-payout policy-id severity) ERR_CONDITIONS_NOT_MET))
    )
      ;; Create claim record
      (map-set insurance-claims
        { claim-id: claim-id }
        {
          policy-id: policy-id,
          farmer: farmer,
          claim-amount: payout-amount,
          weather-condition: weather-condition,
          trigger-date: block-height,
          processed-date: u0,
          approved: false,
          payout-amount: u0
        }
      )
      
      ;; Record weather trigger
      (map-set weather-triggers
        { policy-id: policy-id, trigger-date: block-height }
        {
          event-type: (unwrap-panic (as-max-len? weather-condition u20)),
          severity: severity,
          duration: u1, ;; Default 1 day, can be updated
          eligible-for-payout: true
        }
      )
      
      (var-set total-claims claim-id)
      (ok claim-id)
    )
  )
)

(define-public (process-payout (claim-id uint))
  (let (
    (claim (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR_POLICY_NOT_FOUND))
    (policy-id (get policy-id claim))
    (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    (farmer (get farmer claim))
    (payout-amount (get claim-amount claim))
  )
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_UNAUTHORIZED)
    (asserts! (not (get approved claim)) ERR_PAYOUT_ALREADY_CLAIMED)
    (asserts! (>= (var-get contract-balance) payout-amount) ERR_INSUFFICIENT_FUNDS)
    
    ;; Process the payout
    (try! (as-contract (stx-transfer? payout-amount tx-sender farmer)))
    
    ;; Update claim record
    (map-set insurance-claims
      { claim-id: claim-id }
      (merge claim {
        processed-date: block-height,
        approved: true,
        payout-amount: payout-amount
      })
    )
    
    ;; Mark policy as claimed
    (map-set insurance-policies
      { policy-id: policy-id }
      (merge policy { payout-claimed: true })
    )
    
    ;; Update farmer records
    (let (
      (farmer-data (get-farmer-policies farmer))
      (updated-claims (unwrap-panic (as-max-len? 
        (append (get claims-history farmer-data) claim-id) u20)))
    )
      (map-set farmer-policies
        { farmer: farmer }
        (merge farmer-data {
          total-payouts-received: (+ (get total-payouts-received farmer-data) payout-amount),
          claims-history: updated-claims
        })
      )
    )
    
    ;; Update contract stats
    (var-set total-payouts (+ (var-get total-payouts) payout-amount))
    (var-set contract-balance (- (var-get contract-balance) payout-amount))
    
    (ok payout-amount)
  )
)

(define-public (cancel-policy (policy-id uint))
  (let (
    (farmer tx-sender)
    (policy (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR_POLICY_NOT_FOUND))
    (refund-amount (/ (get premium-paid policy) u2)) ;; 50% refund
  )
    (asserts! (is-eq farmer (get farmer policy)) ERR_UNAUTHORIZED)
    (asserts! (get is-active policy) ERR_POLICY_EXPIRED)
    (asserts! (not (get payout-claimed policy)) ERR_PAYOUT_ALREADY_CLAIMED)
    (asserts! (< block-height (+ (get start-date policy) GRACE_PERIOD)) ERR_POLICY_EXPIRED)
    
    ;; Process refund
    (try! (as-contract (stx-transfer? refund-amount tx-sender farmer)))
    
    ;; Deactivate policy
    (map-set insurance-policies
      { policy-id: policy-id }
      (merge policy { is-active: false })
    )
    
    ;; Update contract balance
    (var-set contract-balance (- (var-get contract-balance) refund-amount))
    
    (ok refund-amount)
  )
)

(define-public (add-funds (amount uint))
  (begin
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set contract-balance (+ (var-get contract-balance) amount))
    (ok true)
  )
)

(define-public (withdraw-funds (amount uint))
  (let (
    (caller tx-sender)
  )
    (asserts! (is-eq caller (var-get contract-owner)) ERR_UNAUTHORIZED)
    (asserts! (>= (var-get contract-balance) amount) ERR_INSUFFICIENT_FUNDS)
    
    (try! (as-contract (stx-transfer? amount tx-sender caller)))
    (var-set contract-balance (- (var-get contract-balance) amount))
    (ok amount)
  )
)

(define-public (update-risk-factors 
  (crop-type uint)
  (location-zone uint)
  (base-rate uint)
  (drought-risk uint)
  (flood-risk uint)
  (temperature-risk uint)
)
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_UNAUTHORIZED)
    (map-set risk-factors
      { crop-type: crop-type, location-zone: location-zone }
      {
        base-rate: base-rate,
        drought-risk: drought-risk,
        flood-risk: flood-risk,
        temperature-risk: temperature-risk
      }
    )
    (ok true)
  )
)

(define-public (update-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_UNAUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

;; Initialize contract with default risk factors
(begin
  (var-set contract-owner tx-sender)
  ;; Set default risk factors for different crops
  (map-set risk-factors { crop-type: u1, location-zone: u1 } { base-rate: u40, drought-risk: u130, flood-risk: u100, temperature-risk: u110 }) ;; Wheat
  (map-set risk-factors { crop-type: u2, location-zone: u1 } { base-rate: u45, drought-risk: u140, flood-risk: u120, temperature-risk: u100 }) ;; Corn
  (map-set risk-factors { crop-type: u3, location-zone: u1 } { base-rate: u50, drought-risk: u110, flood-risk: u150, temperature-risk: u120 }) ;; Rice
  (map-set risk-factors { crop-type: u4, location-zone: u1 } { base-rate: u42, drought-risk: u125, flood-risk: u110, temperature-risk: u105 }) ;; Soybean
  (map-set risk-factors { crop-type: u5, location-zone: u1 } { base-rate: u55, drought-risk: u160, flood-risk: u130, temperature-risk: u140 }) ;; Cotton
)


;; title: insurance-payout
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

